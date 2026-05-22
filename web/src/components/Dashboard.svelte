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
  import type { DashboardRow as Row } from '../lib/types';

  let loading = $state(true);
  let error = $state<string | null>(null);
  let showAddKeyword = $state(false);
  let showAddApp = $state(false);
  let showSettings = $state(false);
  let historyTarget = $state<Row | null>(null);

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

<div class="min-h-screen bg-zinc-950 text-zinc-100">
  <header class="relative z-30 border-b border-zinc-800 bg-zinc-950/80 px-6 py-3 backdrop-blur">
    <div class="flex items-center gap-3">
      <h1 class="text-base font-semibold tracking-tight">Keywordista</h1>
      <AppSwitcher onAddNew={() => (showAddApp = true)} />

      {#if $currentAppId}
        <div class="ml-2 flex items-center gap-4 text-sm">
          <span><span class="text-zinc-500">Tracked</span> <span class="text-zinc-100">{summary().total}</span></span>
          <span><span class="text-zinc-500">Ranked</span> <span class="text-zinc-100">{summary().ranked}</span></span>
          <span><span class="text-zinc-500">Top 10</span> <span class="text-emerald-400">{summary().top10}</span></span>
          <span><span class="text-zinc-500">Top 50</span> <span class="text-amber-400">{summary().top50}</span></span>
          <span class="text-zinc-500">·</span>
          <span class="text-zinc-500">{visibleRows} of {scopedTotal} shown</span>
        </div>
      {/if}

      <div class="ml-auto flex items-center gap-2">
        <button
          onclick={() => (showAddKeyword = true)}
          class="rounded-md bg-zinc-100 px-3 py-1 text-sm font-medium text-zinc-950 hover:bg-white"
        >
          + Keyword
        </button>
        {#if refreshAllActive}
          <div
            class="flex w-44 flex-col gap-1 rounded-md border border-zinc-700 bg-zinc-900 px-3 py-1"
            title="Refreshing keywords in the background"
          >
            <div class="flex items-baseline justify-between text-xs text-zinc-300">
              <span>Refreshing</span>
              <span class="font-mono text-zinc-100"
                >{refreshAllDone}/{refreshAllTotal}</span
              >
            </div>
            <div class="h-1 overflow-hidden rounded-full bg-zinc-800">
              <div
                class="h-full bg-amber-400 transition-[width] duration-500"
                style="width: {refreshAllProgress * 100}%"
              ></div>
            </div>
          </div>
        {:else}
          <button
            onclick={onRefreshAll}
            class="rounded-md border border-zinc-700 bg-zinc-900 px-3 py-1 text-sm text-zinc-100 hover:bg-zinc-800"
          >
            Refresh all
          </button>
        {/if}
        <button
          onclick={() => (showSettings = true)}
          title="Settings"
          aria-label="Settings"
          class="rounded-md border border-zinc-700 bg-zinc-900 p-1.5 text-zinc-400 hover:bg-zinc-800 hover:text-zinc-100"
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
      <p class="text-sm text-red-400">{error}</p>
    {:else if $apps.length === 0}
      <div class="rounded-lg border border-dashed border-zinc-800 p-12 text-center">
        <p class="text-zinc-300">No watched apps yet.</p>
        <p class="mt-1 text-sm text-zinc-500">
          Open the app switcher (top-left) and click <span class="text-amber-400">+ Add an app</span> to get started.
        </p>
      </div>
    {:else if scopedTotal === 0}
      <div class="rounded-lg border border-dashed border-zinc-800 p-12 text-center">
        <p class="text-zinc-300">No keywords tracked yet.</p>
        <p class="mt-1 text-sm text-zinc-500">
          Click <span class="text-zinc-300">+ Keyword</span> above to add one.
        </p>
      </div>
    {:else if visibleRows === 0}
      <div class="rounded-lg border border-dashed border-zinc-800 p-12 text-center">
        <p class="text-zinc-300">No rows match the current filters.</p>
        <p class="mt-1 text-sm text-zinc-500">Clear filters to see all {scopedTotal} rows.</p>
      </div>
    {:else}
      <div class="overflow-auto rounded-lg border border-zinc-800">
        <table class="w-full text-sm">
          <thead class="bg-zinc-900">
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
</div>
