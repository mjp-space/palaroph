-- 0005_rls_and_seed.sql
-- Row level security + reference data.

alter table ledger_entries enable row level security;
alter table positions      enable row level security;
alter table markets        enable row level security;
alter table market_options enable row level security;
alter table app_users      enable row level security;

-- A user may read their own ledger and nobody else's.
create policy ledger_own_read on ledger_entries
  for select using (
    account_type = 'USER_WALLET' and account_ref = auth.uid()
  );

-- Nothing may write to the ledger through the API. All movement goes through
-- the SECURITY DEFINER money functions, which is what makes double entry
-- unavoidable rather than merely conventional.
revoke insert, update, delete on ledger_entries from public, anon, authenticated;

create policy positions_own_read on positions
  for select using (user_id = auth.uid());

-- Markets and their options are public once they leave DRAFT.
create policy markets_public_read on markets
  for select using (status <> 'DRAFT' or creator_id = auth.uid());
create policy options_public_read on market_options
  for select using (exists (
    select 1 from markets m where m.id = market_id and (m.status <> 'DRAFT' or m.creator_id = auth.uid())
  ));

create policy users_public_read on app_users for select using (true);

-- The money functions run as owner so they can write the ledger.
alter function grant_points(uuid, bigint, text)                   security definer set search_path = public, pg_temp;
alter function place_stake(uuid, uuid, bigint)                    security definer set search_path = public, pg_temp;
alter function settle_market(uuid, uuid, resolution_method, text) security definer set search_path = public, pg_temp;
alter function void_market(uuid, text)                            security definer set search_path = public, pg_temp;
alter function lock_market(uuid)                                  security definer set search_path = public, pg_temp;
alter function lock_due_markets()                                 security definer set search_path = public, pg_temp;
alter function post_entries(uuid, entry_type, jsonb, uuid, text)  security definer set search_path = public, pg_temp;

-- SECURITY DEFINER is what lets these write the ledger. 0006 is what stops that
-- power being reachable from the public API - the two must ship together.

-- ---------------------------------------------------------------- seed

insert into categories (id, label, live_capable, staff_only) values
  ('FlipTop', 'FlipTop',        false, false),
  ('NBA',     'NBA',            true,  false),
  ('PBA',     'PBA',            true,  false),
  ('Weather', 'Weather',        false, false),
  ('Economy', 'Economy',        false, false),
  -- held back in beta: slowest to resolve, attracts the most bad-faith argument
  ('Politics','Politics',       false, true)
on conflict (id) do nothing;
