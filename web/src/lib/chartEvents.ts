// Polling loop that turns the backend's append-only chart_event log into
// browser notifications. Single global timer; multiple subscribers OK.
//
// Persistence model:
//   keywordista:lastSeenChartEvent  — newest createdAt we've already shown a
//                                     notification for. Filters future polls
//                                     so we never re-notify on reload.
//   keywordista:lastVisitedCharts   — when the user last opened /charts.
//                                     Drives the unread badge count.

import { writable, type Writable } from 'svelte/store';
import { getChartEvents } from './api';
import { notify } from './notifications';
import type { ChartEvent } from './types';

const STORAGE_LAST_SEEN = 'keywordista:lastSeenChartEvent';
const STORAGE_LAST_VISITED = 'keywordista:lastVisitedCharts';

// Default poll interval. Apple's RSS updates ~daily so this is conservative;
// the value matters more for "after pressing Check now, how soon do I see
// the event?" The backend job takes seconds, so 30s feels live.
const POLL_INTERVAL_MS = 30_000;

// Newest events first, broadcasted to anything that wants to render the
// activity feed without making its own fetch.
export const chartEvents: Writable<ChartEvent[]> = writable([]);

function readLastSeen(): string | null {
  try { return localStorage.getItem(STORAGE_LAST_SEEN); } catch { return null; }
}

function writeLastSeen(iso: string): void {
  try { localStorage.setItem(STORAGE_LAST_SEEN, iso); } catch { /* */ }
}

export function markChartsVisited(): void {
  try { localStorage.setItem(STORAGE_LAST_VISITED, new Date().toISOString()); } catch { /* */ }
}

export function lastVisited(): string | null {
  try { return localStorage.getItem(STORAGE_LAST_VISITED); } catch { return null; }
}

let timer: ReturnType<typeof setInterval> | null = null;
let inFlight = false;

export async function pollOnce(): Promise<void> {
  if (inFlight) return;
  inFlight = true;
  try {
    const since = readLastSeen() ?? undefined;
    const fresh = await getChartEvents(since, 50);
    if (fresh.length > 0) {
      // Server returns newest-first. Fire notifications in chronological
      // order so the last toast on the screen is the most recent event.
      const chronological = [...fresh].reverse();
      for (const ev of chronological) {
        notify(ev);
      }
      writeLastSeen(fresh[0].createdAt);
      chartEvents.update((existing) => {
        // Merge: keep ones we already had, prepend new (newest first).
        const seen = new Set(existing.map((e) => e.id));
        const merged = [...fresh.filter((e) => !seen.has(e.id)), ...existing];
        return merged.slice(0, 200);
      });
    }
  } catch (err) {
    // Network blips happen — don't spam the console.
    console.debug('chart-events poll failed:', err);
  } finally {
    inFlight = false;
  }
}

// Idempotent. Safe to call from multiple components — the singleton timer
// guards against duplicate intervals.
export function startChartEventPoll(): () => void {
  if (timer !== null) return () => {};
  // Fire once immediately so the dashboard hydrates without waiting a full
  // interval, then settle into the poll cadence.
  void pollOnce();
  timer = setInterval(() => void pollOnce(), POLL_INTERVAL_MS);
  return () => {
    if (timer !== null) {
      clearInterval(timer);
      timer = null;
    }
  };
}

// Seed the store from a single initial fetch — used by the /charts page so
// the activity feed renders without waiting for the next poll tick.
export async function loadInitialEvents(): Promise<void> {
  try {
    const fresh = await getChartEvents(undefined, 50);
    chartEvents.set(fresh);
    if (fresh.length > 0 && readLastSeen() === null) {
      // First-ever load: prime the "last seen" so we don't backfire
      // notifications for events that happened before the user enabled them.
      writeLastSeen(fresh[0].createdAt);
    }
  } catch (err) {
    console.debug('initial chart-events fetch failed:', err);
  }
}
