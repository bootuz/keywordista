// Centralized route map for svelte-spa-router.
//
// Hash-based routing was chosen for two reasons:
//   1. Vapor's existing SPAFallbackMiddleware already converts non-API
//      404s into index.html, but a hash router doesn't depend on that
//      contract — `#/login` always resolves to index.html without any
//      middleware contract change. Belt-and-suspenders.
//   2. The menubar app's WebView (future) and the in-browser deployment
//      view get the same URL shapes (`https://kw.example.com/#/login`)
//      regardless of how they're served.
//
// The auth-aware routing (kick to /login on 401, redirect to
// /bootstrap when firstRun is true, etc.) is NOT here — that lives
// in lib/stores/auth.ts (M2.3) + App.svelte (M2.10). This file is
// just the static map of paths → components.

import type { RouteDefinition } from 'svelte-spa-router';
import Dashboard from '../components/Dashboard.svelte';
import LoginPage from '../components/LoginPage.svelte';
import BootstrapInstructions from '../components/BootstrapInstructions.svelte';
import InviteAcceptPage from '../components/InviteAcceptPage.svelte';
import UsersAdmin from '../components/UsersAdmin.svelte';
import ComparePage from '../components/ComparePage.svelte';
import GapsPage from '../components/GapsPage.svelte';
import ChartsPage from '../components/ChartsPage.svelte';
import NotFoundPage from '../components/NotFoundPage.svelte';

// Routes are wildcards-last per svelte-spa-router conventions —
// the matcher walks them in declaration order, so '*' must be last.
//
// `RouteDefinition` from svelte-spa-router accepts Svelte 5
// `Component<...>` directly (v5.x of the router updated for this).
// Using the router's own type instead of `Record<string, ComponentType>`
// avoids a Svelte-4-vs-5 type-shape mismatch the legacy
// `ComponentType` produces.
export const routes: RouteDefinition = {
  '/': Dashboard,
  '/login': LoginPage,
  // M3.25 — /setup (SetupWizard) replaced by /bootstrap
  // (BootstrapInstructions, an empty-state docs page) because
  // admin creation moved to the createsuperuser CLI.
  '/bootstrap': BootstrapInstructions,
  '/invite/:token': InviteAcceptPage,
  '/settings/users': UsersAdmin,
  '/compare': ComparePage,
  '/gaps': GapsPage,
  '/charts': ChartsPage,
  // Wildcard last — anything unmatched lands on the 404 page.
  '*': NotFoundPage,
};

// Named route constants for callers that push() to a route. Keeping
// these as constants (not magic strings sprinkled across the codebase)
// means renaming a path is one edit, not a project-wide find/replace.
export const ROUTES = {
  dashboard: '/',
  login: '/login',
  bootstrap: '/bootstrap',
  invite: (token: string) => `/invite/${token}`,
  usersAdmin: '/settings/users',
  compare: '/compare',
  gaps: '/gaps',
  charts: '/charts',
} as const;
