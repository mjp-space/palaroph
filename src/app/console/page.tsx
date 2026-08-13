import { listMarkets, invariants, houseTotals } from '@/lib/queries';
import { lockMarket, settleMarket, voidMarket, lockDue } from '@/lib/actions';
import { peso } from '@/lib/db';
import Flash from '@/components/Flash';
import { statusTag } from '@/components/MarketCard';

export const dynamic = 'force-dynamic';

export default async function ConsolePage() {
  const [markets, checks, totals] = await Promise.all([listMarkets(), invariants(), houseTotals()]);
  const openM = markets.filter((m) => m.status === 'OPEN');
  const lockedM = markets.filter((m) => m.status === 'LOCKED');
  const allOk = checks.every((c) => c.ok);

  return (
    <>
      <Flash />

      <h3>Ledger invariants</h3>
      <div className="card" style={allOk ? undefined : { borderColor: 'rgba(255,107,107,.4)' }}>
        {checks.map((c) => (
          <div className="inv" key={c.invariant}>
            <span className={`pip ${c.ok ? 'ok' : 'bad'}`} />
            <span className="nm">{c.invariant}</span>
            <span className="dt">{c.detail}</span>
          </div>
        ))}
      </div>
      <div className="note" style={{ margin: '-4px 4px 16px', color: allOk ? 'var(--faint)' : 'var(--warn)' }}>
        {allOk
          ? '▲ All green. Run these in CI and nightly — any red is a stop-the-line event.'
          : '▲ RED. Stop and investigate before any further movement.'}
      </div>

      <h3>Account totals</h3>
      <div className="card led">
        {totals.map((t: any) => (
          <div className="r" key={t.account_type}>
            <div style={{ fontFamily: 'ui-monospace,monospace', fontSize: 11.5 }}>{t.account_type}</div>
            <div className="amt mono">{peso(t.bal)}</div>
          </div>
        ))}
        <div className="r" style={{ borderTop: '1px solid var(--line)', marginTop: 4, paddingTop: 9 }}>
          <div><b>Net</b><span>must always be exactly zero</span></div>
          <div className="amt mono">
            <b className={totals.reduce((s: number, t: any) => s + t.bal, 0) === 0 ? 'cr' : 'db'}>
              {peso(totals.reduce((s: number, t: any) => s + t.bal, 0))}
            </b>
          </div>
        </div>
      </div>

      <h3>Scheduled sweep</h3>
      <div className="card">
        <p style={{ margin: '0 0 10px', fontSize: 12, color: 'var(--dim)', lineHeight: 1.5 }}>
          In production this is <code>pg_cron</code> calling <code>lock_due_markets()</code>. A market
          that locks late is a money bug — it is exactly the window that admits late money betting
          on a known outcome.
        </p>
        <form action={lockDue}>
          <button className="go gh sm" type="submit">Run lock_due_markets() now</button>
        </form>
      </div>

      {openM.length > 0 && (
        <>
          <h3>Open — lock to begin resolution</h3>
          {openM.map((m) => (
            <div className="card" key={m.id}>
              <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 8 }}>
                <span className="tag">{m.category_id}</span>
                {statusTag(m.status)}
              </div>
              <h2 style={{ fontSize: 14 }}>{m.question}</h2>
              <div className="meta"><span>Pool {peso(m.total_minor, { decimals: false })}</span></div>
              <form action={lockMarket} style={{ marginTop: 10 }}>
                <input type="hidden" name="market_id" value={m.id} />
                <button className="go gh sm" type="submit">⏱ Lock now</button>
              </form>
            </div>
          ))}
        </>
      )}

      <h3>Locked — awaiting resolution</h3>
      {lockedM.length === 0 && <div className="empty">Nothing waiting to be resolved.</div>}
      {lockedM.map((m) => (
        <div className="card" key={m.id}>
          <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 8 }}>
            <span className="tag">{m.category_id}</span>
            {statusTag(m.status)}
          </div>
          <h2 style={{ fontSize: 14 }}>{m.question}</h2>

          <div className="src" style={{ margin: '10px 0' }}>
            <b>Settles against</b>{m.resolution_source}
          </div>

          <form action={settleMarket}>
            <input type="hidden" name="market_id" value={m.id} />
            <label>Published reason (shown to every user)</label>
            <input type="text" name="reason" placeholder="e.g. PAGASA Severe Weather Bulletin #4" />
            <label>Winning outcome</label>
            <div className="btns">
              {m.options.map((o, i) => (
                <button key={o.id} className={`go sm ${i ? 'j' : ''}`} type="submit" name="option_id" value={o.id}>
                  {o.label} won
                </button>
              ))}
            </div>
          </form>

          <form action={voidMarket} style={{ marginTop: 8 }}>
            <input type="hidden" name="market_id" value={m.id} />
            <input type="hidden" name="reason" value="Ambiguous — no clear outcome under the stated source" />
            <button className="go dgr sm" type="submit">Void — refund everyone in full</button>
          </form>

          <div className="note">
            ▲ Settling an outcome nobody backed, or a market with only one funded side, auto-voids
            instead. A void costs one market&apos;s rake; a forced bad call costs half the users in it.
          </div>
        </div>
      ))}
    </>
  );
}
