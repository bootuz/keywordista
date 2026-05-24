<script lang="ts">
  import { addApp } from '../lib/api';

  interface Props {
    onClose: () => void;
    onAdded: () => void;
  }
  let { onClose, onAdded }: Props = $props();

  let appStoreId = $state('');
  let busy = $state(false);
  let error = $state<string | null>(null);

  async function submit(e: Event) {
    e.preventDefault();
    const id = Number(appStoreId.trim());
    if (!Number.isFinite(id) || id <= 0) {
      error = 'App Store ID must be a positive number.';
      return;
    }
    busy = true;
    error = null;
    try {
      await addApp(id);
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
    aria-labelledby="add-app-title"
    class="relative w-full max-w-md rounded-xl border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900 p-6"
  >
    <form onsubmit={submit} class="space-y-4">
      <header class="flex items-baseline justify-between">
        <h2 id="add-app-title" class="text-base font-semibold text-zinc-900 dark:text-zinc-100">Watch a new app</h2>
        <button type="button" onclick={onClose} class="text-sm text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300"
          >Cancel</button
        >
      </header>

      <label class="block space-y-1">
        <span class="text-xs uppercase tracking-wide text-zinc-500">App Store ID</span>
        <input
          type="text"
          inputmode="numeric"
          placeholder="e.g. 1625870857"
          bind:value={appStoreId}
          class="w-full rounded-md border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950 px-3 py-2 text-sm text-zinc-900 dark:text-zinc-100 focus:border-zinc-500 focus:outline-none"
        />
        <span class="text-xs text-zinc-500">
          App will be tracked in every country where a keyword exists. Name + icon are pulled from the US storefront.
        </span>
      </label>

      {#if error}
        <p class="text-sm text-red-600 dark:text-red-400">{error}</p>
      {/if}

      <button
        type="submit"
        disabled={busy}
        class="w-full rounded-md bg-zinc-900 dark:bg-zinc-100 px-3 py-2 text-sm font-medium text-zinc-50 dark:text-zinc-950 hover:bg-black dark:hover:bg-white disabled:opacity-50"
      >
        {busy ? 'Adding…' : 'Add app'}
      </button>
    </form>
  </div>
</div>
