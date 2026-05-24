<script lang="ts">
  import type { ChartPosition } from '../lib/types';
  import { isoCountryToFlag, timeAgo } from '../lib/time';
  import { appStoreCountryName } from '../lib/countries';

  interface Props {
    pos: ChartPosition;
  }
  let { pos }: Props = $props();

  // The App Store's small set of "primary genre" ids we expect to see.
  // Anything else falls through to "Category #<id>" — uncommon enough that
  // shipping a full map isn't worth it.
  const GENRE_NAMES: Record<number, string> = {
    6017: 'Education',
    6007: 'Productivity',
    6014: 'Games',
    6016: 'Entertainment',
    6020: 'Medical',
    6005: 'Social Networking',
    6011: 'Music',
    6012: 'Lifestyle',
    6013: 'Health & Fitness',
    6018: 'Books',
    6021: 'Newsstand',
    6023: 'Food & Drink',
    6024: 'Shopping',
    6000: 'Business',
    6001: 'Weather',
    6002: 'Utilities',
    6003: 'Travel',
    6004: 'Sports',
    6006: 'Reference',
    6008: 'Photo & Video',
    6009: 'Navigation',
    6010: 'Finance',
    6015: 'Finance',
    6022: 'Catalogs',
    6025: 'Stickers',
    6026: 'Developer Tools',
  };

  const genre = $derived(GENRE_NAMES[pos.genreId] ?? `Category #${pos.genreId}`);
</script>

<div class="rounded-md border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-950 p-3">
  <div class="flex items-baseline justify-between text-sm">
    <span class="font-medium text-zinc-900 dark:text-zinc-100">{pos.appName}</span>
    <span class="text-xs text-zinc-500" title={appStoreCountryName(pos.country)}>
      {isoCountryToFlag(pos.country)} {pos.country.toUpperCase()}
    </span>
  </div>
  <div class="my-1 text-2xl font-semibold text-amber-600 dark:text-amber-400">#{pos.position}</div>
  <div class="text-xs text-zinc-500">{genre} · {pos.chartType}</div>
  <div class="mt-1 text-[11px] text-zinc-400 dark:text-zinc-600">Seen {timeAgo(pos.observedAt)}</div>
</div>
