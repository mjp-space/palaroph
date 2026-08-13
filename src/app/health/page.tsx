import { health } from '@/lib/db';
import { q } from '@/lib/db';

export const dynamic = 'force-dynamic';

/**
 * Deployment diagnostics. Reachable even when everything else 500s, because it
 * never assumes the database is up — that's the whole point.
 */
export default async function HealthPage() {
  const h = await health();

  let schema: { ok: boolean; detail: string } = { ok: false, detail: 'not checked' };
  let seeded: { ok: boolean; detail: string } = { ok: false, detail: 'not checked' };

  if (h.ok) {
    try {
      const t = await q<{ n: string }>(
        `select count(*)::text as n from information_schema.tables
          where table_schema='public' and table_name in
            ('markets','market_options','positions','ledger_entries','app_users')`,
      );
      const n = parseInt(t[0]?.n ?? '0', 10);
      schema = { ok: n === 5, detail: `${n}/5 core tables present` };
    } catch (e: any) {
      schema = { ok: false, detail: e.message };
    }

    try {
      const m = await q<{ n: string }>(`select count(*)::text as n from markets`);
      const n = parseInt(m[0]?.n ?? '0', 10);
      seeded = { ok: n > 0, detail: n > 0 ? `${n} markets` : 'no markets — run scripts/seed.sql' };
    } catch (e: any) {
      seeded = { ok: false, detail: e.message };
    }
  }

  const url = process.env.DATABASE_URL ?? '';
  // never print the password
  const redacted = url
    ? url.replace(/:\/\/([^:]+):([^@]+)@/, '://$1:••••••@')
    : '(not set)';
  const port = url.match(/:(\d{4,5})\//)?.[1] ?? '?';

  const rows = [
    { name: 'DATABASE_URL set', ok: !!url, detail: url ? 'yes' : 'missing — add it in Vercel → Settings → Environment Variables' },
    { name: 'Using the pooler (6543)', ok: port === '6543', detail: port === '?' ? 'could not read port' : `port ${port}${port === '5432' ? ' — should be 6543' : ''}` },
    { name: 'Database reachable', ok: h.ok, detail: h.detail },
    { name: 'Schema applied', ok: schema.ok, detail: schema.detail },
    { name: 'Demo data seeded', ok: seeded.ok, detail: seeded.detail },
  ];

  const allOk = rows.every((r) => r.ok);

  return (
    <>
      <h3>Deployment health</h3>
      <div className="card" style={allOk ? undefined : { borderColor: 'rgba(255,107,107,.4)' }}>
        {rows.map((r) => (
          <div className="inv" key={r.name}>
            <span className={`pip ${r.ok ? 'ok' : 'bad'}`} />
            <span className="nm">{r.name}</span>
            <span className="dt">{r.detail}</span>
          </div>
        ))}
      </div>

      {h.hint && (
        <div className="card src" style={{ borderColor: 'rgba(255,107,107,.3)' }}>
          <b>What to do</b>
          {h.hint}
        </div>
      )}

      <h3>Connection</h3>
      <div className="card">
        <code style={{ fontSize: 11, wordBreak: 'break-all', color: 'var(--dim)' }}>{redacted}</code>
      </div>

      {allOk && (
        <div className="card src">
          <b>All good</b>
          Everything is connected. Head to Markets.
        </div>
      )}
    </>
  );
}
