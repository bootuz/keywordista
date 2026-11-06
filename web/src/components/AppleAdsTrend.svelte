<script lang="ts">
  // One daily series as thin bars. Spend and installs get a chart each
  // rather than sharing two y-scales, which would invite reading the
  // crossing of two unrelated axes as meaningful.
  let {
    title,
    points,
    format,
  }: { title: string; points: { date: string; value: number }[]; format: (v: number) => string } = $props();

  const W = 360;
  const H = 120;
  const PAD = { top: 8, right: 4, bottom: 18, left: 4 };
  const innerW = W - PAD.left - PAD.right;
  const innerH = H - PAD.top - PAD.bottom;

  const max = $derived(Math.max(1e-9, ...points.map((p) => p.value)));
  const total = $derived(points.reduce((sum, p) => sum + p.value, 0));
  const step = $derived(points.length > 0 ? innerW / points.length : innerW);
  // Thin bars with a visible gap, so 30 days never fuse into a block.
  const barW = $derived(Math.max(2, Math.min(14, step - 2)));
  const x = (i: number): number => PAD.left + step * i + step / 2;
  const h = (v: number): number => (v / max) * innerH;
  // First and last day label the axis; the hover title carries the rest.
  // "Oct 7", not "7/10": numeric day/month order differs by locale.
  const shortDate = (d: string): string =>
    new Date(`${d}T00:00:00Z`).toLocaleDateString(undefined, { month: 'short', day: 'numeric', timeZone: 'UTC' });
  let hovered = $state<number | null>(null);
</script>

<figure class="rounded-md border border-zinc-200 dark:border-zinc-800 p-3 space-y-1">
  <figcaption class="flex items-baseline justify-between text-xs text-zinc-500">
    <span>{title}</span>
    <span class="tabular-nums text-zinc-700 dark:text-zinc-300">
      {#if hovered != null && points[hovered]}
        {points[hovered].date}: {format(points[hovered].value)}
      {:else}
        {format(total)} total
      {/if}
    </span>
  </figcaption>
  <svg viewBox="0 0 {W} {H}" class="w-full h-28" role="img" aria-label="{title} per day">
    <line x1={PAD.left} x2={W - PAD.right} y1={PAD.top + innerH} y2={PAD.top + innerH} class="stroke-zinc-200 dark:stroke-zinc-800" />
    {#each points as p, i (p.date)}
      {#if p.value > 0}
        <rect
          x={x(i) - barW / 2}
          y={PAD.top + innerH - h(p.value)}
          width={barW}
          height={h(p.value)}
          rx="2"
          class="fill-sky-600 dark:fill-sky-400 {hovered === i ? 'opacity-100' : 'opacity-80'}"
        />
      {/if}
      <!-- Full-height hit target, wider than the bar. -->
      <rect
        x={x(i) - step / 2}
        y={PAD.top}
        width={step}
        height={innerH}
        fill="transparent"
        role="presentation"
        onmouseenter={() => (hovered = i)}
        onmouseleave={() => (hovered = null)}
      >
        <title>{p.date}: {format(p.value)}</title>
      </rect>
    {/each}
    {#if points.length > 0}
      <text x={x(0)} y={H - 4} text-anchor="start" class="fill-zinc-400 text-[10px]">{shortDate(points[0].date)}</text>
      <text x={x(points.length - 1)} y={H - 4} text-anchor="end" class="fill-zinc-400 text-[10px]">{shortDate(points[points.length - 1].date)}</text>
    {/if}
  </svg>
</figure>
