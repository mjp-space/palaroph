# Getting this live — about 10 minutes

Three steps: push to GitHub, connect Vercel, point it at Supabase.

---

## 1. Push to GitHub

Create a **new empty repository** at https://github.com/new — name it `palaro`,
and **do not** tick "Add a README" or any of the initialise options. An empty
repo is what you want; this folder already has its full git history.

Then, in this folder:

```bash
git remote add origin https://github.com/YOUR-USERNAME/palaro.git
git push -u origin main
```

If it asks for a password, GitHub wants a **personal access token**, not your
account password — create one at Settings → Developer settings → Personal
access tokens, with `repo` scope, and paste that.

---

## 2. Get your Supabase password

The project is already created and migrated: **palaro-ph**,
`qvlxxtbkvrwvhdokxcnb`, Singapore.

1. Open https://supabase.com/dashboard/project/qvlxxtbkvrwvhdokxcnb
2. **Project Settings → Database → Reset database password**
3. Copy it immediately — it is shown once

Your connection string is then:

```
postgresql://postgres.qvlxxtbkvrwvhdokxcnb:YOUR-PASSWORD@aws-0-ap-southeast-1.pooler.supabase.com:6543/postgres
```

⚠️ **Port 6543, the transaction pooler** — not the direct connection on 5432.
Vercel runs serverless functions that open a connection per invocation and will
exhaust direct connection slots. This is the single most common way a
Supabase + Vercel deploy falls over under any real traffic.

If your password contains `@`, `:`, `/` or `#`, URL-encode it (`@` → `%40`).
Easiest to just reset it until you get one without those.

---

## 3. Connect Vercel

1. https://vercel.com/new → **Import Git Repository** → pick `palaro`
2. Framework preset: **Next.js** (it should auto-detect)
3. Root directory: **leave as `.`** — the app is at the repo root deliberately
4. Before deploying, open **Environment Variables** and add:

   | Name | Value |
   |---|---|
   | `DATABASE_URL` | the pooler string from step 2 |

   Tick all three environments (Production, Preview, Development).
5. **Deploy**

You get a URL like `palaro.vercel.app`. Open it on your phone.

---

## From then on

Every push to `main` auto-deploys. GitHub Actions also runs all 141 tests on
each push — the ✓ or ✗ next to your commit tells you whether the deploy that
just went out is sound.

---

## If something goes wrong

**Blank page or a 500** — check Vercel → your project → **Logs**. Almost always
`DATABASE_URL`: wrong password, or the direct connection string instead of the
pooler.

**"Too many connections"** — you used port 5432. Switch to 6543.

**"password authentication failed"** — special characters in the password.
Reset it to one that is letters and numbers only.

**Markets list is empty** — the seed didn't run. In the Supabase dashboard open
**SQL Editor** and paste the contents of `scripts/seed.sql`.

**Tests fail in Actions but the site works** — that's fine to look at later;
the CI Postgres is a fresh empty database, unrelated to your live data.

---

## What you'll see

The app opens on the markets list. Note the orange **DEV** bar at the top — it
switches which user you are, because real login isn't built yet. That is the
next thing to build, and it must be replaced before anyone else uses this.

Tabs: **Markets** (live pooled odds) · **Live** (in-play) · **Wallet**
(balance + the ledger behind it) · **Console** (invariants, and lock/settle/void).

The Console is worth opening first. It shows the six ledger invariants and the
account totals netting to exactly ₱0.00 — that's the double-entry guarantee,
live, on your own data.
