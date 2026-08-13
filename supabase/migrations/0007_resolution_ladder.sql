-- 0007_resolution_ladder.sql
--
-- The three-layer resolution system from the design doc.
--
--   Layer 1  resolution source, mandatory at creation      (already in 0003)
--   Layer 2  optimistic proposal + challenge window        (here)
--   Layer 3  3-person blind panel -> admin -> void         (here)
--
-- The point of layer 2 is that ~95% of markets never reach a human. The bond is
-- what keeps that true: without a cost to challenge, every losing bettor
-- challenges every market for free and you are back to a human in the loop for
-- 100% of volume.

-- ---------------------------------------------------------------- proposals

create table proposals (
  id                  uuid primary key default gen_random_uuid(),
  market_id           uuid not null references markets(id),
  option_id           uuid not null references market_options(id),
  proposer_id         uuid not null references app_users(id),
  -- No evidence, no proposal. This is a hard constraint, not a convention:
  -- the published reason is what makes users accept losing.
  evidence_url        text not null check (length(btrim(evidence_url)) >= 8),
  evidence_note       text,
  proposed_at         timestamptz not null default now(),
  challenge_closes_at timestamptz not null,
  superseded          boolean not null default false,
  constraint challenge_window_positive check (challenge_closes_at > proposed_at)
);

create index proposals_market on proposals (market_id);
create unique index proposals_one_live_per_market
  on proposals (market_id) where not superseded;

-- ---------------------------------------------------------------- challenges

create table challenges (
  id           uuid primary key default gen_random_uuid(),
  proposal_id  uuid not null references proposals(id),
  market_id    uuid not null references markets(id),
  user_id      uuid not null references app_users(id),
  bond_minor   bigint not null check (bond_minor > 0),
  reason       text not null check (length(btrim(reason)) >= 10),
  created_at   timestamptz not null default now(),
  -- filled in when the panel decides
  upheld       boolean,
  resolved_at  timestamptz,
  -- one challenge per person per proposal; brigading is not a bond
  unique (proposal_id, user_id)
);

create index challenges_market on challenges (market_id);

-- ---------------------------------------------------------------- panel

create table mod_assignments (
  id           uuid primary key default gen_random_uuid(),
  market_id    uuid not null references markets(id),
  moderator_id uuid not null references app_users(id),
  assigned_at  timestamptz not null default now(),
  due_at       timestamptz not null,
  unique (market_id, moderator_id)
);

create table mod_votes (
  id           uuid primary key default gen_random_uuid(),
  market_id    uuid not null references markets(id),
  moderator_id uuid not null references app_users(id),
  -- null option = vote to void
  option_id    uuid references market_options(id),
  reason       text not null check (length(btrim(reason)) >= 10),
  voted_at     timestamptz not null default now(),
  unique (market_id, moderator_id)
);

create index mod_votes_market on mod_votes (market_id);

-- Blind voting. Votes are sealed until all three are in, otherwise the first
-- vote anchors the other two and you effectively have one moderator deciding.
create or replace function panel_state(p_market uuid)
returns table (assigned int, cast_votes int, sealed boolean)
language sql stable set search_path = public, pg_temp as $$
  select
    (select count(*)::int from mod_assignments where market_id = p_market),
    (select count(*)::int from mod_votes       where market_id = p_market),
    (select count(*) from mod_votes where market_id = p_market)
      < (select count(*) from mod_assignments where market_id = p_market);
$$;

-- ---------------------------------------------------------------- audit log

create table audit_log (
  id         bigint generated always as identity primary key,
  actor_id   uuid references app_users(id),
  action     text not null,
  entity     text not null,
  entity_id  uuid,
  payload    jsonb,
  created_at timestamptz not null default now()
);

create index audit_entity on audit_log (entity, entity_id);

create or replace function audit_is_immutable() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  raise exception 'audit_log is append-only: % is not permitted', tg_op;
end $$;

create trigger audit_no_update before update on audit_log
  for each row execute function audit_is_immutable();
create trigger audit_no_delete before delete on audit_log
  for each row execute function audit_is_immutable();

create or replace function audit(
  p_actor uuid, p_action text, p_entity text, p_entity_id uuid, p_payload jsonb default null
) returns void
language sql set search_path = public, pg_temp as $$
  insert into audit_log (actor_id, action, entity, entity_id, payload)
  values (p_actor, p_action, p_entity, p_entity_id, p_payload);
$$;

-- ---------------------------------------------------------------- config

create table settings (
  key   text primary key,
  value jsonb not null
);

insert into settings (key, value) values
  ('challenge_bond_minor',      '10000'::jsonb),   -- ₱100
  ('challenge_reward_minor',    '10000'::jsonb),   -- ₱100 paid on an upheld challenge
  ('challenge_window_minutes',  '360'::jsonb),     -- 6h standard
  ('live_challenge_window_minutes', '45'::jsonb),  -- live markets pay first, reverse later
  ('panel_size',                '3'::jsonb),
  ('panel_sla_hours',           '48'::jsonb)
on conflict (key) do nothing;

create or replace function setting_int(p_key text) returns bigint
language sql stable set search_path = public, pg_temp as $$
  select (value #>> '{}')::bigint from settings where key = p_key;
$$;
