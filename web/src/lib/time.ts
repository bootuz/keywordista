// "checked X ago" formatter for the dashboard's last-checked column.
// No external dep — relative time is two switch statements.
export function timeAgo(iso: string | null | undefined): string {
  if (!iso) return '—';
  const then = new Date(iso).getTime();
  const seconds = Math.floor((Date.now() - then) / 1000);
  if (seconds < 5) return 'Just now';
  if (seconds < 60) return `${seconds}s ago`;
  const m = Math.floor(seconds / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  const d = Math.floor(h / 24);
  if (d < 30) return `${d}d ago`;
  const mo = Math.floor(d / 30);
  if (mo < 12) return `${mo}mo ago`;
  return `${Math.floor(mo / 12)}y ago`;
}

export function isoCountryToFlag(cc: string): string {
  const code = cc.toUpperCase();
  if (code.length !== 2) return cc;
  // Regional indicator letters: A → 0x1F1E6, etc.
  const base = 0x1f1e6 - 'A'.charCodeAt(0);
  return String.fromCodePoint(code.charCodeAt(0) + base, code.charCodeAt(1) + base);
}
