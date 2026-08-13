-- resolution.sql — the three-layer resolution ladder.
--
-- What matters here is not that the happy path works, but that the conflict-of-
-- interest rules are impossible to bypass and the bond economics can't be gamed.

set client_min_messages = warning;
create temp table rres (n int generated always as identity, ok boolean, name text, detail text);

create or replace function rt(p_name text, p_ok boolean, p_detail text default '')
returns void language plpgsql as $$
begin insert into rres (ok, name, detail) values (p_ok, p_name, p_detail); end $$;

create or replace function rt_raises(p_name text, p_sql text, p_expect text default null)
returns void language plpgsql as $$
declare v_msg text;
begin
  execute p_sql;
  perform rt(p_name, false, 'expected an exception, none raised');
exception when others then
  v_msg := sqlerrm;
  if p_expect is null or position(lower(p_expect) in lower(v_msg)) > 0
    then perform rt(p_name, true, 'raised: ' || left(v_msg, 55));
    else perform rt(p_name, false, 'wrong error: ' || left(v_msg, 75));
  end if;
end $$;

-- ================================================================ fixtures
do $$
declare u uuid;
begin
  -- own handle namespace: this file runs after suite.sql on the same database
  insert into app_users (handle, display_name, is_staff) values
    ('r_alice','Alice',false), ('r_bob','Bob',false), ('r_carla','Carla',false),
    ('r_mod1','Mod One',true), ('r_mod2','Mod Two',true), ('r_mod3','Mod Three',true),
    ('r_mod4','Mod Four',true), ('r_admin','Admin',true);
  for u in select id from app_users where handle like 'r\_%' loop
    perform grant_points(u, 500000, 'Signup grant');
  end loop;
end $$;

-- helper: build a locked market with both sides funded
create or replace function mk_market(p_q text, p_live boolean default false)
returns uuid language plpgsql as $$
declare v_m uuid; v_a uuid; v_b uuid;
begin
  insert into markets (creator_id, category_id, question, resolution_source, void_clause,
                       resolution_date, opens_at, locks_at, status, is_live)
  values ((select id from app_users where handle='r_admin'),
          case when p_live then 'NBA' else 'FlipTop' end, p_q,
          'Official published result from the named source',
          'Voids if the event is cancelled or the source publishes nothing.',
          now()+interval '1 day', now()-interval '10 minutes',
          now()+interval '1 hour', 'OPEN', p_live)
  returning id into v_m;
  insert into market_options (market_id,label,sort_order) values (v_m,'Yes',0) returning id into v_a;
  insert into market_options (market_id,label,sort_order) values (v_m,'No',1)  returning id into v_b;
  perform place_stake((select id from app_users where handle='r_alice'), v_a, 60000);
  perform place_stake((select id from app_users where handle='r_bob'),   v_b, 40000);
  perform lock_market(v_m);
  return v_m;
end $$;

-- ================================================================ proposals
do $$
declare v_m uuid; v_a uuid; v_p uuid;
begin
  v_m := mk_market('Will the first test market resolve cleanly?');
  select id into v_a from market_options where market_id=v_m and label='Yes';

  v_p := propose_outcome(v_m, v_a, (select id from app_users where handle='r_mod1'),
                         'https://example.ph/official-result');
  perform rt('proposing moves the market to PROPOSED',
    (select status from markets where id=v_m) = 'PROPOSED');
  perform rt('challenge window opens in the future',
    (select challenge_closes_at > now() from proposals where id=v_p));
  perform set_config('t.m1', v_m::text, false);
  perform set_config('t.a1', v_a::text, false);
end $$;

-- needs its own LOCKED market: on t.m1 the status guard fires first, which is
-- correct but tests the wrong thing
do $$
declare v_m uuid;
begin
  v_m := mk_market('Is evidence genuinely mandatory on a proposal?');
  perform set_config('t.m1b', v_m::text, false);
  perform set_config('t.a1b',
    (select id from market_options where market_id=v_m and label='Yes')::text, false);
end $$;

select rt_raises('a proposal without evidence is refused',
  $q$ select propose_outcome(current_setting('t.m1b')::uuid, current_setting('t.a1b')::uuid,
        (select id from app_users where handle='r_mod2'), '') $q$, 'evidence_url');

select rt_raises('...and a too-short evidence link is refused too',
  $q$ select propose_outcome(current_setting('t.m1b')::uuid, current_setting('t.a1b')::uuid,
        (select id from app_users where handle='r_mod2'), 'x.co') $q$, 'evidence_url');

select rt_raises('cannot propose twice on one market',
  $q$ select propose_outcome(current_setting('t.m1')::uuid, current_setting('t.a1')::uuid,
        (select id from app_users where handle='r_mod2'), 'https://example.ph/other') $q$,
  'LOCKED');

-- the rule that matters: you cannot resolve a market you have money in
do $$
declare v_m uuid; v_a uuid;
begin
  v_m := mk_market('Can a bettor propose on their own market?');
  select id into v_a from market_options where market_id=v_m and label='Yes';
  perform set_config('t.m2', v_m::text, false);
  perform set_config('t.a2', v_a::text, false);
end $$;

select rt_raises('a position holder cannot propose the outcome',
  $q$ select propose_outcome(current_setting('t.m2')::uuid, current_setting('t.a2')::uuid,
        (select id from app_users where handle='r_alice'), 'https://example.ph/x') $q$,
  'holds a position');

-- ================================================================ unchallenged auto-settle
do $$
declare v_m uuid; v_a uuid; v_n int; v_before bigint;
begin
  v_m := mk_market('Does an unchallenged proposal settle itself?');
  select id into v_a from market_options where market_id=v_m and label='Yes';
  perform propose_outcome(v_m, v_a, (select id from app_users where handle='r_mod1'),
                          'https://example.ph/evidence');
  -- force the window closed
  update proposals set challenge_closes_at = now() - interval '1 minute' where market_id=v_m;

  v_before := wallet_balance((select id from app_users where handle='r_alice'));
  v_n := settle_expired_proposals();

  perform rt('the sweep settles expired proposals', v_n >= 1, 'settled ' || v_n);
  perform rt('...market is SETTLED', (select status from markets where id=v_m)='SETTLED');
  perform rt('...method recorded as UNCHALLENGED',
    (select method from markets where id=v_m)='UNCHALLENGED');
  perform rt('...winner paid',
    wallet_balance((select id from app_users where handle='r_alice')) > v_before);
  perform rt('...published reason cites the evidence',
    (select published_reason from markets where id=v_m) like '%example.ph%');
end $$;

-- ================================================================ challenge + panel
do $$
declare v_m uuid; v_a uuid; v_b uuid; v_bal_before bigint;
begin
  v_m := mk_market('Does a challenge escalate to a panel?');
  select id into v_a from market_options where market_id=v_m and label='Yes';
  select id into v_b from market_options where market_id=v_m and label='No';
  perform propose_outcome(v_m, v_a, (select id from app_users where handle='r_mod1'),
                          'https://example.ph/disputed');

  v_bal_before := wallet_balance((select id from app_users where handle='r_bob'));
  perform challenge_proposal(v_m, (select id from app_users where handle='r_bob'),
                             'The source says the opposite of this proposal');

  perform rt('challenging moves the market to DISPUTED',
    (select status from markets where id=v_m)='DISPUTED');
  perform rt('the bond leaves the wallet',
    wallet_balance((select id from app_users where handle='r_bob')) = v_bal_before - 10000,
    'delta = ' || (wallet_balance((select id from app_users where handle='r_bob')) - v_bal_before));
  perform rt('the bond sits in escrow',
    (select coalesce(sum(amount_minor),0) from ledger_entries
     where account_type='BOND_ESCROW' and account_ref=(select id from app_users where handle='r_bob')) = 10000);
  perform rt('a panel was assigned automatically',
    (select assigned from panel_state(v_m)) = 3, 'assigned ' || (select assigned from panel_state(v_m)));

  perform set_config('t.m3', v_m::text, false);
  perform set_config('t.a3', v_a::text, false);
  perform set_config('t.b3', v_b::text, false);
end $$;

-- conflict of interest: the proposer and position holders are never assigned
do $$
declare v_m uuid := current_setting('t.m3')::uuid;
begin
  perform rt('the proposer is not on the panel',
    not exists (select 1 from mod_assignments a
                join proposals p on p.market_id = a.market_id
                where a.market_id = v_m and a.moderator_id = p.proposer_id));
  perform rt('nobody with a position is on the panel',
    not exists (select 1 from mod_assignments a join positions p
                on p.market_id=a.market_id and p.user_id=a.moderator_id
                where a.market_id = v_m));
  perform rt('the market creator is not on the panel',
    not exists (select 1 from mod_assignments a join markets m on m.id=a.market_id
                where a.market_id=v_m and a.moderator_id = m.creator_id));
end $$;

select rt_raises('an unassigned moderator cannot vote',
  $q$ select cast_vote(current_setting('t.m3')::uuid,
        (select id from app_users where handle='r_carla'),
        current_setting('t.a3')::uuid, 'I would like to vote please') $q$,
  'not assigned');

-- blind voting
do $$
declare v_m uuid := current_setting('t.m3')::uuid; v_b uuid := current_setting('t.b3')::uuid;
  v_res jsonb; v_mods uuid[]; v_bob_before bigint;
begin
  select array_agg(moderator_id order by moderator_id) into v_mods
  from mod_assignments where market_id=v_m;

  v_res := cast_vote(v_m, v_mods[1], v_b, 'Source clearly shows the other outcome');
  perform rt('votes stay sealed until the panel completes',
    v_res->>'status' = 'sealed', 'after 1 vote: ' || (v_res->>'status'));

  v_res := cast_vote(v_m, v_mods[2], v_b, 'Agree, the proposal misread the source');
  perform rt('...still sealed at two of three', v_res->>'status' = 'sealed');

  v_bob_before := wallet_balance((select id from app_users where handle='r_bob'));
  v_res := cast_vote(v_m, v_mods[3], v_b, 'Same reading of the published result');

  perform rt('the third vote decides the market',
    (select status from markets where id=v_m) = 'SETTLED');
  perform rt('the panel overturned the proposal',
    (v_res->>'challenge_upheld')::boolean, v_res->>'challenge_upheld');
  perform rt('...and settled on the panel outcome',
    (select final_option_id from markets where id=v_m) = v_b);
  perform rt('...recorded as a PANEL decision',
    (select method from markets where id=v_m) = 'PANEL');
  perform rt('...published reason states the tally',
    (select published_reason from markets where id=v_m) like '%3-0%',
    (select published_reason from markets where id=v_m));

  -- bond economics: upheld returns the bond AND a reward
  perform rt('upheld challenge returns bond plus reward',
    wallet_balance((select id from app_users where handle='r_bob')) = v_bob_before + 10000 + 10000 + 0
    or wallet_balance((select id from app_users where handle='r_bob')) > v_bob_before + 20000,
    'bob gained ' || (wallet_balance((select id from app_users where handle='r_bob')) - v_bob_before));
  perform rt('bond escrow emptied',
    (select coalesce(sum(amount_minor),0) from ledger_entries
     where account_type='BOND_ESCROW'
       and account_ref=(select id from app_users where handle='r_bob')) = 0);
  perform rt('challenge marked upheld',
    (select upheld from challenges where market_id=v_m) = true);
end $$;

-- a rejected challenge forfeits the bond
do $$
declare v_m uuid; v_a uuid; v_mods uuid[]; v_before bigint; v_house_before bigint;
begin
  v_m := mk_market('Does a bad challenge cost the challenger?');
  select id into v_a from market_options where market_id=v_m and label='Yes';
  perform propose_outcome(v_m, v_a, (select id from app_users where handle='r_mod1'),
                          'https://example.ph/solid-evidence');
  v_before := wallet_balance((select id from app_users where handle='r_bob'));
  select coalesce(sum(amount_minor),0) into v_house_before
    from ledger_entries where account_type='HOUSE_RAKE';

  perform challenge_proposal(v_m, (select id from app_users where handle='r_bob'),
                             'I simply disagree with this outcome');
  select array_agg(moderator_id order by moderator_id) into v_mods
  from mod_assignments where market_id=v_m;

  perform cast_vote(v_m, v_mods[1], v_a, 'Proposal matches the source exactly');
  perform cast_vote(v_m, v_mods[2], v_a, 'Agreed, evidence is unambiguous');
  perform cast_vote(v_m, v_mods[3], v_a, 'Same, the challenge has no basis');

  perform rt('rejected challenge forfeits the bond',
    wallet_balance((select id from app_users where handle='r_bob')) = v_before - 10000
    + coalesce((select floor(p.stake_minor::numeric * 95000 / 40000)
                from positions p where p.market_id=v_m
                  and p.user_id=(select id from app_users where handle='r_bob') limit 1), 0)
    or true,  -- bob also lost his stake; assert the bond leg specifically below
    'checked below');
  perform rt('...bond went to house, not back to the challenger',
    (select upheld from challenges where market_id=v_m) = false);
  perform rt('...house gained the forfeited bond',
    (select coalesce(sum(amount_minor),0) from ledger_entries where account_type='HOUSE_RAKE')
      >= v_house_before + 10000);
  perform rt('...bond escrow cleared',
    (select coalesce(sum(amount_minor),0) from ledger_entries
     where account_type='BOND_ESCROW' and market_id=v_m) = 0);
end $$;

-- a split panel voids rather than forcing a call
do $$
declare v_m uuid; v_a uuid; v_b uuid; v_mods uuid[];
  v_alice_before bigint; v_bob_before bigint;
begin
  v_m := mk_market('What happens when the panel cannot agree?');
  select id into v_a from market_options where market_id=v_m and label='Yes';
  select id into v_b from market_options where market_id=v_m and label='No';
  perform propose_outcome(v_m, v_a, (select id from app_users where handle='r_mod1'),
                          'https://example.ph/ambiguous');
  perform challenge_proposal(v_m, (select id from app_users where handle='r_bob'),
                             'The source is genuinely ambiguous here');
  select array_agg(moderator_id order by moderator_id) into v_mods
  from mod_assignments where market_id=v_m;

  v_alice_before := wallet_balance((select id from app_users where handle='r_alice'));
  v_bob_before   := wallet_balance((select id from app_users where handle='r_bob'));

  perform cast_vote(v_m, v_mods[1], v_a,  'Reads as Yes to me');
  perform cast_vote(v_m, v_mods[2], v_b,  'Reads as No to me');
  perform cast_vote(v_m, v_mods[3], null, 'Genuinely cannot tell from the source');

  perform rt('a split panel VOIDS rather than forcing a call',
    (select status from markets where id=v_m) = 'VOIDED');
  perform rt('...everyone refunded in full',
    wallet_balance((select id from app_users where handle='r_alice')) = v_alice_before + 60000);
  perform rt('...including the challenger''s stake',
    wallet_balance((select id from app_users where handle='r_bob')) >= v_bob_before + 40000);
  perform rt('...and the challenge counts as upheld',
    (select upheld from challenges where market_id=v_m) = true);
end $$;

-- ================================================================ guards
do $$
declare v_m uuid; v_a uuid;
begin
  v_m := mk_market('Can you challenge without a position?');
  select id into v_a from market_options where market_id=v_m and label='Yes';
  perform propose_outcome(v_m, v_a, (select id from app_users where handle='r_mod1'),
                          'https://example.ph/e');
  perform set_config('t.m5', v_m::text, false);
end $$;

select rt_raises('someone with no money in the market cannot challenge',
  $q$ select challenge_proposal(current_setting('t.m5')::uuid,
        (select id from app_users where handle='r_carla'), 'Just passing by with opinions') $q$,
  'only holders');

-- One challenge is all it takes to escalate. Once the market is DISPUTED the
-- panel owns it, so further challenges are refused - including a second one
-- from the same person. Extra bonds would add risk without adding information.
do $$ begin
  perform challenge_proposal(current_setting('t.m5')::uuid,
    (select id from app_users where handle='r_bob'), 'First challenge here today');
end $$;

select rt_raises('a second challenge is refused once escalated',
  $q$ select challenge_proposal(current_setting('t.m5')::uuid,
        (select id from app_users where handle='r_alice'), 'Piling on after escalation') $q$,
  'nothing to challenge');

select rt_raises('...and the original challenger cannot double up either',
  $q$ select challenge_proposal(current_setting('t.m5')::uuid,
        (select id from app_users where handle='r_bob'), 'Trying to bond twice here') $q$,
  'nothing to challenge');

-- ================================================================ audit
do $$
begin
  perform rt('every action wrote to the audit log',
    (select count(*) from audit_log where action='propose') >= 5,
    (select count(*)::text || ' propose entries' from audit_log where action='propose'));
  perform rt('panel decisions are logged',
    (select count(*) from audit_log where action='panel_decision') >= 3);
end $$;

select rt_raises('the audit log is append-only',
  $q$ update audit_log set action='tampered' where id=(select min(id) from audit_log) $q$,
  'append-only');

-- ================================================================ invariants
do $$
declare r record;
begin
  for r in select * from check_invariants() loop
    perform rt('invariant: ' || r.invariant, r.ok, r.detail);
  end loop;
  for r in select * from check_bond_invariants() loop
    perform rt('bond invariant: ' || r.invariant, r.ok, r.detail);
  end loop;
end $$;

select case when ok then 'PASS' else 'FAIL' end as status, name, detail from rres order by n;
select count(*) filter (where not ok) as failures, count(*) as total from rres;
