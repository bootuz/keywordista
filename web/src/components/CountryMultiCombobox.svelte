<script lang="ts">
  import { onMount, tick } from 'svelte';
  import { isoCountryToFlag } from '../lib/time';
  import { appStoreCountryName } from '../lib/countries';

  interface Props {
    options: readonly string[];
    selected: string[];
    onChange: (next: string[]) => void;
    placeholder?: string;
  }
  let { options, selected, onChange, placeholder = 'Pick countries…' }: Props = $props();

  let open = $state(false);
  let search = $state('');
  let highlight = $state(0);
  let rootEl: HTMLDivElement | null = $state(null);
  let searchEl: HTMLInputElement | null = $state(null);
  let listEl: HTMLDivElement | null = $state(null);

  const filtered = $derived(filterAndSort(options, search, selected));

  function filterAndSort(opts: readonly string[], q: string, sel: string[]): string[] {
    const needle = q.trim().toLowerCase();
    const matches = opts.filter((cc) => {
      if (!needle) return true;
      return cc.includes(needle) || appStoreCountryName(cc).toLowerCase().includes(needle);
    });
    return [...matches].sort((a, b) => {
      const aSel = sel.includes(a) ? 0 : 1;
      const bSel = sel.includes(b) ? 0 : 1;
      if (aSel !== bSel) return aSel - bSel;
      return appStoreCountryName(a).localeCompare(appStoreCountryName(b));
    });
  }

  async function openMenu() {
    open = true;
    search = '';
    highlight = 0;
    await tick();
    searchEl?.focus();
  }

  function closeMenu() {
    open = false;
    search = '';
  }

  function toggle(cc: string) {
    const set = new Set(selected);
    if (set.has(cc)) set.delete(cc);
    else set.add(cc);
    onChange([...set]);
  }

  function removeOne(cc: string, e: Event) {
    e.stopPropagation();
    onChange(selected.filter((c) => c !== cc));
  }

  function onKey(e: KeyboardEvent) {
    if (!open) return;
    // Stop these from bubbling to the modal's window-level Escape handler,
    // which would otherwise close the modal when the user just meant to
    // close the popover.
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      e.stopPropagation();
      highlight = Math.min(filtered.length - 1, highlight + 1);
      scrollHighlightIntoView();
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      e.stopPropagation();
      highlight = Math.max(0, highlight - 1);
      scrollHighlightIntoView();
    } else if (e.key === 'Enter') {
      e.preventDefault();
      e.stopPropagation();
      const cc = filtered[highlight];
      if (cc) toggle(cc);
    } else if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      closeMenu();
    }
  }

  function scrollHighlightIntoView() {
    if (!listEl) return;
    const row = listEl.querySelector<HTMLElement>(`[data-idx="${highlight}"]`);
    row?.scrollIntoView({ block: 'nearest' });
  }

  $effect(() => {
    search;
    highlight = 0;
  });

  onMount(() => {
    const handler = (e: MouseEvent) => {
      if (!open) return;
      if (rootEl && !rootEl.contains(e.target as Node)) closeMenu();
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  });
</script>

<div class="relative" bind:this={rootEl} onkeydown={onKey} role="presentation">
  <div
    role="combobox"
    tabindex="0"
    aria-haspopup="listbox"
    aria-expanded={open}
    aria-controls="country-multi-listbox"
    onclick={() => (open ? closeMenu() : openMenu())}
    onkeydown={(e) => {
      if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault();
        if (!open) openMenu();
      }
    }}
    class="flex w-full cursor-pointer flex-wrap items-center gap-1.5 rounded-md border border-zinc-700 bg-zinc-950 px-2 py-1.5 text-left text-sm text-zinc-100 hover:border-zinc-600 focus:border-zinc-500 focus:outline-none"
  >
    {#if selected.length === 0}
      <span class="px-1 text-zinc-500">{placeholder}</span>
    {:else}
      {#each selected as cc (cc)}
        <span class="inline-flex items-center gap-1 rounded bg-zinc-800 py-0.5 pl-1.5 pr-1 text-xs">
          <span>{isoCountryToFlag(cc)}</span>
          <span class="font-mono uppercase text-zinc-200">{cc}</span>
          <button
            type="button"
            aria-label={`Remove ${appStoreCountryName(cc)}`}
            onclick={(e) => removeOne(cc, e)}
            class="ml-0.5 grid h-4 w-4 place-items-center rounded text-zinc-400 hover:bg-zinc-700 hover:text-zinc-100"
          >
            ×
          </button>
        </span>
      {/each}
    {/if}
    <span class="ml-auto self-center pl-1 text-zinc-500">▾</span>
  </div>

  {#if open}
    <div
      id="country-multi-listbox"
      role="listbox"
      class="absolute left-0 top-full z-30 mt-1 w-full overflow-hidden rounded-md border border-zinc-700 bg-zinc-900 shadow-xl"
    >
      <div class="border-b border-zinc-800 p-2">
        <input
          bind:this={searchEl}
          type="search"
          placeholder="Search by name or code…"
          bind:value={search}
          class="w-full rounded-md border border-zinc-800 bg-zinc-950 px-2 py-1 text-sm text-zinc-100 placeholder:text-zinc-600 focus:border-zinc-600 focus:outline-none"
        />
      </div>

      <div bind:this={listEl} class="max-h-72 overflow-auto py-1">
        {#each filtered as cc, idx (cc)}
          {@const active = selected.includes(cc)}
          {@const isHighlighted = idx === highlight}
          <button
            type="button"
            role="option"
            aria-selected={active}
            data-idx={idx}
            onmouseenter={() => (highlight = idx)}
            onclick={() => toggle(cc)}
            class="flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm"
            class:bg-zinc-800={isHighlighted}
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
            <span class="text-zinc-200">{appStoreCountryName(cc)}</span>
            <span class="ml-auto font-mono text-xs uppercase text-zinc-500">({cc})</span>
          </button>
        {:else}
          <div class="px-3 py-2 text-sm text-zinc-500">No matches.</div>
        {/each}
      </div>

      <div class="flex items-center justify-between border-t border-zinc-800 px-2 py-1.5 text-xs text-zinc-500">
        <span>{selected.length} selected</span>
        <button type="button" onclick={closeMenu} class="hover:text-zinc-200">Done</button>
      </div>
    </div>
  {/if}
</div>
