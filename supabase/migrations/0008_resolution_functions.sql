-- 0008_resolution_functions.sql
-- Layer 2 and 3 behaviour: propose, challenge, assign, vote, decide.

-- ---------------------------------------------------------------- propose

create or replace function propose_outcome(
  p_market uuid, p_option uuid, p_proposer uuid,
  p_evidence_url text, p_note text default null
) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_m      markets%rowtype;
  v_window int;
  v_id     uuid;
begin
  select * into v_m from markets where id = p_market for update;
  if not found then raise exception 'no such market'; end if;
  if v_m.status <> 'LOCKED' then
    raise exception 'can only propose on a LOCKED market, this is %', v_m.status;
  end if;
  if not exists (select 1 from market_options where id = p_option and market_id = p_market) then
    raise exception 'option does not belong to this market';
  end if;

  -- The proposer must not hold a position: proposing on a market you have money
  -- in is the same conflict as a creator resolving their own market.
  if exists (select 1 from positions where market_id = p_market and user_id = p_proposer) then
    raise exception 'proposer holds a position in this market'
      using hint = 'Resolution must be independent of the pool.';
  end if;

  v_window := case when v_m.is_live
                then setting_int('live_challenge_window_minutes')
                else setting_int('challenge_window_minutes') end;

  insert into proposals (market_id, option_id, proposer_id, evidence_url, evidence_note,
                         challenge_closes_at)
  values (p_market, p_option, p_proposer, p_evidence_url, p_note,
          now() + make_interval(mins => v_window))
  returning id into v_id;

  update markets set status = 'PROPOSED' where id = p_market;
  perform audit(p_proposer, 'propose', 'market', p_market,
                jsonb_build_object('option_id', p_option, 'evidence', p_evidence_url));
  return v_id;
end $$;

-- ---------------------------------------------------------------- challenge

-- Posting a bond escalates to the panel. The bond is the whole mechanism: it
-- makes challenging rational only when you are actually right.
create or replace function challenge_proposal(
  p_market uuid, p_user uuid, p_reason text
) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_m    markets%rowtype;
  v_p    proposals%rowtype;
  v_bond bigint := setting_int('challenge_bond_minor');
  v_txn  uuid := gen_random_uuid();
  v_id   uuid;
begin
  select * into v_m from markets where id = p_market for update;
  if v_m.status <> 'PROPOSED' then
    raise exception 'nothing to challenge: market is %', v_m.status;
  end if;

  select * into v_p from proposals where market_id = p_market and not superseded;
  if not found then raise exception 'no live proposal'; end if;
  if now() >= v_p.challenge_closes_at then
    raise exception 'challenge window closed at %', v_p.challenge_closes_at;
  end if;

  -- Only people with money in the market may challenge. Opening it to everyone
  -- invites brigading and noise from people with nothing at stake.
  if not exists (select 1 from positions where market_id = p_market and user_id = p_user) then
    raise exception 'only holders of a position in this market may challenge';
  end if;

  if wallet_balance(p_user) < v_bond then
    raise exception 'insufficient balance for the % bond', v_bond;
  end if;

  insert into challenges (proposal_id, market_id, user_id, bond_minor, reason)
  values (v_p.id, p_market, p_user, v_bond, p_reason)
  returning id into v_id;

  perform post_entries(v_txn, 'BOND_HOLD', jsonb_build_array(
    jsonb_build_object('account_type','USER_WALLET','account_ref', p_user,'amount_minor', -v_bond),
    jsonb_build_object('account_type','BOND_ESCROW','account_ref', p_user,'amount_minor',  v_bond)
  ), p_market, 'Challenge bond');

  update markets set status = 'DISPUTED' where id = p_market;
  perform assign_panel(p_market);
  perform audit(p_user, 'challenge', 'market', p_market, jsonb_build_object('reason', p_reason));
  return v_id;
end $$;

-- Unchallenged proposals settle themselves. This is the happy path and should
-- be ~95% of markets - the reason the whole ladder scales.
create or replace function settle_expired_proposals() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; v_n int := 0;
begin
  for r in
    select p.market_id, p.option_id, p.evidence_url
    from proposals p join markets m on m.id = p.market_id
    where not p.superseded and m.status = 'PROPOSED' and now() >= p.challenge_closes_at
  loop
    perform settle_market(r.market_id, r.option_id, 'UNCHALLENGED',
                          'Unchallenged. Source: ' || r.evidence_url);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- ---------------------------------------------------------------- panel

-- Conflict of interest is enforced as a query, not a policy. Anyone holding a
-- position, the market's creator, and the proposer are all filtered out
-- automatically - there is no path where a human remembers to check.
create or replace function eligible_moderators(p_market uuid)
returns table (user_id uuid)
language sql stable set search_path = public, pg_temp as $$
  select u.id
  from app_users u
  where u.is_staff
    and not exists (select 1 from positions p where p.market_id = p_market and p.user_id = u.id)
    and u.id <> (select creator_id from markets where id = p_market)
    and u.id not in (select proposer_id from proposals where market_id = p_market)
  order by u.id;
$$;

create or replace function assign_panel(p_market uuid) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_size int := setting_int('panel_size')::int;
  v_sla  int := setting_int('panel_sla_hours')::int;
  v_n    int;
begin
  insert into mod_assignments (market_id, moderator_id, due_at)
  select p_market, e.user_id, now() + make_interval(hours => v_sla)
  from (select user_id from eligible_moderators(p_market) limit v_size) e
  on conflict (market_id, moderator_id) do nothing;

  select count(*) into v_n from mod_assignments where market_id = p_market;
  perform audit(null, 'assign_panel', 'market', p_market, jsonb_build_object('assigned', v_n));
  return v_n;
end $$;

-- A vote with option_id = null is a vote to void.
create or replace function cast_vote(
  p_market uuid, p_moderator uuid, p_option uuid, p_reason text
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_m       markets%rowtype;
  v_state   record;
begin
  select * into v_m from markets where id = p_market for update;
  if v_m.status <> 'DISPUTED' then
    raise exception 'panel only votes on a DISPUTED market, this is %', v_m.status;
  end if;
  if not exists (select 1 from mod_assignments where market_id = p_market and moderator_id = p_moderator) then
    raise exception 'not assigned to this market';
  end if;
  -- redundant with eligible_moderators, deliberately: assignment and voting are
  -- separated in time, and a moderator could have staked in between
  if exists (select 1 from positions where market_id = p_market and user_id = p_moderator) then
    raise exception 'moderator holds a position in this market';
  end if;
  if p_option is not null
     and not exists (select 1 from market_options where id = p_option and market_id = p_market) then
    raise exception 'option does not belong to this market';
  end if;

  insert into mod_votes (market_id, moderator_id, option_id, reason)
  values (p_market, p_moderator, p_option, p_reason);

  perform audit(p_moderator, 'vote', 'market', p_market,
                jsonb_build_object('option_id', p_option, 'reason', p_reason));

  select * into v_state from panel_state(p_market);
  if not v_state.sealed then
    return decide_panel(p_market);
  end if;

  return jsonb_build_object('status','sealed',
    'votes_cast', v_state.cast_votes, 'of', v_state.assigned);
end $$;

-- Majority wins; a tie or a majority-to-void voids the market. Bonds settle
-- against the outcome: upheld gets the bond back plus a reward, rejected
-- forfeits it to house.
create or replace function decide_panel(p_market uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_p        proposals%rowtype;
  v_winner   uuid;
  v_top      int;
  v_void     int;
  v_total    int;
  v_res      jsonb;
  v_bond     bigint;
  v_reward   bigint := setting_int('challenge_reward_minor');
  v_txn      uuid;
  c          record;
  v_upheld   boolean;
begin
  select * into v_p from proposals where market_id = p_market and not superseded;

  select count(*) into v_total from mod_votes where market_id = p_market;
  select count(*) into v_void  from mod_votes where market_id = p_market and option_id is null;

  select option_id, cnt into v_winner, v_top
  from (
    select option_id, count(*) as cnt from mod_votes
    where market_id = p_market and option_id is not null
    group by option_id order by count(*) desc, option_id limit 1
  ) t;

  -- void wins outright, or nobody reached a majority of the votes cast
  if v_void > coalesce(v_top, 0) or coalesce(v_top, 0) * 2 <= v_total then
    v_res := void_market(p_market, 'Panel could not agree on an outcome under the stated source');
    v_upheld := true;   -- the challenge was not wrong: the proposal did not stand
  else
    v_res := settle_market(p_market, v_winner, 'PANEL',
      'Panel decision ' || v_top || '-' || (v_total - v_top) || '. Source: ' || v_p.evidence_url);
    v_upheld := (v_winner is distinct from v_p.option_id);
  end if;

  -- settle every bond on this market
  for c in select * from challenges where market_id = p_market and upheld is null loop
    v_bond := c.bond_minor;
    v_txn  := gen_random_uuid();
    if v_upheld then
      perform post_entries(v_txn, 'BOND_REWARD', jsonb_build_array(
        jsonb_build_object('account_type','BOND_ESCROW','account_ref', c.user_id,'amount_minor', -v_bond),
        jsonb_build_object('account_type','USER_WALLET','account_ref', c.user_id,'amount_minor',  v_bond + v_reward),
        jsonb_build_object('account_type','HOUSE_RAKE', 'account_ref', null,     'amount_minor', -v_reward)
      ), p_market, 'Challenge upheld: bond returned plus reward');
    else
      perform post_entries(v_txn, 'BOND_FORFEIT', jsonb_build_array(
        jsonb_build_object('account_type','BOND_ESCROW','account_ref', c.user_id,'amount_minor', -v_bond),
        jsonb_build_object('account_type','HOUSE_RAKE', 'account_ref', null,     'amount_minor',  v_bond)
      ), p_market, 'Challenge rejected: bond forfeited');
    end if;
    update challenges set upheld = v_upheld, resolved_at = now() where id = c.id;
  end loop;

  perform audit(null, 'panel_decision', 'market', p_market,
                jsonb_build_object('upheld', v_upheld, 'result', v_res));

  return v_res || jsonb_build_object('challenge_upheld', v_upheld,
                                     'votes_for', coalesce(v_top,0), 'votes_total', v_total);
end $$;

-- Admin override for a panel that misses its SLA. Always available, always logged.
create or replace function admin_resolve(
  p_market uuid, p_admin uuid, p_option uuid, p_reason text
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_res jsonb; v_bond bigint; v_txn uuid; c record;
begin
  if not exists (select 1 from app_users where id = p_admin and is_staff) then
    raise exception 'admin_resolve requires staff';
  end if;

  if p_option is null then
    v_res := void_market(p_market, p_reason);
  else
    v_res := settle_market(p_market, p_option, 'ADMIN', p_reason);
  end if;

  -- an admin override returns every bond: the challenger was not adjudicated
  for c in select * from challenges where market_id = p_market and upheld is null loop
    v_bond := c.bond_minor; v_txn := gen_random_uuid();
    perform post_entries(v_txn, 'BOND_RETURN', jsonb_build_array(
      jsonb_build_object('account_type','BOND_ESCROW','account_ref', c.user_id,'amount_minor', -v_bond),
      jsonb_build_object('account_type','USER_WALLET','account_ref', c.user_id,'amount_minor',  v_bond)
    ), p_market, 'Bond returned on admin resolution');
    update challenges set upheld = null, resolved_at = now() where id = c.id;
  end loop;

  perform audit(p_admin, 'admin_resolve', 'market', p_market, jsonb_build_object('reason', p_reason));
  return v_res;
end $$;

-- ---------------------------------------------------------------- invariants

-- Bond escrow must empty out exactly like market escrow does.
create or replace function check_bond_invariants()
returns table (invariant text, ok boolean, detail text)
language plpgsql stable set search_path = public, pg_temp as $$
begin
  return query
  select 'bond_escrow_empty_when_resolved'::text, count(*) = 0,
         count(*)::text || ' resolved challenge(s) still holding bond'
  from challenges c
  where c.resolved_at is not null
    and (select coalesce(sum(amount_minor),0) from ledger_entries
         where account_type='BOND_ESCROW' and account_ref = c.user_id
           and market_id = c.market_id) <> 0;

  return query
  select 'no_negative_bond_escrow'::text, count(*) = 0,
         count(*)::text || ' negative bond escrow account(s)'
  from account_balances
  where account_type = 'BOND_ESCROW' and balance_minor < 0;

  return query
  select 'votes_within_assignments'::text, count(*) = 0,
         count(*)::text || ' vote(s) from unassigned moderators'
  from mod_votes v
  where not exists (select 1 from mod_assignments a
                    where a.market_id = v.market_id and a.moderator_id = v.moderator_id);

  return query
  select 'no_moderator_holds_position'::text, count(*) = 0,
         count(*)::text || ' moderator(s) voted on a market they had money in'
  from mod_votes v
  where exists (select 1 from positions p
                where p.market_id = v.market_id and p.user_id = v.moderator_id);
end $$;

-- lock down: resolution functions are server-side only, same as the money ones
revoke execute on function propose_outcome(uuid,uuid,uuid,text,text)   from public, anon, authenticated;
revoke execute on function challenge_proposal(uuid,uuid,text)          from public, anon, authenticated;
revoke execute on function settle_expired_proposals()                  from public, anon, authenticated;
revoke execute on function assign_panel(uuid)                          from public, anon, authenticated;
revoke execute on function cast_vote(uuid,uuid,uuid,text)              from public, anon, authenticated;
revoke execute on function decide_panel(uuid)                          from public, anon, authenticated;
revoke execute on function admin_resolve(uuid,uuid,uuid,text)          from public, anon, authenticated;
revoke execute on function check_bond_invariants()                     from public, anon, authenticated;
revoke execute on function eligible_moderators(uuid)                   from public, anon, authenticated;
revoke execute on function panel_state(uuid)                           from public, anon, authenticated;
revoke execute on function audit(uuid,text,text,uuid,jsonb)            from public, anon, authenticated;
revoke execute on function setting_int(text)                           from public, anon, authenticated;

alter table proposals       enable row level security;
alter table challenges      enable row level security;
alter table mod_assignments enable row level security;
alter table mod_votes       enable row level security;
alter table audit_log       enable row level security;
alter table settings        enable row level security;

-- proposals are public: the evidence is the point
create policy proposals_public_read on proposals for select using (true);
-- votes stay sealed until the panel completes, then become public record
create policy votes_read_when_complete on mod_votes for select using (
  (select count(*) from mod_votes v2 where v2.market_id = mod_votes.market_id)
  >= (select count(*) from mod_assignments a where a.market_id = mod_votes.market_id)
);
create policy challenges_own_read on challenges for select using (user_id = auth.uid());
