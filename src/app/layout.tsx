import './globals.css';
import type { Metadata, Viewport } from 'next';
import { listUsers, walletBalance } from '@/lib/queries';
import { currentUserId, switchUser } from '@/lib/actions';
import { peso } from '@/lib/db';
import NavBar from '@/components/NavBar';

export const metadata: Metadata = { title: 'Palaro — prediction market' };
export const viewport: Viewport = { width: 'device-width', initialScale: 1, viewportFit: 'cover' };
export const dynamic = 'force-dynamic';

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const userId = await currentUserId();
  const [users, balance] = await Promise.all([listUsers(), walletBalance(userId)]);
  const me = users.find((u: any) => u.id === userId);

  return (
    <html lang="en">
      <body>
        <div id="shell">
          {/* Dev-only identity switcher. Real auth is Supabase email + mobile OTP. */}
          <div className="devbar">
            <span>DEV</span>
            <form action={switchUser}>
              <select name="user_id" defaultValue={userId}>
                {users.map((u: any) => (
                  <option key={u.id} value={u.id}>
                    {u.display_name} (@{u.handle}){u.is_staff ? ' · staff' : ''}
                  </option>
                ))}
              </select>
              <button type="submit">Switch</button>
            </form>
          </div>

          <header>
            <div className="brand">
              Palaro<small>play money · beta</small>
            </div>
            <div className="bal">
              <span>{me?.display_name ?? 'Wallet'}</span>
              <b>{peso(balance, { decimals: false })}</b>
            </div>
          </header>

          <main>{children}</main>
          <NavBar />
        </div>
      </body>
    </html>
  );
}
