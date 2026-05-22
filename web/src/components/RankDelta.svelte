<script lang="ts">
  // Renders the change between previousRank and rank as one of:
  //   ▲ N    — rank improved by N positions (green)
  //   ▼ N    — rank dropped by N positions (red)
  //   ▲ in   — just entered top 200 from outside (green)
  //   ▼ out  — just dropped out of top 200 (red)
  //   —      — no change (gray)
  //   (nothing) — no previous check yet
  //
  // App Store rank semantics: lower number = better. So delta is
  // `previousRank - currentRank` — positive means improvement.

  interface Props {
    rank: number | null;
    previousRank: number | null;
    hasPreviousCheck: boolean;
  }
  let { rank, previousRank, hasPreviousCheck }: Props = $props();

  type Indicator =
    | { kind: 'none' }
    | { kind: 'same' }
    | { kind: 'up'; positions: number }
    | { kind: 'down'; positions: number }
    | { kind: 'in' }
    | { kind: 'out' };

  const indicator = $derived<Indicator>(computeIndicator(rank, previousRank, hasPreviousCheck));

  function computeIndicator(r: number | null, p: number | null, hasPrev: boolean): Indicator {
    if (!hasPrev) return { kind: 'none' };
    if (r == null && p == null) return { kind: 'same' };
    if (r != null && p == null) return { kind: 'in' };
    if (r == null && p != null) return { kind: 'out' };
    // Both ranked
    const delta = (p as number) - (r as number);
    if (delta > 0) return { kind: 'up', positions: delta };
    if (delta < 0) return { kind: 'down', positions: -delta };
    return { kind: 'same' };
  }
</script>

{#if indicator.kind === 'up'}
  <span class="inline-flex items-center gap-0.5 text-xs font-medium text-emerald-400" title="Improved by {indicator.positions} since last check">
    <span>▲</span><span>{indicator.positions}</span>
  </span>
{:else if indicator.kind === 'down'}
  <span class="inline-flex items-center gap-0.5 text-xs font-medium text-red-400" title="Dropped by {indicator.positions} since last check">
    <span>▼</span><span>{indicator.positions}</span>
  </span>
{:else if indicator.kind === 'in'}
  <span class="inline-flex items-center gap-0.5 text-xs font-medium text-emerald-400" title="Entered top 200 since last check">
    <span>▲</span><span>in</span>
  </span>
{:else if indicator.kind === 'out'}
  <span class="inline-flex items-center gap-0.5 text-xs font-medium text-red-400" title="Dropped out of top 200 since last check">
    <span>▼</span><span>out</span>
  </span>
{:else if indicator.kind === 'same'}
  <span class="text-xs text-zinc-600" title="No change since last check">—</span>
{/if}
