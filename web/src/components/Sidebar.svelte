<script lang="ts">
  // Persistent app-shell navigation. Rendered by App.svelte for every
  // product route (not the auth routes). Holds the "lenses" (Dashboard,
  // Charts, Compare, Gaps) plus the meta cluster (Settings, Sign out,
  // GitHub). App-scoped controls (AppSwitcher, +Keyword, Refresh) stay in
  // the Dashboard's own top bar because they only apply there.
  import { onMount } from 'svelte';
  import { router, push } from 'svelte-spa-router';
  import { ROUTES } from '../lib/router';
  import { logout } from '../lib/auth';
  import { clearAuthState, currentUser, serverMode } from '../lib/authStore';
  import { chartEvents, lastVisited, startChartEventPoll } from '../lib/chartEvents';
  import SettingsPanel from './SettingsPanel.svelte';

  // The unread badge lives here now, so the poll must run app-wide (not just
  // on the dashboard). startChartEventPoll is idempotent — safe if something
  // else already started it.
  onMount(() => startChartEventPoll());

  // Collapse state persists across reloads so the user's space/density
  // preference sticks. Defaults to expanded (labeled).
  let collapsed = $state(localStorage.getItem('kw:sidebar-collapsed') === '1');
  $effect(() => {
    localStorage.setItem('kw:sidebar-collapsed', collapsed ? '1' : '0');
  });

  let showSettings = $state(false);
  let loggingOut = $state(false);

  // router.location is the reactive current path (v5 runes API), e.g. "/gaps".
  const path = $derived(router.location);
  const isActive = (href: string): boolean => path === href;

  // Same unread-events badge the old header showed, now on the Charts item.
  const chartsUnread = $derived.by(() => {
    const last = lastVisited();
    if (!last) return $chartEvents.length;
    const lastDate = new Date(last).getTime();
    return $chartEvents.filter((e) => new Date(e.createdAt).getTime() > lastDate).length;
  });

  async function handleLogout(): Promise<void> {
    if (loggingOut) return;
    loggingOut = true;
    try {
      await logout();
    } catch {
      // Idempotent server-side; clear local state regardless.
    } finally {
      await clearAuthState();
      push(ROUTES.login);
      loggingOut = false;
    }
  }

  const nav = [
    { href: ROUTES.dashboard, label: 'Dashboard' },
    { href: ROUTES.charts, label: 'Charts' },
    { href: ROUTES.compare, label: 'Compare' },
    { href: ROUTES.gaps, label: 'Gaps' },
    { href: ROUTES.optimizer, label: 'Optimizer' },
  ];

  // Shared classes for a sidebar row (nav link or meta button).
  const rowBase =
    'flex items-center gap-3 rounded-md px-3 py-2 text-sm transition-colors';
  const rowIdle =
    'text-zinc-600 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800 hover:text-zinc-900 dark:hover:text-zinc-100';
  const rowActive =
    'bg-zinc-100 dark:bg-zinc-800 text-zinc-900 dark:text-zinc-100 font-medium';
</script>

<aside
  class="flex shrink-0 flex-col border-r border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-950 transition-[width] duration-200 {collapsed ? 'w-14' : 'w-56'}"
>
  <!-- Brand + collapse toggle -->
  <div class="flex h-12 items-center gap-2 border-b border-zinc-200 px-3 dark:border-zinc-800">
    {#if !collapsed}
      <span class="truncate text-sm font-semibold tracking-tight text-zinc-900 dark:text-zinc-100">
        Keywordista
      </span>
    {/if}
    <button
      type="button"
      onclick={() => (collapsed = !collapsed)}
      title={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
      aria-label={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
      class="ml-auto rounded-md p-1.5 text-zinc-500 hover:bg-zinc-100 hover:text-zinc-900 dark:hover:bg-zinc-800 dark:hover:text-zinc-100"
    >
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        {#if collapsed}
          <path d="M9 18l6-6-6-6" />
        {:else}
          <path d="M15 18l-6-6 6-6" />
        {/if}
      </svg>
    </button>
  </div>

  <!-- Nav (the "lenses") -->
  <nav class="flex-1 space-y-1 overflow-y-auto p-2">
    {#each nav as item (item.href)}
      <a
        href="#{item.href}"
        title={collapsed ? item.label : undefined}
        class="{rowBase} {isActive(item.href) ? rowActive : rowIdle} {collapsed ? 'justify-center' : ''}"
        aria-current={isActive(item.href) ? 'page' : undefined}
      >
        <span class="relative grid place-items-center">
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            {#if item.label === 'Dashboard'}
              <rect x="3" y="3" width="7" height="7" /><rect x="14" y="3" width="7" height="7" /><rect x="14" y="14" width="7" height="7" /><rect x="3" y="14" width="7" height="7" />
            {:else if item.label === 'Charts'}
              <line x1="18" y1="20" x2="18" y2="10" /><line x1="12" y1="20" x2="12" y2="4" /><line x1="6" y1="20" x2="6" y2="14" />
            {:else if item.label === 'Compare'}
              <rect x="3" y="3" width="7" height="18" /><rect x="14" y="3" width="7" height="18" />
            {:else if item.label === 'Gaps'}
              <circle cx="12" cy="12" r="9" /><circle cx="12" cy="12" r="4" /><circle cx="12" cy="12" r="0.5" fill="currentColor" />
            {:else}
              <path d="M12 3l1.9 5.8a2 2 0 0 0 1.3 1.3L21 12l-5.8 1.9a2 2 0 0 0-1.3 1.3L12 21l-1.9-5.8a2 2 0 0 0-1.3-1.3L3 12l5.8-1.9a2 2 0 0 0 1.3-1.3L12 3z" />
            {/if}
          </svg>
          {#if item.label === 'Charts' && chartsUnread > 0}
            <span
              class="absolute -right-1.5 -top-1.5 grid h-4 min-w-4 place-items-center rounded-full bg-amber-500 px-1 text-[10px] font-bold text-zinc-950"
              aria-label="{chartsUnread} unread chart events"
            >
              {chartsUnread}
            </span>
          {/if}
        </span>
        {#if !collapsed}<span class="truncate">{item.label}</span>{/if}
      </a>
    {/each}
  </nav>

  <!-- Meta cluster -->
  <div class="space-y-1 border-t border-zinc-200 p-2 dark:border-zinc-800">
    <button
      type="button"
      onclick={() => (showSettings = true)}
      title={collapsed ? 'Settings' : undefined}
      class="{rowBase} {rowIdle} w-full {collapsed ? 'justify-center' : ''}"
    >
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <circle cx="12" cy="12" r="3" />
        <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33h0a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82v0a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
      </svg>
      {#if !collapsed}<span class="truncate">Settings</span>{/if}
    </button>

    {#if $serverMode && $currentUser}
      <button
        type="button"
        onclick={handleLogout}
        disabled={loggingOut}
        title={collapsed ? `Sign out (${$currentUser.email})` : undefined}
        class="{rowBase} {rowIdle} w-full disabled:opacity-60 {collapsed ? 'justify-center' : ''}"
      >
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" /><polyline points="16 17 21 12 16 7" /><line x1="21" y1="12" x2="9" y2="12" />
        </svg>
        {#if !collapsed}<span class="truncate">{loggingOut ? 'Signing out…' : 'Sign out'}</span>{/if}
      </button>
    {/if}

    <a
      href="https://github.com/bootuz/keywordista"
      target="_blank"
      rel="noopener noreferrer"
      title="View source on GitHub"
      class="{rowBase} {rowIdle} {collapsed ? 'justify-center' : ''}"
    >
      <svg width="18" height="18" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
        <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8Z" />
      </svg>
      {#if !collapsed}<span class="truncate">GitHub</span>{/if}
    </a>
  </div>
</aside>

{#if showSettings}
  <SettingsPanel onClose={() => (showSettings = false)} />
{/if}
