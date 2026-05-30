<script lang="ts">
  import { onMount } from 'svelte';
  import { getDashboard, listApps, refreshKeyword } from '../lib/api';
  import {
    dashboard,
    apps,
    refreshing,
    refreshBatch,
    markRefreshing,
    ensurePolling,
    refreshDeveloperKeywords,
    refreshOpportunity,
  } from '../lib/stores';
  import {
    groupedSections,
    groupBy,
    collapsedGroups,
    currentAppId,
    appScopedRows,
    filteredRows,
  } from '../lib/viewState';
  import DashboardRow from './DashboardRow.svelte';
  import AddKeywordModal from './AddKeywordModal.svelte';
  import AddAppModal from './AddAppModal.svelte';
  import HistoryPanel from './HistoryPanel.svelte';
  import FilterBar from './FilterBar.svelte';
  import SortableHeader from './SortableHeader.svelte';
  import GroupHeader from './GroupHeader.svelte';
  import AppSwitcher from './AppSwitcher.svelte';
  import type { DashboardRow as Row } from '../lib/types';

  let loading = $state(true);
  let error = $state<string | null>(null);
  let showAddKeyword = $state(false);
  let showAddApp = $state(false);
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
  const TABLE_COLSPAN = 9;

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
    // The chart-event poll (notifications + unread badge) now starts in the
    // persistent Sidebar, so it runs on every product route, not just here.
    // Pull the latest ASC keyword list in the background — localStorage gives
    // us instant-paint badges from the last session; this refresh keeps them
    // current if the user shipped a new version since the page was last open.
    // Failure is non-fatal: dashboard rows render fine without the badge.
    void refreshDeveloperKeywords().catch(() => {});
    // Opportunity scores (ASA-backed) — lazily merged into the table. Empty
    // when ASA isn't configured; the column just shows "—" then.
    void refreshOpportunity();
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

  // Number of keywords the next Refresh click would dispatch. Equals
  // $filteredRows.length collapsed by keywordId (the same keyword can
  // appear in multiple rows when it's tracked across multiple watched
  // apps; one refresh dispatch covers all rank checks for it). The
  // button reflects this count so the user always sees the actual
  // scope — "Refresh (302)" with no filters, "Refresh (12)" with
  // filters narrowing the table.
  const refreshableCount = $derived(
    new Set($filteredRows.map((r) => r.keywordId)).size,
  );

  async function onRefreshAll() {
    if (refreshAllActive) return;
    const startedAt = new Date();
    // Batch = every keyword visible in the current filter. With no filters
    // active this equals "all keywords for the current app". Deduping
    // by keywordId because (keyword × watched_app) rows share a single
    // refresh dispatch — the backend re-checks rank for every watched
    // app under one keyword in a single job.
    const ids = [...new Set($filteredRows.map((r) => r.keywordId))];
    if (ids.length === 0) return;

    // Mark every row as refreshing, persist the batch, then dispatch.
    for (const id of ids) markRefreshing(id, startedAt);
    refreshBatch.set({ ids, startedAt });
    try {
      // Fan out per-keyword dispatches in parallel. allSettled keeps the
      // batch alive when individual dispatches fail (deleted keyword,
      // transient 5xx) — we clear spinners only for the failed ids so the
      // succeeded ones still get their rank polled to completion.
      const results = await Promise.allSettled(ids.map((id) => refreshKeyword(id)));
      const failed = results
        .map((r, i) => (r.status === 'rejected' ? ids[i] : null))
        .filter((x): x is string => x !== null);
      if (failed.length > 0) {
        for (const id of failed) {
          refreshing.update((m) => { const n = new Map(m); n.delete(id); return n; });
        }
        if (failed.length === ids.length) {
          // Every dispatch rejected — likely a 5xx storm or auth lost.
          // Drop the batch entirely so the chip doesn't sit at 0/N forever.
          refreshBatch.set(null);
          throw new Error(`Refresh failed for ${failed.length} keyword${failed.length === 1 ? '' : 's'}`);
        }
        // Partial failure: shrink the batch so the progress chip's
        // denominator reflects only the rows we expect to see update.
        refreshBatch.update((b) => (b ? { ...b, ids: b.ids.filter((id) => !failed.includes(id)) } : b));
      }
      ensurePolling();
    } catch (err) {
      // If the fan-out itself threw (network catastrophe, etc.), drop the
      // batch + spinners. allSettled above wouldn't throw — this catches
      // the rare unhandled case.
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
            disabled={refreshableCount === 0}
            title={refreshableCount === 0
              ? 'No keywords match the current filters'
              : `Refresh ${refreshableCount} keyword${refreshableCount === 1 ? '' : 's'} (everything visible in the table)`}
            class="rounded-md border border-zinc-300 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-900 px-3 py-1 text-sm text-zinc-900 dark:text-zinc-100 hover:bg-zinc-100 dark:hover:bg-zinc-800 disabled:cursor-not-allowed disabled:opacity-50"
          >
            Refresh ({refreshableCount})
          </button>
        {/if}
        <!--
          Navigation (Charts / Compare / Gaps), Settings, Sign out, and the
          GitHub link moved to the persistent sidebar (Sidebar.svelte). This
          header keeps only the app-scoped controls: AppSwitcher + summary
          (left) and the +Keyword / Refresh actions (here).
        -->
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
              <th
                class="px-3 py-2 text-left text-xs uppercase tracking-wide text-zinc-500"
                title="ASA impressions ÷ difficulty — shown only for keywords with Apple Search Ads data"
              >Opportunity</th>
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
</div>
