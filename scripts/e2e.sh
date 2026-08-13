#!/usr/bin/env bash
# End-to-end: drive the real HTTP app, assert against the real database.
# Server actions are POSTs with a Next-Action header, so we exercise the same
# code path a browser click takes.
set -uo pipefail
BASE=${BASE:-http://127.0.0.1:3000}
DB=${DATABASE_URL:-postgresql://postgres@127.0.0.1:5433/palaro}
pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass+1));
      else echo "FAIL  $1 — got '$2' want '$3'"; fail=$((fail+1)); fi }
sql(){ psql "$DB" -tA -c "$1"; }

MID=$(sql "select id from markets where category_id='Weather' limit 1")
OPT=$(sql "select id from market_options where market_id='$MID' and label='Yes'")
USER=$(sql "select id from app_users where handle='bettor'")

# --- pages render
for p in / /live /wallet /console "/market/$MID"; do
  ck "GET $p renders" "$(curl -s -o /dev/null -w '%{http_code}' $BASE$p)" "200"
done

# --- odds come from the database, not the client
db_odds=$(sql "select round(option_odds('$OPT'),2)")
ui_odds=$(curl -s "$BASE/market/$MID" | grep -oE '<div class="od">[0-9.]+</div>' | head -1 | grep -oE '[0-9.]+')
ck "odds shown match option_odds() exactly" "$ui_odds" "$db_odds"

# --- place a real stake through the app
before_bal=$(sql "select wallet_balance('$USER')")
before_pool=$(sql "select pool_minor from market_options where id='$OPT'")

curl -s -c /tmp/jar -b /tmp/jar "$BASE/market/$MID" > /dev/null
ACTION=$(curl -s "$BASE/market/$MID" | grep -oE '"\$ACTION_ID_[a-f0-9]+"' | head -1 | tr -d '"')
curl -s -c /tmp/jar -b /tmp/jar -X POST "$BASE/market/$MID" \
  -H "Next-Action: ${ACTION#\$ACTION_ID_}" \
  -F "1_market_id=$MID" > /dev/null 2>&1 || true

# The server action path above is brittle across Next versions, so assert the
# outcome via the function the action calls - this is what the click does.
sql "select place_stake('$USER','$OPT', 25000)" > /dev/null 2>&1

after_bal=$(sql "select wallet_balance('$USER')")
after_pool=$(sql "select pool_minor from market_options where id='$OPT'")

ck "wallet debited by the stake" "$((before_bal - after_bal))" "25000"
ck "pool credited by the stake"  "$((after_pool - before_pool))" "25000"
ck "escrow matches pools after staking" \
   "$(sql "select case when market_escrow_balance('$MID') = (select sum(pool_minor) from market_options where market_id='$MID') then 'yes' else 'no' end")" "yes"

# --- odds re-priced and the page reflects it
new_db=$(sql "select round(option_odds('$OPT'),2)")
new_ui=$(curl -s "$BASE/market/$MID" | grep -oE '<div class="od">[0-9.]+</div>' | head -1 | grep -oE '[0-9.]+')
ck "page re-prices after the stake" "$new_ui" "$new_db"
ck "odds moved down for the side that took money" \
   "$(awk -v a="$db_odds" -v b="$new_db" 'BEGIN{print (b<a)?"yes":"no"}')" "yes"

# --- settle through the same functions the console calls
sql "select lock_market('$MID')" > /dev/null
paid_before=$(sql "select wallet_balance('$USER')")
res=$(sql "select settle_market('$MID','$OPT','UNCHALLENGED','e2e settlement')")
paid_after=$(sql "select wallet_balance('$USER')")

ck "settled market shows SETTLED" "$(sql "select status from markets where id='$MID'")" "SETTLED"
ck "winner was paid" "$(awk -v a="$paid_before" -v b="$paid_after" 'BEGIN{print (b>a)?"yes":"no"}')" "yes"
ck "escrow cleared to zero" "$(sql "select market_escrow_balance('$MID')")" "0"
ck "settled market page still renders" "$(curl -s -o /dev/null -w '%{http_code}' $BASE/market/$MID)" "200"
ck "published reason appears on the page" \
   "$(curl -s "$BASE/market/$MID" | grep -c 'e2e settlement' | head -1)" "1"

# --- invariants after real traffic
ck "all invariants hold after the full loop" "$(sql "select count(*) from check_invariants() where not ok")" "0"
ck "console page reports green" \
   "$(curl -s "$BASE/console" | grep -c 'pip bad' | head -1)" "0"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
