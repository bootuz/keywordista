// Formatting shared by the Apple Ads tabs. Money comes in the campaign's
// currency; ratios are fractions (0.05 = 5%). Missing values show as "—".

import type { AppleAdsMetrics } from './types';

export function fmtMoney(value: number | null | undefined, currency: string | null | undefined): string {
  if (value == null) return '—';
  try {
    return new Intl.NumberFormat(undefined, {
      style: 'currency',
      currency: currency || 'USD',
      maximumFractionDigits: value >= 100 ? 0 : 2,
    }).format(value);
  } catch {
    // Unknown currency code: plain number beats a thrown render.
    return value.toFixed(2);
  }
}

export function fmtPct(value: number | null | undefined): string {
  if (value == null) return '—';
  return `${(value * 100).toFixed(value < 0.1 ? 1 : 0)}%`;
}

export function fmtInt(value: number | null | undefined): string {
  return value == null ? '—' : new Intl.NumberFormat().format(value);
}

/** Relative change from `previous` to `current`, or null when there's no base. */
export function change(current: number | null | undefined, previous: number | null | undefined): number | null {
  if (current == null || previous == null || previous === 0) return null;
  return (current - previous) / previous;
}

/** Tailwind classes for a ratio cell: muted when the row has under 50 taps. */
export function lowDataClass(m: AppleAdsMetrics | null | undefined): string {
  return m?.lowData ? 'text-zinc-400 dark:text-zinc-600' : '';
}

export const LOW_DATA_TITLE = 'Not enough data: fewer than 50 taps in this period';
