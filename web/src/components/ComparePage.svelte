<script lang="ts">
  import { onMount } from 'svelte';
  import {
    listApps, listCompetitors, getCompare,
    refreshAppMetadata, deleteCompetitor,
  } from '../lib/api';
  import type { WatchedApp, CompareResponse } from '../lib/types';
  import { APP_STORE_COUNTRIES } from '../lib/countries';
  import { apps, competitors } from '../lib/stores';
  import CountrySingleCombobox from './CountrySingleCombobox.svelte';
  import CompetitorPicker from './CompetitorPicker.svelte';
  import MetadataDiffTable from './MetadataDiffTable.svelte';
  import ChangeTimeline from './ChangeTimeline.svelte';
  import ScreenshotStrip from './ScreenshotStrip.svelte';
  import AddCompetitorModal from './AddCompetitorModal.svelte';

  // The compare page owns three pieces of state:
  //   • ownAppID — which of the user's own apps is the baseline.
  //   • selectedCompetitorIDs — which competitors to render columns for.
  //   • country — which storefront's snapshots to render.
  // Every change triggers a re-fetch of /compare; the response shape
  // includes lazy-backfilled snapshots so missing (app, country) pairs
  // get filled in on demand.
  let ownAppID = $state<string | null>(null);
  let selectedCompetitorIDs: string[] = $state([]);
  let country = $state('us');
  let compareData = $state<CompareResponse | null>(null);
  let loading = $state(false);
  let error = $state<string | null>(null);
  let showAddModal = $state(false);

  // Load the apps and competitors lists on mount so the pickers
  // populate. Both come from cheap GETs; no need for the dashboard
  // polling machinery here — metadata changes daily at most.
  onMount(() => {
    void loadAppsAndCompetitors();
  });

  async function loadAppsAndCompetitors(): Promise<void> {
    try {
      const [ownList, compList] = await Promise.all([listApps(), listCompetitors()]);
      // The /apps endpoint returns ALL apps (own + competitor); for
      // the own-app picker we filter to own only. The competitors
      // store is populated from the dedicated /competitors endpoint
      // since it already filters server-side.
      apps.set(ownList.filter((a) => a.kind === 'own'));
      competitors.set(compList);
      // Default selection: first own app, all competitors.
      const ownApps = ownList.filter((a) => a.kind === 'own');
      if (!ownAppID && ownApps.length > 0) ownAppID = ownApps[0].id;
      if (selectedCompetitorIDs.length === 0) {
        selectedCompetitorIDs = compList.map((c) => c.id);
      }
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    }
  }

  // Re-fetch /compare whenever the selection changes. Debouncing is
  // unnecessary at this scale — the picker mutations are user-paced,
  // not keystroke-paced.
  $effect(() => {
    const own = ownAppID;
    const competitorIds = selectedCompetitorIDs;
    const c = country;
    if (!own && competitorIds.length === 0) {
      compareData = null;
      return;
    }
    void fetchCompare(own, competitorIds, c);
  });

  async function fetchCompare(own: string | null, competitorIds: string[], c: string): Promise<void> {
    if (!own) {
      compareData = null;
      return;
    }
    loading = true;
    error = null;
    try {
      compareData = await getCompare(own, competitorIds, c);
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      loading = false;
    }
  }

  async function refreshAll(): Promise<void> {
    if (!compareData) return;
    loading = true;
    try {
      const targets = [
        compareData.ownApp?.id,
        ...compareData.competitors.map((c) => c.id),
      ].filter((x): x is string => !!x);
      await Promise.all(targets.map((id) => refreshAppMetadata(id, country)));
      // Re-fetch the aggregate to pull the freshly-stored rows.
      await fetchCompare(ownAppID, selectedCompetitorIDs, country);
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      loading = false;
    }
  }

  async function removeCompetitor(id: string): Promise<void> {
    if (!confirm('Remove this competitor? Snapshot history will be deleted.')) return;
    try {
      await deleteCompetitor(id);
      // Drop from selection + reload.
      selectedCompetitorIDs = selectedCompetitorIDs.filter((x) => x !== id);
      await loadAppsAndCompetitors();
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    }
  }

  // Pull the iPhone screenshots from each app's latest snapshot for the
  // strip rendering. Stored as JSON strings server-side; the strip
  // component parses defensively.
  function screenshotsJSON(appId: string): string | null {
    if (compareData?.ownApp?.id === appId) return compareData.ownApp.latest?.screenshotURLsJSON ?? null;
    return (
      compareData?.competitors.find((c) => c.id === appId)?.latest?.screenshotURLsJSON ?? null
    );
  }
</script>

<div class="max-w-7xl mx-auto px-4 py-6 space-y-6">
  <header class="flex items-center justify-between gap-4">
    <div>
      <h1 class="text-xl font-semibold text-zinc-900 dark:text-zinc-100">Compare</h1>
      <p class="text-sm text-zinc-500">
        Side-by-side metadata for your apps vs. competitors. Snapshots are taken daily.
      </p>
    </div>
    <button
      type="button"
      onclick={() => (showAddModal = true)}
      class="rounded-md bg-zinc-900 dark:bg-zinc-100 px-3 py-2 text-sm font-medium text-zinc-50 dark:text-zinc-950 hover:bg-black dark:hover:bg-white"
    >
      Add competitor
    </button>
  </header>

  <!-- Selection bar -->
  <section
    class="rounded-md border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900/50 p-4 grid grid-cols-1 md:grid-cols-3 gap-4"
  >
    <div class="space-y-1">
      <label class="text-xs uppercase tracking-wide text-zinc-500" for="own-app">
        Your app
      </label>
      <select
        id="own-app"
        bind:value={ownAppID}
        class="w-full rounded-md border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950 px-3 py-2 text-sm text-zinc-900 dark:text-zinc-100"
      >
        {#each $apps as app (app.id)}
          <option value={app.id}>{app.name}</option>
        {/each}
      </select>
    </div>

    <div class="space-y-1">
      <span class="text-xs uppercase tracking-wide text-zinc-500">Competitors</span>
      <CompetitorPicker
        competitors={$competitors}
        selectedIds={selectedCompetitorIDs}
        onChange={(next) => (selectedCompetitorIDs = next)}
      />
    </div>

    <div class="space-y-1">
      <label class="text-xs uppercase tracking-wide text-zinc-500" for="country">
        Storefront
      </label>
      <CountrySingleCombobox
        options={APP_STORE_COUNTRIES}
        selected={country}
        onChange={(c) => (country = c)}
      />
      <button
        type="button"
        onclick={() => void refreshAll()}
        disabled={loading || !compareData}
        class="mt-2 text-xs underline text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 disabled:opacity-50"
      >
        Refresh metadata now
      </button>
    </div>
  </section>

  {#if error}
    <p class="text-sm text-red-600 dark:text-red-400 rounded-md border border-red-200 dark:border-red-900 p-3 bg-red-50 dark:bg-red-900/20">
      {error}
    </p>
  {/if}

  {#if !ownAppID}
    <div class="rounded-md border border-zinc-200 dark:border-zinc-800 p-6 text-center text-sm text-zinc-500">
      Add at least one of your own apps to start comparing.
    </div>
  {:else if loading && !compareData}
    <div class="rounded-md border border-zinc-200 dark:border-zinc-800 p-6 text-center text-sm text-zinc-500">
      Loading metadata…
    </div>
  {:else if compareData}
    <!-- Diff table -->
    <MetadataDiffTable own={compareData.ownApp} competitors={compareData.competitors} />

    <!-- Screenshot strips per app -->
    <section class="space-y-4">
      <h2 class="text-sm font-semibold text-zinc-700 dark:text-zinc-300 uppercase tracking-wide">
        Screenshots
      </h2>
      {#if compareData.ownApp}
        <div>
          <h3 class="text-sm font-medium text-zinc-800 dark:text-zinc-200 mb-1">
            {compareData.ownApp.name} <span class="text-xs text-emerald-700 dark:text-emerald-300">(You)</span>
          </h3>
          <ScreenshotStrip json={screenshotsJSON(compareData.ownApp.id)} />
        </div>
      {/if}
      {#each compareData.competitors as competitor (competitor.id)}
        <div>
          <div class="flex items-center justify-between mb-1">
            <h3 class="text-sm font-medium text-zinc-800 dark:text-zinc-200">{competitor.name}</h3>
            <button
              type="button"
              onclick={() => void removeCompetitor(competitor.id)}
              class="text-xs text-zinc-500 underline hover:text-red-600 dark:hover:text-red-400"
            >
              Remove
            </button>
          </div>
          <ScreenshotStrip json={screenshotsJSON(competitor.id)} />
        </div>
      {/each}
    </section>

    <!-- Per-competitor change timeline -->
    {#if compareData.competitors.length > 0}
      <section class="space-y-4">
        <h2 class="text-sm font-semibold text-zinc-700 dark:text-zinc-300 uppercase tracking-wide">
          Competitor change timelines
        </h2>
        {#each compareData.competitors as competitor (competitor.id)}
          <div class="rounded-md border border-zinc-200 dark:border-zinc-800 p-4 space-y-3">
            <h3 class="text-sm font-medium text-zinc-800 dark:text-zinc-200">
              {competitor.name}
            </h3>
            <ChangeTimeline changes={competitor.recentChanges} title={null} />
          </div>
        {/each}
      </section>
    {/if}
  {/if}
</div>

{#if showAddModal}
  <AddCompetitorModal
    onClose={() => (showAddModal = false)}
    onAdded={() => void loadAppsAndCompetitors()}
  />
{/if}
