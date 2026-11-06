<script lang="ts">
  // Bid keywords with their paid results next to the app's organic rank for
  // the same term and storefront.
  import type { Snippet } from 'svelte';
  import { addKeyword, ApiError, errorMessage, getAppleAdsKeywords } from '../lib/api';
  import type { AppleAdsDays, AppleAdsKeywordRow, AppleAdsSyncStatus } from '../lib/types';
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

  let rows = $state<AppleAdsKeywordRow[] | null>(null);
  let error = $state<string | null>(null);
  let notConnected = $state(false);
  // Terms tracked from this table, keyed term|country, so the button flips at once.
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
      const result = await getAppleAdsKeywords(id, d);
      if (token !== requestToken) return;
      rows = result;
      notConnected = false;
    } catch (err) {
      if (token !== requestToken) return;
      notConnected = err instanceof ApiError && err.status === 409;
      if (!notConnected) error = errorMessage(err);
    }
  }

  async function track(row: AppleAdsKeywordRow): Promise<void> {
    const key = `${row.text.toLowerCase()}|${row.country}`;
    trackedHere = new Set(trackedHere).add(key);
    try {
      await addKeyword(row.text, row.country.toLowerCase());
    } catch (err) {
      // Already tracked counts as success.
      if (err instanceof ApiError && err.status === 409) return;
      const next = new Set(trackedHere);
      next.delete(key);
      trackedHere = next;
      error = errorMessage(err);
    }
  }
</script>

{#if notConnected}
  {@render emptyState('notConnected')}
{:else if error}
  <p class="text-sm text-red-600 dark:text-red-400 rounded-md border border-red-200 dark:border-red-900 p-3 bg-red-50 dark:bg-red-900/20">{error}</p>
{:else if !rows}
  <div class="rounded-md border border-zinc-200 dark:border-zinc-800 p-6 text-center text-sm text-zinc-500">Loading…</div>
{:else if !status?.lastSuccessAt}
  {@render emptyState('notSynced')}
{:else if rows.length === 0}
  <div class="rounded-md border border-zinc-200 dark:border-zinc-800 p-6 text-center text-sm text-zinc-500">
    No keyword had impressions for this app in the period.
  </div>
{:else}
  <div class="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
    <table class="min-w-full text-sm">
      <thead class="bg-zinc-50 dark:bg-zinc-900/50 text-left text-xs uppercase tracking-wide text-zinc-500">
        <tr>
          <th class="px-3 py-2 font-medium">Keyword</th>
          <th class="px-3 py-2 font-medium">Campaign</th>
          <th class="px-3 py-2 font-medium text-right">Bid</th>
          <th class="px-3 py-2 font-medium text-right" title="Apple's suggested bid, most recent in the period">Suggested</th>
          <th class="px-3 py-2 font-medium text-right">Spend</th>
          <th class="px-3 py-2 font-medium text-right">Taps</th>
          <th class="px-3 py-2 font-medium text-right">Tap installs</th>
          <th class="px-3 py-2 font-medium text-right">CPI</th>
          <th class="px-3 py-2 font-medium text-right">CR</th>
          <th class="px-3 py-2 font-medium text-right" title="Your latest organic rank for this term in this storefront">Organic</th>
        </tr>
      </thead>
      <tbody class="divide-y divide-zinc-100 dark:divide-zinc-800">
        {#each rows as row (row.keywordId + ':' + row.country)}
          {@const muted = lowDataClass(row.metrics)}
          {@const lowTitle = row.metrics.lowData ? LOW_DATA_TITLE : undefined}
          <tr class="hover:bg-zinc-50 dark:hover:bg-zinc-900/40">
            <td class="px-3 py-2">
              <span class="text-zinc-900 dark:text-zinc-100">{row.text}</span>
              <span class="ml-1 text-xs uppercase text-zinc-400">{row.country}</span>
              <span class="ml-1 rounded bg-zinc-100 dark:bg-zinc-800 px-1.5 py-0.5 text-[10px] text-zinc-500">{row.matchType.toLowerCase()}</span>
            </td>
            <td class="px-3 py-2 text-zinc-600 dark:text-zinc-400">{row.campaignName}</td>
            <td class="px-3 py-2 text-right tabular-nums">{fmtMoney(row.bid, row.currency)}</td>
            <td class="px-3 py-2 text-right tabular-nums text-zinc-500">{fmtMoney(row.suggestedBid, row.currency)}</td>
            <td class="px-3 py-2 text-right tabular-nums">{fmtMoney(row.metrics.spend, row.currency)}</td>
            <td class="px-3 py-2 text-right tabular-nums">{fmtInt(row.metrics.taps)}</td>
            <td class="px-3 py-2 text-right tabular-nums">{fmtInt(row.metrics.tapInstalls)}</td>
            <td class="px-3 py-2 text-right tabular-nums {muted}" title={lowTitle}>{fmtMoney(row.metrics.cpi, row.currency)}</td>
            <td class="px-3 py-2 text-right tabular-nums {muted}" title={lowTitle}>{fmtPct(row.metrics.cr)}</td>
            <td class="px-3 py-2 text-right tabular-nums">
              {#if row.organicRank != null}
                <span>#{row.organicRank}</span>
                {#if row.alreadyRanksWell}
                  <span
                    class="ml-1 rounded bg-emerald-100 dark:bg-emerald-900/30 px-1.5 py-0.5 text-[10px] text-emerald-700 dark:text-emerald-300"
                    title="You already rank in the top 5 organically; some paid taps may be ones you'd have had anyway"
                  >
                    ranks well
                  </span>
                {/if}
              {:else if row.trackedKeywordId || trackedHere.has(`${row.text.toLowerCase()}|${row.country}`)}
                <span class="text-zinc-400" title="Tracked; no rank yet">—</span>
              {:else}
                <button type="button" onclick={() => track(row)} class="text-xs text-amber-600 dark:text-amber-400 hover:underline">
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
