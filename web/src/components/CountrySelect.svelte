<script lang="ts">
  import { onMount } from 'svelte';
  import { isoCountryToFlag } from '../lib/time';

  interface Props {
    options: string[]; // available ISO codes (e.g. ['us','gb','jp'])
    selected: string[]; // currently selected ISO codes
    onChange: (next: string[]) => void;
  }
  let { options, selected, onChange }: Props = $props();

  let open = $state(false);
  let search = $state('');
  let rootEl: HTMLDivElement | null = $state(null);

  // Intl.DisplayNames is built into every modern browser — gives us
  // "United States", "Japan", "Россия", etc. with no lookup table to ship.
  const displayNames = new Intl.DisplayNames(['en'], { type: 'region' });

  function nameOf(cc: string): string {
    try {
      return displayNames.of(cc.toUpperCase()) ?? cc.toUpperCase();
    } catch {
      return cc.toUpperCase();
    }
  }

  // Filtered + sorted options. Selected entries sort first inside the menu
  // so you can always see what's currently active without scrolling.
  const filtered = $derived(filterAndSort(options, search, selected));

  function filterAndSort(opts: string[], q: string, sel: string[]): string[] {
    const needle = q.trim().toLowerCase();
    const matches = opts.filter((cc) => {
      if (!needle) return true;
      return cc.includes(needle) || nameOf(cc).toLowerCase().includes(needle);
    });
    return matches.sort((a, b) => {
      const aSel = sel.includes(a) ? 0 : 1;
      const bSel = sel.includes(b) ? 0 : 1;
      if (aSel !== bSel) return aSel - bSel;
      return nameOf(a).localeCompare(nameOf(b));
    });
  }

  function toggle(cc: string) {
    const set = new Set(selected);
    if (set.has(cc)) set.delete(cc);
    else set.add(cc);
    onChange(Array.from(set));
  }

  function clearAll() {
    onChange([]);
  }

  function selectAll() {
    onChange([...options]);
  }

  // Close the popover when clicking outside the component.
  onMount(() => {
    const handler = (e: MouseEvent) => {
      if (!open) return;
      if (rootEl && !rootEl.contains(e.target as Node)) open = false;
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  });

  const triggerLabel = $derived(buildTriggerLabel(selected));
  function buildTriggerLabel(sel: string[]): string {
    if (sel.length === 0) return 'All countries';
    if (sel.length === 1) return `${isoCountryToFlag(sel[0])} ${sel[0].toUpperCase()}`;
    return `${sel.length} countries`;
  }
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && (open = false)} />

<div class="relative" bind:this={rootEl}>
  <button
    type="button"
    onclick={() => (open = !open)}
    class="inline-flex items-center gap-1.5 rounded-md border border-zinc-800 bg-zinc-900 px-2.5 py-1 text-sm text-zinc-100 hover:bg-zinc-800"
    aria-haspopup="listbox"
    aria-expanded={open}
  >
    <span class="text-xs uppercase tracking-wide text-zinc-500">Countries:</span>
    <span class="font-medium">{triggerLabel}</span>
    <span class="text-zinc-500">▾</span>
  </button>

  {#if open}
    <div
      role="listbox"
      class="absolute left-0 top-full z-30 mt-1 w-72 overflow-hidden rounded-md border border-zinc-700 bg-zinc-900 shadow-xl"
    >
      <div class="border-b border-zinc-800 p-2">
        <input
          type="search"
          placeholder="Filter countries…"
          bind:value={search}
          class="w-full rounded-md border border-zinc-800 bg-zinc-950 px-2 py-1 text-sm text-zinc-100 placeholder:text-zinc-600 focus:border-zinc-600 focus:outline-none"
        />
      </div>

      <div class="max-h-72 overflow-auto py-1">
        {#each filtered as cc (cc)}
          {@const active = selected.includes(cc)}
          <button
            type="button"
            role="option"
            aria-selected={active}
            onclick={() => toggle(cc)}
            class="flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm hover:bg-zinc-800"
          >
            <span
              class="grid h-4 w-4 place-items-center rounded border text-[10px]"
              class:border-amber-500={active}
              class:bg-amber-500={active}
              class:text-zinc-950={active}
              class:border-zinc-700={!active}
            >
              {active ? '✓' : ''}
            </span>
            <span>{isoCountryToFlag(cc)}</span>
            <span class="w-7 font-mono text-xs uppercase text-zinc-500">{cc}</span>
            <span class="text-zinc-200">{nameOf(cc)}</span>
          </button>
        {:else}
          <div class="px-3 py-2 text-sm text-zinc-500">No matches.</div>
        {/each}
      </div>

      <div class="flex items-center justify-between gap-2 border-t border-zinc-800 px-2 py-1.5 text-xs">
        <button type="button" onclick={clearAll} class="text-zinc-500 hover:text-zinc-200">
          Clear
        </button>
        <span class="text-zinc-600">{selected.length} of {options.length} selected</span>
        <button type="button" onclick={selectAll} class="text-zinc-500 hover:text-zinc-200">
          Select all
        </button>
      </div>
    </div>
  {/if}
</div>
