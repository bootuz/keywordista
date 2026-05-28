<script lang="ts">
  import type { DashboardRow as Row } from '../lib/types';
  import { refreshKeyword, deleteKeyword, addCompetitor, listCompetitors } from '../lib/api';
  import { refreshing, markRefreshing, clearRefreshing, ensurePolling, competitors } from '../lib/stores';
  import { timeAgo } from '../lib/time';
  import AppIcon from './AppIcon.svelte';
  import CountryFlag from './CountryFlag.svelte';
  import DotsIndicator from './DotsIndicator.svelte';
  import KeywordBadge from './KeywordBadge.svelte';
  import RankDelta from './RankDelta.svelte';

  interface Props {
    row: Row;
    onChanged: () => Promise<void>;
    onOpenHistory: () => void;
  }
  let { row, onChanged, onOpenHistory }: Props = $props();

  const isRefreshing = $derived($refreshing.has(row.keywordId));

  // Track which top-result app store ids are already tracked (so the
  // "+ track" button can disable itself for already-added apps). We
  // check the local `competitors` store rather than re-fetching per
  // hover. The store is populated by ComparePage; if the dashboard
  // is the first thing the user opens we accept a one-tick window
  // where the button shows "add" even for already-tracked apps —
  // the POST itself will then 409 on the uniqueness constraint.
  function isAlreadyTrackedAsCompetitor(appStoreId: number): boolean {
    return $competitors.some((c) => c.appStoreId === appStoreId);
  }

  let adding: Set<number> = $state(new Set());
  async function addAsCompetitor(appStoreId: number, country: string): Promise<void> {
    if (adding.has(appStoreId)) return;
    const next = new Set(adding);
    next.add(appStoreId);
    adding = next;
    try {
      await addCompetitor(appStoreId, country);
      // Refresh the competitors store so the button updates without
      // a page reload. Failure is non-fatal — the add still succeeded
      // server-side; the UI just won't reflect it until next reload.
      try {
        const list = await listCompetitors();
        competitors.set(list);
      } catch {
        // ignore
      }
    } catch (e) {
      alert(`Could not add competitor: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      const after = new Set(adding);
      after.delete(appStoreId);
      adding = after;
    }
  }

  function rankLabel(r: number | null): string {
    return r == null ? '—' : `#${r}`;
  }

  function rankColor(r: number | null): string {
    if (r == null) return 'text-zinc-500';
    if (r <= 10) return 'text-emerald-600 dark:text-emerald-400';
    if (r <= 50) return 'text-amber-600 dark:text-amber-400';
    return 'text-red-600 dark:text-red-400';
  }

  async function onRefresh() {
    markRefreshing(row.keywordId);
    try {
      await refreshKeyword(row.keywordId);
      // The shared poll loop watches `refreshing` and clears each id when
      // its row's checkedAt advances past the timestamp we just stored.
      // No per-row polling here — that was N concurrent dashboard fetches
      // for a "Refresh all" batch.
      ensurePolling();
    } catch (err) {
      // If the dispatch failed, drop the spinner so the user can retry.
      clearRefreshing(row.keywordId);
      throw err;
    }
  }

  async function onDelete() {
    if (!confirm(`Delete keyword "${row.term}"? Cascades to its rank history.`)) return;
    await deleteKeyword(row.keywordId);
    await onChanged();
  }
</script>

<tr class="border-t border-zinc-200 dark:border-zinc-800 hover:bg-zinc-50 dark:hover:bg-zinc-900/60">
  <td class="px-3 py-2">
    <button
      class="text-left text-sm font-medium text-zinc-900 dark:text-zinc-100 hover:text-amber-700 dark:hover:text-amber-300"
      onclick={onOpenHistory}
    >
      {row.term}
    </button>
    <KeywordBadge term={row.term} countryCode={row.countryCode} appId={row.watchedAppId} />
  </td>
  <td class="px-3 py-2"><CountryFlag code={row.countryCode} /></td>
  <td class="px-3 py-2">
    <div class="flex items-center gap-2">
      <span class="font-mono text-sm {rankColor(row.rank)}">{rankLabel(row.rank)}</span>
      <RankDelta
        rank={row.rank}
        previousRank={row.previousRank}
        hasPreviousCheck={row.hasPreviousCheck}
      />
    </div>
  </td>
  <td class="px-3 py-2">
    <div class="flex items-center gap-1">
      {#each row.topResults as r}
        {@const tracked = isAlreadyTrackedAsCompetitor(r.appStoreId)}
        {@const isAdding = adding.has(r.appStoreId)}
        <span class="relative group">
          <a
            href="https://apps.apple.com/{row.countryCode}/app/id{r.appStoreId}"
            target="_blank"
            rel="noopener noreferrer"
            title={r.name}
          >
            <AppIcon src={r.iconURL} alt={r.name} size={24} />
          </a>
          <!-- Hover-revealed "+ track as competitor" button. Hidden by
               default to keep the dashboard's existing density; appears
               on hover via group-hover. Disabled when already tracked
               or while the add request is in flight. -->
          <button
            type="button"
            onclick={() => void addAsCompetitor(r.appStoreId, row.countryCode)}
            disabled={tracked || isAdding}
            title={tracked ? 'Already tracked as a competitor' : 'Track this app as a competitor'}
            class="absolute -top-1 -right-1 hidden group-hover:flex items-center justify-center
                   h-4 w-4 rounded-full text-[10px] leading-none font-bold
                   bg-zinc-900 text-zinc-50 dark:bg-zinc-100 dark:text-zinc-900
                   disabled:bg-zinc-300 dark:disabled:bg-zinc-700 disabled:cursor-not-allowed"
            aria-label="Track {r.name} as a competitor"
          >
            {tracked ? '✓' : isAdding ? '…' : '+'}
          </button>
        </span>
      {/each}
    </div>
  </td>
  <td class="px-3 py-2"><DotsIndicator score={row.difficulty} /></td>
  <td class="px-3 py-2"><DotsIndicator score={row.entryBarrier} /></td>
  <td class="px-3 py-2 text-sm text-zinc-500">
    {#if isRefreshing}
      <span class="text-amber-600 dark:text-amber-400">Checking…</span>
    {:else}
      {timeAgo(row.checkedAt)}
    {/if}
  </td>
  <td class="px-3 py-2 text-right">
    <div class="flex justify-end gap-1.5">
      <button
        title="Refresh"
        onclick={onRefresh}
        disabled={isRefreshing}
        class="rounded p-1.5 text-zinc-600 dark:text-zinc-400 transition hover:bg-zinc-100 dark:hover:bg-zinc-800 hover:text-zinc-900 dark:hover:text-zinc-100 disabled:opacity-50"
      >
        <svg
          class={isRefreshing ? 'animate-spin' : ''}
          width="14"
          height="14"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
        >
          <path d="M3 12a9 9 0 0 1 15.5-6.3L21 8" />
          <path d="M21 3v5h-5" />
          <path d="M21 12a9 9 0 0 1-15.5 6.3L3 16" />
          <path d="M3 21v-5h5" />
        </svg>
      </button>
      <button
        title="Delete"
        onclick={onDelete}
        class="rounded p-1.5 text-zinc-600 dark:text-zinc-400 transition hover:bg-zinc-100 dark:hover:bg-zinc-800 hover:text-red-700 dark:hover:text-red-300"
      >
        <svg
          width="14"
          height="14"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
        >
          <polyline points="3 6 5 6 21 6"></polyline>
          <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"
          ></path>
        </svg>
      </button>
    </div>
  </td>
</tr>
