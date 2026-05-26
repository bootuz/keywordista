<script lang="ts">
  import type { DashboardRow as Row } from '../lib/types';
  import { refreshKeyword, deleteKeyword } from '../lib/api';
  import { refreshing, markRefreshing, clearRefreshing, ensurePolling } from '../lib/stores';
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
        <a
          href="https://apps.apple.com/{row.countryCode}/app/id{r.appStoreId}"
          target="_blank"
          rel="noopener noreferrer"
          title={r.name}
        >
          <AppIcon src={r.iconURL} alt={r.name} size={24} />
        </a>
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
