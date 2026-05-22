<script lang="ts">
  interface Props {
    src: string | null;
    alt: string;
    size?: number;
  }
  let { src, alt, size = 28 }: Props = $props();
</script>

{#if src}
  <img
    {src}
    {alt}
    width={size}
    height={size}
    loading="lazy"
    class="rounded-md ring-1 ring-zinc-800"
    style="width: {size}px; height: {size}px;"
  />
{:else}
  <div
    class="rounded-md bg-zinc-800 ring-1 ring-zinc-700"
    style="width: {size}px; height: {size}px;"
  ></div>
{/if}
