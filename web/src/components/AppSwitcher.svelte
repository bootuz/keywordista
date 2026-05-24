<script lang="ts">
  import { onMount } from 'svelte';
  import { apps } from '../lib/stores';
  import { currentAppId } from '../lib/viewState';

  interface Props {
    onAddNew: () => void;
  }
  let { onAddNew }: Props = $props();

  let open = $state(false);
  let rootEl: HTMLDivElement | null = $state(null);

  const currentApp = $derived($apps.find((a) => a.id === $currentAppId) ?? null);
  const triggerLabel = $derived(currentApp?.name ?? 'Select app');

  function select(id: string) {
    currentAppId.set(id);
    open = false;
  }

  function addAndClose() {
    open = false;
    onAddNew();
  }

  onMount(() => {
    const handler = (e: MouseEvent) => {
      if (!open) return;
      if (rootEl && !rootEl.contains(e.target as Node)) open = false;
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  });
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && (open = false)} />

<div class="relative" bind:this={rootEl}>
  <button
    type="button"
    onclick={() => (open = !open)}
    class="inline-flex items-center gap-2 rounded-md border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900 px-2.5 py-1 text-sm text-zinc-900 dark:text-zinc-100 hover:bg-zinc-100 dark:hover:bg-zinc-800"
    aria-haspopup="listbox"
    aria-expanded={open}
  >
    {#if currentApp?.iconURL}
      <img
        src={currentApp.iconURL}
        alt=""
        width="18"
        height="18"
        class="rounded-[4px] ring-1 ring-zinc-200 dark:ring-zinc-800"
      />
    {/if}
    <span class="font-medium">{triggerLabel}</span>
    <span class="text-zinc-500">▾</span>
  </button>

  {#if open}
    <div
      role="listbox"
      class="absolute left-0 top-full z-30 mt-1 w-72 overflow-hidden rounded-md border border-zinc-300 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-900 shadow-xl"
    >
      <div class="max-h-72 overflow-auto py-1">
        {#each $apps as app (app.id)}
          {@const active = app.id === $currentAppId}
          <button
            type="button"
            role="option"
            aria-selected={active}
            onclick={() => select(app.id)}
            class="flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm hover:bg-zinc-100 dark:hover:bg-zinc-800"
            class:bg-zinc-100={active}
            class:dark:bg-zinc-800={active}
          >
            {#if app.iconURL}
              <img
                src={app.iconURL}
                alt=""
                width="20"
                height="20"
                class="rounded-[5px] ring-1 ring-zinc-200 dark:ring-zinc-800"
              />
            {:else}
              <span class="h-5 w-5 rounded-[5px] bg-zinc-100 dark:bg-zinc-800"></span>
            {/if}
            <span class="flex-1 truncate text-zinc-800 dark:text-zinc-200">{app.name}</span>
            {#if active}
              <span class="text-amber-600 dark:text-amber-400">✓</span>
            {/if}
          </button>
        {:else}
          <div class="px-3 py-2 text-sm text-zinc-500">No apps yet.</div>
        {/each}
      </div>

      <button
        type="button"
        onclick={addAndClose}
        class="flex w-full items-center gap-2 border-t border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-950 px-3 py-2 text-left text-sm text-amber-600 dark:text-amber-400 hover:bg-zinc-100 dark:hover:bg-zinc-800"
      >
        <span class="text-base leading-none">+</span>
        <span>Add an app</span>
      </button>
    </div>
  {/if}
</div>
