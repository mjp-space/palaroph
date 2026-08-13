import { listMarkets } from '@/lib/queries';
import MarketCard from '@/components/MarketCard';
import Flash from '@/components/Flash';

export const dynamic = 'force-dynamic';

export default async function LivePage() {
  const markets = await listMarkets({ live: true });
  const open = markets.filter((m) => m.status === 'OPEN');
  const done = markets.filter((m) => m.status !== 'OPEN');

  return (
    <>
      <Flash />

      <h3>In-play micro-markets</h3>
      {open.length === 0 ? (
        <div className="empty">
          No live markets running.<br /><br />
          Open one from the <b>Console</b> tab — live markets are operator-driven in beta.
        </div>
      ) : (
        open.map((m) => <MarketCard key={m.id} m={m} />)
      )}

      {done.length > 0 && (
        <>
          <h3>Settled this session</h3>
          {done.map((m) => <MarketCard key={m.id} m={m} />)}
        </>
      )}

      <div className="card" style={{ background: 'linear-gradient(180deg,rgba(74,158,255,.09),rgba(74,158,255,.03))', border: '1px dashed rgba(74,158,255,.35)' }}>
        <h2 style={{ fontSize: 13, color: 'var(--a)', margin: '0 0 4px' }}>Why these are short, not one long market</h2>
        <p style={{ margin: 0, fontSize: 11.5, color: 'var(--dim)', lineHeight: 1.55 }}>
          A single “who wins?” market open all game would let 4th-quarter money — betting on a
          near-certainty — settle at the same odds as someone who called it at tipoff, diluting
          the early bettor to nothing.
          <br /><br />
          So each market locks <b>before</b> the thing it asks about is knowable. The database
          enforces it: a market flagged <code>is_live</code> cannot run more than four hours.
        </p>
      </div>
    </>
  );
}
