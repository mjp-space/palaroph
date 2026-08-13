import { readFlash } from '@/lib/actions';

/** Surfaces whatever Postgres said. The SQL functions raise user-facing
 *  messages by design ("insufficient balance: have X, need Y"), so there is no
 *  second copy of the rules in TypeScript to drift out of sync. */
export default async function Flash() {
  const f = await readFlash();
  if (!f) return null;
  return <div className={`flash ${f.kind === 'ok' ? 'ok' : 'error'}`}>{f.text}</div>;
}
