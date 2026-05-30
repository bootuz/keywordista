<script lang="ts">
  import { onMount } from 'svelte';
  import { listApps, getMetadataLint } from '../lib/api';
  import type { LintFinding } from '../lib/types';
  import { apps } from '../lib/stores';
  import { APP_STORE_COUNTRIES } from '../lib/countries';
  import CountrySingleCombobox from './CountrySingleCombobox.svelte';

  // Per-app, per-storefront listing lint. Mirrors GapsPage's self-contained
  // shape, with a country picker because listings are localized.
  let ownAppID = $state<string | null>(null);
  let country = $state('us');
  let findings = $state<LintFinding[] | null>(null);
  let loading = $state(false);
  let error = $state<string | null>(null);

  onMount(() => {
    void loadApps();
  });

  async function loadApps(): Promise<void> {
    try {
      const own = (await listApps()).filter((a) => a.kind === 'own');
      apps.set(own);
      if (!ownAppID && own.length > 0) ownAppID = own[0].id;
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    }
  }

  $effect(() => {
    const id = ownAppID;
    const c = country;
    if (!id) {
      findings = null;
      return;
    }
    void fetchFindings(id, c);
  });

  async function fetchFindings(id: string, c: string): Promise<void> {
    loading = true;
    error = null;
    try {
      findings = await getMetadataLint(id, c);
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      loading = false;
    }
  }

  // Warnings first — the most actionable findings on top.
  const sorted = $derived(
    (findings ?? [])
      .slice()
      .sort((a, b) => severityRank(a.severity) - severityRank(b.severity)),
  );
  const warningCount = $derived((findings ?? []).filter((f) => f.severity === 'warning').length);

  function severityRank(s: LintFinding['severity']): number {
    return s === 'warning' ? 0 : 1;
  }

  function ruleLabel(rule: LintFinding['rule']): string {
    switch (rule) {
      case 'duplicateWord':
        return 'Duplicate word';
      case 'wastedBudget':
        return 'Wasted space';
      case 'untrackedWord':
        return 'Untracked word';
    }
  }

  function severityStyle(s: LintFinding['severity']): string {
    return s === 'warning'
      ? 'bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-300'
      : 'bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300';
  }
</script>

<div class="max-w-4xl mx-auto px-4 py-6 space-y-6">
  <header>
    <a href="#/" class="text-xs text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300">← Dashboard</a>
    <h1 class="text-xl font-semibold text-zinc-900 dark:text-zinc-100">Listing optimizer</h1>
    <p class="text-sm text-zinc-500">
      ASO checks for your title &amp; subtitle — the fields Apple indexes for search.
      (The description doesn't affect ranking, so it isn't checked.)
    </p>
  </header>

  <!-- items-start (not items-end): the country combobox is taller than the
       plain select, and bottom-aligning would drop the shorter group's label
       out of line. Top-aligning keeps both field labels on one row. -->
  <section
    class="rounded-md border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900/50 p-4 flex flex-wrap items-start gap-4"
  >
    <div class="flex flex-col gap-1">
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
    <div class="flex flex-col gap-1">
      <span class="text-xs uppercase tracking-wide text-zinc-500">Storefront</span>
      <CountrySingleCombobox
        options={APP_STORE_COUNTRIES}
        selected={country}
        onChange={(c) => (country = c)}
      />
    </div>
  </section>

  {#if error}
    <p class="text-sm text-red-600 dark:text-red-400 rounded-md border border-red-200 dark:border-red-900 p-3 bg-red-50 dark:bg-red-900/20">
      {error}
    </p>
  {/if}

  {#if !ownAppID}
    <div class="rounded-md border border-zinc-200 dark:border-zinc-800 p-6 text-center text-sm text-zinc-500">
      Add one of your own apps to lint its listing.
    </div>
  {:else if loading && !findings}
    <div class="rounded-md border border-zinc-200 dark:border-zinc-800 p-6 text-center text-sm text-zinc-500">
      Linting…
    </div>
  {:else if findings && findings.length === 0}
    <div class="rounded-md border border-dashed border-zinc-200 dark:border-zinc-800 p-12 text-center">
      <p class="text-zinc-700 dark:text-zinc-300">
        No findings — your title &amp; subtitle look well-optimized for this storefront. 🎉
      </p>
      <p class="mt-1 text-sm text-zinc-500">
        If you just added this app, run a metadata refresh on the Compare page first.
      </p>
    </div>
  {:else if findings}
    <div class="space-y-2">
      <p class="text-sm text-zinc-500">
        {findings.length} finding{findings.length === 1 ? '' : 's'}{warningCount > 0
          ? ` · ${warningCount} warning${warningCount === 1 ? '' : 's'}`
          : ''}
      </p>
      {#each sorted as finding (finding.rule + finding.message)}
        <div class="rounded-md border border-zinc-200 dark:border-zinc-800 p-3 flex items-start gap-3">
          <span class="mt-0.5 inline-block whitespace-nowrap rounded px-2 py-0.5 text-xs font-medium {severityStyle(finding.severity)}">
            {ruleLabel(finding.rule)}
          </span>
          <div class="min-w-0">
            <p class="text-sm text-zinc-800 dark:text-zinc-200">{finding.message}</p>
            <p class="text-xs text-zinc-400">{finding.field}</p>
          </div>
        </div>
      {/each}
    </div>
  {/if}
</div>
