import { writable, get } from 'svelte/store';
import type { DashboardRow, WatchedApp } from './types';
import { getDashboard, getRefreshStatus } from './api';

// Shared UI state. Each store has a single owner (the component that calls
// the matching `set` after an API call); other components subscribe read-only.
export const dashboard = writable<DashboardRow[]>([]);
export const apps = writable<WatchedApp[]>([]);

// ── Refreshing state ────────────────────────────────────────────────────
//
// Map of keywordId → the Date when that row's refresh was triggered. Lives at
// the store level so multiple rows can spin simultaneously (per-row refresh
// or a "Refresh all" batch) and the central poll loop can reconcile them.
//
// The key insight: a row is "done" when its dashboard `checkedAt` advances
// past the startedAt timestamp captured here. That's the only source of truth
// we need — no queue accounting, no baseline subtraction, no negative numbers.
export const refreshing = writable<Map<string, Date>>(new Map());

export function markRefreshing(keywordId: string, startedAt: Date = new Date()): void {
  refreshing.update((m) => {
    const next = new Map(m);
    next.set(keywordId, startedAt);
    return next;
  });
}

export function clearRefreshing(keywordId: string): void {
  refreshing.update((m) => {
    const next = new Map(m);
    next.delete(keywordId);
    return next;
  });
}

// ── Refresh batch (Refresh All) ─────────────────────────────────────────
//
// When the user clicks Refresh All we capture the set of keyword IDs that
// belong to *this* batch. The header chip's count comes from how many of
// those are still in the `refreshing` map. Persisted to localStorage so a
// page reload reconnects the chip to the same batch — the queue keeps going
// either way.
export interface RefreshBatch {
  ids: string[];
  startedAt: Date;
}

const REFRESH_BATCH_KEY = 'keywordista_refresh_batch';

function loadBatch(): RefreshBatch | null {
  try {
    const raw = localStorage.getItem(REFRESH_BATCH_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as { ids: string[]; startedAt: string };
    return { ids: parsed.ids, startedAt: new Date(parsed.startedAt) };
  } catch {
    return null;
  }
}

export const refreshBatch = writable<RefreshBatch | null>(loadBatch());

refreshBatch.subscribe((batch) => {
  try {
    if (!batch) {
      localStorage.removeItem(REFRESH_BATCH_KEY);
    } else {
      localStorage.setItem(
        REFRESH_BATCH_KEY,
        JSON.stringify({ ids: batch.ids, startedAt: batch.startedAt.toISOString() }),
      );
    }
  } catch {
    /* fail silent */
  }
});

// ── Shared polling loop ─────────────────────────────────────────────────
//
// One poll loop services every active refresh, regardless of how it was
// triggered. Every tick it fetches /dashboard *and* /refresh-status, then
// runs reconcile() which clears any id whose:
//   1. row's checkedAt has advanced past its stored startedAt (happy path),
//   2. row is missing from the dashboard (keyword was deleted mid-batch),
//   3. queue has drained (pending == 0) but the id still hasn't advanced —
//      i.e. the job ran but the iTunes call failed or the RankCheck wasn't
//      persisted. Silent job failures used to wedge the spinner until the
//      user reloaded; the queue-empty signal is the authoritative "we are
//      done, give up on stragglers" trigger.
//
// `ensurePolling()` is idempotent — calling it twice doesn't start a second
// loop. Per-row and batch refresh both call it after they mark IDs.
const POLL_INTERVAL_MS = 2_000;
// Grace before treating queue-empty as authoritative. The queue can briefly
// dip to 0 between dispatch and the worker picking up the next job; this
// window prevents reconcile from prematurely clearing an id that hasn't
// actually run yet.
const QUEUE_EMPTY_GRACE_MS = 5_000;
let pollingActive = false;

export function ensurePolling(): void {
  if (pollingActive) return;
  pollingActive = true;
  void (async () => {
    try {
      while (get(refreshing).size > 0) {
        await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
        try {
          // Fetch both in parallel — saves a round-trip on slow networks
          // and keeps the dashboard view + queue gauge in lockstep so the
          // user doesn't see a stale "Refreshing N/M" chip after the queue
          // has already drained.
          const [fresh, status] = await Promise.all([
            getDashboard(),
            getRefreshStatus(),
          ]);
          dashboard.set(fresh);
          reconcile(fresh, status.pending);
        } catch {
          // Transient network failure — let the next iteration retry.
          // We don't bail out of the loop because the worker is still
          // chewing through queued jobs even if our fetch hiccupped.
        }
      }
    } finally {
      pollingActive = false;
    }
  })();
}

function reconcile(rows: DashboardRow[], queuePending: number): void {
  const now = Date.now();
  refreshing.update((m) => {
    const next = new Map(m);
    for (const [id, startedAt] of next) {
      const row = rows.find((r) => r.keywordId === id);
      // 1. Happy path — the row's checkedAt has advanced past startedAt.
      if (row?.checkedAt && new Date(row.checkedAt).getTime() >= startedAt.getTime()) {
        next.delete(id);
        continue;
      }
      // 2. Orphan — the keyword was deleted while the batch was running.
      // Nothing to wait for; drop the spinner.
      if (!row) {
        next.delete(id);
        continue;
      }
      // 3. Silent failure — queue has drained but this id didn't advance.
      // Job either errored (RefreshKeywordJob.error just logs) or hit some
      // edge case that bypassed persistRankChecks. Grace window prevents
      // the dispatch-boundary race where pending briefly reads 0.
      if (queuePending === 0 && now - startedAt.getTime() > QUEUE_EMPTY_GRACE_MS) {
        next.delete(id);
        continue;
      }
    }
    return next;
  });

  // If the batch is fully done, drop it.
  const batch = get(refreshBatch);
  if (batch) {
    const stillPending = batch.ids.some((id) => get(refreshing).has(id));
    if (!stillPending) refreshBatch.set(null);
  }
}

// ── Developer keywords (ASC) ────────────────────────────────────────────
//
// Indexed appId → countryCode → set of normalized terms. Phase 4b will
// populate this via the ASC API and persist into the same localStorage key,
// so the seam is consistent across UI reloads and API loads.
// Shape on disk:
//   { "<appUUID>": { "us": ["flashcards", "anki"], "jp": ["暗記カード"] } }
const DEV_KW_STORAGE_KEY = 'keywordista_developer_keywords';

function loadDeveloperKeywords(): Map<string, Map<string, Set<string>>> {
  try {
    const raw = localStorage.getItem(DEV_KW_STORAGE_KEY);
    if (!raw) return new Map();
    const parsed = JSON.parse(raw) as Record<string, Record<string, string[]>>;
    const out = new Map<string, Map<string, Set<string>>>();
    for (const [appId, byCountry] of Object.entries(parsed)) {
      const inner = new Map<string, Set<string>>();
      for (const [cc, terms] of Object.entries(byCountry)) {
        inner.set(cc.toLowerCase(), new Set(terms.map((t) => t.toLowerCase())));
      }
      out.set(appId, inner);
    }
    return out;
  } catch {
    return new Map();
  }
}

export const developerKeywords = writable<Map<string, Map<string, Set<string>>>>(
  loadDeveloperKeywords(),
);

developerKeywords.subscribe((map) => {
  try {
    const obj: Record<string, Record<string, string[]>> = {};
    for (const [appId, byCountry] of map) {
      obj[appId] = {};
      for (const [cc, set] of byCountry) {
        obj[appId][cc] = Array.from(set);
      }
    }
    localStorage.setItem(DEV_KW_STORAGE_KEY, JSON.stringify(obj));
  } catch {
    /* fail silent */
  }
});

export function normalizeTerm(t: string): string {
  return t.trim().toLowerCase();
}

export function isInDeveloperKeywords(
  table: Map<string, Map<string, Set<string>>>,
  appId: string,
  countryCode: string,
  term: string,
): boolean {
  return table.get(appId)?.get(countryCode.toLowerCase())?.has(normalizeTerm(term)) ?? false;
}
