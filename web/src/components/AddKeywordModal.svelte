<script lang="ts">
  import { addKeyword } from '../lib/api';
  import { APP_STORE_COUNTRIES, isAppStoreCountry, appStoreCountryName } from '../lib/countries';
  import CountryMultiCombobox from './CountryMultiCombobox.svelte';

  interface Props {
    onClose: () => void;
    onAdded: () => void;
  }
  let { onClose, onAdded }: Props = $props();

  const STORAGE_KEY = 'keywordista:lastCountries';

  // Restore the user's last committed country selection so they don't have to
  // re-pick every time. Falls back to ['us'] for first-time users or if
  // storage is unavailable / corrupted.
  function loadLastCountries(): string[] {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return ['us'];
      const parsed = JSON.parse(raw);
      if (!Array.isArray(parsed)) return ['us'];
      const valid = parsed.filter((x): x is string => typeof x === 'string' && isAppStoreCountry(x));
      return valid.length ? valid : ['us'];
    } catch {
      return ['us'];
    }
  }

  let term = $state('');
  let countries = $state<string[]>(loadLastCountries());
  let busy = $state(false);
  let error = $state<string | null>(null);
  let progress = $state<{ done: number; total: number } | null>(null);

  async function submit(e: Event) {
    e.preventDefault();
    if (!term.trim()) {
      error = 'Term cannot be empty.';
      return;
    }
    if (countries.length === 0) {
      error = 'Pick at least one country.';
      return;
    }
    busy = true;
    error = null;
    progress = { done: 0, total: countries.length };

    const results = await Promise.allSettled(
      countries.map(async (cc) => {
        await addKeyword(term.trim(), cc);
        progress = { done: (progress?.done ?? 0) + 1, total: countries.length };
      }),
    );

    busy = false;
    progress = null;

    const failures = results
      .map((r, i) => ({ cc: countries[i], r }))
      .filter((x): x is { cc: string; r: PromiseRejectedResult } => x.r.status === 'rejected');

    const succeeded = results.length - failures.length;

    if (succeeded > 0) {
      try {
        localStorage.setItem(STORAGE_KEY, JSON.stringify(countries));
      } catch { /* storage may be disabled — non-fatal */ }
      onAdded();
    }

    if (failures.length === 0) {
      onClose();
    } else {
      error = failures
        .map(({ cc, r }) => {
          const msg = r.reason instanceof Error ? r.reason.message : String(r.reason);
          return `${appStoreCountryName(cc)} (${cc.toUpperCase()}): ${msg}`;
        })
        .join(' • ');
    }
  }
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && onClose()} />
<div class="fixed inset-0 z-50 flex items-center justify-center">
  <button
    type="button"
    aria-label="Close"
    onclick={onClose}
    class="absolute inset-0 bg-black/60 backdrop-blur-sm"
  ></button>
  <div
    role="dialog"
    aria-modal="true"
    aria-labelledby="add-keyword-title"
    class="relative w-full max-w-md rounded-xl border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900 p-6"
  >
  <form onsubmit={submit} class="space-y-4">
    <header class="flex items-baseline justify-between">
      <h2 id="add-keyword-title" class="text-base font-semibold text-zinc-900 dark:text-zinc-100">Track a new keyword</h2>
      <button type="button" onclick={onClose} class="text-sm text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300"
        >Cancel</button
      >
    </header>

    <label class="block space-y-1">
      <span class="text-xs uppercase tracking-wide text-zinc-500">Term</span>
      <input
        type="text"
        placeholder="e.g. flashcards"
        bind:value={term}
        class="w-full rounded-md border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950 px-3 py-2 text-sm text-zinc-900 dark:text-zinc-100 focus:border-zinc-500 focus:outline-none"
      />
    </label>

    <div class="space-y-1">
      <div class="flex items-baseline justify-between">
        <span class="text-xs uppercase tracking-wide text-zinc-500">Countries</span>
        {#if countries.length > 0}
          <button
            type="button"
            onclick={() => (countries = [])}
            class="text-xs text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
          >
            Clear
          </button>
        {/if}
      </div>
      <CountryMultiCombobox
        options={APP_STORE_COUNTRIES}
        selected={countries}
        onChange={(next) => (countries = next)}
      />
    </div>

    {#if error}
      <p class="text-sm text-red-600 dark:text-red-400">{error}</p>
    {/if}

    <button
      type="submit"
      disabled={busy}
      class="w-full rounded-md bg-zinc-900 dark:bg-zinc-100 px-3 py-2 text-sm font-medium text-zinc-50 dark:text-zinc-950 hover:bg-black dark:hover:bg-white disabled:opacity-50"
    >
      {#if busy && progress}
        Adding {progress.done}/{progress.total}…
      {:else if busy}
        Adding…
      {:else}
        Add in {countries.length} {countries.length === 1 ? 'country' : 'countries'}
      {/if}
    </button>
  </form>
  </div>
</div>
