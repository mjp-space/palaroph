import { q, one, toMinor } from './db';

export type Option = {
  id: string;
  label: string;
  pool_minor: number;
  odds: number | null;   // null = no counterparty yet, not a price of zero
};

export type Market = {
  id: string;
  question: string;
  category_id: string;
  status: string;
  resolution_source: string;
  resolution_source_url: string | null;
  void_clause: string;
  rake_bps: number;
  is_live: boolean;
  max_stake_minor: number | null;
  opens_at: string;
  locks_at: string;
  resolution_date: string;
  total_minor: number;
  options: Option[];
  final_option_id: string | null;
  method: string | null;
  published_reason: string | null;
};

const MARKET_COLUMNS = `
  m.id, m.question, m.category_id, m.status, m.resolution_source,
  m.resolution_source_url, m.void_clause, m.rake_bps, m.is_live,
  m.max_stake_minor, m.opens_at, m.locks_at, m.resolution_date,
  m.final_option_id, m.method, m.published_reason,
  coalesce((select sum(o.pool_minor) from market_options o where o.market_id = m.id), 0) as total_minor,
  (
    select json_agg(json_build_object(
      'id', o.id, 'label', o.label, 'pool_minor', o.pool_minor,
      'odds', option_odds(o.id)
    ) order by o.sort_order, o.label)
    from market_options o where o.market_id = m.id
  ) as options
`;

function hydrate(row: any): Market {
  return {
    ...row,
    total_minor: toMinor(row.total_minor),
    max_stake_minor: row.max_stake_minor === null ? null : toMinor(row.max_stake_minor),
    options: (row.options ?? []).map((o: any) => ({
      ...o,
      pool_minor: toMinor(o.pool_minor),
      odds: o.odds === null ? null : Number(o.odds),
    })),
  };
}

export async function listMarkets(opts: { live?: boolean } = {}): Promise<Market[]> {
  const rows = await q(
    `select ${MARKET_COLUMNS} from markets m
      where m.status <> 'DRAFT'
        ${opts.live === undefined ? '' : 'and m.is_live = $1'}
      order by
        case m.status when 'OPEN' then 0 when 'LOCKED' then 1 else 2 end,
        m.locks_at asc`,
    opts.live === undefined ? [] : [opts.live],
  );
  return rows.map(hydrate);
}

export async function getMarket(id: string): Promise<Market | null> {
  const row = await one(`select ${MARKET_COLUMNS} from markets m where m.id = $1`, [id]);
  return row ? hydrate(row) : null;
}

export async function walletBalance(userId: string): Promise<number> {
  const row = await one<{ b: string }>(`select wallet_balance($1) as b`, [userId]);
  return toMinor(row?.b);
}

export async function myPositions(userId: string, marketId: string) {
  const rows = await q(
    `select p.option_id, o.label, sum(p.stake_minor) as staked
       from positions p join market_options o on o.id = p.option_id
      where p.user_id = $1 and p.market_id = $2
      group by p.option_id, o.label`,
    [userId, marketId],
  );
  return rows.map((r) => ({ ...r, staked: toMinor(r.staked) }));
}

/** What a stake would return right now — computed in SQL so the UI can never
 *  disagree with settlement. Includes self-dilution. */
export async function projectReturn(optionId: string, stakeMinor: number): Promise<number> {
  const row = await one<{ r: string }>(`select project_return($1, $2) as r`, [optionId, stakeMinor]);
  return toMinor(row?.r);
}

export async function ledger(userId: string, limit = 60) {
  const rows = await q(
    `select l.id, l.entry_type, l.amount_minor, l.memo, l.created_at, m.question
       from ledger_entries l
       left join markets m on m.id = l.market_id
      where l.account_type = 'USER_WALLET' and l.account_ref = $1
      order by l.id desc limit $2`,
    [userId, limit],
  );
  return rows.map((r) => ({ ...r, amount_minor: toMinor(r.amount_minor) }));
}

export async function listUsers() {
  return q(`select id, handle, display_name, verified_creator, is_staff
              from app_users order by handle`);
}

export async function invariants() {
  return q<{ invariant: string; ok: boolean; detail: string }>(`select * from check_invariants()`);
}

export async function houseTotals() {
  const rows = await q(
    `select account_type, coalesce(sum(amount_minor),0) as bal
       from ledger_entries group by account_type order by account_type`,
  );
  return rows.map((r) => ({ ...r, bal: toMinor(r.bal) }));
}
