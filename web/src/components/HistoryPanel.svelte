<script lang="ts">
  import { getHistory } from '../lib/api';
  import type { HistoryPoint } from '../lib/types';
  import CountryFlag from './CountryFlag.svelte';

  interface Props {
    keywordId: string;
    keywordTerm: string;
    countryCode: string;
    watchedAppId: string;
    watchedAppName: string;
    onClose: () => void;
  }
  let { keywordId, keywordTerm, countryCode, watchedAppId, watchedAppName, onClose }: Props = $props();

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
    void (async () => {
      try {
        const result = await getHistory(targetKeyword, targetApp);
        if (token !== fetchToken) return; // a newer request superseded this
        points = result;
      } catch (err) {
        if (token !== fetchToken) return;
        error = err instanceof Error ? err.message : String(err);
      } finally {
        if (token === fetchToken) loading = false;
      }
    })();
  });

  // Build an SVG path for rank-over-time. Lower rank = better, so we invert
  // the y-axis (rank 1 sits at the top). Null ranks (outside top 200) skip
  // — we draw a dashed segment between known points to make missing data
  // visually obvious without inventing fake values.
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
</script>

<aside
  class="fixed inset-y-0 right-0 z-40 flex w-[640px] max-w-full flex-col border-l border-zinc-800 bg-zinc-950 shadow-2xl"
>
  <header class="flex items-baseline justify-between border-b border-zinc-800 px-6 py-4">
    <div class="min-w-0">
      <div class="flex items-center gap-2">
        <h2 class="truncate text-base font-semibold text-zinc-100">{keywordTerm}</h2>
        <CountryFlag code={countryCode} />
      </div>
      <p class="text-sm text-zinc-500">rank history — {watchedAppName}</p>
    </div>
    <button onclick={onClose} class="text-sm text-zinc-500 hover:text-zinc-300">Close</button>
  </header>

  <div class="flex-1 overflow-auto p-6">
    {#if loading}
      <p class="text-sm text-zinc-500">Loading history…</p>
    {:else if error}
      <p class="text-sm text-red-400">{error}</p>
    {:else if points.length === 0}
      <p class="text-sm text-zinc-500">No checks yet.</p>
    {:else}
      <svg
        viewBox="0 0 {chartWidth} {chartHeight}"
        class="w-full rounded-md border border-zinc-800 bg-zinc-900 p-2"
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
            <tr class="border-t border-zinc-800">
              <td class="py-1.5 text-zinc-300">{new Date(p.checkedAt).toLocaleString()}</td>
              <td class="text-zinc-100">{formatRank(p.rank)}</td>
              <td class="text-zinc-400">{p.difficulty}/5</td>
              <td class="text-zinc-400">{p.entryBarrier}/5</td>
            </tr>
          {/each}
        </tbody>
      </table>
    {/if}
  </div>
</aside>
