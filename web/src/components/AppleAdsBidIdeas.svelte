<script lang="ts">
  // What to bid on next: terms that already convert, Apple's own ideas,
  // and terms that cost money without installs. Plus related search terms
  // for any tracked keyword.
  import type { Snippet } from 'svelte';
  import { onMount } from 'svelte';
  import { addKeyword, ApiError, errorMessage, getAppleAdsBidIdeas, getKeywordSuggestions, listKeywords } from '../lib/api';
  import type { AppleAdsBidIdeas, AppleAdsDays, AppleAdsIdea, AppleAdsSyncStatus, Keyword, SuggestionsResponse } from '../lib/types';
  import { fmtInt, fmtMoney, fmtPct, LOW_DATA_TITLE, lowDataClass } from '../lib/appleAds';

  let {
    appId,
    days,
    status,
    reloadKey,
    emptyState,
  }: {
    appId: string;
    days: AppleAdsDays;
    status: AppleAdsSyncStatus | null;
    reloadKey: number;
    emptyState: Snippet<['notConnected' | 'notSynced']>;
  } = $props();

  let ideas = $state<AppleAdsBidIdeas | null>(null);
  let error = $state<string | null>(null);
  let notConnected = $state(false);
  let trackedHere = $state(new Set<string>());

  $effect(() => {
    void reloadKey;
    void load(appId, days);
  });

  let requestToken = 0;
  async function load(id: string, d: AppleAdsDays): Promise<void> {
    const token = ++requestToken;
    error = null;
    try {
      const result = await getAppleAdsBidIdeas(id, d);
      if (token !== requestToken) return;
      ideas = result;
      notConnected = false;
    } catch (err) {
      if (token !== requestToken) return;
      notConnected = err instanceof ApiError && err.status === 409;
      if (!notConnected) error = errorMessage(err);
    }
  }

  const key = (term: string, country: string): string => `${term.toLowerCase()}|${country.toUpperCase()}`;
  const isTracked = (term: string, country: string, trackedId?: string | null): boolean =>
    !!trackedId || trackedHere.has(key(term, country));

  async function track(term: string, country: string): Promise<void> {
    const k = key(term, country);
    trackedHere = new Set(trackedHere).add(k);
    try {
      await addKeyword(term, country.toLowerCase());
    } catch (err) {
      if (err instanceof ApiError && err.status === 409) return;
      const next = new Set(trackedHere);
      next.delete(k);
      trackedHere = next;
      error = errorMessage(err);
    }
  }

  // ── Related to a keyword ──────────────────────────────────────────────
  let tracked = $state<Keyword[]>([]);
  let seedId = $state('');
  let related = $state<SuggestionsResponse | null>(null);
  let relatedError = $state<string | null>(null);
  let relatedLoading = $state(false);

  onMount(async () => {
    try {
      tracked = (await listKeywords()).slice().sort((a, b) => a.term.localeCompare(b.term));
    } catch {
      tracked = [];
    }
  });

  const seed = $derived(tracked.find((k) => k.id === seedId) ?? null);

  async function loadRelated(id: string): Promise<void> {
    related = null;
    relatedError = null;
    if (!id) return;
    relatedLoading = true;
    try {
      related = await getKeywordSuggestions(id);
    } catch (err) {
      relatedError = errorMessage(err);
    } finally {
      relatedLoading = false;
    }
  }

  const sections = $derived(
    ideas
      ? [
          {
            id: 'converted',
            title: 'Converting search terms',
            hint: 'Brought tap installs but aren’t an exact-match keyword yet. Sorted by installs.',
            empty: 'No search term converted in this period that isn’t already an exact-match bid.',
            rows: ideas.converted,
          },
          {
            id: 'suggestions',
            title: 'Apple’s suggestions',
            hint: 'Keywords Apple recommends for this app that you don’t bid on yet.',
            empty: 'Apple has no new keyword suggestions for this app.',
            rows: ideas.suggestions,
          },
          {
            id: 'wasted',
            title: 'Wasted spend',
            hint: '50 or more taps and no installs. Candidates for negative keywords. Sorted by spend.',
            empty: 'No search term reached 50 taps without an install.',
            rows: ideas.wasted,
          },
        ]
      : [],
  );
</script>

{#snippet ideaTable(rows: AppleAdsIdea[], withMetrics: boolean)}
  <div class="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
    <table class="min-w-full text-sm">
      <thead class="bg-zinc-50 dark:bg-zinc-900/50 text-left text-xs uppercase tracking-wide text-zinc-500">
        <tr>
          <th class="px-3 py-2 font-medium">Term</th>
          {#if withMetrics}
            <th class="px-3 py-2 font-medium text-right">Spend</th>
            <th class="px-3 py-2 font-medium text-right">Taps</th>
            <th class="px-3 py-2 font-medium text-right">Tap installs</th>
            <th class="px-3 py-2 font-medium text-right">CPI</th>
          {/if}
          <th class="px-3 py-2 font-medium text-right" title="Apple's search popularity, 1–100">Popularity</th>
          <th class="px-3 py-2 font-medium text-right">Organic</th>
          <th class="px-3 py-2 font-medium text-right">Difficulty</th>
          <th class="px-3 py-2"><span class="sr-only">Track</span></th>
        </tr>
      </thead>
      <tbody class="divide-y divide-zinc-100 dark:divide-zinc-800">
        {#each rows as idea (idea.term + '|' + idea.country)}
          <tr class="hover:bg-zinc-50 dark:hover:bg-zinc-900/40">
            <td class="px-3 py-2">
              <span class="text-zinc-900 dark:text-zinc-100">{idea.term}</span>
              <span class="ml-1 text-xs uppercase text-zinc-400">{idea.country}</span>
            </td>
            {#if withMetrics}
              {@const m = idea.metrics}
              <td class="px-3 py-2 text-right tabular-nums">{fmtMoney(m?.spend, ideas?.currency)}</td>
              <td class="px-3 py-2 text-right tabular-nums">{fmtInt(m?.taps)}</td>
              <td class="px-3 py-2 text-right tabular-nums">{fmtInt(m?.tapInstalls)}</td>
              <td class="px-3 py-2 text-right tabular-nums {lowDataClass(m)}" title={m?.lowData ? LOW_DATA_TITLE : undefined}>
                {fmtMoney(m?.cpi, ideas?.currency)}
              </td>
            {/if}
            <td class="px-3 py-2 text-right tabular-nums">{idea.popularity ?? '—'}</td>
            <td class="px-3 py-2 text-right tabular-nums">{idea.organicRank != null ? `#${idea.organicRank}` : '—'}</td>
            <td class="px-3 py-2 text-right tabular-nums">{idea.difficulty ?? '—'}</td>
            <td class="px-3 py-2 text-right">
              {#if isTracked(idea.term, idea.country, idea.trackedKeywordId)}
                <span class="text-xs text-zinc-400">Tracked</span>
              {:else}
                <button type="button" onclick={() => track(idea.term, idea.country)} class="text-xs text-amber-600 dark:text-amber-400 hover:underline">
                  Track
                </button>
              {/if}
            </td>
          </tr>
        {/each}
      </tbody>
    </table>
  </div>
{/snippet}

{#if notConnected}
  {@render emptyState('notConnected')}
{:else if error}
  <p class="text-sm text-red-600 dark:text-red-400 rounded-md border border-red-200 dark:border-red-900 p-3 bg-red-50 dark:bg-red-900/20">{error}</p>
{:else if !ideas}
  <div class="rounded-md border border-zinc-200 dark:border-zinc-800 p-6 text-center text-sm text-zinc-500">Loading…</div>
{:else if !status?.lastSuccessAt}
  {@render emptyState('notSynced')}
{:else}
  <div class="space-y-8">
    {#each sections as section (section.id)}
      <section class="space-y-2">
        <div>
          <h2 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">
            {section.title} <span class="font-normal text-zinc-400">{section.rows.length}</span>
          </h2>
          <p class="text-xs text-zinc-500">{section.hint}</p>
        </div>
        {#if section.rows.length === 0}
          <p class="rounded-md border border-dashed border-zinc-200 dark:border-zinc-800 p-4 text-sm text-zinc-500">{section.empty}</p>
        {:else}
          {@render ideaTable(section.rows, section.id !== 'suggestions')}
        {/if}
      </section>
    {/each}

    <section class="space-y-2">
      <div>
        <h2 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">Related to a keyword</h2>
        <p class="text-xs text-zinc-500">Search terms from your Apple Ads campaigns, last 30 synced days, that share words with a tracked keyword.</p>
      </div>
      <select
        bind:value={seedId}
        onchange={() => void loadRelated(seedId)}
        aria-label="Tracked keyword"
        class="w-72 rounded-md border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950 px-2 py-1.5 text-sm text-zinc-900 dark:text-zinc-100"
      >
        <option value="">Pick a tracked keyword…</option>
        {#each tracked as k (k.id)}
          <option value={k.id}>{k.term} · {k.countryCode.toUpperCase()}</option>
        {/each}
      </select>
      {#if relatedLoading}
        <p class="text-sm text-zinc-500">Reading search terms…</p>
      {:else if relatedError}
        <p class="text-sm text-red-600 dark:text-red-400">{relatedError}</p>
      {:else if related && seed}
        {#if related.anonymized}
          <p class="text-xs text-zinc-500">
            Apple withheld the text of {fmtInt(related.anonymized.impressions)} impressions for privacy (LOW_VOLUME).
          </p>
        {/if}
        {#if related.rows.length === 0}
          <p class="rounded-md border border-dashed border-zinc-200 dark:border-zinc-800 p-4 text-sm text-zinc-500">
            No related search terms in {seed.countryCode.toUpperCase()} yet.
          </p>
        {:else}
          <div class="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
            <table class="min-w-full text-sm">
              <thead class="bg-zinc-50 dark:bg-zinc-900/50 text-left text-xs uppercase tracking-wide text-zinc-500">
                <tr>
                  <th class="px-3 py-2 font-medium">Term</th>
                  <th class="px-3 py-2 font-medium text-right">Impressions</th>
                  <th class="px-3 py-2 font-medium text-right">Taps</th>
                  <th class="px-3 py-2 font-medium text-right">TTR</th>
                  <th class="px-3 py-2"><span class="sr-only">Track</span></th>
                </tr>
              </thead>
              <tbody class="divide-y divide-zinc-100 dark:divide-zinc-800">
                {#each related.rows as row (row.term)}
                  <tr class="hover:bg-zinc-50 dark:hover:bg-zinc-900/40">
                    <td class="px-3 py-2 text-zinc-900 dark:text-zinc-100">{row.term}</td>
                    <td class="px-3 py-2 text-right tabular-nums">{fmtInt(row.impressions)}</td>
                    <td class="px-3 py-2 text-right tabular-nums">{fmtInt(row.taps)}</td>
                    <td class="px-3 py-2 text-right tabular-nums">{fmtPct(row.ttr)}</td>
                    <td class="px-3 py-2 text-right">
                      {#if row.alreadyTracked || isTracked(row.term, seed.countryCode)}
                        <span class="text-xs text-zinc-400">Tracked</span>
                      {:else}
                        <button type="button" onclick={() => seed && track(row.term, seed.countryCode)} class="text-xs text-amber-600 dark:text-amber-400 hover:underline">
                          Track
                        </button>
                      {/if}
                    </td>
                  </tr>
                {/each}
              </tbody>
            </table>
          </div>
        {/if}
      {/if}
    </section>
  </div>
{/if}
