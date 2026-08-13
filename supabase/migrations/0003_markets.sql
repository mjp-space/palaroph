-- 0003_markets.sql
-- Markets, options, positions.
--
-- The design decision enforced here: a market CANNOT EXIST without a named
-- resolution source and a void clause. Most disputes come from badly-worded
-- questions, not dishonest people - so ambiguity is made structurally impossible
-- rather than moderated after the fact.

create table markets (
  id                    uuid primary key default gen_random_uuid(),
  creator_id            uuid not null references app_users(id),
  category_id           text not null references categories(id),

  question              text not null check (length(btrim(question)) between 10 and 200),

  -- NOT NULL by design. No source, no market.
  resolution_source     text not null check (length(btrim(resolution_source)) >= 10),
  resolution_source_url text,
  -- what happens if the event is cancelled / drawn / unreported
  void_clause           text not null check (length(btrim(void_clause)) >= 10),
  resolution_date       timestamptz not null,

  status                market_status not null default 'DRAFT',
  rake_bps              int not null default 500 check (rake_bps between 0 and 1000),

  is_live               boolean not null default false,
  -- live markets cap stakes to bound the damage from a courtsiding exploit
  max_stake_minor       bigint check (max_stake_minor is null or max_stake_minor > 0),

  opens_at              timestamptz not null,
  locks_at              timestamptz not null,

  final_option_id       uuid,
  method                resolution_method,
  published_reason      text,
  settled_at            timestamptz,

  created_at            timestamptz not null default now(),

  constraint locks_after_open  check (locks_at > opens_at),
  -- you cannot claim a source will have published before betting even closes
  constraint resolves_after_lock check (resolution_date >= locks_at),
  -- live markets are short-lived by definition; a 3-day "live" market is a modelling error
  constraint live_is_short check (
    not is_live or locks_at <= opens_at + interval '4 hours'
  ),
  constraint settled_has_outcome check (
    status <> 'SETTLED' or (final_option_id is not null and method is not null)
  )
);

create index markets_status   on markets (status);
create index markets_locks_at on markets (locks_at) where status = 'OPEN';
create index markets_category on markets (category_id);
create index markets_live     on markets (is_live) where is_live;

create table market_options (
  id         uuid primary key default gen_random_uuid(),
  market_id  uuid not null references markets(id) on delete cascade,
  label      text not null check (length(btrim(label)) > 0),
  sort_order smallint not null default 0,
  -- denormalised for fast odds reads; invariant #5 asserts it against positions
  pool_minor bigint not null default 0 check (pool_minor >= 0),
  unique (market_id, label)
);

create index market_options_market on market_options (market_id);

alter table markets
  add constraint markets_final_option_fk
  foreign key (final_option_id) references market_options(id);

create table positions (
  id          uuid primary key default gen_random_uuid(),
  market_id   uuid not null references markets(id),
  option_id   uuid not null references market_options(id),
  user_id     uuid not null references app_users(id),
  stake_minor bigint not null check (stake_minor > 0),
  -- odds are NOT stored: in a parimutuel pool everyone on the winning side
  -- settles at the same rate, computed at settlement from the final pools.
  created_at  timestamptz not null default now()
);

create index positions_market on positions (market_id);
create index positions_user   on positions (user_id);
create index positions_option on positions (option_id);

-- ---------------------------------------------------------------- odds

-- Live odds for one option. NULL when undefined: an option with no money, or
-- no opposing money, has no counterparty and therefore no price. Show "be the
-- first", never a divide-by-zero or a fabricated number.
create or replace function option_odds(p_option uuid) returns numeric
language sql stable as $$
  select case
    when o.pool_minor <= 0 then null
    when t.total - o.pool_minor <= 0 then null
    -- multiply the whole numerator before dividing once: numeric division
    -- truncates to a fixed scale, so dividing early throws away precision
    else round((t.total * (10000 - m.rake_bps)) / (10000.0 * o.pool_minor), 4)
  end
  from market_options o
  join markets m on m.id = o.market_id
  cross join lateral (
    select coalesce(sum(x.pool_minor), 0)::numeric as total
    from market_options x where x.market_id = o.market_id
  ) t
  where o.id = p_option;
$$;

-- What a NEW stake would return at this instant.
-- Critical: the stake dilutes its own side. Projecting off pre-stake pools
-- overstates badly - on a 200/100 pool a 100 stake on the thin side returns 190,
-- but the naive calculation says 285.
create or replace function project_return(p_option uuid, p_stake bigint) returns bigint
language sql stable as $$
  select case
    when p_stake <= 0 then 0
    when (t.total + p_stake) - (o.pool_minor + p_stake) <= 0 then 0
    -- single division at the end. Dividing first costs real centavos:
    -- the staged form returned 66499 where the exact answer is 66500.
    else floor(
      (p_stake::numeric * (t.total + p_stake) * (10000 - m.rake_bps))
      / (10000.0 * (o.pool_minor + p_stake))
    )::bigint
  end
  from market_options o
  join markets m on m.id = o.market_id
  cross join lateral (
    select coalesce(sum(x.pool_minor), 0)::numeric as total
    from market_options x where x.market_id = o.market_id
  ) t
  where o.id = p_option;
$$;

-- A market is only settleable if at least two options hold money. One funded
-- side means the backers had no counterparty - settling would just return their
-- own money minus rake, which is theft. Void instead.
create or replace function has_counterparty(p_market uuid) returns boolean
language sql stable as $$
  select count(*) >= 2 from market_options
  where market_id = p_market and pool_minor > 0;
$$;
