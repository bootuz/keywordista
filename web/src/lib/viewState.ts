import { derived, writable } from 'svelte/store';
import { dashboard } from './stores';
import type { DashboardRow } from './types';
import {
  chain,
  compareDate,
  compareNullableNumber,
  compareNumber,
  compareString,
  type SortDirection,
} from './comparators';
import { groupRows, type GroupBy, type GroupSection } from './grouping';

export type SortColumn =
  | 'term'
  | 'country'
  | 'rank'
  | 'difficulty'
  | 'entryBarrier'
  | 'checkedAt';

export interface SortState {
  column: SortColumn | null;
  direction: SortDirection;
}

export type RankBucket = 'all' | 'top10' | 'top50' | 'top200' | 'unranked';

export interface FilterState {
  search: string;
  countries: string[]; // empty = all
  rankBucket: RankBucket;
  difficultyMin: number;
  difficultyMax: number;
  barrierMin: number;
  barrierMax: number;
}

export interface ViewPrefs {
  sort: SortState;
  filters: FilterState;
  groupBy: GroupBy;
  collapsedGroups: string[];
  currentAppId: string | null;
}

// ── Defaults ──────────────────────────────────────────────────────────────

export const DEFAULT_SORT: SortState = { column: 'rank', direction: 'asc' };
export const DEFAULT_FILTERS: FilterState = {
  search: '',
  countries: [],
  rankBucket: 'all',
  difficultyMin: 0,
  difficultyMax: 5,
  barrierMin: 0,
  barrierMax: 5,
};
export const DEFAULT_GROUP_BY: GroupBy = 'none';

const STORAGE_KEY = 'keywordista_view_prefs';

// ── Stores ────────────────────────────────────────────────────────────────

const initial = loadPrefs();
export const sort = writable<SortState>(initial.sort);
export const filters = writable<FilterState>(initial.filters);
export const groupBy = writable<GroupBy>(initial.groupBy);
export const collapsedGroups = writable<Set<string>>(new Set(initial.collapsedGroups));
// Which app the dashboard is scoped to. Null = none selected yet (no watched
// apps, or freshly loaded UI that hasn't picked one). Dashboard auto-selects
// the first app on load when null.
export const currentAppId = writable<string | null>(initial.currentAppId);

// ── Persistence ───────────────────────────────────────────────────────────

const prefsForStorage = derived(
  [sort, filters, groupBy, collapsedGroups, currentAppId],
  ([$sort, $filters, $groupBy, $collapsedGroups, $currentAppId]): ViewPrefs => ({
    sort: $sort,
    filters: $filters,
    groupBy: $groupBy,
    collapsedGroups: Array.from($collapsedGroups),
    currentAppId: $currentAppId,
  }),
);

prefsForStorage.subscribe((prefs) => {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(prefs));
  } catch {
    /* localStorage full or unavailable — fail silent, in-memory state still works. */
  }
});

function loadPrefs(): ViewPrefs {
  const fallback: ViewPrefs = {
    sort: DEFAULT_SORT,
    filters: DEFAULT_FILTERS,
    groupBy: DEFAULT_GROUP_BY,
    collapsedGroups: [],
    currentAppId: null,
  };
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return fallback;
    const parsed = JSON.parse(raw) as Partial<ViewPrefs>;
    return {
      sort: { ...DEFAULT_SORT, ...(parsed.sort ?? {}) },
      filters: { ...DEFAULT_FILTERS, ...(parsed.filters ?? {}) },
      groupBy: parsed.groupBy ?? DEFAULT_GROUP_BY,
      collapsedGroups: parsed.collapsedGroups ?? [],
      currentAppId: parsed.currentAppId ?? null,
    };
  } catch {
    return fallback;
  }
}

// ── Derived: filter → sort → group ────────────────────────────────────────

const SEARCH_DEBOUNCE_MS = 150;

// Rows for the active app only — before any user-driven filters.
// Used both for the table source and for the summary-strip counters.
export const appScopedRows = derived(
  [dashboard, currentAppId],
  ([$dashboard, $currentAppId]) =>
    $currentAppId ? $dashboard.filter((r) => r.watchedAppId === $currentAppId) : $dashboard,
);

export const filteredRows = derived(
  [appScopedRows, filters],
  ([$appScopedRows, $filters], set) => {
    // Debounce only the search field — other filters apply instantly.
    const apply = () => set(applyFilters($appScopedRows, $filters));
    if ($filters.search) {
      const handle = setTimeout(apply, SEARCH_DEBOUNCE_MS);
      return () => clearTimeout(handle);
    }
    apply();
  },
  [] as DashboardRow[],
);

export const sortedRows = derived(
  [filteredRows, sort],
  ([$filteredRows, $sort]) => applySort($filteredRows, $sort),
);

export const groupedSections = derived(
  [sortedRows, groupBy],
  ([$sortedRows, $groupBy]): GroupSection[] => groupRows($sortedRows, $groupBy),
);

// ── Filter logic ──────────────────────────────────────────────────────────

function applyFilters(rows: DashboardRow[], f: FilterState): DashboardRow[] {
  const needle = f.search.trim().toLowerCase();
  return rows.filter((r) => {
    if (needle && !r.term.toLowerCase().includes(needle) && !r.watchedAppName.toLowerCase().includes(needle)) {
      return false;
    }
    if (f.countries.length && !f.countries.includes(r.countryCode)) return false;
    if (!matchesBucket(r, f.rankBucket)) return false;
    if (r.difficulty < f.difficultyMin || r.difficulty > f.difficultyMax) return false;
    if (r.entryBarrier < f.barrierMin || r.entryBarrier > f.barrierMax) return false;
    return true;
  });
}

function matchesBucket(row: DashboardRow, bucket: RankBucket): boolean {
  switch (bucket) {
    case 'all':
      return true;
    case 'top10':
      return row.rank != null && row.rank <= 10;
    case 'top50':
      return row.rank != null && row.rank <= 50;
    case 'top200':
      return row.rank != null && row.rank <= 200;
    case 'unranked':
      return row.rank == null;
  }
}

// ── Sort logic ────────────────────────────────────────────────────────────

function applySort(rows: DashboardRow[], s: SortState): DashboardRow[] {
  if (!s.column) return rows;
  const sorted = [...rows].sort((a, b) =>
    chain(
      () => compareByColumn(a, b, s.column!, s.direction),
      // Stable tiebreakers — always ASC, so the secondary order stays sensible
      // no matter what the primary key direction is.
      () => compareString(a.countryCode, b.countryCode, 'asc'),
      () => compareString(a.term, b.term, 'asc'),
    ),
  );
  return sorted;
}

function compareByColumn(
  a: DashboardRow,
  b: DashboardRow,
  col: SortColumn,
  dir: SortDirection,
): number {
  switch (col) {
    case 'term':
      return compareString(a.term, b.term, dir);
    case 'country':
      return compareString(a.countryCode, b.countryCode, dir);
    case 'rank':
      return compareNullableNumber(a.rank, b.rank, dir);
    case 'difficulty':
      return compareNumber(a.difficulty, b.difficulty, dir);
    case 'entryBarrier':
      return compareNumber(a.entryBarrier, b.entryBarrier, dir);
    case 'checkedAt':
      return compareDate(a.checkedAt, b.checkedAt, dir);
  }
}

// ── Mutators (called from components) ─────────────────────────────────────

// 3-state header click: asc → desc → off → asc.
export function toggleSort(column: SortColumn): void {
  sort.update((s) => {
    if (s.column !== column) return { column, direction: 'asc' };
    if (s.direction === 'asc') return { column, direction: 'desc' };
    return { column: null, direction: 'asc' };
  });
}

export function toggleCollapsed(groupId: string): void {
  collapsedGroups.update((set) => {
    const next = new Set(set);
    if (next.has(groupId)) next.delete(groupId);
    else next.add(groupId);
    return next;
  });
}

export function clearFilters(): void {
  filters.set(DEFAULT_FILTERS);
}

// Pure helpers for the FilterBar — take the rows explicitly so `$derived`
// sees the real dependency on the dashboard store.
export function uniqueCountriesFrom(rows: DashboardRow[]): string[] {
  return Array.from(new Set(rows.map((r) => r.countryCode))).sort();
}

export function uniqueAppsFrom(rows: DashboardRow[]): Array<{ id: string; name: string }> {
  const seen = new Map<string, string>();
  for (const r of rows) seen.set(r.watchedAppId, r.watchedAppName);
  return Array.from(seen, ([id, name]) => ({ id, name })).sort((a, b) =>
    a.name.localeCompare(b.name),
  );
}
