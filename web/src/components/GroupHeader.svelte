<script lang="ts">
  import { collapsedGroups, toggleCollapsed } from '../lib/viewState';

  interface Props {
    id: string;
    label: string;
    summary: string;
    colspan: number;
  }
  let { id, label, summary, colspan }: Props = $props();

  const isCollapsed = $derived($collapsedGroups.has(id));
</script>

<tr class="bg-zinc-900/80 sticky top-0">
  <td {colspan} class="px-3 py-2">
    <button
      type="button"
      onclick={() => toggleCollapsed(id)}
      class="flex w-full items-center gap-2 text-left text-zinc-200 hover:text-white"
    >
      <span class="inline-block w-3 text-zinc-500 transition" class:rotate-90={!isCollapsed}>▸</span>
      <span class="font-medium">{label}</span>
      <span class="text-xs text-zinc-500">{summary}</span>
    </button>
  </td>
</tr>
