<script lang="ts">
  // The Apple Ads area: one page, four tabs. Everything shown comes from the
  // local copy the daily sync keeps; "Sync now" refreshes it on demand.
  import { onDestroy, onMount } from 'svelte';
  import { push } from 'svelte-spa-router';
  import { ApiError, errorMessage, getAppleAdsSyncStatus, listApps, syncAppleAdsNow } from '../lib/api';
  import type { AppleAdsDays, AppleAdsSyncStatus } from '../lib/types';
  import { apps } from '../lib/stores';
  import { currentAppId } from '../lib/viewState';
  import { ROUTES } from '../lib/router';
  import { timeAgo } from '../lib/time';
  import AppleAdsOverview from './AppleAdsOverview.svelte';
  import AppleAdsKeywords from './AppleAdsKeywords.svelte';
  import AppleAdsBidIdeas from './AppleAdsBidIdeas.svelte';
  import AppleAdsSetup from './AppleAdsSetup.svelte';

  type Tab = 'overview' | 'keywords' | 'ideas' | 'setup';
  const tabs: { id: Tab; label: string }[] = [
    { id: 'overview', label: 'Overview' },
    { id: 'keywords', label: 'Keywords' },
    { id: 'ideas', label: 'Bid ideas' },
    { id: 'setup', label: 'Setup' },
  ];

  let { params }: { params?: { tab?: string } } = $props();
  const tab = $derived<Tab>(tabs.some((t) => t.id === params?.tab) ? (params?.tab as Tab) : 'overview');

  let appId = $state<string | null>(null);
  let days = $state<AppleAdsDays>(30);
  let status = $state<AppleAdsSyncStatus | null>(null);
  let syncError = $state<string | null>(null);
  // Bumped when a sync finishes so the open tab re-reads the fresh copy.
  let reloadKey = $state(0);
  let pollTimer: ReturnType<typeof setTimeout> | null = null;

  onMount(() => {
    void loadApps();
    void loadStatus();
  });
  onDestroy(() => {
    if (pollTimer) clearTimeout(pollTimer);
  });

  async function loadApps(): Promise<void> {
    try {
      const own = (await listApps()).filter((a) => a.kind === 'own');
      apps.set(own);
      // Follow the app picked in the app switcher, so Apple Ads opens on it.
      if (!appId) appId = own.find((a) => a.id === $currentAppId)?.id ?? own[0]?.id ?? null;
    } catch {
      // The tabs show their own errors; an empty picker is enough here.
    }
  }

  async function loadStatus(): Promise<void> {
    const wasRunning = status?.running ?? false;
    try {
      status = await getAppleAdsSyncStatus();
    } catch {
      return;
    }
    if (wasRunning && !status.running) reloadKey += 1;
    // Poll only while a sync runs; the daily one is picked up on the next visit.
    if (pollTimer) clearTimeout(pollTimer);
    pollTimer = status.running ? setTimeout(() => void loadStatus(), 2000) : null;
  }

  async function syncNow(): Promise<void> {
    syncError = null;
    try {
      status = await syncAppleAdsNow();
      void loadStatus();
    } catch (err) {
      // Not connected: Setup is where that gets fixed.
      if (err instanceof ApiError && err.status === 409) push(ROUTES.appleAds('setup'));
      else syncError = errorMessage(err);
    }
  }

  const chip = $derived.by(() => {
    if (!status) return { text: '…', cls: 'text-zinc-500' };
    if (status.running) return { text: 'Syncing…', cls: 'text-amber-600 dark:text-amber-400' };
    if (status.lastRun?.outcome === 'failed') return { text: 'Last sync failed', cls: 'text-red-600 dark:text-red-400' };
    if (status.lastSuccessAt) return { text: `Synced ${timeAgo(status.lastSuccessAt).toLowerCase()}`, cls: 'text-zinc-500' };
    return { text: 'Not synced yet', cls: 'text-zinc-500' };
  });
</script>

{#snippet emptyState(kind: 'notConnected' | 'notSynced')}
  <div class="rounded-md border border-zinc-200 dark:border-zinc-800 p-8 text-center text-sm text-zinc-500 space-y-3">
    {#if kind === 'notConnected'}
      <p>Apple Ads isn't connected yet.</p>
      <a href="#{ROUTES.appleAds('setup')}" class="inline-block text-amber-600 dark:text-amber-400 hover:underline">
        Connect it in Setup →
      </a>
    {:else if status?.running}
      <p>The first sync is running. This page fills in when it finishes.</p>
    {:else}
      <p>Nothing synced from Apple Ads yet.</p>
      <button
        type="button"
        onclick={syncNow}
        class="rounded-md bg-zinc-900 dark:bg-zinc-100 px-3 py-1.5 text-sm font-medium text-zinc-50 dark:text-zinc-950 hover:bg-black dark:hover:bg-white"
      >
        Sync now
      </button>
    {/if}
  </div>
{/snippet}

<div class="max-w-7xl mx-auto px-4 py-6 space-y-5">
  <header class="flex flex-wrap items-end justify-between gap-4">
    <div>
      <h1 class="text-xl font-semibold text-zinc-900 dark:text-zinc-100">Apple Ads</h1>
      <p class="text-sm text-zinc-500">How your ads perform, and which keywords to bid on next.</p>
    </div>
    <div class="flex items-center gap-3 text-sm">
      <span class={chip.cls} title={status?.lastRun?.error ?? undefined}>{chip.text}</span>
      <button
        type="button"
        onclick={syncNow}
        disabled={status?.running}
        class="rounded-md border border-zinc-300 dark:border-zinc-700 px-3 py-1.5 text-sm text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 disabled:opacity-50"
      >
        {status?.running ? 'Syncing…' : 'Sync now'}
      </button>
    </div>
  </header>

  {#if syncError}
    <p class="text-sm text-red-600 dark:text-red-400">{syncError}</p>
  {/if}

  <div class="flex flex-wrap items-end justify-between gap-4 border-b border-zinc-200 dark:border-zinc-800">
    <nav class="flex gap-1" aria-label="Apple Ads sections">
      {#each tabs as t (t.id)}
        <a
          href="#{ROUTES.appleAds(t.id)}"
          aria-current={tab === t.id ? 'page' : undefined}
          class="-mb-px border-b-2 px-3 py-2 text-sm {tab === t.id
            ? 'border-zinc-900 dark:border-zinc-100 text-zinc-900 dark:text-zinc-100 font-medium'
            : 'border-transparent text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200'}"
        >
          {t.label}
        </a>
      {/each}
    </nav>
    {#if tab !== 'setup' && $apps.length > 0}
      <div class="flex items-center gap-2 pb-2">
        <select
          bind:value={appId}
          onchange={() => currentAppId.set(appId)}
          aria-label="App"
          class="w-48 rounded-md border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950 px-2 py-1.5 text-sm text-zinc-900 dark:text-zinc-100"
        >
          {#each $apps as app (app.id)}
            <option value={app.id}>{app.name}</option>
          {/each}
        </select>
        <div class="flex rounded-md border border-zinc-300 dark:border-zinc-700 text-sm" role="group" aria-label="Period">
          {#each [7, 30] as const as d (d)}
            <button
              type="button"
              onclick={() => (days = d)}
              aria-pressed={days === d}
              class="px-2.5 py-1.5 {days === d
                ? 'bg-zinc-900 text-zinc-50 dark:bg-zinc-100 dark:text-zinc-950'
                : 'text-zinc-600 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800'}"
            >
              {d}d
            </button>
          {/each}
        </div>
      </div>
    {/if}
  </div>

  {#if tab === 'setup'}
    <AppleAdsSetup {status} onSyncNow={syncNow} onChanged={() => void loadStatus()} />
  {:else if !appId}
    <div class="rounded-md border border-zinc-200 dark:border-zinc-800 p-6 text-center text-sm text-zinc-500">
      Add one of your own apps first; Apple Ads numbers are shown per app.
    </div>
  {:else if tab === 'overview'}
    <AppleAdsOverview {appId} {days} {status} {reloadKey} {emptyState} />
  {:else if tab === 'keywords'}
    <AppleAdsKeywords {appId} {days} {status} {reloadKey} {emptyState} />
  {:else}
    <AppleAdsBidIdeas {appId} {days} {status} {reloadKey} {emptyState} />
  {/if}
</div>
