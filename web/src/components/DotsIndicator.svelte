<script lang="ts">
  // Renders five dots; the first `score` are colored, the rest are empty.
  // Color comes from the dot palette (1 → green, 5 → deep red).
  interface Props {
    score: number;
  }
  let { score }: Props = $props();

  const dotClasses = ['', 'bg-dot-1', 'bg-dot-2', 'bg-dot-3', 'bg-dot-4', 'bg-dot-5'];
  const clamped = $derived(Math.max(0, Math.min(5, Math.round(score))));
</script>

<div class="flex items-center gap-1">
  {#each Array(5) as _, i}
    <span
      class="h-2 w-2 rounded-full {i < clamped ? dotClasses[clamped] : 'bg-zinc-300 dark:bg-dot-empty'}"
    ></span>
  {/each}
</div>
