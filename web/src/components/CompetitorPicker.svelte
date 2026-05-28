<script lang="ts">
  import type { WatchedApp } from '../lib/types';
  import AppIcon from './AppIcon.svelte';

  // Multi-select picker for competitors. Simpler than
  // CountryMultiCombobox (which it loosely follows) because the option
  // list is small — a user typically has a few competitors, not 175.
  // A flat checkbox list reads better than a combobox at this scale.

  interface Props {
    competitors: WatchedApp[];
    /// Currently selected competitor IDs. Two-way bound by the parent.
    selectedIds: string[];
    onChange: (selectedIds: string[]) => void;
  }
  let { competitors, selectedIds, onChange }: Props = $props();

  function toggle(id: string): void {
    if (selectedIds.includes(id)) {
      onChange(selectedIds.filter((x) => x !== id));
    } else {
      onChange([...selectedIds, id]);
    }
  }
</script>

{#if competitors.length === 0}
  <p class="text-sm text-zinc-500 italic">
    No competitors tracked yet. Use the "Add competitor" button to start.
  </p>
{:else}
  <ul class="space-y-1 max-h-64 overflow-y-auto">
    {#each competitors as competitor (competitor.id)}
      <li>
        <label
          class="flex items-center gap-2 px-2 py-1.5 rounded hover:bg-zinc-100 dark:hover:bg-zinc-800 cursor-pointer"
        >
          <input
            type="checkbox"
            checked={selectedIds.includes(competitor.id)}
            onchange={() => toggle(competitor.id)}
            class="rounded border-zinc-300 dark:border-zinc-700"
          />
          <AppIcon src={competitor.iconURL} alt={competitor.name} size={20} />
          <span class="text-sm text-zinc-800 dark:text-zinc-200 truncate">
            {competitor.name}
          </span>
        </label>
      </li>
    {/each}
  </ul>
{/if}
