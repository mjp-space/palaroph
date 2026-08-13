'use server';

import { cookies } from 'next/headers';
import { revalidatePath } from 'next/cache';
import { one } from './db';

/**
 * DEV SESSION ONLY.
 *
 * Real auth is Supabase Auth with email + mobile OTP (KYC tiers 0-1). Until
 * that exists, the "current user" is a cookie you can switch at will. This must
 * not survive contact with anything resembling production — it is here so the
 * money loop can be exercised end to end today.
 */
export async function currentUserId(): Promise<string> {
  const jar = await cookies();
  const existing = jar.get('demo_user')?.value;
  if (existing) return existing;
  const row = await one<{ id: string }>(`select id from app_users order by handle limit 1`);
  return row!.id;
}

export async function switchUser(formData: FormData) {
  const id = String(formData.get('user_id'));
  (await cookies()).set('demo_user', id, { httpOnly: true, sameSite: 'lax', path: '/' });
  revalidatePath('/', 'layout');
}

type Result = { ok: true; message: string } | { ok: false; message: string };

/**
 * Every one of these is a thin wrapper over a tested SQL function. No money
 * arithmetic happens in TypeScript — if it did, the UI and the ledger could
 * disagree, and the ledger would still be right.
 */

export async function placeStake(formData: FormData): Promise<void> {
  const optionId = String(formData.get('option_id'));
  const marketId = String(formData.get('market_id'));
  const stakeMinor = Math.round(Number(formData.get('stake_pesos')) * 100);
  const userId = await currentUserId();

  try {
    await one(`select place_stake($1, $2, $3) as id`, [userId, optionId, stakeMinor]);
  } catch (e: any) {
    // Postgres raised it, so the message is already the user-facing reason
    // ("insufficient balance: have X, need Y", "market locked at ...").
    (await cookies()).set('flash', `error:${e.message?.split('\n')[0] ?? 'Stake failed'}`, {
      path: '/', maxAge: 10,
    });
    revalidatePath(`/market/${marketId}`);
    return;
  }
  (await cookies()).set('flash', 'ok:Stake placed — odds re-priced', { path: '/', maxAge: 10 });
  revalidatePath(`/market/${marketId}`);
  revalidatePath('/');
  revalidatePath('/wallet');
}

export async function lockMarket(formData: FormData): Promise<void> {
  const marketId = String(formData.get('market_id'));
  await runGuarded(() => one(`select lock_market($1)`, [marketId]), 'Market locked');
  revalidateAll(marketId);
}

export async function settleMarket(formData: FormData): Promise<void> {
  const marketId = String(formData.get('market_id'));
  const optionId = String(formData.get('option_id'));
  const reason = String(formData.get('reason') || '') || null;

  await runGuarded(async () => {
    const row = await one<{ r: any }>(
      `select settle_market($1, $2, 'UNCHALLENGED', $3) as r`,
      [marketId, optionId, reason],
    );
    // settle_market auto-voids rather than settling unfairly, so report what
    // actually happened instead of assuming.
    const r = row?.r ?? {};
    return r.refunded_minor !== undefined
      ? `Auto-voided: ${r.reason}`
      : `Settled — ${(r.distributed_minor / 100).toLocaleString('en-PH')} paid out, dust ${r.rounding_swept_minor}c swept`;
  }, 'Settled');
  revalidateAll(marketId);
}

export async function voidMarket(formData: FormData): Promise<void> {
  const marketId = String(formData.get('market_id'));
  const reason = String(formData.get('reason') || 'Ambiguous — no clear source');
  await runGuarded(() => one(`select void_market($1, $2)`, [marketId, reason]), 'Voided — everyone refunded in full');
  revalidateAll(marketId);
}

export async function lockDue(): Promise<void> {
  await runGuarded(async () => {
    const row = await one<{ n: number }>(`select lock_due_markets() as n`);
    return `${row?.n ?? 0} market(s) locked by the scheduled sweep`;
  }, 'Sweep run');
  revalidatePath('/console');
  revalidatePath('/');
}

async function runGuarded(fn: () => Promise<any>, fallback: string) {
  const jar = await cookies();
  try {
    const res = await fn();
    jar.set('flash', `ok:${typeof res === 'string' ? res : fallback}`, { path: '/', maxAge: 10 });
  } catch (e: any) {
    jar.set('flash', `error:${e.message?.split('\n')[0] ?? 'Failed'}`, { path: '/', maxAge: 10 });
  }
}

function revalidateAll(marketId: string) {
  revalidatePath(`/market/${marketId}`);
  revalidatePath('/console');
  revalidatePath('/wallet');
  revalidatePath('/');
}

export async function readFlash(): Promise<{ kind: string; text: string } | null> {
  const raw = (await cookies()).get('flash')?.value;
  if (!raw) return null;
  const [kind, ...rest] = raw.split(':');
  return { kind, text: rest.join(':') };
}
