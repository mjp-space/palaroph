import Link from 'next/link';
import { notFound } from 'next/navigation';
import { getMarket, myPositions, projectReturn } from '@/lib/queries';
import { currentUserId } from '@/lib/actions';
import { peso } from '@/lib/db';
import StakeForm from '@/components/StakeForm';
import Flash from '@/components/Flash';
import { statusTag, countdown } from '@/components/MarketCard';

export const dynamic = 'force-dynamic';

const CHIPS = [50, 100, 250, 500];

export default async function MarketPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const market = await getMarket(id);
  if (!market) notFound();

  const userId = await currentUserId();
  const positions = await myPositions(userId, id);

  // Precompute every projection server-side so the client never does money maths.
  const projections: Record<string, Record<number, number>> = {};
  if (market.status === 'OPEN') {
    for (const o of market.options) {
      projections[o.id] = {};
      for (const c of CHIPS) projections[o.id][c] = await projectReturn(o.id, c * 100);
    }
  }

  const pctA = market.total_minor > 0 ? (market.options[0].pool_minor / market.total_minor) * 100 : 50;
  const winner = market.options.find((o) => o.id === market.final_option_id);

  return (
    <>
      <div style={{ marginBottom: 12 }}>
        <Link href="/"><button className="go gh" style={{ width: 'auto', padding: '8px 14px', fontSize: 13 }}>← Markets</button></Link>
      </div>

      <Flash />

      <div className="card">
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 9 }}>
          <span className="tag">{market.category_id}</span>
          {statusTag(market.status)}
        </div>
        <h2>{market.question}</h2>

        <div style={{ display: 'flex', justifyContent: 'space-between', background: 'var(--card2)', borderRadius: 10, padding: '10px 13px', margin: '12px 0' }}>
          <div>
            <div style={{ fontSize: 9.5, color: 'var(--faint)', textTransform: 'uppercase', letterSpacing: .6 }}>
              {market.status === 'OPEN' ? 'Betting closes in' : 'Status'}
            </div>
            <div style={{ fontSize: 18, fontWeight: 700 }} className="mono">
              {market.status === 'OPEN' ? countdown(market.locks_at) : market.status}
            </div>
          </div>
          <div style={{ textAlign: 'right' }}>
            <div style={{ fontSize: 9.5, color: 'var(--faint)', textTransform: 'uppercase', letterSpacing: .6 }}>Total pool</div>
            <div style={{ fontSize: 18, fontWeight: 700 }} className="mono">{peso(market.total_minor, { decimals: false })}</div>
          </div>
        </div>

        <div className="bar">
          <i style={{ width: `${pctA}%` }} />
          <i style={{ width: `${100 - pctA}%` }} />
        </div>

        {market.status === 'OPEN' ? (
          <StakeForm
            marketId={market.id}
            options={market.options}
            projections={projections}
            capMinor={market.max_stake_minor}
          />
        ) : (
          <div className="sides">
            {market.options.map((o, i) => (
              <div key={o.id} className={`side ${i ? 'j' : ''}`} style={{ cursor: 'default' }}>
                <div className="lbl"><span className="dot" />{o.label}</div>
                <div className="od">{o.odds ? o.odds.toFixed(2) : '—'}</div>
                <div className="pl">{peso(o.pool_minor, { decimals: false })} staked</div>
                {market.final_option_id === o.id && <div className="win">✓ WON</div>}
              </div>
            ))}
          </div>
        )}
      </div>

      {positions.length > 0 && (
        <>
          <h3>Your positions</h3>
          <div className="card led">
            {positions.map((p: any) => (
              <div className="r" key={p.option_id}>
                <div>{p.label}<span>staked {peso(p.staked)}</span></div>
                <div className="amt">
                  {market.status === 'SETTLED'
                    ? (market.final_option_id === p.option_id ? <span className="cr">won</span> : <span className="zero">lost</span>)
                    : market.status === 'VOIDED' ? <span className="cr">refunded</span> : '—'}
                </div>
              </div>
            ))}
          </div>
        </>
      )}

      <h3>Resolution source</h3>
      <div className="card src">
        <b>Settles against</b>
        {market.resolution_source}
        {market.resolution_source_url && (
          <a href={market.resolution_source_url} style={{ color: 'var(--a)', display: 'block', marginTop: 4 }}>
            {market.resolution_source_url}
          </a>
        )}
        <span className="vc">{market.void_clause}</span>
      </div>

      {(market.status === 'SETTLED' || market.status === 'VOIDED') && market.published_reason && (
        <>
          <h3>Published resolution</h3>
          <div className="card src">
            <b>{market.status === 'VOIDED' ? 'Voided — everyone refunded in full' : `Resolved: ${winner?.label}`}</b>
            {market.published_reason}
            <span className="vc">
              Method: {market.method}. Users accept losing far better when they can see the reasoning —
              this text is public on the market.
            </span>
          </div>
        </>
      )}
    </>
  );
}
