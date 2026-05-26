<script lang="ts">
  import { getHistory, getKeywordSuggestions, addKeyword, ApiError } from '../lib/api';
  import type { AnonymizedSummary, HistoryPoint, SuggestionRow } from '../lib/types';
  import CountryFlag from './CountryFlag.svelte';

  interface Props {
    keywordId: string;
    keywordTerm: string;
    countryCode: string;
    watchedAppId: string;
    watchedAppName: string;
    onClose: () => void;
    onAdded?: () => void;
  }
  let {
    keywordId,
    keywordTerm,
    countryCode,
    watchedAppId,
    watchedAppName,
    onClose,
    onAdded,
  }: Props = $props();

  type Tab = 'history' | 'related';
  let activeTab = $state<Tab>('history');

  // ── History tab state ─────────────────────────────────────────────────
  let points = $state<HistoryPoint[]>([]);
  let loading = $state(true);
  let error = $state<string | null>(null);

  // Re-fetch whenever the user clicks a different row without closing the
  // panel. `$effect` re-runs every time keywordId or watchedAppId changes;
  // `onMount` would have fired only once for the component's lifetime.
  // A token guards against an old in-flight fetch resolving after a newer
  // one and clobbering its results.
  let fetchToken = 0;
  $effect(() => {
    const targetKeyword = keywordId;
    const targetApp = watchedAppId;
    const token = ++fetchToken;
    loading = true;
    error = null;
    points = [];
    // Reset the suggestions tab so a stale list from the previous keyword
    // can't flash before the new fetch completes.
    suggestions = null;
    anonymized = null;
    suggestionsError = null;
    suggestionsLoading = false;
    addedTerms.clear();
    addedTerms = addedTerms; // poke reactivity
    showTracked = false;
    void (async () => {
      try {
        const result = await getHistory(targetKeyword, targetApp);
        if (token !== fetchToken) return;
        points = result;
      } catch (err) {
        if (token !== fetchToken) return;
        error = err instanceof Error ? err.message : String(err);
      } finally {
        if (token === fetchToken) loading = false;
      }
    })();
  });

  // ── Related tab state ────────────────────────────────────────────────
  // Lazy: only fetched on first activation of the Related tab. Cached for
  // the panel's lifetime so re-tabbing doesn't refetch.
  let suggestions = $state<SuggestionRow[] | null>(null);
  // Apple's LOW_VOLUME aggregated totals — see AnonymizedSummary in types.ts.
  // Null until the first successful fetch; null after a fetch that returned
  // no anonymized rows (campaign produced only above-threshold queries).
  let anonymized = $state<AnonymizedSummary | null>(null);
  let suggestionsLoading = $state(false);
  let suggestionsError = $state<string | null>(null);
  let showTracked = $state(false);
  let addedTerms = $state<Set<string>>(new Set());

  async function loadSuggestions(): Promise<void> {
    if (suggestions !== null || suggestionsLoading) return;
    suggestionsLoading = true;
    suggestionsError = null;
    const token = fetchToken;
    try {
      const result = await getKeywordSuggestions(keywordId);
      if (token !== fetchToken) return;
      suggestions = result.rows;
      anonymized = result.anonymized;
    } catch (err) {
      if (token !== fetchToken) return;
      suggestionsError = err instanceof Error ? err.message : String(err);
    } finally {
      if (token === fetchToken) suggestionsLoading = false;
    }
  }

  // Auto-load suggestions whenever the Related tab is active AND we
  // don't yet have data for the current keyword. Fires in two important
  // cases the original code missed:
  //   1. User opens panel on a keyword, switches to Related, switches to
  //      a different keyword — the keyword-change effect resets
  //      suggestions=null but doesn't refetch on its own.
  //   2. Component re-renders with same Related tab but new props.
  // The single guard inside loadSuggestions() makes this idempotent —
  // selectTab() can still call it eagerly without risking a double fetch.
  $effect(() => {
    if (activeTab === 'related' && suggestions === null && !suggestionsLoading) {
      void loadSuggestions();
    }
  });

  // Force a re-fetch even when we already have data on screen. The
  // current rows blank out (the conditional below falls through to the
  // "Looking up…" branch because suggestions is null) so the user gets
  // an unambiguous "refresh in flight" signal — matches the first-load
  // UX byte-for-byte.
  function refreshSuggestions(): void {
    if (suggestionsLoading) return;
    suggestions = null;
    anonymized = null;
    suggestionsError = null;
    // No need to call loadSuggestions() here — the $effect above will
    // observe (suggestions === null && !suggestionsLoading) and fire it.
  }

  function selectTab(tab: Tab): void {
    activeTab = tab;
    if (tab === 'related') void loadSuggestions();
  }

  async function addSuggestion(term: string): Promise<void> {
    addedTerms.add(term);
    addedTerms = addedTerms;
    try {
      await addKeyword(term, countryCode);
      onAdded?.();
    } catch (err) {
      // Roll back the "added" state so the user can retry. Treat
      // "already exists" as success (race against a concurrent add).
      if (err instanceof ApiError && err.status === 409) return;
      addedTerms.delete(term);
      addedTerms = addedTerms;
      suggestionsError = err instanceof Error ? err.message : String(err);
    }
  }

  function rankColor(r: number | null): string {
    if (r == null) return 'text-zinc-500';
    if (r <= 10) return 'text-emerald-600 dark:text-emerald-400';
    if (r <= 50) return 'text-amber-600 dark:text-amber-400';
    return 'text-red-600 dark:text-red-400';
  }

  // ── Chart helpers (unchanged from before) ────────────────────────────
  const chartWidth = 560;
  const chartHeight = 180;
  const padding = { top: 16, right: 16, bottom: 24, left: 36 };

  const polyline = $derived(buildPolyline(points));

  function buildPolyline(pts: HistoryPoint[]): string {
    if (pts.length === 0) return '';
    const maxRank = Math.max(200, ...pts.map((p) => p.rank ?? 0));
    const minTime = new Date(pts[0].checkedAt).getTime();
    const maxTime = new Date(pts[pts.length - 1].checkedAt).getTime();
    const timeRange = Math.max(1, maxTime - minTime);
    const usableW = chartWidth - padding.left - padding.right;
    const usableH = chartHeight - padding.top - padding.bottom;
    return pts
      .map((p) => {
        const x = padding.left + ((new Date(p.checkedAt).getTime() - minTime) / timeRange) * usableW;
        const rank = p.rank ?? maxRank + 1;
        const y = padding.top + ((rank - 1) / maxRank) * usableH;
        return `${x.toFixed(1)},${y.toFixed(1)}`;
      })
      .join(' ');
  }

  function formatRank(r: number | null): string {
    return r == null ? '—' : `#${r}`;
  }

  function formatTTR(ttr: number): string {
    return `${(ttr * 100).toFixed(0)}%`;
  }

  // Visible suggestion rows after honoring the "Show tracked" toggle.
  const visibleSuggestions = $derived.by(() => {
    if (!suggestions) return [];
    return showTracked ? suggestions : suggestions.filter((s) => !s.alreadyTracked);
  });
  const trackedCount = $derived(suggestions?.filter((s) => s.alreadyTracked).length ?? 0);
</script>

<aside
  class="fixed inset-y-0 right-0 z-40 flex w-[640px] max-w-full flex-col border-l border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-950 shadow-2xl"
>
  <header class="flex items-baseline justify-between border-b border-zinc-200 dark:border-zinc-800 px-6 py-4">
    <div class="min-w-0">
      <div class="flex items-center gap-2">
        <h2 class="truncate text-base font-semibold text-zinc-900 dark:text-zinc-100">{keywordTerm}</h2>
        <CountryFlag code={countryCode} />
      </div>
      <p class="text-sm text-zinc-500">{watchedAppName}</p>
    </div>
    <button onclick={onClose} class="text-sm text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300">Close</button>
  </header>

  <!-- Tab strip -->
  <nav class="flex border-b border-zinc-200 dark:border-zinc-800 px-6">
    <button
      onclick={() => selectTab('history')}
      class="-mb-px border-b-2 px-3 py-2 text-sm transition"
      class:border-amber-400={activeTab === 'history'}
      class:text-zinc-900={activeTab === 'history'}
      class:dark:text-zinc-100={activeTab === 'history'}
      class:border-transparent={activeTab !== 'history'}
      class:text-zinc-500={activeTab !== 'history'}
      class:hover:text-zinc-700={activeTab !== 'history'}
      class:dark:hover:text-zinc-300={activeTab !== 'history'}
    >
      History
    </button>
    <button
      onclick={() => selectTab('related')}
      class="-mb-px border-b-2 px-3 py-2 text-sm transition"
      class:border-amber-400={activeTab === 'related'}
      class:text-zinc-900={activeTab === 'related'}
      class:dark:text-zinc-100={activeTab === 'related'}
      class:border-transparent={activeTab !== 'related'}
      class:text-zinc-500={activeTab !== 'related'}
      class:hover:text-zinc-700={activeTab !== 'related'}
      class:dark:hover:text-zinc-300={activeTab !== 'related'}
    >
      Related
    </button>
  </nav>

  <div class="flex-1 overflow-auto p-6">
    {#if activeTab === 'history'}
      {#if loading}
        <p class="text-sm text-zinc-500">Loading history…</p>
      {:else if error}
        <p class="text-sm text-red-600 dark:text-red-400">{error}</p>
      {:else if points.length === 0}
        <p class="text-sm text-zinc-500">No checks yet.</p>
      {:else}
        <svg
          viewBox="0 0 {chartWidth} {chartHeight}"
          class="w-full rounded-md border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900 p-2"
        >
          <polyline points={polyline} fill="none" stroke="#a1a1aa" stroke-width="1.5" />
          {#each points as p}
            {@const x =
              padding.left +
              ((new Date(p.checkedAt).getTime() - new Date(points[0].checkedAt).getTime()) /
                Math.max(
                  1,
                  new Date(points[points.length - 1].checkedAt).getTime() -
                    new Date(points[0].checkedAt).getTime(),
                )) *
                (chartWidth - padding.left - padding.right)}
            {@const maxRank = Math.max(200, ...points.map((q) => q.rank ?? 0))}
            {@const y =
              padding.top +
              (((p.rank ?? maxRank + 1) - 1) / maxRank) * (chartHeight - padding.top - padding.bottom)}
            <circle cx={x} cy={y} r={2.5} fill={p.rank == null ? '#52525b' : '#fbbf24'} />
          {/each}
        </svg>

        <table class="mt-4 w-full text-sm">
          <thead class="text-xs uppercase tracking-wide text-zinc-500">
            <tr>
              <th class="py-2 text-left">Checked</th>
              <th class="text-left">Rank</th>
              <th class="text-left">Difficulty</th>
              <th class="text-left">Barrier</th>
            </tr>
          </thead>
          <tbody>
            {#each [...points].reverse() as p}
              <tr class="border-t border-zinc-200 dark:border-zinc-800">
                <td class="py-1.5 text-zinc-700 dark:text-zinc-300">{new Date(p.checkedAt).toLocaleString()}</td>
                <td class="text-zinc-900 dark:text-zinc-100">{formatRank(p.rank)}</td>
                <td class="text-zinc-600 dark:text-zinc-400">{p.difficulty}/5</td>
                <td class="text-zinc-600 dark:text-zinc-400">{p.entryBarrier}/5</td>
              </tr>
            {/each}
          </tbody>
        </table>
      {/if}
    {:else}
      <!-- Related tab -->
      <!--
        Section header gives the refresh button a visual anchor — without
        it, the button floats in dead space whenever the body below is an
        empty state. The label also makes the tab content self-describing
        for screen readers (h3 lands in the document outline). Refresh is
        right-aligned on the same row; thin border underneath frames the
        section so subsequent empty/loading copy doesn't crowd it.
      -->
      <div class="mb-3 flex items-baseline justify-between border-b border-zinc-200 dark:border-zinc-800 pb-2">
        <h3 class="text-xs font-medium uppercase tracking-wide text-zinc-500">
          Related search terms
        </h3>
        <button
          type="button"
          onclick={refreshSuggestions}
          disabled={suggestionsLoading}
          aria-label="Refresh related search terms"
          title="Refresh"
          class="-my-1 rounded-md p-1.5 text-zinc-500 transition hover:bg-zinc-100 hover:text-zinc-900 dark:hover:bg-zinc-800 dark:hover:text-zinc-100 disabled:cursor-not-allowed disabled:opacity-50"
        >
          <!-- Heroicons arrow-path (Apache 2.0) -->
          <svg
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            class="h-4 w-4 {suggestionsLoading ? 'animate-spin' : ''}"
          >
            <path d="M21 12a9 9 0 1 1-3.6-7.2" />
            <path d="M21 4v5h-5" />
          </svg>
        </button>
      </div>

      {#if suggestionsLoading}
        <p class="text-sm text-zinc-500">Looking up search terms from your Apple Search Ads campaign…</p>
      {:else if suggestionsError}
        <p class="text-sm text-red-600 dark:text-red-400">{suggestionsError}</p>
        <button
          type="button"
          onclick={() => { suggestions = null; void loadSuggestions(); }}
          class="mt-2 text-xs text-amber-600 dark:text-amber-400 hover:underline"
        >
          Retry
        </button>
      {:else if !suggestions}
        <p class="text-sm text-zinc-500">No related search terms yet.</p>
      {:else}
        <!--
          Banner first: Apple's LOW_VOLUME totals tell the user the
          campaign IS producing signal even when no individual term passes
          the privacy threshold. This is more important than the empty
          state and renders even if the term list below is empty.
        -->
        {#if anonymized}
          <div
            class="mb-4 rounded-md border border-amber-200 dark:border-amber-900/50 bg-amber-50 dark:bg-amber-950/30 px-3 py-2 text-xs text-amber-900 dark:text-amber-200"
          >
            <p>
              Apple is anonymizing <span class="font-semibold tabular-nums">{anonymized.impressions}</span>
              additional {anonymized.impressions === 1 ? 'impression' : 'impressions'}
              {anonymized.taps > 0 ? ` and ${anonymized.taps} ${anonymized.taps === 1 ? 'tap' : 'taps'}` : ''}
              across {anonymized.sourceCount} {anonymized.sourceCount === 1 ? 'ad group' : 'ad groups'} as low-volume queries.
            </p>
            <p class="mt-1 text-amber-800/80 dark:text-amber-300/80">
              These are real campaign impressions — Apple just won't deanonymize the query text until volume
              clears its privacy threshold. Check back in a few days.
            </p>
          </div>
        {/if}

        {#if suggestions.length === 0}
          <div class="text-sm text-zinc-500">
            <p>No deanonymized search terms yet.</p>
            <p class="mt-2 text-xs">
              {#if anonymized}
                Your campaign is serving impressions, but every individual query is still under Apple's
                privacy threshold. Wait for traffic to accumulate.
              {:else}
                Apple Search Ads only surfaces search terms after your discovery campaign has served
                impressions for this storefront. If you just created the campaign, check back in a day or two.
              {/if}
            </p>
          </div>
        {:else if visibleSuggestions.length === 0}
          <!--
            "Hidden by filter" empty state: suggestions exist but the
            already-tracked filter (default on) has hidden all of them.
            Without this, the user sees headers + empty tbody + a tiny
            grey link at the bottom — easy to miss and easy to mistake
            for "no data".
          -->
          <div class="text-sm text-zinc-500">
            <p>
              {trackedCount === 1
                ? 'The only related term is already tracked.'
                : `All ${trackedCount} related terms are already tracked.`}
            </p>
            <button
              type="button"
              onclick={() => (showTracked = true)}
              class="mt-2 text-xs text-amber-600 dark:text-amber-400 hover:underline"
            >
              {trackedCount === 1 ? 'Show it' : `Show ${trackedCount} tracked`}
            </button>
          </div>
        {:else}
        <p class="mb-3 text-xs text-zinc-500">
          Queries from your Apple Search Ads campaigns in {countryCode.toUpperCase()} that mention
          <span class="text-zinc-700 dark:text-zinc-300">{keywordTerm}</span>. Sorted by relevance.
        </p>

        <table class="w-full text-sm">
          <thead class="text-xs uppercase tracking-wide text-zinc-500">
            <tr>
              <th class="py-2 text-left">Term</th>
              <th class="text-right">Impressions</th>
              <th class="text-right">Taps</th>
              <th class="text-right">TTR</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {#each visibleSuggestions as s}
              <tr class="border-t border-zinc-200 dark:border-zinc-800">
                <td class="py-1.5 text-zinc-900 dark:text-zinc-100">
                  {s.term}
                  {#if s.alreadyTracked && s.currentRank != null}
                    <span class="ml-1 text-xs {rankColor(s.currentRank)}">#{s.currentRank}</span>
                  {/if}
                </td>
                <td class="text-right text-zinc-700 dark:text-zinc-300 tabular-nums">{s.impressions}</td>
                <td class="text-right text-zinc-700 dark:text-zinc-300 tabular-nums">{s.taps}</td>
                <td
                  class="text-right tabular-nums"
                  class:text-emerald-600={s.ttr >= 0.1}
                  class:dark:text-emerald-400={s.ttr >= 0.1}
                  class:text-zinc-700={s.ttr < 0.1}
                  class:dark:text-zinc-300={s.ttr < 0.1}
                >
                  {formatTTR(s.ttr)}
                </td>
                <td class="py-1.5 pl-3 text-right">
                  {#if addedTerms.has(s.term)}
                    <span class="text-xs text-emerald-600 dark:text-emerald-400">Added ✓</span>
                  {:else if s.alreadyTracked}
                    <span class="text-xs text-zinc-400 dark:text-zinc-600">tracked</span>
                  {:else}
                    <button
                      type="button"
                      onclick={() => addSuggestion(s.term)}
                      class="rounded bg-zinc-900 dark:bg-zinc-100 px-2 py-1 text-xs font-medium text-zinc-50 dark:text-zinc-950 hover:bg-zinc-700 dark:hover:bg-white"
                    >
                      + Add
                    </button>
                  {/if}
                </td>
              </tr>
            {/each}
          </tbody>
        </table>

        {#if trackedCount > 0}
          <button
            type="button"
            onclick={() => (showTracked = !showTracked)}
            class="mt-3 text-xs text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300"
          >
            {showTracked ? 'Hide' : 'Show'} {trackedCount} already tracked
          </button>
        {/if}
        {/if}
      {/if}
    {/if}
  </div>
</aside>
