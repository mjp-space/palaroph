-- suite.sql — ledger, parimutuel and lifecycle tests.
-- Emits one row per assertion. Any FAIL is a stop-the-line event.
-- Money is in centavos throughout: 100000 = ₱1,000.00

set client_min_messages = warning;

create temp table results (n int generated always as identity, ok boolean, name text, detail text);

create or replace function t(p_name text, p_ok boolean, p_detail text default '')
returns void language plpgsql as $$
begin insert into results (ok, name, detail) values (p_ok, p_name, p_detail); end $$;

-- expect an exception; record whether the right kind fired
create or replace function t_raises(p_name text, p_sql text, p_expect text default null)
returns void language plpgsql as $$
declare v_msg text;
begin
  execute p_sql;
  perform t(p_name, false, 'expected an exception, none raised');
exception when others then
  v_msg := sqlerrm;
  if p_expect is null or position(lower(p_expect) in lower(v_msg)) > 0 then
    perform t(p_name, true, 'raised: ' || left(v_msg, 60));
  else
    perform t(p_name, false, 'wrong error: ' || left(v_msg, 80));
  end if;
end $$;

-- ================================================================ fixtures
do $$
declare v_u uuid;
begin
  insert into app_users (handle, display_name, email) values
    ('alice','Alice','a@x.ph'), ('bob','Bob','b@x.ph'), ('carla','Carla','c@x.ph'),
    ('dan','Dan','d@x.ph'), ('staff','Staff','s@x.ph');
  for v_u in select id from app_users loop
    perform grant_points(v_u, 500000, 'Signup grant');   -- ₱5,000 each
  end loop;
end $$;

-- ================================================================ grants
do $$
begin
  perform t('grant credits the wallet',
    wallet_balance((select id from app_users where handle='alice')) = 500000,
    'balance = ' || wallet_balance((select id from app_users where handle='alice')));

  perform t('grant source account runs negative (it funds the system)',
    (select balance_minor from account_balances where account_type='PROMO_GRANT') = -2500000);
end $$;

select t_raises('grant rejects a negative amount',
  $q$ select grant_points((select id from app_users where handle='alice'), -100) $q$,
  'positive');

-- ================================================================ market creation guards
select t_raises('market cannot be created without a resolution source',
  $q$ insert into markets (creator_id, category_id, question, resolution_source, void_clause,
        resolution_date, opens_at, locks_at)
      values ((select id from app_users where handle='alice'),'FlipTop',
        'Will Loonie win his next bout?', null, 'Voids if cancelled.',
        now()+interval '2 days', now(), now()+interval '1 day') $q$,
  'null');

select t_raises('market cannot resolve before it locks',
  $q$ insert into markets (creator_id, category_id, question, resolution_source, void_clause,
        resolution_date, opens_at, locks_at)
      values ((select id from app_users where handle='alice'),'FlipTop',
        'Will Loonie win his next bout?','Official FlipTop YouTube upload','Voids if cancelled.',
        now(), now(), now()+interval '1 day') $q$,
  'resolves_after_lock');

select t_raises('a "live" market cannot run for days',
  $q$ insert into markets (creator_id, category_id, question, resolution_source, void_clause,
        resolution_date, opens_at, locks_at, is_live)
      values ((select id from app_users where handle='alice'),'NBA',
        'Who wins this quarter?','Official play-by-play','Voids if abandoned.',
        now()+interval '3 days', now(), now()+interval '2 days', true) $q$,
  'live_is_short');

-- ================================================================ odds
do $$
declare
  v_m uuid; v_a uuid; v_b uuid;
  v_alice uuid := (select id from app_users where handle='alice');
  v_bob   uuid := (select id from app_users where handle='bob');
begin
  insert into markets (creator_id, category_id, question, resolution_source, void_clause,
                       resolution_date, opens_at, locks_at, status)
  values (v_alice,'FlipTop','Will Loonie win his next Isabuhay bout?',
          'Result announced on the official FlipTop Battle League YouTube upload',
          'If the battle is cancelled or ends in a draw, this bet voids and all stakes are refunded.',
          now()+interval '2 days', now()-interval '1 minute', now()+interval '1 day','OPEN')
  returning id into v_m;
  insert into market_options (market_id,label,sort_order) values (v_m,'Loonie',0) returning id into v_a;
  insert into market_options (market_id,label,sort_order) values (v_m,'Opponent',1) returning id into v_b;

  perform t('odds undefined with an empty book', option_odds(v_a) is null);

  perform place_stake(v_alice, v_a, 100000);   -- ₱1,000
  perform t('odds still undefined with only one funded side', option_odds(v_a) is null,
            'no counterparty to win from');

  perform place_stake(v_bob, v_b, 100000);     -- ₱1,000
  perform t('even pool at 5% rake prices both sides 1.90',
            option_odds(v_a) = 1.9000 and option_odds(v_b) = 1.9000,
            'a=' || option_odds(v_a) || ' b=' || option_odds(v_b));

  perform t('escrow equals the pools it holds',
            market_escrow_balance(v_m) = 200000, 'escrow = ' || market_escrow_balance(v_m));
end $$;

-- lopsided book, built from real stakes (never fudge pool_minor - invariant #6
-- catches it, which is precisely what it is there for)
do $$
declare
  v_m uuid; v_a uuid; v_b uuid;
  v_alice uuid := (select id from app_users where handle='alice');
  v_bob   uuid := (select id from app_users where handle='bob');
begin
  insert into markets (creator_id, category_id, question, resolution_source, void_clause,
                       resolution_date, opens_at, locks_at, status)
  values (v_alice,'FlipTop','Will the challenger take round one?',
          'Official FlipTop Battle League YouTube upload','Voids if the event is cancelled.',
          now()+interval '2 days', now()-interval '1 minute', now()+interval '1 day','OPEN')
  returning id into v_m;
  insert into market_options (market_id,label) values (v_m,'Favourite') returning id into v_a;
  insert into market_options (market_id,label) values (v_m,'Underdog')  returning id into v_b;

  perform place_stake(v_alice, v_a, 180000);   -- ₱1,800
  perform place_stake(v_bob,   v_b,  20000);   -- ₱200

  perform t('lopsided book pays the underdog 9.50',
            option_odds(v_b) = 9.5000, 'underdog = ' || option_odds(v_b));
  perform t('...and the favourite about 1.06',
            round(option_odds(v_a),2) = 1.06, 'favourite = ' || option_odds(v_a));

  perform t('escrow still matches pools on a lopsided book',
            market_escrow_balance(v_m) = 200000, 'escrow = ' || market_escrow_balance(v_m));
end $$;

-- the dilution case from the design doc: a 200/100 pool, ₱100 onto the thin side
do $$
declare
  v_m uuid; v_a uuid; v_b uuid;
  v_alice uuid := (select id from app_users where handle='alice');
  v_bob   uuid := (select id from app_users where handle='bob');
begin
  insert into markets (creator_id, category_id, question, resolution_source, void_clause,
                       resolution_date, opens_at, locks_at, status)
  values (v_alice,'Weather','Will Metro Manila see rain before midnight?',
          'Official PAGASA observation','Voids if no observation is published.',
          now()+interval '2 days', now()-interval '1 minute', now()+interval '1 day','OPEN')
  returning id into v_m;
  insert into market_options (market_id,label) values (v_m,'Yes') returning id into v_a;
  insert into market_options (market_id,label) values (v_m,'No')  returning id into v_b;

  perform place_stake(v_alice, v_a, 20000);   -- ₱200
  perform place_stake(v_bob,   v_b, 10000);   -- ₱100

  -- ₱100 onto the ₱100 side: returns ₱190, NOT the naive ₱285 you get from
  -- projecting against pre-stake pools
  perform t('a new stake dilutes its own side (190, not the naive 285)',
            project_return(v_b, 10000) = 19000,
            'projected = ' || project_return(v_b, 10000));

  perform t('...and the naive pre-stake figure would have been 285',
            floor(10000::numeric / 10000 * 30000 * 0.95) = 28500);
end $$;

-- ================================================================ stake guards
do $$
declare
  v_m uuid; v_a uuid; v_b uuid;
  v_dan uuid := (select id from app_users where handle='dan');
begin
  insert into markets (creator_id, category_id, question, resolution_source, void_clause,
                       resolution_date, opens_at, locks_at, status, is_live, max_stake_minor)
  values (v_dan,'NBA','Who wins this quarter?','Official NBA play-by-play',
          'Voids if the game is abandoned.',
          now()+interval '30 minutes', now()-interval '1 minute', now()+interval '20 minutes',
          'OPEN', true, 100000)
  returning id into v_m;
  insert into market_options (market_id,label) values (v_m,'Lakers') returning id into v_a;
  insert into market_options (market_id,label) values (v_m,'Celtics') returning id into v_b;

  perform set_config('test.live_market', v_m::text, false);
  perform set_config('test.live_a', v_a::text, false);
  perform set_config('test.live_b', v_b::text, false);
end $$;

select t_raises('stake above the live cap is refused',
  $q$ select place_stake((select id from app_users where handle='dan'),
        current_setting('test.live_a')::uuid, 200000) $q$, 'cap');

-- on an uncapped market, so the cap does not fire first and mask this
select t_raises('stake beyond the wallet is refused',
  $q$ select place_stake((select id from app_users where handle='dan'),
        (select o.id from market_options o join markets m on m.id=o.market_id
         where m.status='OPEN' and m.max_stake_minor is null limit 1), 99000000) $q$,
  'insufficient');

select t_raises('zero stake is refused',
  $q$ select place_stake((select id from app_users where handle='dan'),
        current_setting('test.live_a')::uuid, 0) $q$, 'positive');

do $$ begin perform lock_market(current_setting('test.live_market')::uuid); end $$;

select t_raises('stake on a LOCKED market is refused',
  $q$ select place_stake((select id from app_users where handle='dan'),
        current_setting('test.live_a')::uuid, 10000) $q$, 'not accepting');

-- server-side clock, not a hidden button
do $$
declare v_m uuid; v_a uuid;
begin
  insert into markets (creator_id, category_id, question, resolution_source, void_clause,
                       resolution_date, opens_at, locks_at, status)
  values ((select id from app_users where handle='dan'),'Weather',
          'Will PAGASA name a cyclone before Aug 20?','Official PAGASA bulletin',
          'Voids if no bulletin covers the window.',
          now()+interval '1 day', now()-interval '2 hours', now()-interval '1 hour','OPEN')
  returning id into v_m;
  insert into market_options (market_id,label) values (v_m,'Yes') returning id into v_a;
  perform set_config('test.past_a', v_a::text, false);
  perform set_config('test.past_m', v_m::text, false);
end $$;

select t_raises('stake after locks_at is refused even while status says OPEN',
  $q$ select place_stake((select id from app_users where handle='dan'),
        current_setting('test.past_a')::uuid, 10000) $q$, 'locked at');

do $$
declare v_n int;
begin
  v_n := lock_due_markets();
  perform t('scheduled sweep locks markets past their time', v_n >= 1, 'locked ' || v_n);
  perform t('...and the overdue market is now LOCKED',
    (select status from markets where id = current_setting('test.past_m')::uuid) = 'LOCKED');
end $$;

-- ================================================================ settlement maths
do $$
declare
  v_m uuid; v_a uuid; v_b uuid; v_res jsonb;
  v_alice uuid := (select id from app_users where handle='alice');
  v_bob   uuid := (select id from app_users where handle='bob');
  v_carla uuid := (select id from app_users where handle='carla');
  v_before bigint;
begin
  insert into markets (creator_id, category_id, question, resolution_source, void_clause,
                       resolution_date, opens_at, locks_at, status)
  values (v_alice,'Economy','Will diesel prices roll back next week?',
          'DOE weekly oil price adjustment advisory','Voids if DOE publishes no advisory.',
          now()+interval '2 days', now()-interval '1 minute', now()+interval '1 day','OPEN')
  returning id into v_m;
  insert into market_options (market_id,label) values (v_m,'Rollback') returning id into v_a;
  insert into market_options (market_id,label) values (v_m,'Increase') returning id into v_b;

  -- genuinely indivisible: three near-equal winners over ₱1,900 payable.
  -- 33333/100000 * 190000 = 63332.7 -> 63332, and the dust must go somewhere.
  perform place_stake(v_alice, v_a, 33333);
  perform place_stake(v_bob,   v_a, 33333);
  perform place_stake(v_carla, v_a, 33334);
  perform place_stake((select id from app_users where handle='dan'), v_b, 100000);

  v_before := wallet_balance(v_alice);
  perform lock_market(v_m);
  v_res := settle_market(v_m, v_a, 'UNCHALLENGED', 'DOE advisory dated today');

  perform t('total pool captured correctly', (v_res->>'total_minor')::bigint = 200000,
            v_res->>'total_minor');
  perform t('rake is exactly 5% of the pool', (v_res->>'rake_minor')::bigint = 10000,
            v_res->>'rake_minor');
  perform t('payable = pool - rake', (v_res->>'payable_minor')::bigint = 190000);
  perform t('effective odds 1.90 for the winning side',
            (v_res->>'effective_odds')::numeric = 1.9000);

  perform t('rounding is swept, never invented',
    (v_res->>'distributed_minor')::bigint + (v_res->>'rounding_swept_minor')::bigint = 190000,
    'distributed ' || (v_res->>'distributed_minor') || ' + dust ' || (v_res->>'rounding_swept_minor'));

  perform t('payouts round DOWN (house never short)',
    (v_res->>'distributed_minor')::bigint <= 190000,
    'distributed = ' || (v_res->>'distributed_minor'));

  perform t('dust exists in this indivisible case',
    (v_res->>'rounding_swept_minor')::bigint > 0, 'dust = ' || (v_res->>'rounding_swept_minor'));

  perform t('escrow is empty after settlement', market_escrow_balance(v_m) = 0,
            'escrow = ' || market_escrow_balance(v_m));

  perform t('winner is paid pro rata',
    wallet_balance(v_alice) - v_before = floor(33333::numeric * 190000 / 100000),
    'alice received ' || (wallet_balance(v_alice) - v_before));

  perform t('house keeps base rake plus the dust',
    (v_res->>'house_total_minor')::bigint
      = 10000 + (v_res->>'rounding_swept_minor')::bigint,
    'house = ' || (v_res->>'house_total_minor'));

  perform t('market records how it was resolved',
    (select method from markets where id=v_m) = 'UNCHALLENGED'
    and (select published_reason from markets where id=v_m) is not null);
end $$;

-- ================================================================ settlement edge cases
do $$
declare
  v_m uuid; v_a uuid; v_b uuid; v_res jsonb;
  v_alice uuid := (select id from app_users where handle='alice');
  v_before bigint;
begin
  -- only one funded side: backers had no counterparty
  insert into markets (creator_id, category_id, question, resolution_source, void_clause,
                       resolution_date, opens_at, locks_at, status)
  values (v_alice,'Weather','Will signal number 3 be raised in Metro Manila?',
          'Official PAGASA bulletin','Voids if no bulletin is issued.',
          now()+interval '2 days', now()-interval '1 minute', now()+interval '1 day','OPEN')
  returning id into v_m;
  insert into market_options (market_id,label) values (v_m,'Yes') returning id into v_a;
  insert into market_options (market_id,label) values (v_m,'No')  returning id into v_b;

  v_before := wallet_balance(v_alice);
  perform place_stake(v_alice, v_a, 50000);
  perform lock_market(v_m);
  v_res := settle_market(v_m, v_a, 'UNCHALLENGED', 'tried to settle a one-sided book');

  perform t('one-sided book voids instead of settling',
    (select status from markets where id=v_m) = 'VOIDED');
  perform t('...and the backer is made whole, no rake',
    wallet_balance(v_alice) = v_before, 'delta = ' || (wallet_balance(v_alice) - v_before));
end $$;

do $$
declare
  v_m uuid; v_a uuid; v_b uuid; v_res jsonb;
  v_alice uuid := (select id from app_users where handle='alice');
  v_bob   uuid := (select id from app_users where handle='bob');
  v_ba bigint; v_bb bigint;
begin
  -- nobody backed the outcome that actually happened
  insert into markets (creator_id, category_id, question, resolution_source, void_clause,
                       resolution_date, opens_at, locks_at, status)
  values (v_alice,'FlipTop','Will the battle end in a draw?',
          'Official FlipTop YouTube upload','Voids if the event is cancelled.',
          now()+interval '2 days', now()-interval '1 minute', now()+interval '1 day','OPEN')
  returning id into v_m;
  insert into market_options (market_id,label) values (v_m,'Yes') returning id into v_a;
  insert into market_options (market_id,label) values (v_m,'No')  returning id into v_b;

  perform place_stake(v_alice, v_a, 20000);
  perform place_stake(v_bob,   v_b, 30000);
  v_ba := wallet_balance(v_alice); v_bb := wallet_balance(v_bob);

  perform lock_market(v_m);
  -- settle on an option nobody funded
  update market_options set pool_minor = 0 where id = v_a;
  update positions set option_id = v_b, stake_minor = 20000 where option_id = v_a;
  update market_options set pool_minor = 50000 where id = v_b;
  v_res := settle_market(v_m, v_a, 'PANEL', 'nobody backed the winner');

  perform t('no stakes on the winning outcome voids the market',
    (select status from markets where id=v_m) = 'VOIDED');
  perform t('...everyone refunded in full',
    wallet_balance(v_alice) = v_ba + 20000 and wallet_balance(v_bob) = v_bb + 30000);
end $$;

do $$
declare
  v_m uuid; v_a uuid; v_b uuid; v_res jsonb;
  v_alice uuid := (select id from app_users where handle='alice');
  v_bob   uuid := (select id from app_users where handle='bob');
  v_ba bigint; v_bb bigint;
begin
  insert into markets (creator_id, category_id, question, resolution_source, void_clause,
                       resolution_date, opens_at, locks_at, status, rake_bps)
  values (v_alice,'FlipTop','Will there be a rematch announced on stage?',
          'Official FlipTop YouTube upload','Voids if the event is cancelled.',
          now()+interval '2 days', now()-interval '1 minute', now()+interval '1 day','OPEN', 500)
  returning id into v_m;
  insert into market_options (market_id,label) values (v_m,'Yes') returning id into v_a;
  insert into market_options (market_id,label) values (v_m,'No')  returning id into v_b;

  perform place_stake(v_alice, v_a, 12345);
  perform place_stake(v_bob,   v_b, 67890);
  v_ba := wallet_balance(v_alice); v_bb := wallet_balance(v_bob);

  perform lock_market(v_m);
  v_res := void_market(v_m, 'Question was ambiguous - no clear source');

  perform t('void refunds the exact stakes',
    wallet_balance(v_alice) = v_ba + 12345 and wallet_balance(v_bob) = v_bb + 67890);
  perform t('void takes ZERO rake', (v_res->>'rake_minor')::bigint = 0);
  perform t('void clears escrow', market_escrow_balance(v_m) = 0);
  perform t('void publishes a reason',
    (select published_reason from markets where id=v_m) is not null);
end $$;

select t_raises('a finished market cannot be settled twice',
  $q$ select settle_market(
        (select id from markets where status='VOIDED' limit 1),
        (select id from market_options where market_id=(select id from markets where status='VOIDED' limit 1) limit 1))
  $q$, 'cannot settle');

-- ================================================================ ledger immutability
select t_raises('ledger rows cannot be UPDATEd',
  $q$ update ledger_entries set amount_minor = 1 where id = (select min(id) from ledger_entries) $q$,
  'append-only');

select t_raises('ledger rows cannot be DELETEd',
  $q$ delete from ledger_entries where id = (select min(id) from ledger_entries) $q$,
  'append-only');

select t_raises('an unbalanced transaction is impossible',
  $q$ select post_entries(gen_random_uuid(), 'STAKE', jsonb_build_array(
        jsonb_build_object('account_type','HOUSE_RAKE','account_ref',null,'amount_minor',500))) $q$,
  'unbalanced');

select t_raises('house accounts cannot carry an account_ref',
  $q$ insert into ledger_entries (txn_id, entry_type, account_type, account_ref, amount_minor)
      values (gen_random_uuid(),'RAKE','HOUSE_RAKE',gen_random_uuid(), 100) $q$,
  'ledger_ref_shape');

-- ================================================================ invariants
do $$
declare r record;
begin
  for r in select * from check_invariants() loop
    perform t('invariant: ' || r.invariant, r.ok, r.detail);
  end loop;
end $$;

-- ================================================================ report
select case when ok then 'PASS' else 'FAIL' end as status, name, detail
from results order by n;

select count(*) filter (where not ok) as failures, count(*) as total from results;
