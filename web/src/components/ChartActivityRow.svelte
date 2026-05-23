<script lang="ts">
  import type { ChartEvent } from '../lib/types';
  import { isoCountryToFlag, timeAgo } from '../lib/time';
  import { appStoreCountryName } from '../lib/countries';

  interface Props {
    event: ChartEvent;
  }
  let { event }: Props = $props();

  // One glyph per transition kind. Green = entry (good), red = exit (bad),
  // blue = mid-chart movement (neutral). The activity feed is mostly
  // scannable by color alone for a quick visual check.
  const ICON: Record<ChartEvent['kind'], string> = {
    entered: '🟢',
    moved:   '🔵',
    exited:  '🔴',
  };
</script>

<div class="flex items-center gap-3 border-b border-zinc-900 px-1 py-2 text-sm">
  <span class="text-base">{ICON[event.kind]}</span>
  <span class="flex-1 text-zinc-200">
    <span class="font-medium">{event.appName}</span>
    {#if event.kind === 'entered'}
      entered <span title={appStoreCountryName(event.country)}>{isoCountryToFlag(event.country)} {event.country.toUpperCase()}</span> at <span class="font-medium">#{event.position}</span>
    {:else if event.kind === 'moved'}
      moved in <span title={appStoreCountryName(event.country)}>{isoCountryToFlag(event.country)} {event.country.toUpperCase()}</span>: <span class="font-medium">#{event.prevPosition} → #{event.position}</span>
    {:else}
      exited <span title={appStoreCountryName(event.country)}>{isoCountryToFlag(event.country)} {event.country.toUpperCase()}</span> <span class="text-zinc-500">(was #{event.prevPosition})</span>
    {/if}
  </span>
  <span class="text-xs text-zinc-500" title={event.createdAt}>{timeAgo(event.createdAt)}</span>
</div>
