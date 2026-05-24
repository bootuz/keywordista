<script lang="ts">
  import type { Theme } from '../lib/theme';

  // Segmented Light/Dark/System picker. Stateless — owns no preference itself;
  // the parent passes the current value and an onchange handler. This keeps
  // the picker reusable (e.g. could be lifted into a top-bar later) and keeps
  // the source of truth in the theme module's localStorage.
  let { value, onchange }: { value: Theme; onchange: (t: Theme) => void } = $props();

  const options: { value: Theme; label: string }[] = [
    { value: 'light', label: 'Light' },
    { value: 'dark', label: 'Dark' },
    { value: 'system', label: 'System' },
  ];
</script>

<div
  role="radiogroup"
  aria-label="Theme"
  class="inline-flex rounded-md border border-zinc-200 bg-zinc-50 p-0.5 dark:border-zinc-800 dark:bg-zinc-900"
>
  {#each options as opt (opt.value)}
    {@const active = value === opt.value}
    <button
      type="button"
      role="radio"
      aria-checked={active}
      onclick={() => onchange(opt.value)}
      class="flex items-center gap-1.5 rounded px-3 py-1.5 text-xs font-medium transition-colors {active
        ? 'bg-white text-zinc-900 shadow-sm dark:bg-zinc-700 dark:text-zinc-100'
        : 'text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-200'}"
    >
      {#if opt.value === 'light'}
        <!-- sun -->
        <svg class="h-3.5 w-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <circle cx="12" cy="12" r="4" />
          <path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41" />
        </svg>
      {:else if opt.value === 'dark'}
        <!-- moon -->
        <svg class="h-3.5 w-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
        </svg>
      {:else}
        <!-- laptop / system -->
        <svg class="h-3.5 w-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <rect x="2" y="4" width="20" height="14" rx="2" />
          <path d="M2 20h20" />
        </svg>
      {/if}
      {opt.label}
    </button>
  {/each}
</div>
