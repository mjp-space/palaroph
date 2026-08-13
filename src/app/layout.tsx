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
  // The layout wraps every page, so a database failure here takes down even the
  // error and health pages. Degrade instead: render the shell, let the page
  // below report the actual problem.
  let users: any[] = [];
  let balance = 0;
  let userId = '';
  let dbDown = false;

  try {
    userId = await currentUserId();
    [users, balance] = await Promise.all([listUsers(), walletBalance(userId)]);
  } catch {
    dbDown = true;
  }

  const me = users.find((u: any) => u.id === userId);

  return (
    <html lang="en">
      <body>
        <div id="shell">
          {dbDown ? (
            <div className="devbar" style={{ background: 'rgba(255,107,107,.12)', borderColor: 'rgba(255,107,107,.3)', color: 'var(--warn)' }}>
              <span>DB</span>
              <span style={{ flex: 1 }}>
                Can&apos;t reach the database — open <a href="/health" style={{ textDecoration: 'underline' }}>/health</a> to see why
              </span>
            </div>
          ) : (
            /* Dev-only identity switcher. Real auth is Supabase email + mobile OTP. */
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
          )}

          <header>
            <div className="brand">
              Palaro<small>play money · beta</small>
            </div>
            <div className="bal">
              <span>{dbDown ? 'offline' : me?.display_name ?? 'Wallet'}</span>
              <b>{dbDown ? '—' : peso(balance, { decimals: false })}</b>
            </div>
          </header>

          <main>{children}</main>
          <NavBar />
        </div>
      </body>
    </html>
  );
}
