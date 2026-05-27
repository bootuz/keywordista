<script lang="ts">
  import {
    filters,
    groupBy,
    clearFilters,
    uniqueCountriesFrom,
    DEFAULT_FILTERS,
    type RankBucket,
  } from '../lib/viewState';
  import type { GroupBy } from '../lib/grouping';
  import { dashboard, developerKeywords } from '../lib/stores';
  import CountrySelect from './CountrySelect.svelte';

  // Recompute available countries when the dashboard changes (add/delete).
  const countries = $derived(uniqueCountriesFrom($dashboard));

  // Whether the ASC filter has any data to match against. Empty map means
  // ASC creds aren't configured (or the GET /api/v1/settings/asc/keywords
  // call returned {}). We disable the toggle in that case so the user
  // can't toggle into a confusing zero-row state. If they're already ON
  // when creds get cleared, the "Clear filters" link is the escape
  // hatch — isDirty includes inASCOnly so it renders.
  const hasASCData = $derived($developerKeywords.size > 0);

  function setCountries(next: string[]) {
    filters.update((f) => ({ ...f, countries: next }));
  }

  const rankBuckets: Array<{ id: RankBucket; label: string }> = [
    { id: 'all', label: 'All' },
    { id: 'top10', label: 'Top 10' },
    { id: 'top50', label: 'Top 50' },
    { id: 'top200', label: 'Top 200' },
    { id: 'unranked', label: 'Unranked' },
  ];

  const groupOptions: Array<{ id: GroupBy; label: string }> = [
    { id: 'none', label: 'No grouping' },
    { id: 'country', label: 'Group: Country' },
    { id: 'app', label: 'Group: App' },
    { id: 'rankStatus', label: 'Group: Rank status' },
    { id: 'difficulty', label: 'Group: Difficulty' },
  ];

  function setRankBucket(b: RankBucket) {
    filters.update((f) => ({ ...f, rankBucket: b }));
  }

  function toggleASC() {
    filters.update((f) => ({ ...f, inASCOnly: !f.inASCOnly }));
  }

  const isDirty = $derived(
    $filters.search !== DEFAULT_FILTERS.search ||
      $filters.countries.length > 0 ||
      $filters.rankBucket !== DEFAULT_FILTERS.rankBucket ||
      $filters.inASCOnly !== DEFAULT_FILTERS.inASCOnly ||
      $filters.difficultyMin !== DEFAULT_FILTERS.difficultyMin ||
      $filters.difficultyMax !== DEFAULT_FILTERS.difficultyMax ||
      $filters.barrierMin !== DEFAULT_FILTERS.barrierMin ||
      $filters.barrierMax !== DEFAULT_FILTERS.barrierMax,
  );
</script>

<div class="relative z-20 space-y-3 border-b border-zinc-200 dark:border-zinc-800 bg-white/60 dark:bg-zinc-950/60 px-6 py-3">
  <!-- Row 1: search + grouping + clear -->
  <div class="flex flex-wrap items-center gap-3">
    <input
      type="search"
      placeholder="Search term or app…"
      bind:value={$filters.search}
      class="w-64 rounded-md border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900 px-3 py-1 text-sm text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 dark:placeholder:text-zinc-600 focus:border-zinc-400 dark:focus:border-zinc-600 focus:outline-none"
    />
    <select
      bind:value={$groupBy}
      class="rounded-md border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900 px-2 py-1 text-sm text-zinc-900 dark:text-zinc-100"
    >
      {#each groupOptions as opt}
        <option value={opt.id}>{opt.label}</option>
      {/each}
    </select>

    <!-- Rank bucket pills -->
    <div class="flex items-center gap-1 rounded-md border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900 p-0.5">
      {#each rankBuckets as bucket}
        <button
          type="button"
          onclick={() => setRankBucket(bucket.id)}
          class="rounded px-2 py-0.5 text-xs transition"
          class:bg-zinc-200={$filters.rankBucket === bucket.id}
          class:dark:bg-zinc-700={$filters.rankBucket === bucket.id}
          class:text-zinc-900={$filters.rankBucket === bucket.id}
          class:dark:text-zinc-100={$filters.rankBucket === bucket.id}
          class:text-zinc-600={$filters.rankBucket !== bucket.id}
          class:dark:text-zinc-400={$filters.rankBucket !== bucket.id}
        >
          {bucket.label}
        </button>
      {/each}
    </div>

    <!--
      ASC toggle — orthogonal to rankBucket (AND-composes via the
      predicate in viewState.applyFilters). Styled to match the rank pill
      group's *active* state when ON so it visually reads as "filter
      currently engaged"; matches the inactive state when OFF so it reads
      as "available filter". The single-pill wrapper mirrors the rank
      group's chrome, keeping both filter affordances visually aligned
      while signalling they're different concepts (one group of radios
      vs one toggle).
    -->
    <div class="flex items-center gap-1 rounded-md border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900 p-0.5">
      <button
        type="button"
        onclick={toggleASC}
        disabled={!hasASCData}
        title={hasASCData
          ? 'Show only keywords in your App Store Connect keywords field'
          : 'Configure App Store Connect API credentials in Settings to use this filter'}
        aria-pressed={$filters.inASCOnly}
        class={[
          'rounded px-2 py-0.5 text-xs font-medium uppercase tracking-wide transition',
          // Disabled state gets standard opacity treatment + not-allowed
          // cursor; the title attribute carries the why.
          'disabled:cursor-not-allowed disabled:opacity-50',
          // Svelte's `class:` directive can't handle slashes in Tailwind
          // arbitrary-opacity utilities (bg-amber-500/20, ring-amber-500/30),
          // so the conditional state lives in this template literal instead.
          $filters.inASCOnly
            ? 'bg-amber-500/20 text-amber-600 dark:text-amber-400 ring-1 ring-amber-500/30'
            : 'text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100',
        ].join(' ')}
      >
        ASC
      </button>
    </div>

    {#if isDirty}
      <button
        onclick={clearFilters}
        class="ml-auto text-xs text-zinc-500 underline-offset-2 hover:text-zinc-700 dark:hover:text-zinc-300 hover:underline"
      >
        Clear filters
      </button>
    {/if}
  </div>

  <!-- Row 2: country chips + app chips + ranges -->
  <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
    {#if countries.length > 0}
      <CountrySelect
        options={countries}
        selected={$filters.countries}
        onChange={setCountries}
      />
    {/if}

    <label class="flex items-center gap-1 text-xs text-zinc-600 dark:text-zinc-400">
      Difficulty
      <select
        bind:value={$filters.difficultyMin}
        class="rounded border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900 px-1 py-0.5 text-zinc-900 dark:text-zinc-100"
      >
        {#each [0, 1, 2, 3, 4, 5] as n}
          <option value={n}>{n}</option>
        {/each}
      </select>
      –
      <select
        bind:value={$filters.difficultyMax}
        class="rounded border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900 px-1 py-0.5 text-zinc-900 dark:text-zinc-100"
      >
        {#each [0, 1, 2, 3, 4, 5] as n}
          <option value={n}>{n}</option>
        {/each}
      </select>
    </label>

    <label class="flex items-center gap-1 text-xs text-zinc-600 dark:text-zinc-400">
      Barrier
      <select
        bind:value={$filters.barrierMin}
        class="rounded border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900 px-1 py-0.5 text-zinc-900 dark:text-zinc-100"
      >
        {#each [0, 1, 2, 3, 4, 5] as n}
          <option value={n}>{n}</option>
        {/each}
      </select>
      –
      <select
        bind:value={$filters.barrierMax}
        class="rounded border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900 px-1 py-0.5 text-zinc-900 dark:text-zinc-100"
      >
        {#each [0, 1, 2, 3, 4, 5] as n}
          <option value={n}>{n}</option>
        {/each}
      </select>
    </label>
  </div>
</div>
