import { listMarkets } from '@/lib/queries';
import MarketCard from '@/components/MarketCard';
import Flash from '@/components/Flash';

export const dynamic = 'force-dynamic';

export default async function MarketsPage() {
  let markets: Awaited<ReturnType<typeof listMarkets>> = [];
  let error: { message: string; hint?: string } | null = null;

  // A dead database should point you at the diagnosis, not throw Next's generic
  // "A server error occurred" with nothing to act on.
  try {
    markets = await listMarkets({ live: false });
  } catch (e: any) {
    error = { message: e.message, hint: e.hint };
  }

  if (error) {
    return (
      <>
        <h3>Can&apos;t load markets</h3>
        <div className="card" style={{ borderColor: 'rgba(255,107,107,.4)' }}>
          <div style={{ color: 'var(--warn)', fontSize: 13, marginBottom: 8 }}>{error.message}</div>
          {error.hint && <div style={{ fontSize: 12, color: 'var(--dim)', lineHeight: 1.5 }}>{error.hint}</div>}
        </div>
        <a href="/health"><button className="go gh">Open the health check →</button></a>
      </>
    );
  }

  const open = markets.filter((m) => m.status === 'OPEN');
  const rest = markets.filter((m) => m.status !== 'OPEN');

  return (
    <>
      <Flash />

      <h3>Open markets</h3>
      {open.length === 0 && (
        <div className="empty">
          No open markets.<br />
          <br />Seed some with <code>npm run seed</code>.
        </div>
      )}
      {open.map((m) => <MarketCard key={m.id} m={m} />)}

      {rest.length > 0 && (
        <>
          <h3>Locked & settled</h3>
          {rest.map((m) => <MarketCard key={m.id} m={m} />)}
        </>
      )}

      <div className="card" style={{ background: 'linear-gradient(180deg,rgba(74,158,255,.09),rgba(74,158,255,.03))', border: '1px dashed rgba(74,158,255,.35)' }}>
        <h2 style={{ fontSize: 13, color: 'var(--a)', margin: '0 0 4px' }}>These odds are real</h2>
        <p style={{ margin: 0, fontSize: 11.5, color: 'var(--dim)', lineHeight: 1.55 }}>
          Every price here is computed by <code>option_odds()</code> in Postgres from the money
          actually staked — not by anyone setting a line, and not by JavaScript. Place a stake and
          the pool re-prices for everyone.
        </p>
      </div>
    </>
  );
}
