<script lang="ts">
  import { onMount } from 'svelte';
  import { listApps, getAppGaps } from '../lib/api';
  import type { CompetitorGapRow, GapVerdict } from '../lib/types';
  import { apps } from '../lib/stores';

  // Mirrors ComparePage's self-contained shape: the page owns which own
  // app is the baseline, loads its own apps list, and re-fetches the
  // matrix whenever the baseline changes.
  let ownAppID = $state<string | null>(null);
  let gaps = $state<CompetitorGapRow[] | null>(null);
  let loading = $state(false);
  let error = $state<string | null>(null);
  // The matrix is exhaustive (every keyword × competitor). This toggle
  // collapses it to the actionable rows — where a competitor out-ranks me
  // or ranks while I'm absent.
  let onlyGaps = $state(false);

  onMount(() => {
    void loadApps();
  });

  async function loadApps(): Promise<void> {
    try {
      const all = await listApps();
      const own = all.filter((a) => a.kind === 'own');
      apps.set(own);
      if (!ownAppID && own.length > 0) ownAppID = own[0].id;
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    }
  }

  // Re-fetch whenever the baseline app changes.
  $effect(() => {
    const id = ownAppID;
    if (!id) {
      gaps = null;
      return;
    }
    void fetchGaps(id);
  });

  async function fetchGaps(id: string): Promise<void> {
    loading = true;
    error = null;
    try {
      gaps = await getAppGaps(id);
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      loading = false;
    }
  }

  // Sorted most-urgent-first using the server's verdict score, with the
  // optional "only losing" filter applied. Slice before sort to avoid
  // mutating the reactive source array.
  const visibleRows = $derived(
    (gaps ?? [])
      .filter(
        (r) =>
          !onlyGaps ||
          r.verdict.kind === 'behind' ||
          r.verdict.kind === 'pureGap',
      )
      .slice()
      .sort((a, b) => b.verdict.score - a.verdict.score),
  );

  // Visual treatment per verdict kind. Losing states (pureGap, behind)
  // get warm colors so they pop; winning/neutral states recede.
  function verdictStyle(kind: GapVerdict['kind']): { label: string; cls: string } {
    switch (kind) {
      case 'pureGap':
        return {
          label: 'Not ranking',
          cls: 'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-300',
        };
      case 'behind':
        return {
          label: 'Behind',
          cls: 'bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-300',
        };
      case 'tied':
        return {
          label: 'Tied',
          cls: 'bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300',
        };
      case 'ahead':
        return {
          label: 'Ahead',
          cls: 'bg-emerald-100 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-300',
        };
      case 'neither':
        return {
          label: '—',
          cls: 'bg-zinc-50 text-zinc-400 dark:bg-zinc-900 dark:text-zinc-600',
        };
    }
  }

  // Loose `== null` on purpose: Vapor omits nil optionals from JSON, so an
  // absent rank arrives as `undefined`, not `null` (matches DashboardRow).
  const fmtRank = (r: number | null): string => (r == null ? '—' : `#${r}`);
</script>

<div class="max-w-7xl mx-auto px-4 py-6 space-y-6">
  <header class="flex items-center justify-between gap-4">
    <div>
      <a href="#/" class="text-xs text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300">← Dashboard</a>
      <h1 class="text-xl font-semibold text-zinc-900 dark:text-zinc-100">Competitor gaps</h1>
      <p class="text-sm text-zinc-500">
        Where competitors stand against you across your tracked keywords. Sorted by urgency.
      </p>
    </div>
  </header>

  <!-- Controls -->
  <section
    class="rounded-md border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900/50 p-4 flex flex-wrap items-end gap-4"
  >
    <div class="space-y-1">
      <label class="text-xs uppercase tracking-wide text-zinc-500" for="own-app">Your app</label>
      <select
        id="own-app"
        bind:value={ownAppID}
        class="w-56 rounded-md border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950 px-3 py-2 text-sm text-zinc-900 dark:text-zinc-100"
      >
        {#each $apps as app (app.id)}
          <option value={app.id}>{app.name}</option>
        {/each}
      </select>
    </div>

    <!-- py-2 matches the select's height so, with the row's items-end, the
         checkbox text centers on the dropdown's text instead of sitting low. -->
    <label class="flex items-center gap-2 py-2 text-sm text-zinc-700 dark:text-zinc-300">
      <input type="checkbox" bind:checked={onlyGaps} class="h-4 w-4 rounded border-zinc-300 dark:border-zinc-700" />
      Only show where I'm losing
    </label>
  </section>

  {#if error}
    <p class="text-sm text-red-600 dark:text-red-400 rounded-md border border-red-200 dark:border-red-900 p-3 bg-red-50 dark:bg-red-900/20">
      {error}
    </p>
  {/if}

  {#if !ownAppID}
    <div class="rounded-md border border-zinc-200 dark:border-zinc-800 p-6 text-center text-sm text-zinc-500">
      Add at least one of your own apps to see competitor gaps.
    </div>
  {:else if loading && !gaps}
    <div class="rounded-md border border-zinc-200 dark:border-zinc-800 p-6 text-center text-sm text-zinc-500">
      Loading gaps…
    </div>
  {:else if gaps && gaps.length === 0}
    <div class="rounded-md border border-zinc-200 dark:border-zinc-800 p-6 text-center text-sm text-zinc-500">
      No data yet. Add competitors on the Compare page and run a refresh, then check back.
    </div>
  {:else if gaps && visibleRows.length === 0}
    <div class="rounded-md border border-zinc-200 dark:border-zinc-800 p-6 text-center text-sm text-zinc-500">
      No losing keywords — you're ahead of or tied with every competitor on every tracked keyword. 🎉
    </div>
  {:else if gaps}
    <div class="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
      <table class="min-w-full text-sm">
        <thead class="bg-zinc-50 dark:bg-zinc-900/50 text-left text-xs uppercase tracking-wide text-zinc-500">
          <tr>
            <th class="px-3 py-2 font-medium">Keyword</th>
            <th class="px-3 py-2 font-medium">Competitor</th>
            <th class="px-3 py-2 font-medium text-right">You</th>
            <th class="px-3 py-2 font-medium text-right">Them</th>
            <th class="px-3 py-2 font-medium">Status</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-zinc-100 dark:divide-zinc-800">
          {#each visibleRows as row (row.keywordId + ':' + row.competitorAppId)}
            {@const v = verdictStyle(row.verdict.kind)}
            <tr class="hover:bg-zinc-50 dark:hover:bg-zinc-900/40">
              <td class="px-3 py-2">
                <span class="text-zinc-900 dark:text-zinc-100">{row.term}</span>
                <span class="ml-1 text-xs uppercase text-zinc-400">{row.countryCode}</span>
              </td>
              <td class="px-3 py-2 text-zinc-700 dark:text-zinc-300">{row.competitorName}</td>
              <td class="px-3 py-2 text-right tabular-nums text-zinc-700 dark:text-zinc-300">{fmtRank(row.myRank)}</td>
              <td class="px-3 py-2 text-right tabular-nums text-zinc-700 dark:text-zinc-300">{fmtRank(row.competitorRank)}</td>
              <td class="px-3 py-2">
                <span class="inline-block rounded px-2 py-0.5 text-xs font-medium {v.cls}">{v.label}</span>
              </td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  {/if}
</div>
