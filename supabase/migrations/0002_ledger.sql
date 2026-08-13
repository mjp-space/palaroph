-- 0002_ledger.sql
-- The single most important table in the system.
--
-- A user's balance is NEVER a column you UPDATE. It is the sum of immutable rows.
-- Every dispute you will ever have is settled by replaying this table.
--
-- Convention: amount_minor is SIGNED. Positive = value into that account.
-- Every txn_id group must sum to exactly zero (double entry).
--   stake:  USER_WALLET -10000 , MARKET_ESCROW +10000
--   payout: MARKET_ESCROW -19000 , USER_WALLET +19000
--   rake:   MARKET_ESCROW  -1000 , HOUSE_RAKE   +1000
-- Source accounts (PROMO_GRANT) legitimately run negative - they are the origin
-- of play money, the same way an equity account funds a balance sheet.

create table ledger_entries (
  id           bigint generated always as identity primary key,
  txn_id       uuid        not null,
  entry_type   entry_type  not null,
  account_type account_type not null,
  account_ref  uuid,                      -- user id / market id; null for house accounts
  amount_minor bigint      not null check (amount_minor <> 0),
  market_id    uuid,                      -- denormalised for fast per-market assertions
  memo         text,
  created_at   timestamptz not null default now()
);

create index ledger_txn      on ledger_entries (txn_id);
create index ledger_account  on ledger_entries (account_type, account_ref);
create index ledger_market   on ledger_entries (market_id) where market_id is not null;
create index ledger_created  on ledger_entries (created_at desc);

-- account_ref is required for per-entity accounts, forbidden for house accounts.
alter table ledger_entries add constraint ledger_ref_shape check (
  case account_type
    when 'USER_WALLET'   then account_ref is not null
    when 'MARKET_ESCROW' then account_ref is not null
    when 'BOND_ESCROW'   then account_ref is not null
    else account_ref is null
  end
);

-- ---------------------------------------------------------------- append-only
-- Enforced two ways: a trigger (catches everything including superuser paths that
-- ignore grants) and revoked privileges (defence in depth).

create or replace function ledger_is_immutable() returns trigger
language plpgsql as $$
begin
  raise exception 'ledger_entries is append-only: % is not permitted', tg_op
    using hint = 'To reverse a movement, insert compensating entries. Never edit history.';
end $$;

create trigger ledger_no_update before update on ledger_entries
  for each row execute function ledger_is_immutable();
create trigger ledger_no_delete before delete on ledger_entries
  for each row execute function ledger_is_immutable();
create trigger ledger_no_truncate before truncate on ledger_entries
  for each statement execute function ledger_is_immutable();

-- ---------------------------------------------------------------- balances

create view account_balances as
  select account_type, account_ref, sum(amount_minor)::bigint as balance_minor
  from ledger_entries
  group by account_type, account_ref;

create or replace function wallet_balance(p_user uuid) returns bigint
language sql stable as $$
  select coalesce(sum(amount_minor), 0)::bigint
  from ledger_entries
  where account_type = 'USER_WALLET' and account_ref = p_user;
$$;

create or replace function market_escrow_balance(p_market uuid) returns bigint
language sql stable as $$
  select coalesce(sum(amount_minor), 0)::bigint
  from ledger_entries
  where account_type = 'MARKET_ESCROW' and account_ref = p_market;
$$;

-- ---------------------------------------------------------------- posting helper
-- The ONLY sanctioned way to write to the ledger. Refuses any txn that does not
-- balance, so an unbalanced transaction cannot exist even by accident.

create or replace function post_entries(
  p_txn_id  uuid,
  p_type    entry_type,
  p_entries jsonb,          -- [{account_type, account_ref, amount_minor}, ...]
  p_market  uuid default null,
  p_memo    text default null
) returns void
language plpgsql as $$
declare
  v_sum bigint;
begin
  select coalesce(sum((e->>'amount_minor')::bigint), 0) into v_sum
  from jsonb_array_elements(p_entries) e;

  if v_sum <> 0 then
    raise exception 'unbalanced transaction: entries sum to %, must be 0', v_sum
      using hint = 'Double entry: every debit needs a matching credit.';
  end if;

  insert into ledger_entries (txn_id, entry_type, account_type, account_ref, amount_minor, market_id, memo)
  select p_txn_id, p_type,
         (e->>'account_type')::account_type,
         nullif(e->>'account_ref','')::uuid,
         (e->>'amount_minor')::bigint,
         p_market, p_memo
  from jsonb_array_elements(p_entries) e;
end $$;

-- ---------------------------------------------------------------- invariants
-- Run in CI and nightly in production. Returns one row per check.
-- Any row with ok = false is a stop-the-line event.

create or replace function check_invariants()
returns table (invariant text, ok boolean, detail text)
language plpgsql stable as $$
begin
  -- 1. the whole ledger nets to zero
  return query
  select 'global_ledger_balances'::text,
         coalesce(sum(amount_minor), 0) = 0,
         'net = ' || coalesce(sum(amount_minor), 0)::text
  from ledger_entries;

  -- 2. every individual transaction nets to zero
  return query
  select 'every_txn_balances'::text,
         count(*) = 0,
         count(*)::text || ' unbalanced txn(s)'
  from (
    select txn_id from ledger_entries group by txn_id having sum(amount_minor) <> 0
  ) bad;

  -- 3. finished markets have emptied their escrow
  return query
  select 'finished_market_escrow_empty'::text,
         count(*) = 0,
         count(*)::text || ' finished market(s) holding funds'
  from markets m
  where m.status in ('SETTLED','VOIDED')
    and market_escrow_balance(m.id) <> 0;

  -- 4. no user wallet is ever negative
  return query
  select 'no_negative_wallet'::text,
         count(*) = 0,
         count(*)::text || ' negative wallet(s)'
  from account_balances
  where account_type = 'USER_WALLET' and balance_minor < 0;

  -- 5. denormalised pools match the positions that created them
  return query
  select 'pools_match_positions'::text,
         count(*) = 0,
         count(*)::text || ' option(s) drifted from position sum'
  from market_options o
  where o.pool_minor <> (
    select coalesce(sum(p.stake_minor), 0) from positions p where p.option_id = o.id
  );

  -- 6. live escrow equals the pools it is holding
  return query
  select 'open_market_escrow_matches_pools'::text,
         count(*) = 0,
         count(*)::text || ' market(s) where escrow <> pool total'
  from markets m
  where m.status in ('OPEN','LOCKED','PROPOSED','DISPUTED')
    and market_escrow_balance(m.id) <>
        (select coalesce(sum(o.pool_minor),0) from market_options o where o.market_id = m.id);
end $$;

comment on function check_invariants is
  'Ledger integrity assertions. Run in CI and nightly. Any ok=false is stop-the-line.';
