# Palaro

A Filipino prediction market — FlipTop, weather, sports, anything with a
checkable outcome. Pooled (parimutuel) odds, a three-layer resolution ladder,
live in-play micro-markets. **Play money only** (see *Legal* below).

**141 tests passing:** 52 core · 48 resolution · 32 privilege · 9 concurrency.

```
src/                    Next.js 15 app (App Router) — Vercel deploys this
supabase/migrations/    schema, in order; apply to Supabase as-is
tests/                  run.sh runs everything
scripts/                seed.sql, e2e.sh
```

## Setup

```bash
npm install
cp .env.example .env.local        # set DATABASE_URL
npm run dev                       # http://localhost:3000
```

**`DATABASE_URL` must be the Supabase transaction pooler string (port 6543)**,
not the direct connection — serverless opens a connection per invocation and
exhausts direct slots.

```
postgresql://postgres.<ref>:<password>@aws-0-ap-southeast-1.pooler.supabase.com:6543/postgres
```

Tests need a local Postgres:

```bash
./tests/run.sh
```

## The rules this codebase enforces

**1. Balance is never a column.** It is `sum(ledger_entries)`. Triggers reject
UPDATE, DELETE and TRUNCATE; privileges are revoked as well. Reversing a
movement means posting compensating entries — history is never edited.

**2. No money arithmetic in TypeScript.** Every peso moves through a tested SQL
function; every price comes from `option_odds()`. If the UI computed odds
independently, the number on screen could disagree with what settlement pays,
and the ledger would still be right.

**3. Money is `bigint` centavos.** Never numeric, never float.

**4. A market cannot exist without a resolution source and a void clause.**
Both `NOT NULL`. Most disputes come from badly-worded questions rather than
dishonest people, so ambiguity is made structurally impossible instead of
moderated afterwards.

**5. Payouts round DOWN, dust sweeps to house.** Parimutuel rarely divides
evenly. Round up and you are insolvent by a centavo per market.

**6. Nothing that moves money is reachable from the browser.** Supabase
publishes `public` through PostgREST, so every function was callable with the
anon key until `0006` revoked it. See below.

## Odds

Pooled. Nobody sets a price:

```
effective odds = (total pool − rake) ÷ winning side total
payout         = (your stake ÷ winning side total) × (total pool − rake)
```

`option_odds()` returns **NULL**, not a number, when a side is empty — no money
on an option, or none opposing it, means no counterparty and therefore no
price. Show "be the first", never a fabricated figure.

`project_return()` accounts for self-dilution: a new stake moves the odds it is
chasing. On a ₱200/₱100 pool, ₱100 on the thin side returns **₱190**, not the
naive ₱285.

## Resolution ladder

| Layer | Handles | Target volume |
|---|---|---|
| 1. Source declared at creation | prevents ambiguity | ~all markets |
| 2. Proposal + challenge window | routine settlement | ~95% |
| 3. 3-person blind panel → admin → void | real disputes | ~5% |

- **Proposals require evidence.** No URL, no proposal.
- **The proposer may not hold a position.** Enforced in `propose_outcome`.
- **Challenges cost a ₱100 bond.** Upheld returns it plus a reward; rejected
  forfeits it. Without a cost, every losing bettor challenges everything for
  free and you are back to a human in the loop for 100% of volume.
- **Panel votes are sealed** until all three are in — otherwise the first vote
  anchors the rest and you effectively have one moderator.
- **Conflict of interest is a query, not a policy.** `eligible_moderators()`
  filters out position holders, the creator and the proposer automatically.
- **A split panel voids** rather than forcing a call. Everyone refunded, zero
  rake. A void costs one market's revenue; a forced bad call costs half the
  users in it, permanently.

## Invariants

`select * from check_invariants()` and `check_bond_invariants()` — run in CI and
nightly. Any `ok = false` is stop-the-line.

| Invariant | Catches |
|---|---|
| `global_ledger_balances` | money created or destroyed |
| `every_txn_balances` | a malformed transaction |
| `finished_market_escrow_empty` | settlement that didn't fully pay out |
| `no_negative_wallet` | overdraft / double-spend |
| `pools_match_positions` | denormalised pool drift |
| `open_market_escrow_matches_pools` | escrow diverging from stakes |
| `bond_escrow_empty_when_resolved` | a bond never returned or forfeited |
| `no_moderator_holds_position` | a conflicted vote |

During development `open_market_escrow_matches_pools` caught a test fixture
that had written `pool_minor` directly instead of staking through
`place_stake`.

## Security note — read before adding any function

Supabase exposes the `public` schema through PostgREST. Every function in it is
reachable at `/rest/v1/rpc/<name>` with the **anon key, which ships in the
browser**. Before `0006_harden_api_surface.sql`, anyone could have run:

```
POST /rest/v1/rpc/grant_points  {p_user: <self>, p_amount: 999999999}
POST /rest/v1/rpc/settle_market {p_market: ..., p_winning_option: <mine>}
```

Local Postgres has no PostgREST, so 61 local tests passed with the door open.
It was found by Supabase's security advisor after deploying.

Two things follow. **Revoke from `PUBLIC`, not just from `anon`** — `anon`
inherits `PUBLIC`, and a revoke that names only the role leaves the grant
intact. And `tests/privileges.sql` asserts the whole surface, so adding a
function without locking it down fails CI.

## Not built yet

- **Real auth.** The orange DEV bar switches users via a cookie. Replace with
  Supabase Auth (email + mobile OTP = KYC tiers 0–1) before anyone else sees it.
- Market creation UI — markets are seeded via SQL
- Bet-acceptance delay + `PENDING` fund state for live markets
- Analyst records, tiers, calls, tail/fade
- Realtime odds push

## Legal

**Play money only, permanently non-redeemable.** PAGCOR has no licensing
category for prediction markets, and PayMongo's prohibited-business list bars
"games of chance… contests with a buy-in or cash prize" — so real-money
cash-in is blocked at the payment rails regardless of intent. Points must never
be purchasable or transferable between users. See the project design docs.
