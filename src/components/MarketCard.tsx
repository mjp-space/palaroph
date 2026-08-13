import Link from 'next/link';
import { peso } from '@/lib/db';
import type { Market } from '@/lib/queries';

export function statusTag(status: string) {
  const cls =
    status === 'OPEN' ? 'live' :
    status === 'SETTLED' ? 'done' :
    status === 'VOIDED' ? 'void' : 'lock';
  return <span className={`tag ${cls}`}>{status === 'OPEN' ? '● open' : status}</span>;
}

export function countdown(iso: string): string {
  const ms = new Date(iso).getTime() - Date.now();
  if (ms <= 0) return 'due';
  const h = Math.floor(ms / 3_600_000);
  const m = Math.floor((ms % 3_600_000) / 60_000);
  if (h >= 24) return `${Math.floor(h / 24)}d ${h % 24}h`;
  return h > 0 ? `${h}h ${m}m` : `${m}m`;
}

export default function MarketCard({ m }: { m: Market }) {
  const [a, b] = m.options;
  const pctA = m.total_minor > 0 ? (a.pool_minor / m.total_minor) * 100 : 50;

  return (
    <Link href={`/market/${m.id}`}>
      <div className="card">
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 9 }}>
          <span className="tag">{m.category_id}{m.is_live ? ' · live' : ''}</span>
          {statusTag(m.status)}
        </div>
        <h2>{m.question}</h2>

        <div className="bar">
          <i style={{ width: `${pctA}%` }} />
          <i style={{ width: `${100 - pctA}%` }} />
        </div>

        <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12.5 }}>
          <span>
            <span className="dot" style={{ display: 'inline-block', marginRight: 5 }} />
            {a.label} <b className="mono">{a.odds ? a.odds.toFixed(2) : '—'}</b>
          </span>
          <span>
            <b className="mono">{b?.odds ? b.odds.toFixed(2) : '—'}</b> {b?.label}
            <span className="dot" style={{ display: 'inline-block', marginLeft: 5, background: 'var(--b)' }} />
          </span>
        </div>

        <div className="meta">
          <span>Pool {peso(m.total_minor, { decimals: false })}</span>
          {m.status === 'OPEN' && <span>Locks in {countdown(m.locks_at)}</span>}
          {m.status === 'SETTLED' && <span>Settled</span>}
          {m.status === 'VOIDED' && <span>Voided · refunded</span>}
        </div>
      </div>
    </Link>
  );
}
