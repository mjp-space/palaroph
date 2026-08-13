#!/usr/bin/env bash
# Concurrency tests. These need genuinely parallel sessions, so they can't live
# in suite.sql. This is where a missing FOR UPDATE lock shows up as free money.
set -uo pipefail
export PGHOST=${PGHOST:-/tmp/pgrun} PGPORT=${PGPORT:-5433} PGUSER=${PGUSER:-postgres}
export PGPASSWORD=${PGPASSWORD:-}
DB=palaro_conc
pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass+1));
      else echo "FAIL  $1 — got '$2', want '$3'"; fail=$((fail+1)); fi }

dropdb --if-exists $DB 2>/dev/null; createdb $DB
for f in supabase/migrations/*.sql; do psql -q -d $DB -v ON_ERROR_STOP=1 -f "$f" >/dev/null; done

# ---------------------------------------------------------------- fixture
psql -q -d $DB <<'SQL' >/dev/null
insert into app_users (handle, display_name) values ('racer','Racer'),('crowd','Crowd');
select grant_points((select id from app_users where handle='racer'), 10000, 'exactly one bet''s worth');
select grant_points((select id from app_users where handle='crowd'), 10000000, 'deep pockets');
insert into markets (id, creator_id, category_id, question, resolution_source, void_clause,
                     resolution_date, opens_at, locks_at, status)
values ('11111111-1111-1111-1111-111111111111',
        (select id from app_users where handle='racer'),'NBA',
        'Who wins this quarter of the race test?','Official play-by-play',
        'Voids if abandoned.', now()+interval '1 day', now()-interval '1 minute',
        now()+interval '1 hour','OPEN');
insert into market_options (id, market_id, label) values
 ('22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111','A'),
 ('33333333-3333-3333-3333-333333333333','11111111-1111-1111-1111-111111111111','B');
SQL

# ------------------------------------------------- 1. double-spend the last peso
# Racer has exactly ₱100. Fire two ₱100 stakes at once; exactly one must win.
for i in 1 2; do
  psql -q -d $DB -tA -c "select place_stake(
      (select id from app_users where handle='racer'),
      '22222222-2222-2222-2222-222222222222', 10000)" \
    >/tmp/race_$i.out 2>/tmp/race_$i.err &
done
wait
ok_count=$(grep -c . /tmp/race_1.out /tmp/race_2.out 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')
ck "concurrent double-spend: exactly one stake succeeds" "$ok_count" "1"

bal=$(psql -d $DB -tA -c "select wallet_balance((select id from app_users where handle='racer'))")
ck "loser's balance untouched (no negative wallet)" "$bal" "0"

err=$(cat /tmp/race_1.err /tmp/race_2.err 2>/dev/null | grep -c "insufficient balance")
ck "the losing session was refused for insufficient funds" "$err" "1"

# ------------------------------------------------- 2. no lost updates under load
# 30 concurrent stakes from a funded account. The denormalised pool must equal
# the sum of positions exactly — a lost update here is silent money loss.
for i in $(seq 1 30); do
  opt=$([ $((i % 2)) -eq 0 ] && echo '22222222-2222-2222-2222-222222222222' \
                             || echo '33333333-3333-3333-3333-333333333333')
  psql -q -d $DB -tA -c "select place_stake(
      (select id from app_users where handle='crowd'), '$opt', 1000)" >/dev/null 2>&1 &
done
wait

drift=$(psql -d $DB -tA -c "
  select count(*) from market_options o
  where o.pool_minor <> (select coalesce(sum(p.stake_minor),0) from positions p where p.option_id=o.id)")
ck "30 concurrent stakes: no lost updates in pool_minor" "$drift" "0"

escrow_ok=$(psql -d $DB -tA -c "
  select case when market_escrow_balance('11111111-1111-1111-1111-111111111111')
    = (select sum(pool_minor) from market_options
       where market_id='11111111-1111-1111-1111-111111111111') then 'yes' else 'no' end")
ck "escrow still equals pools after the burst" "$escrow_ok" "yes"

# ------------------------------------------------- 3. settle races a late stake
# A stake landing mid-settlement must not slip into a market being paid out.
psql -q -d $DB -c "select lock_market('11111111-1111-1111-1111-111111111111')" >/dev/null 2>&1
(psql -q -d $DB -tA -c "select settle_market('11111111-1111-1111-1111-111111111111',
   '22222222-2222-2222-2222-222222222222','UNCHALLENGED','race test')" >/dev/null 2>&1) &
(psql -q -d $DB -tA -c "select place_stake((select id from app_users where handle='crowd'),
   '22222222-2222-2222-2222-222222222222', 1000)" >/tmp/late.out 2>/tmp/late.err) &
wait
late=$(grep -c . /tmp/late.out 2>/dev/null | head -1)
ck "late stake cannot join a settling market" "${late:-0}" "0"
ck "...and it was refused with a reason" \
   "$(grep -qE 'not accepting|locked' /tmp/late.err && echo yes || echo no)" "yes"

final=$(psql -d $DB -tA -c "select market_escrow_balance('11111111-1111-1111-1111-111111111111')")
ck "escrow fully cleared after settlement" "$final" "0"

inv=$(psql -d $DB -tA -c "select count(*) from check_invariants() where not ok")
ck "all invariants hold after the concurrency run" "$inv" "0"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
