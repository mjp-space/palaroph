'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

const TABS = [
  { href: '/', icon: '◈', label: 'Markets' },
  { href: '/live', icon: '◉', label: 'Live' },
  { href: '/wallet', icon: '☰', label: 'Wallet' },
  { href: '/console', icon: '⚖', label: 'Console' },
];

export default function NavBar() {
  const path = usePathname();
  return (
    <nav>
      {TABS.map((t) => {
        const on = t.href === '/' ? path === '/' : path.startsWith(t.href);
        return (
          <Link key={t.href} href={t.href} className={on ? 'on' : ''}>
            <i>{t.icon}</i>
            {t.label}
          </Link>
        );
      })}
    </nav>
  );
}
