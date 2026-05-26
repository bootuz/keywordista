<script lang="ts">
  import { onMount } from 'svelte';
  import { getDashboard, listApps, refreshAll } from '../lib/api';
  import {
    dashboard,
    apps,
    refreshing,
    refreshBatch,
    markRefreshing,
    ensurePolling,
    refreshDeveloperKeywords,
  } from '../lib/stores';
  import {
    groupedSections,
    groupBy,
    collapsedGroups,
    currentAppId,
    appScopedRows,
  } from '../lib/viewState';
  import DashboardRow from './DashboardRow.svelte';
  import AddKeywordModal from './AddKeywordModal.svelte';
  import AddAppModal from './AddAppModal.svelte';
  import HistoryPanel from './HistoryPanel.svelte';
  import FilterBar from './FilterBar.svelte';
  import SortableHeader from './SortableHeader.svelte';
  import GroupHeader from './GroupHeader.svelte';
  import AppSwitcher from './AppSwitcher.svelte';
  import SettingsPanel from './SettingsPanel.svelte';
  import ChartsPage from './ChartsPage.svelte';
  import { chartEvents, lastVisited, startChartEventPoll } from '../lib/chartEvents';
  import type { DashboardRow as Row } from '../lib/types';
  // Auth UI (M2.9): in server mode the header shows the signed-in
  // user's email + a logout button. Both gated on serverMode so
  // local-mode dashboards stay byte-identical to the pre-M2 UX.
  import { push } from 'svelte-spa-router';
  import { logout } from '../lib/auth';
  import { clearAuthState } from '../lib/authStore';
  import { currentUser, serverMode } from '../lib/authStore';
  import { ROUTES } from '../lib/router';

  let loading = $state(true);
  let error = $state<string | null>(null);
  let showAddKeyword = $state(false);
  let showAddApp = $state(false);
  let showSettings = $state(false);
  let showCharts = $state(false);
  let historyTarget = $state<Row | null>(null);

  let loggingOut = $state(false);
  async function handleLogout() {
    if (loggingOut) return;
    loggingOut = true;
    try {
      await logout();
    } catch {
      // Logout's idempotent server-side; even on network error the
      // user expects local state to clear. Fall through.
    } finally {
      await clearAuthState();
      push(ROUTES.login);
      loggingOut = false;
    }
  }

  // Unread chart events for the toolbar badge: count of events created after
  // the last time the user opened the Charts page. Visible badge nudges them
  // to look at the activity without competing with the keyword dashboard.
  const chartsUnreadCount = $derived.by(() => {
    const last = lastVisited();
    if (!last) return $chartEvents.length;
    const lastDate = new Date(last).getTime();
    return $chartEvents.filter((e) => new Date(e.createdAt).getTime() > lastDate).length;
  });

  // Refresh-all progress is derived directly from the row-level state:
  //   total  = number of keyword IDs in the active batch
  //   done   = total minus how many of those IDs are still in `refreshing`
  // No baseline subtraction, no queue accounting — the rows' own checkedAt
  // is the source of truth, and the shared poll loop in stores.ts keeps
  // `refreshing` in sync with reality.
  const refreshAllActive = $derived($refreshBatch !== null);
  const refreshAllTotal = $derived($refreshBatch?.ids.length ?? 0);
  const refreshAllDone = $derived(
    $refreshBatch ? $refreshBatch.ids.filter((id) => !$refreshing.has(id)).length : 0,
  );
  const refreshAllProgress = $derived(
    refreshAllTotal > 0 ? Math.min(1, refreshAllDone / refreshAllTotal) : 0,
  );

  // After loading apps, ensure currentAppId points at something that exists.
  // Default = first app. Persisted IDs that no longer exist get reset.
  $effect(() => {
    const list = $apps;
    if (list.length === 0) {
      if ($currentAppId !== null) currentAppId.set(null);
      return;
    }
    const stillValid = list.some((a) => a.id === $currentAppId);
    if (!stillValid) currentAppId.set(list[0].id);
  });

  const visibleRows = $derived($groupedSections.reduce((n, s) => n + s.rows.length, 0));
  const scopedTotal = $derived($appScopedRows.length);
  const flatMode = $derived($groupBy === 'none');
  const TABLE_COLSPAN = 8;

  // Summary strip — counts based on the app-scoped set, before user filters.
  const summary = $derived(() => {
    const rows = $appScopedRows;
    const ranked = rows.filter((r) => r.rank != null).length;
    const top10 = rows.filter((r) => r.rank != null && r.rank! <= 10).length;
    const top50 = rows.filter((r) => r.rank != null && r.rank! <= 50).length;
    return { total: rows.length, ranked, top10, top50 };
  });

  async function load() {
    try {
      const [d, a] = await Promise.all([getDashboard(), listApps()]);
      dashboard.set(d);
      apps.set(a);
      error = null;
    } catch (err) {
      error = err instanceof Error ? err.message : String(err);
    } finally {
      loading = false;
    }
  }

  onMount(async () => {
    await load();
    // Start the singleton chart-event poll. It fires browser notifications
    // for new transitions and keeps the unread badge live. Safe to call from
    // anywhere; the loop dedupes itself.
    startChartEventPoll();
    // Pull the latest ASC keyword list in the background — localStorage gives
    // us instant-paint badges from the last session; this refresh keeps them
    // current if the user shipped a new version since the page was last open.
    // Failure is non-fatal: dashboard rows render fine without the badge.
    void refreshDeveloperKeywords().catch(() => {});
    // If a Refresh All was in flight when the page was unloaded, the queue
    // is still chewing through it. The persisted batch tells us which IDs
    // were in this run; for each, check whether the row's checkedAt has
    // already advanced past the batch's startedAt. Anything that hasn't is
    // still in flight — re-mark it so the chip resumes.
    const saved = $refreshBatch;
    if (!saved) return;
    const startedAt = saved.startedAt;
    const stillPending = saved.ids.filter((id) => {
      const row = $dashboard.find((r) => r.keywordId === id);
      if (!row?.checkedAt) return true;
      return new Date(row.checkedAt).getTime() < startedAt.getTime();
    });
    if (stillPending.length === 0) {
      refreshBatch.set(null);
      return;
    }
    for (const id of stillPending) markRefreshing(id, startedAt);
    ensurePolling();
  });

  async function onRefreshAll() {
    if (refreshAllActive) return;
    const startedAt = new Date();
    // Batch = every keyword visible in the current app context. Filters and
    // grouping don't change the batch — Refresh All means "everything tracked
    // for this app", not "everything currently filtered to."
    const ids = $appScopedRows.map((r) => r.keywordId);
    if (ids.length === 0) return;

    // Mark every row as refreshing, persist the batch, then dispatch.
    for (const id of ids) markRefreshing(id, startedAt);
    refreshBatch.set({ ids, startedAt });
    try {
      await refreshAll();
      ensurePolling();
    } catch (err) {
      // If the dispatch itself failed (e.g. 5xx), drop the batch + spinners.
      refreshBatch.set(null);
      for (const id of ids) refreshing.update((m) => { const n = new Map(m); n.delete(id); return n; });
      throw err;
    }
  }
</script>

<div class="min-h-screen bg-white dark:bg-zinc-950 text-zinc-900 dark:text-zinc-100">
  <header class="relative z-30 border-b border-zinc-200 dark:border-zinc-800 bg-white/80 dark:bg-zinc-950/80 px-6 py-3 backdrop-blur">
    <div class="flex items-center gap-3">
      <h1 class="text-base font-semibold tracking-tight">Keywordista</h1>
      <AppSwitcher onAddNew={() => (showAddApp = true)} />

      {#if $currentAppId}
        <div class="ml-2 flex items-center gap-4 text-sm">
          <span><span class="text-zinc-500">Tracked</span> <span class="text-zinc-900 dark:text-zinc-100">{summary().total}</span></span>
          <span><span class="text-zinc-500">Ranked</span> <span class="text-zinc-900 dark:text-zinc-100">{summary().ranked}</span></span>
          <span><span class="text-zinc-500">Top 10</span> <span class="text-emerald-600 dark:text-emerald-400">{summary().top10}</span></span>
          <span><span class="text-zinc-500">Top 50</span> <span class="text-amber-600 dark:text-amber-400">{summary().top50}</span></span>
          <span class="text-zinc-500">·</span>
          <span class="text-zinc-500">{visibleRows} of {scopedTotal} shown</span>
        </div>
      {/if}

      <div class="ml-auto flex items-center gap-2">
        <button
          onclick={() => (showAddKeyword = true)}
          class="rounded-md bg-zinc-900 dark:bg-zinc-100 px-3 py-1 text-sm font-medium text-zinc-50 dark:text-zinc-950 hover:bg-black dark:hover:bg-white"
        >
          + Keyword
        </button>
        {#if refreshAllActive}
          <div
            class="flex w-44 flex-col gap-1 rounded-md border border-zinc-300 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-900 px-3 py-1"
            title="Refreshing keywords in the background"
          >
            <div class="flex items-baseline justify-between text-xs text-zinc-700 dark:text-zinc-300">
              <span>Refreshing</span>
              <span class="font-mono text-zinc-900 dark:text-zinc-100"
                >{refreshAllDone}/{refreshAllTotal}</span
              >
            </div>
            <div class="h-1 overflow-hidden rounded-full bg-zinc-100 dark:bg-zinc-800">
              <div
                class="h-full bg-amber-400 transition-[width] duration-500"
                style="width: {refreshAllProgress * 100}%"
              ></div>
            </div>
          </div>
        {:else}
          <button
            onclick={onRefreshAll}
            class="rounded-md border border-zinc-300 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-900 px-3 py-1 text-sm text-zinc-900 dark:text-zinc-100 hover:bg-zinc-100 dark:hover:bg-zinc-800"
          >
            Refresh all
          </button>
        {/if}
        <button
          onclick={() => (showCharts = true)}
          title="Chart positions"
          aria-label="Charts"
          class="relative rounded-md border border-zinc-300 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-900 px-3 py-1 text-sm text-zinc-900 dark:text-zinc-100 hover:bg-zinc-100 dark:hover:bg-zinc-800"
        >
          Charts
          {#if chartsUnreadCount > 0}
            <span
              class="absolute -right-1.5 -top-1.5 grid h-4 min-w-4 place-items-center rounded-full bg-amber-500 px-1 text-[10px] font-bold text-zinc-950"
              aria-label="{chartsUnreadCount} unread chart events"
            >
              {chartsUnreadCount}
            </span>
          {/if}
        </button>
        {#if $serverMode && $currentUser}
          <button
            onclick={handleLogout}
            disabled={loggingOut}
            title="Sign out as {$currentUser.email}"
            aria-label="Sign out"
            class="rounded-md border border-zinc-300 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-900 px-3 py-1 text-sm text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 disabled:opacity-60"
          >
            {loggingOut ? 'Signing out…' : 'Sign out'}
          </button>
        {/if}
        <!--
          External link to the source repo. Sits next to the Settings
          button in the header's "meta actions" cluster. Uses an <a>
          rather than a <button> because it's pure navigation to an
          external URL; rel=noopener noreferrer prevents the opened tab
          from accessing window.opener (perf + minor security hardening).
        -->
        <a
          href="https://github.com/bootuz/keywordista"
          target="_blank"
          rel="noopener noreferrer"
          title="View source on GitHub"
          aria-label="View source on GitHub"
          class="rounded-md border border-zinc-300 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-900 p-1.5 text-zinc-600 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800 hover:text-zinc-900 dark:hover:text-zinc-100"
        >
          <!-- GitHub Octicons mark-github (MIT) — single-path so it
               scales cleanly at 16px and matches the Settings icon's
               stroke-light visual weight reasonably well at this size. -->
          <svg
            width="16"
            height="16"
            viewBox="0 0 16 16"
            fill="currentColor"
            aria-hidden="true"
          >
            <path
              d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8Z"
            />
          </svg>
        </a>
        <button
          onclick={() => (showSettings = true)}
          title="Settings"
          aria-label="Settings"
          class="rounded-md border border-zinc-300 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-900 p-1.5 text-zinc-600 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800 hover:text-zinc-900 dark:hover:text-zinc-100"
        >
          <svg
            width="16"
            height="16"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <circle cx="12" cy="12" r="3"></circle>
            <path
              d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33h0a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82v0a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"
            ></path>
          </svg>
        </button>
      </div>
    </div>
  </header>

  <FilterBar />

  <main class="px-6 py-4">
    {#if loading}
      <p class="text-sm text-zinc-500">Loading…</p>
    {:else if error}
      <p class="text-sm text-red-600 dark:text-red-400">{error}</p>
    {:else if $apps.length === 0}
      <div class="rounded-lg border border-dashed border-zinc-200 dark:border-zinc-800 p-12 text-center">
        <p class="text-zinc-700 dark:text-zinc-300">No watched apps yet.</p>
        <p class="mt-1 text-sm text-zinc-500">
          Open the app switcher (top-left) and click <span class="text-amber-600 dark:text-amber-400">+ Add an app</span> to get started.
        </p>
      </div>
    {:else if scopedTotal === 0}
      <div class="rounded-lg border border-dashed border-zinc-200 dark:border-zinc-800 p-12 text-center">
        <p class="text-zinc-700 dark:text-zinc-300">No keywords tracked yet.</p>
        <p class="mt-1 text-sm text-zinc-500">
          Click <span class="text-zinc-700 dark:text-zinc-300">+ Keyword</span> above to add one.
        </p>
      </div>
    {:else if visibleRows === 0}
      <div class="rounded-lg border border-dashed border-zinc-200 dark:border-zinc-800 p-12 text-center">
        <p class="text-zinc-700 dark:text-zinc-300">No rows match the current filters.</p>
        <p class="mt-1 text-sm text-zinc-500">Clear filters to see all {scopedTotal} rows.</p>
      </div>
    {:else}
      <div class="overflow-auto rounded-lg border border-zinc-200 dark:border-zinc-800">
        <table class="w-full text-sm">
          <thead class="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <SortableHeader column="term" label="Keyword" />
              <SortableHeader column="country" label="Country" />
              <SortableHeader column="rank" label="Our Rank" />
              <th class="px-3 py-2 text-left text-xs uppercase tracking-wide text-zinc-500"
                >Top Results</th
              >
              <SortableHeader column="difficulty" label="Difficulty" />
              <SortableHeader column="entryBarrier" label="Entry Barrier" />
              <SortableHeader column="checkedAt" label="Checked" />
              <th class="px-3 py-2 text-right"></th>
            </tr>
          </thead>
          <tbody>
            {#each $groupedSections as section (section.id)}
              {#if !flatMode}
                <GroupHeader
                  id={section.id}
                  label={section.label}
                  summary={section.summary}
                  colspan={TABLE_COLSPAN}
                />
              {/if}
              {#if flatMode || !$collapsedGroups.has(section.id)}
                {#each section.rows as row (row.keywordId + row.watchedAppId)}
                  <DashboardRow
                    {row}
                    onChanged={load}
                    onOpenHistory={() => (historyTarget = row)}
                  />
                {/each}
              {/if}
            {/each}
          </tbody>
        </table>
      </div>
    {/if}
  </main>

  {#if showAddKeyword}
    <AddKeywordModal onClose={() => (showAddKeyword = false)} onAdded={load} />
  {/if}
  {#if showAddApp}
    <AddAppModal onClose={() => (showAddApp = false)} onAdded={load} />
  {/if}
  {#if historyTarget}
    <HistoryPanel
      keywordId={historyTarget.keywordId}
      keywordTerm={historyTarget.term}
      countryCode={historyTarget.countryCode}
      watchedAppId={historyTarget.watchedAppId}
      watchedAppName={historyTarget.watchedAppName}
      onClose={() => (historyTarget = null)}
      onAdded={load}
    />
  {/if}
  {#if showSettings}
    <SettingsPanel onClose={() => (showSettings = false)} />
  {/if}
  {#if showCharts}
    <ChartsPage onClose={() => (showCharts = false)} />
  {/if}
</div>
