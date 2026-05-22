// Pure comparator helpers for the dashboard table. All take a direction so
// the same function can drive ascending or descending sort. Null-handling is
// the only subtlety: unranked rows must always sink to the bottom regardless
// of direction, so we short-circuit on null *before* applying `dir`.

export type SortDirection = 'asc' | 'desc';

export function compareNullableNumber(
  a: number | null | undefined,
  b: number | null | undefined,
  dir: SortDirection,
): number {
  // Nulls always last, never affected by direction.
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  const cmp = a - b;
  return dir === 'asc' ? cmp : -cmp;
}

export function compareNumber(a: number, b: number, dir: SortDirection): number {
  const cmp = a - b;
  return dir === 'asc' ? cmp : -cmp;
}

export function compareString(a: string, b: string, dir: SortDirection): number {
  const cmp = a.localeCompare(b);
  return dir === 'asc' ? cmp : -cmp;
}

export function compareDate(
  a: string | null | undefined,
  b: string | null | undefined,
  dir: SortDirection,
): number {
  // Treat nulls as "never checked" — sink to bottom regardless of direction.
  if (!a && !b) return 0;
  if (!a) return 1;
  if (!b) return -1;
  const cmp = new Date(a).getTime() - new Date(b).getTime();
  return dir === 'asc' ? cmp : -cmp;
}

// Chains comparators — first non-zero result wins. Used for stable tiebreaking
// (e.g. when two rows share the same rank, fall back to country then term).
export function chain(...comparators: Array<() => number>): number {
  for (const fn of comparators) {
    const result = fn();
    if (result !== 0) return result;
  }
  return 0;
}
