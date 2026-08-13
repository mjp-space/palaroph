-- privileges.sql — API surface hardening.
--
-- These exist because Supabase publishes the `public` schema through PostgREST:
-- every function in it is reachable at /rest/v1/rpc/<name> with the anon key,
-- which ships in the browser. A SECURITY DEFINER money function left callable
-- there is a total compromise — mint money, settle markets in your own favour,
-- enumerate every balance.
--
-- This was found by Supabase's advisor AFTER deploying, not by any local test,
-- because plain Postgres has no PostgREST. These assertions close that gap.

set client_min_messages = warning;
create temp table pres (n int generated always as identity, ok boolean, name text, detail text);

do $$
declare
  r record;
  v_ok boolean;
begin
  -- must be UNREACHABLE by both API roles
  for r in
    select * from (values
      ('public.grant_points(uuid,bigint,text)',                     'mint money'),
      ('public.place_stake(uuid,uuid,bigint)',                      'stake as anyone'),
      ('public.settle_market(uuid,uuid,resolution_method,text)',    'settle in own favour'),
      ('public.void_market(uuid,text)',                             'void any market'),
      ('public.lock_market(uuid)',                                  'lock any market'),
      ('public.lock_due_markets()',                                 'force the sweep'),
      ('public.post_entries(uuid,entry_type,jsonb,uuid,text)',      'forge ledger entries'),
      ('public.wallet_balance(uuid)',                               'enumerate balances'),
      ('public.market_escrow_balance(uuid)',                        'read escrow'),
      ('public.check_invariants()',                                 'read system state')
    ) t(sig, risk)
  loop
    v_ok := not has_function_privilege('anon', r.sig, 'EXECUTE')
        and not has_function_privilege('authenticated', r.sig, 'EXECUTE');
    insert into pres (ok, name, detail)
    values (v_ok, 'blocked from API: ' || split_part(r.sig, '(', 1), r.risk);
  end loop;

  -- price feed SHOULD stay reachable: no identity, reads only public pools
  for r in
    select * from (values
      ('public.option_odds(uuid)'),
      ('public.project_return(uuid,bigint)')
    ) t(sig)
  loop
    insert into pres (ok, name, detail)
    values (has_function_privilege('anon', r.sig, 'EXECUTE'),
            'still public (price feed): ' || split_part(r.sig, '(', 1), '');
  end loop;
end $$;

-- RLS must be on for everything PostgREST can see
do $$
declare r record;
begin
  for r in select unnest(array['ledger_entries','positions','markets','market_options','app_users','categories']) as t
  loop
    insert into pres (ok, name, detail)
    select c.relrowsecurity, 'RLS enabled: ' || r.t, ''
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = r.t;
  end loop;
end $$;

-- the ledger must be unwritable through the API even with a valid session
do $$
begin
  insert into pres (ok, name, detail) values (
    not has_table_privilege('anon','ledger_entries','INSERT')
    and not has_table_privilege('authenticated','ledger_entries','INSERT')
    and not has_table_privilege('authenticated','ledger_entries','UPDATE')
    and not has_table_privilege('authenticated','ledger_entries','DELETE'),
    'ledger not writable via API', 'insert/update/delete revoked');
end $$;

-- account_balances would leak every wallet past RLS if it ran as definer
do $$
declare v_opts text[];
begin
  select c.reloptions into v_opts from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relname='account_balances';
  -- Postgres normalises the value to 'on'; accept either spelling
  insert into pres (ok, name, detail)
  values (array_to_string(v_opts, ',') ~ 'security_invoker=(on|true)',
          'account_balances is security_invoker',
          coalesce(array_to_string(v_opts,','),'none'));
end $$;

-- a caller must not be able to shadow `markets` and change what these read
do $$
declare r record;
begin
  for r in
    select p.proname, p.proconfig
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in ('wallet_balance','option_odds','project_return','has_counterparty',
                        'check_invariants','place_stake','settle_market','void_market',
                        'grant_points','post_entries','market_escrow_balance','ledger_is_immutable')
  loop
    insert into pres (ok, name, detail)
    values (r.proconfig is not null and array_to_string(r.proconfig,',') like '%search_path%',
            'search_path pinned: ' || r.proname, coalesce(array_to_string(r.proconfig,','),'MUTABLE'));
  end loop;
end $$;

select case when ok then 'PASS' else 'FAIL' end as status, name, detail from pres order by n;
select count(*) filter (where not ok) as failures, count(*) as total from pres;
