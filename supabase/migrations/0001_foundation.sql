-- 0001_foundation.sql
-- Enums, identity, categories. No money yet.
--
-- Money is ALWAYS bigint minor units (centavos). Never numeric, never float.
-- 0.1 + 0.2 != 0.3 will eventually cost a payout dispute you cannot explain.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- enums

create type market_status as enum (
  'DRAFT',                -- being written, not visible
  'OPEN',                 -- accepting stakes
  'LOCKED',               -- lock-in period; pool frozen, event pending
  'PROPOSED',             -- an outcome is on the board, challenge window open
  'DISPUTED',             -- challenged, escalated to panel
  'SETTLED',              -- final, payouts run
  'VOIDED'                -- no valid outcome, everyone refunded in full
);

create type account_type as enum (
  'USER_WALLET',          -- account_ref = user id
  'MARKET_ESCROW',        -- account_ref = market id
  'BOND_ESCROW',          -- account_ref = user id; challenge bonds
  'HOUSE_RAKE',           -- account_ref null
  'PROMO_GRANT',          -- account_ref null; source of play-money grants
  'PSP_CLEARING'          -- account_ref null; real money only, unused in beta
);

create type entry_type as enum (
  'GRANT','STAKE','PAYOUT','RAKE','ROUNDING_SWEEP','REFUND',
  'BOND_HOLD','BOND_RETURN','BOND_FORFEIT','BOND_REWARD'
);

create type resolution_method as enum ('AUTO','UNCHALLENGED','PANEL','ADMIN','VOID');

-- ---------------------------------------------------------------- identity

create table app_users (
  id                uuid primary key default gen_random_uuid(),
  handle            text not null unique check (handle ~ '^[a-zA-Z0-9_]{3,20}$'),
  display_name      text not null,
  email             text unique,
  phone             text unique,
  email_verified_at timestamptz,
  phone_verified_at timestamptz,
  -- 0 = email only, 1 = mobile OTP (can post calls), 2 = full KYC (real money only)
  kyc_tier          smallint not null default 0 check (kyc_tier between 0 and 2),
  -- granted at onboarding for recruited creators. Identity claim, NOT a performance claim.
  verified_creator  boolean not null default false,
  is_staff          boolean not null default false,
  created_at        timestamptz not null default now()
);

comment on column app_users.verified_creator is
  'Granted at onboarding: "this really is who they say they are". Never implies a track record. '
  'Performance tiers are derived from settled positions only - see analyst_records.';

create table categories (
  id           text primary key,
  label        text not null,
  live_capable boolean not null default false,
  -- staff-only categories: politics is held back in beta (slow to resolve, most bad-faith argument)
  staff_only   boolean not null default false
);
