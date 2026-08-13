-- 0000_roles_shim.sql
-- Supabase ships the anon/authenticated roles and an auth schema. Locally we
-- create equivalents so every later migration - especially the 0006 privilege
-- hardening - applies identically in both places and can be tested for real.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_namespace where nspname = 'auth') then
    create schema auth;
    execute 'create function auth.uid() returns uuid language sql stable as $f$ select null::uuid $f$';
  end if;
end $$;
