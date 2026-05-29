<script lang="ts">
  // App shell + boot orchestration.
  //
  // Responsibilities (in order, on mount):
  //   1. Register the 401 handler with the api layer (M2.4's IoC
  //      hook). Fires when any API call returns 401 in server mode;
  //      clears local auth state + pushes to /login.
  //   2. Hydrate authState from /auth/state. AWAITED before mounting
  //      the router — otherwise the SPA would flicker through
  //      "Dashboard → LoginPage" on every refresh because the router
  //      would render with the wrong route assumption.
  //   3. Reactive route guard: derives a target path from
  //      (authState, location) and push()es if they disagree.
  //      Runs on every store-or-location change.
  //
  // Local-mode behavior is byte-identical to pre-M2 — the guard
  // sends users away from auth routes; SPA renders Dashboard at /.

  import { onMount } from 'svelte';
  // svelte-spa-router v5 exposes a reactive `router` object (Svelte 5
  // runes) — `router.location` replaces the legacy `location` store.
  import Router, { router, push } from 'svelte-spa-router';
  import { routes, ROUTES } from './lib/router';
  import Sidebar from './components/Sidebar.svelte';
  import {
    authState,
    hydrateAuthState,
    clearAuthState,
  } from './lib/authStore';
  import { setUnauthorizedHandler } from './lib/api';
  import type { AuthState } from './lib/types';

  let hydrated = $state(false);
  let hydrateError = $state<string | null>(null);

  onMount(() => {
    // Wire the 401 hook BEFORE the first network call. apiFetch
    // filters out /auth/* paths itself, so the LoginPage's own
    // 401 doesn't cause a redirect loop.
    setUnauthorizedHandler(async () => {
      await clearAuthState();
      push(ROUTES.login);
    });

    // Fire-and-forget hydration. We can't `await` in onMount cleanly
    // in Svelte 5 (it returns a teardown function); do it via a
    // local async IIFE so the boot sequence still finishes in one tick.
    void (async () => {
      try {
        await hydrateAuthState();
      } catch {
        hydrateError = "Couldn't reach the server. Refresh to try again.";
      } finally {
        hydrated = true;
      }
    })();

    // Clean up the 401 hook on teardown (HMR, tests).
    return () => setUnauthorizedHandler(null);
  });

  // Reactive route guard.
  //
  // The mental model: there's a "desired location" for every
  // (auth-state, current-location) pair. If desired != current, push.
  // No push when they match (or we'd loop).
  //
  // Runs only after hydration so we don't push someone away from
  // /invite/abc just because authState hasn't loaded yet.
  $effect(() => {
    if (!hydrated) return;
    const state = $authState;
    const path = router.location;
    if (!state) return;
    const target = computeRedirect(state, path);
    if (target && target !== path) {
      push(target);
    }
  });

  // Pure function — returns the path the user SHOULD be on, or null
  // if the current path is already valid. Extracted from the effect
  // so the logic can be reasoned about (and eventually unit-tested)
  // without spinning up a router.
  function computeRedirect(state: AuthState, path: string): string | null {
    // ── Local mode: no auth UI at all. ────────────────────────────
    // Send users away from any auth-related route — the menubar app
    // is the only client and it should never land on /login.
    // /invite/:token is left alone to fall through to NotFoundPage
    // (more honest than silently swallowing a link the user typed).
    if (state.mode === 'local') {
      if (
        path === ROUTES.login
        || path === ROUTES.bootstrap     // M3.25: was ROUTES.setup
        || path === ROUTES.usersAdmin
      ) {
        return ROUTES.dashboard;
      }
      return null;
    }

    // ── Server mode, first run: force /bootstrap. ─────────────────
    // No user exists yet; every path except /bootstrap itself is
    // useless until an admin is created via the createsuperuser
    // CLI (M3.25). /invite/* doesn't apply here either — invites
    // are issued by users, and there are none.
    if (state.firstRun) {
      return path === ROUTES.bootstrap ? null : ROUTES.bootstrap;
    }

    // ── Server mode, admin exists. ────────────────────────────────
    const isPublicAuthRoute =
      path === ROUTES.login
      || path === ROUTES.bootstrap
      || path.startsWith('/invite/');

    // Signed-in user revisiting login or the bootstrap-instructions
    // page → bounce to dashboard. /bootstrap is meaningless to a
    // logged-in user (admin already exists).
    if (state.signedIn && (path === ROUTES.login || path === ROUTES.bootstrap)) {
      return ROUTES.dashboard;
    }

    // Signed-out user trying to reach a protected route → /login.
    // /bootstrap stays accessible even post-bootstrap so a curious
    // operator can read the docs page if they navigate to it manually
    // (the page renders the same content regardless of firstRun).
    if (!state.signedIn && !isPublicAuthRoute) {
      return ROUTES.login;
    }

    return null;
  }

  // Auth routes render bare (no app shell) — a signed-out user must never
  // see product navigation. Everything else gets the persistent sidebar.
  function isAuthRoute(path: string): boolean {
    return (
      path === ROUTES.login
      || path === ROUTES.bootstrap
      || path.startsWith('/invite/')
    );
  }
</script>

{#if !hydrated}
  <!-- Pre-hydration: render nothing visible. The user sees a flash
       of empty white for ~50ms in the worst case; the alternative
       (a "Loading…" placeholder) creates a more jarring layout shift
       on a fast connection. -->
  <div class="min-h-screen bg-white dark:bg-zinc-950"></div>
{:else if hydrateError}
  <div class="flex items-center justify-center min-h-screen px-4">
    <div class="max-w-sm text-center space-y-2">
      <h1 class="text-lg font-semibold text-gray-900 dark:text-gray-100">
        Connection problem
      </h1>
      <p class="text-sm text-gray-500 dark:text-gray-400">
        {hydrateError}
      </p>
    </div>
  </div>
{:else if isAuthRoute(router.location)}
  <Router {routes} />
{:else}
  <div class="flex min-h-screen bg-white dark:bg-zinc-950">
    <Sidebar />
    <main class="min-w-0 flex-1">
      <Router {routes} />
    </main>
  </div>
{/if}
