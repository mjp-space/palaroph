import { Pool } from 'pg';

// One pool per process. Next dev reloads modules, so stash it on globalThis or
// every hot reload leaks connections until Postgres refuses new ones.
const g = globalThis as unknown as { _pool?: Pool };

export const pool =
  g._pool ??
  new Pool({
    connectionString: process.env.DATABASE_URL,
    max: 10,
    idleTimeoutMillis: 30_000,
  });

if (process.env.NODE_ENV !== 'production') g._pool = pool;

export async function q<T = any>(sql: string, params: any[] = []): Promise<T[]> {
  const res = await pool.query(sql, params);
  return res.rows as T[];
}

export async function one<T = any>(sql: string, params: any[] = []): Promise<T | null> {
  const rows = await q<T>(sql, params);
  return rows[0] ?? null;
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
