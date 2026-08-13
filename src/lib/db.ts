import { Pool } from 'pg';

const url = process.env.DATABASE_URL ?? '';

// Supabase (and every hosted Postgres) requires TLS. node-pg does NOT enable it
// by default, so a connection string that works fine against localhost fails
// against Supabase with an opaque error. Turn it on for anything remote.
//
// rejectUnauthorized:false because Supabase's pooler presents a cert chain Node's
// default store doesn't carry. The connection is still encrypted.
const isLocal = /localhost|127\.0\.0\.1|\/tmp\//.test(url);

// Serverless gives every concurrent invocation its own process, so a pool of 10
// per instance multiplies fast and exhausts even the pooler. One connection per
// instance is the right shape here; the pooler does the real pooling.
const maxConnections = process.env.VERCEL ? 1 : 10;

const g = globalThis as unknown as { _pool?: Pool };

export const pool =
  g._pool ??
  new Pool({
    connectionString: url,
    max: maxConnections,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 10_000,
    ssl: isLocal ? undefined : { rejectUnauthorized: false },
  });

if (process.env.NODE_ENV !== 'production') g._pool = pool;

export class DbError extends Error {
  constructor(message: string, readonly hint: string) {
    super(message);
  }
}

/** Turn driver errors into something a human can act on, instead of Next's
 *  generic "A server error occurred". */
function explain(e: any): never {
  const code = e?.code;
  const msg = String(e?.message ?? e);

  if (!url) {
    throw new DbError('DATABASE_URL is not set', 'Add it in Vercel → Settings → Environment Variables, then redeploy.');
  }
  if (code === 'ENOTFOUND' || code === 'EAI_AGAIN') {
    throw new DbError('Database host not found', 'Check the hostname in DATABASE_URL.');
  }
  if (code === 'ETIMEDOUT' || code === 'ECONNREFUSED') {
    throw new DbError('Could not reach the database', 'Check the host and port. Supabase pooler is port 6543.');
  }
  if (/password authentication failed/i.test(msg)) {
    throw new DbError('Wrong database password', 'If it contains @ : / or #, percent-encode it, or reset to letters and numbers only.');
  }
  if (/no pg_hba|SSL|self signed|certificate/i.test(msg)) {
    throw new DbError('TLS problem connecting to the database', 'Hosted Postgres requires SSL.');
  }
  if (/relation .* does not exist|function .* does not exist/i.test(msg)) {
    throw new DbError('Schema is missing', 'Apply supabase/migrations/*.sql in order to this database.');
  }
  if (/too many clients/i.test(msg)) {
    throw new DbError('Too many connections', 'Use the transaction pooler (port 6543), not the direct connection (5432).');
  }
  throw new DbError(msg, 'See Vercel → Logs for the full error.');
}

export async function q<T = any>(sql: string, params: any[] = []): Promise<T[]> {
  try {
    const res = await pool.query(sql, params);
    return res.rows as T[];
  } catch (e) {
    explain(e);
  }
}

export async function one<T = any>(sql: string, params: any[] = []): Promise<T | null> {
  const rows = await q<T>(sql, params);
  return rows[0] ?? null;
}

/** Cheap connectivity probe for the health page. Never throws. */
export async function health(): Promise<{ ok: boolean; detail: string; hint?: string }> {
  try {
    const r = await pool.query('select 1 as ok');
    return { ok: r.rows[0].ok === 1, detail: 'connected' };
  } catch (e: any) {
    try {
      explain(e);
    } catch (d: any) {
      return { ok: false, detail: d.message, hint: d.hint };
    }
    return { ok: false, detail: String(e) };
  }
}

/**
 * Money is bigint centavos everywhere below the API. node-pg hands bigint back
 * as a string to avoid silent precision loss, which is correct — so parse
 * explicitly at the boundary rather than letting `+value` happen by accident.
 */
export const toMinor = (v: string | number | null | undefined): number =>
  v === null || v === undefined ? 0 : typeof v === 'number' ? v : parseInt(v, 10);

/** 123456 centavos -> "₱1,234.56" */
export const peso = (minor: number, opts: { decimals?: boolean } = {}): string => {
  const whole = minor / 100;
  return (
    '₱' +
    whole.toLocaleString('en-PH', {
      minimumFractionDigits: opts.decimals === false ? 0 : 2,
      maximumFractionDigits: opts.decimals === false ? 0 : 2,
    })
  );
};
