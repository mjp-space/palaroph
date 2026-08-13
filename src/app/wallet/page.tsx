import { ledger, walletBalance } from '@/lib/queries';
import { currentUserId } from '@/lib/actions';
import { peso } from '@/lib/db';

export const dynamic = 'force-dynamic';

const LABEL: Record<string, string> = {
  GRANT: 'Play-money grant',
  STAKE: 'Stake placed',
  PAYOUT: 'Payout · won',
  REFUND: 'Refund · market voided',
  BOND_HOLD: 'Challenge bond held',
  BOND_RETURN: 'Challenge bond returned',
  BOND_REWARD: 'Challenge upheld · reward',
  BOND_FORFEIT: 'Challenge rejected · bond forfeited',
};

export default async function WalletPage() {
  const userId = await currentUserId();
  const [balance, rows] = await Promise.all([walletBalance(userId), ledger(userId)]);

  return (
    <>
      <div className="card" style={{ textAlign: 'center', padding: '22px 15px' }}>
        <div style={{ fontSize: 10, color: 'var(--faint)', textTransform: 'uppercase', letterSpacing: .7 }}>
          Balance
        </div>
        <div style={{ fontSize: 34, fontWeight: 700, letterSpacing: -1.2 }} className="mono">
          {peso(balance)}
        </div>
        <div style={{ fontSize: 11, color: 'var(--faint)', marginTop: 6 }}>
          computed as <code>sum(ledger_entries)</code>, never stored
        </div>
      </div>

      <h3>Ledger · append-only</h3>
      {rows.length === 0 ? (
        <div className="empty">No entries yet. Place a stake to see one.</div>
      ) : (
        <div className="card led">
          {rows.map((e: any) => (
            <div className="r" key={e.id}>
              <div style={{ flex: 1, paddingRight: 10 }}>
                {LABEL[e.entry_type] ?? e.entry_type}
                <span>{e.question ?? e.memo ?? ''}</span>
              </div>
              <div className="amt">
                <span className={e.amount_minor > 0 ? 'cr' : e.amount_minor < 0 ? 'db' : 'zero'}>
                  {e.amount_minor > 0 ? '+' : ''}{peso(e.amount_minor)}
                </span>
                <span>{new Date(e.created_at).toLocaleTimeString('en-PH', { hour: '2-digit', minute: '2-digit' })}</span>
              </div>
            </div>
          ))}
        </div>
      )}

      <div className="card src">
        <b>Why this table matters</b>
        Your balance is never a number anyone edits — it is the sum of these rows. Postgres
        triggers reject UPDATE, DELETE and TRUNCATE on this table, so a movement can only ever
        be reversed by posting compensating entries.
        <span className="vc">
          Every dispute you will ever have with a user is settled by replaying this list.
        </span>
      </div>
    </>
  );
}
