'use client';

import { useState } from 'react';
import { placeStake } from '@/lib/actions';
import type { Option } from '@/lib/queries';

const CHIPS = [50, 100, 250, 500];

/**
 * Projections are computed server-side by project_return() for every
 * (option × chip) pair and passed in. The UI never does money arithmetic —
 * if it did, the number shown here could disagree with what settlement pays.
 */
export default function StakeForm({
  marketId, options, projections, capMinor, disabled,
}: {
  marketId: string;
  options: Option[];
  projections: Record<string, Record<number, number>>;
  capMinor: number | null;
  disabled?: boolean;
}) {
  const [sel, setSel] = useState<string | null>(null);
  const [stake, setStake] = useState(100);

  const option = options.find((o) => o.id === sel);
  const projected = sel ? projections[sel]?.[stake] ?? 0 : 0;
  const overCap = capMinor !== null && stake * 100 > capMinor;

  return (
    <>
      <div className="sides">
        {options.map((o, i) => (
          <button
            key={o.id}
            type="button"
            disabled={disabled}
            onClick={() => setSel(sel === o.id ? null : o.id)}
            className={`side ${i ? 'j' : ''} ${sel === o.id ? 'sel' : ''}`}
          >
            <div className="lbl"><span className="dot" />{o.label}</div>
            <div className="od">{o.odds ? o.odds.toFixed(2) : '—'}</div>
            <div className="pl">₱{(o.pool_minor / 100).toLocaleString('en-PH')} staked</div>
          </button>
        ))}
      </div>

      {disabled ? null : !sel ? (
        <div className="note">
          ▲ Tap a side to stake. Odds show “—” until both sides hold money — with an empty
          side there is no counterparty to win from.
        </div>
      ) : (
        <form action={placeStake} style={{ marginTop: 13, paddingTop: 13, borderTop: '1px solid var(--line)' }}>
          <input type="hidden" name="market_id" value={marketId} />
          <input type="hidden" name="option_id" value={sel} />
          <input type="hidden" name="stake_pesos" value={stake} />

          <div style={{ fontSize: 12, color: 'var(--dim)' }}>
            Stake on <b style={{ color: 'var(--txt)' }}>{option?.label}</b>
          </div>

          <div className="chips">
            {CHIPS.map((v) => (
              <button key={v} type="button" className={stake === v ? 'on' : ''} onClick={() => setStake(v)}>
                ₱{v}
              </button>
            ))}
          </div>

          <div className="proj">
            <div className="row"><span style={{ color: 'var(--dim)' }}>Stake</span><b>₱{stake}</b></div>
            <div className="row">
              <span style={{ color: 'var(--dim)' }}>Effective odds</span>
              <b>{projected > 0 ? (projected / (stake * 100)).toFixed(2) : '—'}</b>
            </div>
            <div className="row" style={{ marginTop: 8, paddingTop: 8, borderTop: '1px solid var(--line)' }}>
              <span style={{ color: 'var(--dim)' }}>Projected return</span>
              <b className="big">₱{(projected / 100).toLocaleString('en-PH', { maximumFractionDigits: 2 })}</b>
            </div>
          </div>

          <div className="note">
            ▲ Projected only. Your payout depends on the pool at lock-in, not now — everyone on
            the winning side settles at the same odds.
          </div>

          <button type="submit" className={`go ${sel === options[1]?.id ? 'j' : ''}`} style={{ marginTop: 11 }} disabled={overCap}>
            {overCap ? `Over this market's ₱${(capMinor! / 100).toLocaleString('en-PH')} cap` : `Place ₱${stake} on ${option?.label}`}
          </button>
        </form>
      )}
    </>
  );
}
