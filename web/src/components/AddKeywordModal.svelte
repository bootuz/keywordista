<script lang="ts">
  import { addKeyword } from '../lib/api';
  import { dashboard } from '../lib/stores';

  interface Props {
    onClose: () => void;
    onAdded: () => void;
  }
  let { onClose, onAdded }: Props = $props();

  let term = $state('');
  let country = $state('us');
  let busy = $state(false);
  let error = $state<string | null>(null);

  // Suggest countries you're already tracking keywords in — saves typing
  // on the common case. New countries are allowed; this is just autocomplete.
  const suggestions = $derived(() =>
    Array.from(new Set($dashboard.map((r) => r.countryCode))).sort(),
  );

  async function submit(e: Event) {
    e.preventDefault();
    if (!term.trim()) {
      error = 'Term cannot be empty.';
      return;
    }
    if (country.length !== 2) {
      error = 'Country must be a 2-letter ISO code.';
      return;
    }
    busy = true;
    error = null;
    try {
      await addKeyword(term.trim(), country.trim().toLowerCase());
      onAdded();
      onClose();
    } catch (err) {
      error = err instanceof Error ? err.message : String(err);
    } finally {
      busy = false;
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
    class="relative w-full max-w-md rounded-xl border border-zinc-800 bg-zinc-900 p-6"
  >
  <form onsubmit={submit} class="space-y-4">
    <header class="flex items-baseline justify-between">
      <h2 id="add-keyword-title" class="text-base font-semibold text-zinc-100">Track a new keyword</h2>
      <button type="button" onclick={onClose} class="text-sm text-zinc-500 hover:text-zinc-300"
        >Cancel</button
      >
    </header>

    <label class="block space-y-1">
      <span class="text-xs uppercase tracking-wide text-zinc-500">Term</span>
      <input
        type="text"
        placeholder="e.g. flashcards"
        bind:value={term}
        class="w-full rounded-md border border-zinc-700 bg-zinc-950 px-3 py-2 text-sm text-zinc-100 focus:border-zinc-500 focus:outline-none"
      />
    </label>

    <label class="block space-y-1">
      <span class="text-xs uppercase tracking-wide text-zinc-500">Country</span>
      <input
        type="text"
        maxlength="2"
        list="known-countries"
        placeholder="us"
        bind:value={country}
        class="w-full rounded-md border border-zinc-700 bg-zinc-950 px-3 py-2 text-sm uppercase text-zinc-100 focus:border-zinc-500 focus:outline-none"
      />
      <datalist id="known-countries">
        {#each suggestions() as cc}
          <option value={cc}></option>
        {/each}
      </datalist>
    </label>

    {#if error}
      <p class="text-sm text-red-400">{error}</p>
    {/if}

    <button
      type="submit"
      disabled={busy}
      class="w-full rounded-md bg-zinc-100 px-3 py-2 text-sm font-medium text-zinc-950 hover:bg-white disabled:opacity-50"
    >
      {busy ? 'Adding…' : 'Add keyword'}
    </button>
  </form>
  </div>
</div>
