-- 0004_money_functions.sql
-- Every movement of value. Nothing outside these functions may touch the ledger.

-- ---------------------------------------------------------------- grants

create or replace function grant_points(
  p_user uuid, p_amount bigint, p_memo text default 'Signup grant'
) returns bigint
language plpgsql as $$
declare v_txn uuid := gen_random_uuid();
begin
  if p_amount <= 0 then raise exception 'grant must be positive'; end if;

  perform post_entries(v_txn, 'GRANT', jsonb_build_array(
    jsonb_build_object('account_type','PROMO_GRANT','account_ref',null,'amount_minor', -p_amount),
    jsonb_build_object('account_type','USER_WALLET','account_ref', p_user,'amount_minor',  p_amount)
  ), null, p_memo);

  return wallet_balance(p_user);
end $$;

-- ---------------------------------------------------------------- staking

-- Atomic stake-and-hold. The market row is locked FOR UPDATE so two concurrent
-- stakes cannot both read a stale pool or a stale balance. Without this lock,
-- two simultaneous bets are a live double-spend the moment you have traffic.
create or replace function place_stake(
  p_user uuid, p_option uuid, p_amount bigint
) returns uuid
language plpgsql as $$
declare
  v_market  markets%rowtype;
  v_option  market_options%rowtype;
  v_txn     uuid := gen_random_uuid();
  v_pos     uuid;
  v_balance bigint;
begin
  if p_amount <= 0 then
    raise exception 'stake must be positive' using errcode = 'check_violation';
  end if;

  select o.* into v_option from market_options o where o.id = p_option;
  if not found then raise exception 'no such option'; end if;

  -- lock the market; every other stake on it queues behind this
  select m.* into v_market from markets m where m.id = v_option.market_id for update;

  if v_market.status <> 'OPEN' then
    raise exception 'market is % - not accepting stakes', v_market.status
      using errcode = 'check_violation';
  end if;
  if now() < v_market.opens_at then
    raise exception 'market has not opened yet' using errcode = 'check_violation';
  end if;
  -- server-side clock only. Never trust the client, and never let "locked"
  -- mean "we hid the button".
  if now() >= v_market.locks_at then
    raise exception 'market locked at %', v_market.locks_at using errcode = 'check_violation';
  end if;
  if v_market.max_stake_minor is not null and p_amount > v_market.max_stake_minor then
    raise exception 'stake exceeds this market''s cap of %', v_market.max_stake_minor
      using errcode = 'check_violation';
  end if;

  v_balance := wallet_balance(p_user);
  if v_balance < p_amount then
    raise exception 'insufficient balance: have %, need %', v_balance, p_amount
      using errcode = 'check_violation';
  end if;

  insert into positions (market_id, option_id, user_id, stake_minor)
  values (v_market.id, p_option, p_user, p_amount)
  returning id into v_pos;

  update market_options set pool_minor = pool_minor + p_amount where id = p_option;

  perform post_entries(v_txn, 'STAKE', jsonb_build_array(
    jsonb_build_object('account_type','USER_WALLET',  'account_ref', p_user,      'amount_minor', -p_amount),
    jsonb_build_object('account_type','MARKET_ESCROW','account_ref', v_market.id, 'amount_minor',  p_amount)
  ), v_market.id, 'Stake on ' || v_option.label);

  return v_pos;
end $$;

-- ---------------------------------------------------------------- lifecycle

create or replace function lock_market(p_market uuid) returns void
language plpgsql as $$
declare v_m markets%rowtype;
begin
  select * into v_m from markets where id = p_market for update;
  if v_m.status <> 'OPEN' then
    raise exception 'can only lock an OPEN market, this is %', v_m.status;
  end if;
  update markets set status = 'LOCKED' where id = p_market;
end $$;

-- Scheduled sweep. Wire to pg_cron (or a Vercel cron hitting an edge function).
-- A market that locks late is a money bug, not a UI glitch - it is exactly the
-- window that lets in late money betting on a known outcome.
create or replace function lock_due_markets() returns int
language plpgsql as $$
declare v_n int;
begin
  with due as (
    update markets set status = 'LOCKED'
    where status = 'OPEN' and now() >= locks_at
    returning 1
  ) select count(*) into v_n from due;
  return v_n;
end $$;

-- ---------------------------------------------------------------- settlement

-- Parimutuel payout.
--   payable = total_pool - rake
--   each winner gets floor(stake / winning_pool * payable)
-- Rounding is ALWAYS down, and the remainder is swept to house rake. Round up
-- and you are insolvent by a centavo per market; round to nearest and solvency
-- becomes a coin flip.
create or replace function settle_market(
  p_market uuid,
  p_winning_option uuid,
  p_method resolution_method default 'UNCHALLENGED',
  p_reason text default null
) returns jsonb
language plpgsql as $$
declare
  v_m           markets%rowtype;
  v_total       bigint;
  v_rake        bigint;
  v_payable     bigint;
  v_winpool     bigint;
  v_distributed bigint := 0;
  v_remainder   bigint;
  v_house       bigint;
  v_txn         uuid := gen_random_uuid();
  v_entries     jsonb := '[]'::jsonb;
  r             record;
  v_payout      bigint;
begin
  select * into v_m from markets where id = p_market for update;
  if not found then raise exception 'no such market'; end if;
  if v_m.status not in ('LOCKED','PROPOSED','DISPUTED') then
    raise exception 'cannot settle a market in status %', v_m.status;
  end if;
  if not exists (select 1 from market_options where id = p_winning_option and market_id = p_market) then
    raise exception 'winning option does not belong to this market';
  end if;

  -- No opposing money means the backers had no counterparty. Refund, don't settle.
  if not has_counterparty(p_market) then
    return void_market(p_market, 'No counterparty - fewer than two funded outcomes');
  end if;

  select coalesce(sum(pool_minor),0) into v_total  from market_options where market_id = p_market;
  select pool_minor              into v_winpool from market_options where id = p_winning_option;

  -- Nobody backed the winner: there is no one to pay. Refund everyone.
  if v_winpool = 0 then
    return void_market(p_market, 'No stakes on the winning outcome');
  end if;

  v_rake    := floor(v_total::numeric * v_m.rake_bps / 10000)::bigint;
  v_payable := v_total - v_rake;

  for r in
    select user_id, sum(stake_minor)::bigint as stake
    from positions where option_id = p_winning_option
    group by user_id
  loop
    v_payout := floor(r.stake::numeric * v_payable / v_winpool)::bigint;
    if v_payout > 0 then
      v_distributed := v_distributed + v_payout;
      v_entries := v_entries || jsonb_build_object(
        'account_type','USER_WALLET','account_ref', r.user_id, 'amount_minor', v_payout);
    end if;
  end loop;

  -- everything not distributed is house: base rake + rounding dust
  v_remainder := v_payable - v_distributed;
  v_house     := v_rake + v_remainder;

  if v_house > 0 then
    v_entries := v_entries || jsonb_build_object(
      'account_type','HOUSE_RAKE','account_ref', null, 'amount_minor', v_house);
  end if;

  -- escrow releases exactly what it holds
  v_entries := v_entries || jsonb_build_object(
    'account_type','MARKET_ESCROW','account_ref', p_market, 'amount_minor', -v_total);

  perform post_entries(v_txn, 'PAYOUT', v_entries, p_market,
                       coalesce(p_reason, 'Settled'));

  update markets
     set status = 'SETTLED', final_option_id = p_winning_option,
         method = p_method, published_reason = p_reason, settled_at = now()
   where id = p_market;

  -- belt and braces: this market must now hold nothing
  if market_escrow_balance(p_market) <> 0 then
    raise exception 'escrow did not clear on settle: % remaining', market_escrow_balance(p_market);
  end if;

  return jsonb_build_object(
    'market_id', p_market, 'total_minor', v_total, 'rake_minor', v_rake,
    'payable_minor', v_payable, 'distributed_minor', v_distributed,
    'rounding_swept_minor', v_remainder, 'house_total_minor', v_house,
    'winning_pool_minor', v_winpool,
    'effective_odds', round(v_payable::numeric / v_winpool, 4)
  );
end $$;

-- Void: everyone gets their exact stake back, ZERO rake.
-- A void costs one market's revenue. Forcing a call on an ambiguous market costs
-- half the users in it, permanently - so voiding is a feature, not a failure.
create or replace function void_market(p_market uuid, p_reason text)
returns jsonb
language plpgsql as $$
declare
  v_m       markets%rowtype;
  v_total   bigint;
  v_txn     uuid := gen_random_uuid();
  v_entries jsonb := '[]'::jsonb;
  r         record;
begin
  select * into v_m from markets where id = p_market for update;
  if not found then raise exception 'no such market'; end if;
  if v_m.status in ('SETTLED','VOIDED') then
    raise exception 'market already finished (%)', v_m.status;
  end if;

  select coalesce(sum(pool_minor),0) into v_total from market_options where market_id = p_market;

  if v_total > 0 then
    for r in
      select user_id, sum(stake_minor)::bigint as staked
      from positions where market_id = p_market group by user_id
    loop
      v_entries := v_entries || jsonb_build_object(
        'account_type','USER_WALLET','account_ref', r.user_id, 'amount_minor', r.staked);
    end loop;

    v_entries := v_entries || jsonb_build_object(
      'account_type','MARKET_ESCROW','account_ref', p_market, 'amount_minor', -v_total);

    perform post_entries(v_txn, 'REFUND', v_entries, p_market, p_reason);
  end if;

  update markets
     set status = 'VOIDED', method = 'VOID', published_reason = p_reason, settled_at = now()
   where id = p_market;

  if market_escrow_balance(p_market) <> 0 then
    raise exception 'escrow did not clear on void: % remaining', market_escrow_balance(p_market);
  end if;

  return jsonb_build_object('market_id', p_market, 'refunded_minor', v_total,
                            'rake_minor', 0, 'reason', p_reason);
end $$;
