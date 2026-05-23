<script lang="ts">
  import { onMount } from 'svelte';
  import { apps } from '../lib/stores';
  import { getChartPositions, refreshCharts, refreshAvailability } from '../lib/api';
  import {
    chartEvents,
    loadInitialEvents,
    markChartsVisited,
    pollOnce,
  } from '../lib/chartEvents';
  import {
    permissionState,
    userDismissed,
    markDismissed,
    requestPermission,
    isSupported,
  } from '../lib/notifications';
  import type { ChartPosition } from '../lib/types';
  import ChartPositionCard from './ChartPositionCard.svelte';
  import ChartActivityRow from './ChartActivityRow.svelte';

  interface Props {
    onClose: () => void;
  }
  let { onClose }: Props = $props();

  let positions = $state<ChartPosition[]>([]);
  let loading = $state(true);
  let error = $state<string | null>(null);
  let refreshing = $state(false);
  let probing = $state<string | null>(null);     // appId currently being re-probed
  let permission = $state(permissionState());
  let dismissed = $state(userDismissed());

  const showPermissionCTA = $derived(
    isSupported() && permission !== 'granted' && !dismissed
  );

  async function load() {
    try {
      positions = await getChartPositions();
      error = null;
    } catch (err) {
      error = err instanceof Error ? err.message : String(err);
    } finally {
      loading = false;
    }
  }

  onMount(() => {
    markChartsVisited();
    void load();
    void loadInitialEvents();
  });

  async function onEnable() {
    const result = await requestPermission();
    permission = result === 'unsupported' ? 'unsupported' : (result as NotificationPermission);
  }

  function onLater() {
    markDismissed();
    dismissed = true;
  }

  async function onCheckNow() {
    if (refreshing) return;
    refreshing = true;
    try {
      await refreshCharts();
      // Backend job runs async; give it a moment and then reload + poll.
      setTimeout(async () => {
        await load();
        await pollOnce();
        refreshing = false;
      }, 4000);
    } catch (err) {
      error = err instanceof Error ? err.message : String(err);
      refreshing = false;
    }
  }

  async function onReprobeAll() {
    const all = $apps;
    if (all.length === 0) return;
    probing = all[0].id;
    try {
      for (const a of all) {
        probing = a.id;
        await refreshAvailability(a.id);
      }
    } catch (err) {
      error = err instanceof Error ? err.message : String(err);
    } finally {
      probing = null;
    }
  }
</script>

<div class="fixed inset-0 z-40 flex flex-col bg-zinc-950 text-zinc-100">
  <!-- Header — matches the dashboard's chrome so the chart page feels like
       a peer surface rather than a modal. -->
  <header class="flex items-center gap-3 border-b border-zinc-800 px-6 py-3">
    <h1 class="text-base font-semibold tracking-tight">Keywordista</h1>
    <span class="rounded-md border border-amber-500/50 bg-amber-500/10 px-2 py-0.5 text-xs text-amber-300">
      Charts
    </span>
    <div class="ml-auto flex items-center gap-2">
      <button
        type="button"
        disabled={refreshing}
        onclick={onCheckNow}
        class="rounded-md border border-zinc-700 bg-zinc-900 px-3 py-1 text-sm text-zinc-100 hover:bg-zinc-800 disabled:opacity-50"
      >
        {refreshing ? 'Checking…' : 'Check now ↻'}
      </button>
      <button
        type="button"
        disabled={probing !== null}
        onclick={onReprobeAll}
        title="Re-detect which storefronts each watched app is published in"
        class="rounded-md border border-zinc-700 bg-zinc-900 px-3 py-1 text-sm text-zinc-100 hover:bg-zinc-800 disabled:opacity-50"
      >
        {probing ? 'Probing…' : 'Re-probe availability'}
      </button>
      <button
        type="button"
        onclick={onClose}
        class="rounded-md bg-zinc-100 px-3 py-1 text-sm font-medium text-zinc-950 hover:bg-white"
      >
        Back to Keywords
      </button>
    </div>
  </header>

  <main class="flex-1 overflow-auto px-6 py-4">
    {#if showPermissionCTA}
      <div class="mb-4 flex items-center gap-3 rounded-md border border-blue-900 bg-blue-950/30 p-3 text-sm text-blue-100">
        <span class="text-lg">🔔</span>
        <span class="flex-1">
          <b>Get notified when your apps chart.</b><br />
          <span class="text-blue-200/80">We'll fire a browser notification when one of your watched apps enters, moves in, or exits a top-100 chart in any storefront where it's available.</span>
        </span>
        <div class="flex gap-2">
          <button
            type="button"
            onclick={onEnable}
            class="rounded-md bg-blue-500 px-3 py-1 text-xs font-medium text-white hover:bg-blue-400"
          >
            Enable
          </button>
          <button
            type="button"
            onclick={onLater}
            class="rounded-md px-2 py-1 text-xs text-blue-200/80 hover:text-blue-100"
          >
            Later
          </button>
        </div>
      </div>
    {:else if permission === 'denied'}
      <div class="mb-4 rounded-md border border-amber-900 bg-amber-950/30 p-3 text-sm text-amber-100">
        Browser notifications are blocked. Re-enable them in your browser's site settings, then reload this page.
      </div>
    {/if}

    {#if loading}
      <p class="text-sm text-zinc-500">Loading…</p>
    {:else if error}
      <p class="text-sm text-red-400">{error}</p>
    {:else}
      <!-- Currently charted -->
      <section class="mb-6">
        <h2 class="mb-2 text-xs uppercase tracking-wide text-zinc-500">
          Currently charted
          {#if positions.length > 0}
            <span class="ml-2 text-zinc-600 normal-case tracking-normal">
              {positions.length} {positions.length === 1 ? 'position' : 'positions'}
            </span>
          {/if}
        </h2>
        {#if positions.length === 0}
          <div class="rounded-md border border-dashed border-zinc-800 p-10 text-center text-sm">
            <div class="text-2xl opacity-40">📈</div>
            <div class="mt-2 font-medium text-zinc-300">Nothing charted right now</div>
            <div class="mt-1 text-zinc-500">
              Watching {$apps.length} {$apps.length === 1 ? 'app' : 'apps'} across every storefront they ship in.
              Events show up here the moment something crosses into the top-100.
            </div>
          </div>
        {:else}
          <div class="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-3">
            {#each positions as pos (pos.appId + pos.country + pos.chartType + pos.genreId)}
              <ChartPositionCard {pos} />
            {/each}
          </div>
        {/if}
      </section>

      <!-- Recent activity -->
      <section>
        <h2 class="mb-2 text-xs uppercase tracking-wide text-zinc-500">Recent activity</h2>
        {#if $chartEvents.length === 0}
          <p class="text-sm text-zinc-500">No chart events yet. They'll appear here as soon as something moves.</p>
        {:else}
          <div class="rounded-md border border-zinc-800 bg-zinc-900/30">
            {#each $chartEvents as ev (ev.id)}
              <ChartActivityRow event={ev} />
            {/each}
          </div>
        {/if}
      </section>
    {/if}
  </main>
</div>
