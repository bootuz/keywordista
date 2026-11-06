<script lang="ts">
  // How the app's campaigns did over the period, against the period before.
  import type { Snippet } from 'svelte';
  import { ApiError, errorMessage, getAppleAdsOverview } from '../lib/api';
  import type { AppleAdsDays, AppleAdsMetrics, AppleAdsOverview, AppleAdsSyncStatus } from '../lib/types';
  import { change, fmtInt, fmtMoney, fmtPct, LOW_DATA_TITLE, lowDataClass } from '../lib/appleAds';
  import { timeAgo } from '../lib/time';
  import AppleAdsTrend from './AppleAdsTrend.svelte';

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

  let data = $state<AppleAdsOverview | null>(null);
  let error = $state<string | null>(null);
  let notConnected = $state(false);
  let loading = $state(false);

  $effect(() => {
    void reloadKey;
    void load(appId, days);
  });

  // Responses can arrive out of order when the app or period changes fast.
  let requestToken = 0;
  async function load(id: string, d: AppleAdsDays): Promise<void> {
    const token = ++requestToken;
    loading = true;
    error = null;
    try {
      const result = await getAppleAdsOverview(id, d);
      if (token !== requestToken) return;
      data = result;
      notConnected = false;
    } catch (err) {
      if (token !== requestToken) return;
      notConnected = err instanceof ApiError && err.status === 409;
      if (!notConnected) error = errorMessage(err);
    } finally {
      if (token === requestToken) loading = false;
    }
  }

  const currency = $derived(data?.currency ?? null);
  const lastSync = $derived(data?.lastSync ?? status);
  const failedNotice = $derived(
    lastSync?.lastRun?.outcome === 'failed' && lastSync.lastSuccessAt
      ? `The last sync failed: ${(lastSync.lastRun.error ?? 'unknown error').replace(/\.$/, '')}. Showing data from the sync ${timeAgo(lastSync.lastSuccessAt).toLowerCase()}.`
      : null,
  );

  type Tile = { label: string; value: string; delta: number | null; lowerIsBetter?: boolean; ratio?: boolean; secondary?: string };
  const tiles = $derived.by((): Tile[] => {
    if (!data) return [];
    const t = data.totals;
    const p = data.previousTotals;
    return [
      { label: 'Spend', value: fmtMoney(t.spend, currency), delta: change(t.spend, p.spend) },
      {
        label: 'Tap installs',
        value: fmtInt(t.tapInstalls),
        delta: change(t.tapInstalls, p.tapInstalls),
        secondary: `${fmtInt(t.totalInstalls)} total incl. view-through`,
      },
      { label: 'Cost per install', value: fmtMoney(t.cpi, currency), delta: change(t.cpi, p.cpi), lowerIsBetter: true, ratio: true },
      { label: 'Conversion rate', value: fmtPct(t.cr), delta: change(t.cr, p.cr), ratio: true },
      { label: 'Tap-through rate', value: fmtPct(t.ttr), delta: change(t.ttr, p.ttr), ratio: true },
      { label: 'Cost per tap', value: fmtMoney(t.cpt, currency), delta: change(t.cpt, p.cpt), lowerIsBetter: true, ratio: true },
    ];
  });

  function deltaText(d: number | null): string {
    if (d == null) return '';
    const pct = Math.round(d * 100);
    return `${pct > 0 ? '+' : ''}${pct}%`;
  }
  function deltaClass(d: number | null, lowerIsBetter = false): string {
    if (d == null || Math.abs(d) < 0.005) return 'text-zinc-500';
    const good = lowerIsBetter ? d < 0 : d > 0;
    return good ? 'text-emerald-600 dark:text-emerald-400' : 'text-red-600 dark:text-red-400';
  }
  const ratioCell = (m: AppleAdsMetrics) => ({ cls: lowDataClass(m), title: m.lowData ? LOW_DATA_TITLE : undefined });
</script>

{#if notConnected}
  {@render emptyState('notConnected')}
{:else if error}
  <p class="text-sm text-red-600 dark:text-red-400 rounded-md border border-red-200 dark:border-red-900 p-3 bg-red-50 dark:bg-red-900/20">{error}</p>
{:else if !data}
  <div class="rounded-md border border-zinc-200 dark:border-zinc-800 p-6 text-center text-sm text-zinc-500">
    {loading ? 'Loading…' : ''}
  </div>
{:else if !data.lastSync.lastSuccessAt}
  {@render emptyState('notSynced')}
{:else}
  <div class="space-y-5">
    {#if failedNotice}
      <p class="text-sm text-amber-700 dark:text-amber-300 rounded-md border border-amber-200 dark:border-amber-900 bg-amber-50 dark:bg-amber-900/20 px-3 py-2">
        {failedNotice}
      </p>
    {/if}

    <p class="text-xs text-zinc-500">
      {data.from} – {data.to}, compared with {data.previousFrom} – {data.previousTo}.
      {#if data.totals.lowData}<span title={LOW_DATA_TITLE}> Under 50 taps: ratios are rough.</span>{/if}
    </p>

    <div class="grid grid-cols-2 gap-3 md:grid-cols-3 lg:grid-cols-6">
      {#each tiles as tile (tile.label)}
        <div class="rounded-md border border-zinc-200 dark:border-zinc-800 p-3">
          <div class="text-xs text-zinc-500">{tile.label}</div>
          <div
            class="mt-1 text-lg font-semibold tabular-nums {tile.ratio && data.totals.lowData ? 'text-zinc-400 dark:text-zinc-600' : 'text-zinc-900 dark:text-zinc-100'}"
            title={tile.ratio && data.totals.lowData ? LOW_DATA_TITLE : undefined}
          >
            {tile.value}
          </div>
          <div class="text-xs tabular-nums {deltaClass(tile.delta, tile.lowerIsBetter)}">
            {deltaText(tile.delta) || 'no change data'}
          </div>
          {#if tile.secondary}<div class="mt-1 text-[11px] text-zinc-500">{tile.secondary}</div>{/if}
        </div>
      {/each}
    </div>

    <div class="grid gap-3 md:grid-cols-2">
      <AppleAdsTrend title="Spend per day" points={data.daily.map((p) => ({ date: p.date, value: p.spend }))} format={(v) => fmtMoney(v, currency)} />
      <AppleAdsTrend title="Tap installs per day" points={data.daily.map((p) => ({ date: p.date, value: p.tapInstalls }))} format={(v) => fmtInt(v)} />
    </div>

    {#if data.campaigns.length === 0}
      <div class="rounded-md border border-zinc-200 dark:border-zinc-800 p-6 text-center text-sm text-zinc-500">
        No campaigns promote this app.
      </div>
    {:else}
      <div class="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
        <table class="min-w-full text-sm">
          <thead class="bg-zinc-50 dark:bg-zinc-900/50 text-left text-xs uppercase tracking-wide text-zinc-500">
            <tr>
              <th class="px-3 py-2 font-medium">Campaign</th>
              <th class="px-3 py-2 font-medium text-right">Spend</th>
              <th class="px-3 py-2 font-medium text-right">Taps</th>
              <th class="px-3 py-2 font-medium text-right">Tap installs</th>
              <th class="px-3 py-2 font-medium text-right" title="Tap plus view-through installs">Total installs</th>
              <th class="px-3 py-2 font-medium text-right">CPI</th>
              <th class="px-3 py-2 font-medium text-right">CR</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-zinc-100 dark:divide-zinc-800">
            {#each data.campaigns as c (c.id)}
              {@const r = ratioCell(c.metrics)}
              <tr class="hover:bg-zinc-50 dark:hover:bg-zinc-900/40">
                <td class="px-3 py-2">
                  <span class="text-zinc-900 dark:text-zinc-100">{c.name}</span>
                  <span class="ml-1 text-xs text-zinc-400">{c.status.toLowerCase()}</span>
                </td>
                <td class="px-3 py-2 text-right tabular-nums">{fmtMoney(c.metrics.spend, currency)}</td>
                <td class="px-3 py-2 text-right tabular-nums">{fmtInt(c.metrics.taps)}</td>
                <td class="px-3 py-2 text-right tabular-nums">{fmtInt(c.metrics.tapInstalls)}</td>
                <td class="px-3 py-2 text-right tabular-nums text-zinc-500">{fmtInt(c.metrics.totalInstalls)}</td>
                <td class="px-3 py-2 text-right tabular-nums {r.cls}" title={r.title}>{fmtMoney(c.metrics.cpi, currency)}</td>
                <td class="px-3 py-2 text-right tabular-nums {r.cls}" title={r.title}>{fmtPct(c.metrics.cr)}</td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {/if}

    {#if data.otherAppsCampaignCount > 0}
      <p class="text-xs text-zinc-500">
        {data.otherAppsCampaignCount} campaign{data.otherAppsCampaignCount === 1 ? '' : 's'} for apps you don't watch
        {data.otherAppsCampaignCount === 1 ? "isn't" : "aren't"} included.
      </p>
    {/if}
  </div>
{/if}
