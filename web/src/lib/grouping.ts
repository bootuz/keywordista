import type { DashboardRow } from './types';

export type GroupBy = 'none' | 'country' | 'app' | 'rankStatus' | 'difficulty';

export interface GroupSection {
  id: string;
  label: string;
  summary: string;
  rows: DashboardRow[];
}

// Bucket order for rankStatus — fixed so the UI is predictable.
const RANK_STATUS_ORDER = ['Top 10', 'Top 50', 'Top 200', 'Unranked'] as const;
type RankStatus = (typeof RANK_STATUS_ORDER)[number];

function rankStatusOf(row: DashboardRow): RankStatus {
  if (row.rank == null) return 'Unranked';
  if (row.rank <= 10) return 'Top 10';
  if (row.rank <= 50) return 'Top 50';
  return 'Top 200';
}

function avgRank(rows: DashboardRow[]): number | null {
  const ranked = rows.map((r) => r.rank).filter((r): r is number => r != null);
  if (ranked.length === 0) return null;
  return ranked.reduce((a, b) => a + b, 0) / ranked.length;
}

function summarize(rows: DashboardRow[]): string {
  const ranked = rows.filter((r) => r.rank != null).length;
  const avg = avgRank(rows);
  if (avg == null) return `${rows.length} rows · 0 ranked`;
  return `${rows.length} rows · ${ranked} ranked · avg #${avg.toFixed(0)}`;
}

// Groups rows according to `groupBy`. Returns a list of sections in display
// order. For `'none'`, returns a single anonymous section containing all rows
// (caller is expected to skip rendering the header in that case).
export function groupRows(rows: DashboardRow[], groupBy: GroupBy): GroupSection[] {
  if (groupBy === 'none') {
    return [{ id: 'all', label: '', summary: summarize(rows), rows }];
  }

  const buckets = new Map<string, DashboardRow[]>();
  for (const row of rows) {
    const key = bucketKey(row, groupBy);
    const arr = buckets.get(key);
    if (arr) arr.push(row);
    else buckets.set(key, [row]);
  }

  let entries = Array.from(buckets.entries());
  entries = orderBuckets(entries, groupBy);

  return entries.map(([key, bucketRows]) => ({
    id: key,
    label: labelFor(key, groupBy, bucketRows),
    summary: summarize(bucketRows),
    rows: bucketRows,
  }));
}

function bucketKey(row: DashboardRow, groupBy: GroupBy): string {
  switch (groupBy) {
    case 'country':
      return row.countryCode;
    case 'app':
      return row.watchedAppId;
    case 'rankStatus':
      return rankStatusOf(row);
    case 'difficulty':
      return String(row.difficulty);
    case 'none':
      return 'all';
  }
}

function labelFor(key: string, groupBy: GroupBy, rows: DashboardRow[]): string {
  switch (groupBy) {
    case 'country':
      return key.toUpperCase();
    case 'app':
      return rows[0]?.watchedAppName ?? key;
    case 'rankStatus':
      return key;
    case 'difficulty':
      return `Difficulty ${key}/5`;
    case 'none':
      return '';
  }
}

function orderBuckets(
  entries: Array<[string, DashboardRow[]]>,
  groupBy: GroupBy,
): Array<[string, DashboardRow[]]> {
  switch (groupBy) {
    case 'country':
      // Most-used country first, ties broken alphabetically.
      return entries.sort(([ak, ar], [bk, br]) => br.length - ar.length || ak.localeCompare(bk));
    case 'app':
      return entries.sort(([, a], [, b]) =>
        (a[0]?.watchedAppName ?? '').localeCompare(b[0]?.watchedAppName ?? ''),
      );
    case 'rankStatus':
      return entries.sort(
        ([a], [b]) =>
          RANK_STATUS_ORDER.indexOf(a as RankStatus) -
          RANK_STATUS_ORDER.indexOf(b as RankStatus),
      );
    case 'difficulty':
      return entries.sort(([a], [b]) => Number(a) - Number(b));
    case 'none':
      return entries;
  }
}
