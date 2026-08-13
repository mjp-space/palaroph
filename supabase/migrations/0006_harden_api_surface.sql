-- 0006_harden_api_surface.sql
--
-- CRITICAL — found by Supabase's security advisor after deploying, NOT by any
-- local test, because local Postgres has no PostgREST.
--
-- Supabase exposes the `public` schema through PostgREST, so every function in
-- it was reachable at /rest/v1/rpc/<name> using only the anon key — which ships
-- in the browser. That meant anyone could:
--
--   POST /rest/v1/rpc/grant_points   {p_user: <self>, p_amount: 999999999}
--   POST /rest/v1/rpc/settle_market  {p_market: ..., p_winning_option: <mine>}
--   POST /rest/v1/rpc/wallet_balance {p_user: <anyone>}
--
-- i.e. mint unlimited money, settle any market in their own favour, or
-- enumerate every balance. The SECURITY DEFINER property that lets these
-- functions write the ledger is exactly what made the hole exploitable.
--
-- The money functions are SERVER-SIDE ONLY. The app calls them over a direct
-- connection as a trusted role; nothing browser-facing may reach them.
--
-- NOTE ON ORDERING: revoking from a role does NOT remove a grant held via
-- PUBLIC, and anon/authenticated inherit PUBLIC. Always revoke from PUBLIC.

revoke execute on function grant_points(uuid, bigint, text)                   from public, anon, authenticated;
revoke execute on function place_stake(uuid, uuid, bigint)                    from public, anon, authenticated;
revoke execute on function settle_market(uuid, uuid, resolution_method, text) from public, anon, authenticated;
revoke execute on function void_market(uuid, text)                            from public, anon, authenticated;
revoke execute on function lock_market(uuid)                                  from public, anon, authenticated;
revoke execute on function lock_due_markets()                                 from public, anon, authenticated;
revoke execute on function post_entries(uuid, entry_type, jsonb, uuid, text)  from public, anon, authenticated;

-- balance/state readers: not price data, must not be public
revoke execute on function wallet_balance(uuid)        from public, anon, authenticated;
revoke execute on function market_escrow_balance(uuid) from public, anon, authenticated;
revoke execute on function check_invariants()          from public, anon, authenticated;

-- option_odds and project_return stay public on purpose: they are the price
-- feed, take no user identity, and read only already-public pools.

-- Any future function added to public defaults to unreachable by API roles.
alter default privileges in schema public revoke execute on functions from anon, authenticated;

-- Pin search_path so a caller cannot shadow `markets` or `ledger_entries` with
-- their own table and change what these functions read.
alter function wallet_balance(uuid)          set search_path = public, pg_temp;
alter function market_escrow_balance(uuid)   set search_path = public, pg_temp;
alter function option_odds(uuid)             set search_path = public, pg_temp;
alter function project_return(uuid, bigint)  set search_path = public, pg_temp;
alter function has_counterparty(uuid)        set search_path = public, pg_temp;
alter function check_invariants()            set search_path = public, pg_temp;
alter function ledger_is_immutable()         set search_path = public, pg_temp;

-- Views inherit the definer's rights unless told otherwise, which would let
-- account_balances leak every wallet past RLS.
alter view account_balances set (security_invoker = on);

-- categories is exposed through the API and had no policy at all.
alter table categories enable row level security;
create policy categories_public_read on categories for select using (true);
