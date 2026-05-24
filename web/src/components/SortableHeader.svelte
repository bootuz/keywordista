<script lang="ts">
  import { sort, toggleSort, type SortColumn } from '../lib/viewState';

  interface Props {
    column: SortColumn;
    label: string;
    align?: 'left' | 'right';
  }
  let { column, label, align = 'left' }: Props = $props();

  const isActive = $derived($sort.column === column);
  const direction = $derived(isActive ? $sort.direction : null);
</script>

<th
  class="px-3 py-2 select-none"
  class:text-left={align === 'left'}
  class:text-right={align === 'right'}
>
  <button
    type="button"
    onclick={() => toggleSort(column)}
    class="group inline-flex items-center gap-1 text-xs uppercase tracking-wide text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
    class:text-zinc-800={isActive}
    class:dark:text-zinc-200={isActive}
  >
    {label}
    <span class="inline-flex w-3 text-[10px]">
      {#if direction === 'asc'}
        ↑
      {:else if direction === 'desc'}
        ↓
      {:else}
        <span class="opacity-0 group-hover:opacity-40">↕</span>
      {/if}
    </span>
  </button>
</th>
