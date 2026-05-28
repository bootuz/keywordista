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
      // Snapshot the previous competitor ID set BEFORE the fetch so
      // we can detect newly-added rows after the API returns.
      const previousCompetitorIds = new Set(
        ($competitors ?? []).map((c) => c.id),
      );

      const [ownList, compList] = await Promise.all([listApps(), listCompetitors()]);
      // The /apps endpoint returns ALL apps (own + competitor); for
      // the own-app picker we filter to own only. The competitors
      // store is populated from the dedicated /competitors endpoint
      // since it already filters server-side.
      apps.set(ownList.filter((a) => a.kind === 'own'));
      competitors.set(compList);
      // Default own-app selection on first load.
      const ownApps = ownList.filter((a) => a.kind === 'own');
      if (!ownAppID && ownApps.length > 0) ownAppID = ownApps[0].id;
      // Selection rules:
      //   • First load (no prior set): select every competitor — the
      //     diff is most useful when everything is visible by default.
      //   • Subsequent reloads (e.g. after AddCompetitorModal onAdded
      //     fires): auto-select any *new* competitor that wasn't in the
      //     prior set so the user sees their just-added row without
      //     having to re-tick the checkbox. We preserve existing
      //     selections by union-ing with the current set.
      if (previousCompetitorIds.size === 0) {
        selectedCompetitorIDs = compList.map((c) => c.id);
      } else {
        const newlyAddedIds = compList
          .map((c) => c.id)
          .filter((id) => !previousCompetitorIds.has(id));
        if (newlyAddedIds.length > 0) {
          selectedCompetitorIDs = [...selectedCompetitorIDs, ...newlyAddedIds];
        }
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

  // Pull both screenshot sets from each app's latest snapshot. Apps
  // come in three flavors that all need to render correctly:
  //   • iPhone-only — has screenshotURLsJSON, ipad is null/empty.
  //   • iPad-only (Azri is one) — screenshotURLsJSON is empty but
  //     ipadScreenshotURLsJSON has content. Previously this rendered
  //     blank because we only read the iPhone field.
  //   • Universal — both populated; we stack them so the user can
  //     compare iPhone-to-iPhone AND iPad-to-iPad against competitors.
  //
  // Returns nullable strings (raw JSON from the server); ScreenshotStrip
  // parses defensively.
  function screenshotSets(appId: string): { iphone: string | null; ipad: string | null } {
    const latest =
      compareData?.ownApp?.id === appId
        ? compareData.ownApp.latest
        : compareData?.competitors.find((c) => c.id === appId)?.latest ?? null;
    return {
      iphone: latest?.screenshotURLsJSON ?? null,
      ipad: latest?.ipadScreenshotURLsJSON ?? null,
    };
  }

  /// Returns true when there is at least one parseable URL in the raw
  /// JSON string. Used by the template to decide whether to render a
  /// strip at all (avoiding the "No screenshots available" empty state
  /// next to a populated sibling strip — looks misleading).
  function hasAny(json: string | null): boolean {
    if (!json) return false;
    try {
      const parsed: unknown = JSON.parse(json);
      return Array.isArray(parsed) && parsed.some((v) => typeof v === 'string');
    } catch {
      return false;
    }
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
        {@const sets = screenshotSets(compareData.ownApp.id)}
        {@const hasIphone = hasAny(sets.iphone)}
        {@const hasIpad = hasAny(sets.ipad)}
        <div class="space-y-2">
          <h3 class="text-sm font-medium text-zinc-800 dark:text-zinc-200">
            {compareData.ownApp.name} <span class="text-xs text-emerald-700 dark:text-emerald-300">(You)</span>
          </h3>
          {#if !hasIphone && !hasIpad}
            <!-- Neither device has screenshots — render one empty strip
                 so the "No screenshots available" placeholder appears
                 (preserves the prior empty-state UX). -->
            <ScreenshotStrip json={null} />
          {:else}
            {#if hasIphone}
              <p class="text-xs text-zinc-500 uppercase tracking-wide">iPhone</p>
              <ScreenshotStrip json={sets.iphone} />
            {/if}
            {#if hasIpad}
              <p class="text-xs text-zinc-500 uppercase tracking-wide">iPad</p>
              <ScreenshotStrip json={sets.ipad} />
            {/if}
          {/if}
        </div>
      {/if}
      {#each compareData.competitors as competitor (competitor.id)}
        {@const sets = screenshotSets(competitor.id)}
        {@const hasIphone = hasAny(sets.iphone)}
        {@const hasIpad = hasAny(sets.ipad)}
        <div class="space-y-2">
          <div class="flex items-center justify-between">
            <h3 class="text-sm font-medium text-zinc-800 dark:text-zinc-200">{competitor.name}</h3>
            <button
              type="button"
              onclick={() => void removeCompetitor(competitor.id)}
              class="text-xs text-zinc-500 underline hover:text-red-600 dark:hover:text-red-400"
            >
              Remove
            </button>
          </div>
          {#if !hasIphone && !hasIpad}
            <ScreenshotStrip json={null} />
          {:else}
            {#if hasIphone}
              <p class="text-xs text-zinc-500 uppercase tracking-wide">iPhone</p>
              <ScreenshotStrip json={sets.iphone} />
            {/if}
            {#if hasIpad}
              <p class="text-xs text-zinc-500 uppercase tracking-wide">iPad</p>
              <ScreenshotStrip json={sets.ipad} />
            {/if}
          {/if}
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
