-- Demo data for the app. Play money only.
-- Idempotent: safe to run repeatedly.

insert into app_users (handle, display_name, email, is_staff, verified_creator) values
  ('space',   'Space',        'space@x.ph',   true,  false),
  ('rences',  'Kuya Rences',  'rences@x.ph',  false, true),
  ('titojun', 'TitoJun',      'titojun@x.ph', false, true),
  ('mhel',    'Ate Mhel',     'mhel@x.ph',    false, false),
  ('bettor',  'Juan (bettor)','juan@x.ph',    false, false)
on conflict (handle) do nothing;

-- ₱5,000 opening grant for anyone who has never been granted
do $$
declare u record;
begin
  for u in select id from app_users loop
    if not exists (select 1 from ledger_entries
                   where account_type='USER_WALLET' and account_ref=u.id and entry_type='GRANT') then
      perform grant_points(u.id, 500000, 'Signup grant');
    end if;
  end loop;
end $$;

do $$
declare
  v_space uuid := (select id from app_users where handle='space');
  v_ren   uuid := (select id from app_users where handle='rences');
  v_jun   uuid := (select id from app_users where handle='titojun');
  v_mhel  uuid := (select id from app_users where handle='mhel');
  v_m uuid; v_a uuid; v_b uuid;
begin
  if exists (select 1 from markets) then return; end if;

  -- 1. FlipTop, both sides funded
  insert into markets (creator_id, category_id, question, resolution_source, resolution_source_url,
                       void_clause, resolution_date, opens_at, locks_at, status)
  values (v_ren,'FlipTop','Will Loonie win his next Isabuhay bout?',
    'Result announced on the official FlipTop Battle League YouTube upload',
    'https://youtube.com/@FlipTopBattles',
    'If the battle is cancelled, postponed past the resolution date, or ends in a draw, this market voids and all stakes are refunded in full.',
    now()+interval '3 days', now()-interval '2 hours', now()+interval '2 days','OPEN')
  returning id into v_m;
  insert into market_options (market_id,label,sort_order) values (v_m,'Loonie',0) returning id into v_a;
  insert into market_options (market_id,label,sort_order) values (v_m,'Challenger',1) returning id into v_b;
  perform place_stake(v_ren,  v_a, 80000);
  perform place_stake(v_jun,  v_a, 40000);
  perform place_stake(v_mhel, v_b, 30000);

  -- 2. Weather, close to even
  insert into markets (creator_id, category_id, question, resolution_source,
                       void_clause, resolution_date, opens_at, locks_at, status)
  values (v_space,'Weather','Will PAGASA name a tropical cyclone entering PAR before Aug 20?',
    'Official PAGASA Severe Weather Bulletin',
    'If PAGASA issues no bulletin covering the window, this market voids and all stakes are refunded.',
    now()+interval '6 days', now()-interval '1 day', now()+interval '5 days','OPEN')
  returning id into v_m;
  insert into market_options (market_id,label,sort_order) values (v_m,'Yes',0) returning id into v_a;
  insert into market_options (market_id,label,sort_order) values (v_m,'No',1) returning id into v_b;
  perform place_stake(v_jun,  v_a, 120000);
  perform place_stake(v_mhel, v_a,  35000);
  perform place_stake(v_ren,  v_b, 140000);

  -- 3. Economy, deliberately one-sided so the "odds show —" state is visible
  insert into markets (creator_id, category_id, question, resolution_source,
                       void_clause, resolution_date, opens_at, locks_at, status)
  values (v_space,'Economy','Will diesel prices roll back next week?',
    'DOE weekly oil price adjustment advisory',
    'If DOE publishes no advisory that week, this market voids.',
    now()+interval '8 days', now()-interval '3 hours', now()+interval '7 days','OPEN')
  returning id into v_m;
  insert into market_options (market_id,label,sort_order) values (v_m,'Rollback',0) returning id into v_a;
  insert into market_options (market_id,label,sort_order) values (v_m,'Increase',1) returning id into v_b;
  perform place_stake(v_mhel, v_b, 25000);

  -- 4. Live micro-market, capped and short-lived
  insert into markets (creator_id, category_id, question, resolution_source,
                       void_clause, resolution_date, opens_at, locks_at, status,
                       is_live, max_stake_minor)
  values (v_space,'NBA','Who wins the third quarter?',
    'Official NBA play-by-play',
    'If the game is abandoned or the quarter is not completed, this market voids.',
    now()+interval '50 minutes', now()-interval '3 minutes', now()+interval '40 minutes',
    'OPEN', true, 100000)
  returning id into v_m;
  insert into market_options (market_id,label,sort_order) values (v_m,'Lakers',0) returning id into v_a;
  insert into market_options (market_id,label,sort_order) values (v_m,'Celtics',1) returning id into v_b;
  perform place_stake(v_ren,  v_a, 45000);
  perform place_stake(v_mhel, v_b, 38000);
end $$;

select 'seeded: ' || count(*) || ' markets' from markets;
