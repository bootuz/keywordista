<script lang="ts">
  import { addCompetitor, searchCompetitors } from '../lib/api';
  import { APP_STORE_COUNTRIES } from '../lib/countries';
  import CountrySingleCombobox from './CountrySingleCombobox.svelte';
  import AppIcon from './AppIcon.svelte';
  import type { CompetitorSearchHit } from '../lib/types';

  // Two ways to add a competitor in this modal:
  //   • Search — type a term, hit /competitors/search, pick from
  //     results. Most ergonomic when browsing.
  //   • Paste — drop in an App Store URL or numeric id. Fastest when
  //     you already know the competitor.
  // (The third add-flow promised in the plan — "From keyword top-
  // results" — lives on the dashboard itself as a `+` button on each
  // TopResultDTO row; it doesn't need its own modal tab.)
  type Tab = 'search' | 'paste';

  interface Props {
    onClose: () => void;
    onAdded: () => void;
  }
  let { onClose, onAdded }: Props = $props();

  let tab: Tab = $state('search');
  let lookupCountry = $state('us');
  let busy = $state(false);
  let error = $state<string | null>(null);

  // ── Search tab ─────────────────────────────────────────────────
  let searchTerm = $state('');
  let searchResults = $state<CompetitorSearchHit[]>([]);
  let searching = $state(false);

  async function doSearch(): Promise<void> {
    const term = searchTerm.trim();
    if (term.length < 2) return;
    searching = true;
    error = null;
    try {
      searchResults = await searchCompetitors(term, lookupCountry);
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      searching = false;
    }
  }

  async function addFromHit(hit: CompetitorSearchHit): Promise<void> {
    if (hit.alreadyTracked) return;
    busy = true;
    error = null;
    try {
      await addCompetitor(hit.appStoreId, lookupCountry);
      onAdded();
      onClose();
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      busy = false;
    }
  }

  // ── Paste tab ──────────────────────────────────────────────────
  let pasted = $state('');

  // Accept either a raw numeric id or a URL containing /idNNNN.
  function parseAppStoreId(input: string): number | null {
    const trimmed = input.trim();
    if (/^\d+$/.test(trimmed)) return Number(trimmed);
    const m = trimmed.match(/id(\d+)/);
    if (m) return Number(m[1]);
    return null;
  }

  async function addFromPaste(e: Event): Promise<void> {
    e.preventDefault();
    const id = parseAppStoreId(pasted);
    if (id === null || id <= 0) {
      error = 'Could not parse an App Store id from that input. Paste a URL or numeric id.';
      return;
    }
    busy = true;
    error = null;
    try {
      await addCompetitor(id, lookupCountry);
      onAdded();
      onClose();
    } catch (e2) {
      error = e2 instanceof Error ? e2.message : String(e2);
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
    aria-labelledby="add-competitor-title"
    class="relative w-full max-w-lg rounded-xl border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900 p-6 space-y-4"
  >
    <header class="flex items-baseline justify-between">
      <h2 id="add-competitor-title" class="text-base font-semibold text-zinc-900 dark:text-zinc-100">
        Add a competitor
      </h2>
      <button
        type="button"
        onclick={onClose}
        class="text-sm text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300"
      >
        Cancel
      </button>
    </header>

    <!-- Tab strip -->
    <div role="tablist" class="flex gap-2 border-b border-zinc-200 dark:border-zinc-800">
      <button
        type="button"
        role="tab"
        aria-selected={tab === 'search'}
        onclick={() => (tab = 'search')}
        class="px-3 py-1.5 text-sm border-b-2 -mb-px"
        class:border-zinc-900={tab === 'search'}
        class:dark:border-zinc-100={tab === 'search'}
        class:text-zinc-900={tab === 'search'}
        class:dark:text-zinc-100={tab === 'search'}
        class:border-transparent={tab !== 'search'}
        class:text-zinc-500={tab !== 'search'}
      >
        Search by name
      </button>
      <button
        type="button"
        role="tab"
        aria-selected={tab === 'paste'}
        onclick={() => (tab = 'paste')}
        class="px-3 py-1.5 text-sm border-b-2 -mb-px"
        class:border-zinc-900={tab === 'paste'}
        class:dark:border-zinc-100={tab === 'paste'}
        class:text-zinc-900={tab === 'paste'}
        class:dark:text-zinc-100={tab === 'paste'}
        class:border-transparent={tab !== 'paste'}
        class:text-zinc-500={tab !== 'paste'}
      >
        Paste URL/ID
      </button>
    </div>

    <!-- Storefront — shared across both tabs -->
    <label class="block space-y-1">
      <span class="text-xs uppercase tracking-wide text-zinc-500">Lookup storefront</span>
      <CountrySingleCombobox
        options={APP_STORE_COUNTRIES}
        selected={lookupCountry}
        onChange={(c) => (lookupCountry = c)}
      />
      <span class="text-xs text-zinc-500">
        Initial metadata is pulled from this storefront. The daily job expands to other
        storefronts where you have keywords.
      </span>
    </label>

    {#if tab === 'search'}
      <form
        onsubmit={(e) => {
          e.preventDefault();
          void doSearch();
        }}
        class="space-y-3"
      >
        <input
          type="text"
          placeholder="Search the App Store..."
          bind:value={searchTerm}
          class="w-full rounded-md border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950 px-3 py-2 text-sm text-zinc-900 dark:text-zinc-100 focus:border-zinc-500 focus:outline-none"
        />
        <button
          type="submit"
          disabled={searching || searchTerm.trim().length < 2}
          class="w-full rounded-md bg-zinc-900 dark:bg-zinc-100 px-3 py-2 text-sm font-medium text-zinc-50 dark:text-zinc-950 hover:bg-black dark:hover:bg-white disabled:opacity-50"
        >
          {searching ? 'Searching…' : 'Search'}
        </button>
      </form>

      {#if searchResults.length > 0}
        <ul class="max-h-72 overflow-y-auto space-y-1 border-t border-zinc-200 dark:border-zinc-800 pt-3">
          {#each searchResults as hit (hit.appStoreId)}
            <li class="flex items-center gap-3 p-2 rounded hover:bg-zinc-100 dark:hover:bg-zinc-800">
              <AppIcon src={hit.iconURL} alt={hit.name} size={36} />
              <div class="flex-1 min-w-0">
                <div class="text-sm font-medium truncate text-zinc-900 dark:text-zinc-100">
                  {hit.name}
                </div>
                <div class="text-xs text-zinc-500">
                  {#if hit.averageRating != null}
                    ★ {hit.averageRating.toFixed(2)} • {hit.ratingCount?.toLocaleString() ?? 0} ratings
                  {/if}
                </div>
              </div>
              <button
                type="button"
                disabled={hit.alreadyTracked || busy}
                onclick={() => void addFromHit(hit)}
                class="text-xs px-3 py-1.5 rounded-md font-medium disabled:opacity-50"
                class:bg-zinc-900={!hit.alreadyTracked}
                class:dark:bg-zinc-100={!hit.alreadyTracked}
                class:text-zinc-50={!hit.alreadyTracked}
                class:dark:text-zinc-950={!hit.alreadyTracked}
                class:bg-zinc-200={hit.alreadyTracked}
                class:dark:bg-zinc-800={hit.alreadyTracked}
                class:text-zinc-500={hit.alreadyTracked}
                title={hit.alreadyTracked
                  ? `Already added as ${hit.existingKind === 'own' ? 'your own app' : 'a competitor'}`
                  : ''}
              >
                {hit.alreadyTracked ? hit.existingKind ?? 'tracked' : 'Add'}
              </button>
            </li>
          {/each}
        </ul>
      {/if}
    {:else}
      <form onsubmit={addFromPaste} class="space-y-3">
        <input
          type="text"
          placeholder="https://apps.apple.com/.../id123 or 123"
          bind:value={pasted}
          class="w-full rounded-md border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-950 px-3 py-2 text-sm text-zinc-900 dark:text-zinc-100 focus:border-zinc-500 focus:outline-none"
        />
        <button
          type="submit"
          disabled={busy}
          class="w-full rounded-md bg-zinc-900 dark:bg-zinc-100 px-3 py-2 text-sm font-medium text-zinc-50 dark:text-zinc-950 hover:bg-black dark:hover:bg-white disabled:opacity-50"
        >
          {busy ? 'Adding…' : 'Add competitor'}
        </button>
      </form>
    {/if}

    {#if error}
      <p class="text-sm text-red-600 dark:text-red-400">{error}</p>
    {/if}
  </div>
</div>
