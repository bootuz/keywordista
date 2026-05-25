// Auth-state stores. Single source of truth for "who is logged in"
// and "what mode is the backend in." Hydrated once on app boot via
// `hydrateAuthState()`; mutated thereafter by login / logout /
// accept-invite call sites + the 401 redirect (M2.4).
//
// Layered design:
//   • `authState`   — raw `/auth/state` response, the truth from the
//                     server.
//   • `currentUser` — derived shorthand for `authState.user`. Pages
//                     that just need "am I logged in / what's my role"
//                     subscribe to this, not the whole authState.
//   • `serverMode`  — derived `authState.mode === 'server'`. Gates
//                     every auth UI (header logout button, route
//                     guards, etc.) — false in local mode.
//   • `isAdmin`     — derived shorthand for role gating in the
//                     SPA (mirrors RoleMiddleware.requireAdmin on
//                     the server but is purely cosmetic; server is
//                     the real boundary).
//
// `hydrateAuthState()` is awaitable so App.svelte's onMount can wait
// for it before rendering the router — without that, the SPA would
// flicker through "Dashboard → LoginPage" on every refresh in
// server mode.

import { derived, get, writable } from 'svelte/store';
import { getAuthState } from './auth';
import type { AuthState, UserSummary } from './types';

// Raw `/auth/state` response. `null` means "haven't hydrated yet" —
// distinct from "hydrated but no user," which is `{...,signedIn:false}`.
export const authState = writable<AuthState | null>(null);

export const currentUser = derived<typeof authState, UserSummary | null>(
  authState,
  ($s) => $s?.user ?? null,
);

export const serverMode = derived<typeof authState, boolean>(
  authState,
  ($s) => $s?.mode === 'server',
);

export const isAdmin = derived<typeof authState, boolean>(
  authState,
  ($s) => $s?.user?.role === 'admin',
);

export const isFirstRun = derived<typeof authState, boolean>(
  authState,
  ($s) => $s?.firstRun === true,
);

// Hydration is exposed as a discrete async function (rather than a
// store + auto-fetch on first subscribe) so callers control WHEN it
// runs — App.svelte awaits this in onMount before mounting the
// router; tests can call it manually after seeding fixtures.
//
// Failure modes:
//   • Network error → store stays `null`. App.svelte's boot path
//     should treat that as "render a retry banner" rather than
//     deadlocking. The thrown error propagates so callers can decide.
//   • 401 → not possible here; `/auth/state` is public.
export async function hydrateAuthState(): Promise<AuthState> {
  const state = await getAuthState();
  authState.set(state);
  return state;
}

// Wipe local auth state. Called by:
//   • logout() success path
//   • the 401 redirect (M2.4) when the server rejects a stale cookie
//
// We re-fetch /auth/state right after to pick up the current mode +
// firstRun. Setting `signedIn: false` without re-hydrating would leak
// the prior user's mode / firstRun bits across a logout-login cycle.
export async function clearAuthState(): Promise<void> {
  const prev = get(authState);
  authState.set(
    prev
      ? { ...prev, signedIn: false, user: null }
      : null,
  );
  // Best-effort refresh so the SPA sees the truth. Swallow network
  // errors here — if the server's down we still want logout to feel
  // instantaneous in the UI.
  try {
    await hydrateAuthState();
  } catch {
    // Ignore — caller already has UI on the optimistic clear above.
  }
}
