<script lang="ts">
  import { onMount } from 'svelte';
  import { slide } from 'svelte/transition';
  import {
    getASCSettings,
    putASCSettings,
    deleteASCSettings,
    getASASettings,
    putASASettings,
    deleteASASettings,
  } from '../lib/api';
  import type { ASCStatus, ASAStatus } from '../lib/types';
  import { loadTheme, setTheme, type Theme } from '../lib/theme';
  import ThemePicker from './ThemePicker.svelte';
  import {
    developerKeywords,
    developerKeywordsLastFetchedAt,
    developerKeywordsError,
    refreshDeveloperKeywords,
  } from '../lib/stores';
  import { apps } from '../lib/stores';
  import { timeAgo } from '../lib/time';

  interface Props {
    onClose: () => void;
  }
  let { onClose }: Props = $props();

  // ── Appearance ─────────────────────────────────────────────────────────
  // Source of truth is localStorage (via lib/theme). We mirror it into local
  // reactive state so the picker re-renders immediately when the user clicks.
  let theme = $state<Theme>(loadTheme());
  function handleThemeChange(t: Theme) {
    theme = t;
    setTheme(t);
  }

  // ── Developer keywords (ASC fetch results) ─────────────────────────────
  let devKwBusy = $state(false);
  const devKwSummary = $derived.by(() => {
    const map = $developerKeywords;
    const list = $apps;
    return list.map((a) => {
      const byCountry = map.get(a.id);
      const storefronts = byCountry?.size ?? 0;
      let total = 0;
      if (byCountry) for (const set of byCountry.values()) total += set.size;
      return { name: a.name, total, storefronts };
    });
  });
  async function refreshDevKeywords() {
    devKwBusy = true;
    try {
      await refreshDeveloperKeywords();
    } catch {
      // Error message is captured in developerKeywordsError — surface inline.
    } finally {
      devKwBusy = false;
    }
  }

  // Collapsed/expanded state for the API sections. Default closed to keep the
  // panel compact; `loadASC` / `loadASA` open the section automatically if
  // it's not yet configured (so first-time users see the form they need to
  // fill in without an extra click).
  let ascExpanded = $state(false);
  let asaExpanded = $state(false);

  // ── ASC state ─────────────────────────────────────────────────────────
  let ascStatus = $state<ASCStatus | null>(null);
  let ascKeyId = $state('');
  let ascIssuerId = $state('');
  let ascPrivateKey = $state('');
  let ascReplacing = $state(false);
  let ascBusy = $state(false);
  let ascError = $state<string | null>(null);
  let ascMessage = $state<string | null>(null);

  // ── ASA state ─────────────────────────────────────────────────────────
  let asaStatus = $state<ASAStatus | null>(null);
  let asaClientId = $state('');
  let asaClientSecret = $state('');
  let asaOrgId = $state('');
  let asaReplacingSecret = $state(false);
  let asaBusy = $state(false);
  let asaError = $state<string | null>(null);
  let asaMessage = $state<string | null>(null);

  onMount(async () => {
    await Promise.all([loadASC(), loadASA()]);
  });

  async function loadASC() {
    try {
      ascStatus = await getASCSettings();
      ascKeyId = ascStatus.keyId ?? '';
      ascIssuerId = ascStatus.issuerId ?? '';
      // Auto-open if not configured so the user sees the form they need to
      // fill in. Re-runs after a Clear, which is the right behaviour.
      if (!ascStatus.configured) ascExpanded = true;
    } catch (e) {
      ascError = e instanceof Error ? e.message : String(e);
    }
  }

  async function loadASA() {
    try {
      asaStatus = await getASASettings();
      asaClientId = asaStatus.clientId ?? '';
      asaOrgId = asaStatus.orgId ?? '';
      if (!asaStatus.configured) asaExpanded = true;
    } catch (e) {
      asaError = e instanceof Error ? e.message : String(e);
    }
  }

  async function saveASC(e: Event) {
    e.preventDefault();
    ascBusy = true;
    ascError = null;
    ascMessage = null;
    try {
      // Send the pasted key only when the user is replacing it (or it's the
      // first save). Otherwise omit the field — the backend preserves the
      // existing stored key.
      const includePK = ascReplacing || !ascStatus?.hasPrivateKey;
      if (includePK && !ascPrivateKey.includes('BEGIN PRIVATE KEY')) {
        throw new Error('Paste the contents of your .p8 file (must include BEGIN PRIVATE KEY).');
      }
      ascStatus = await putASCSettings({
        keyId: ascKeyId,
        issuerId: ascIssuerId,
        ...(includePK ? { privateKey: ascPrivateKey } : {}),
      });
      ascPrivateKey = '';
      ascReplacing = false;
      ascMessage = 'Saved.';
      // Immediately pull the keyword list from ASC — this is the whole point
      // of saving credentials; the dashboard badges should light up without
      // requiring a manual refresh or page reload.
      void refreshDevKeywords();
    } catch (err) {
      ascError = err instanceof Error ? err.message : String(err);
    } finally {
      ascBusy = false;
    }
  }

  async function clearASC() {
    if (!confirm('Disconnect the App Store Connect integration?')) return;
    ascBusy = true;
    ascError = null;
    try {
      await deleteASCSettings();
      ascStatus = await getASCSettings();
      ascKeyId = '';
      ascIssuerId = '';
      ascPrivateKey = '';
      ascMessage = 'Disconnected.';
      // Backend will return {} now — that's still the right thing to push
      // into the store so the badges disappear.
      void refreshDevKeywords();
    } catch (err) {
      ascError = err instanceof Error ? err.message : String(err);
    } finally {
      ascBusy = false;
    }
  }

  async function saveASA(e: Event) {
    e.preventDefault();
    asaBusy = true;
    asaError = null;
    asaMessage = null;
    try {
      const includeSecret = asaReplacingSecret || !asaStatus?.hasClientSecret;
      if (includeSecret && !asaClientSecret.trim()) {
        throw new Error('Client secret is required.');
      }
      asaStatus = await putASASettings({
        clientId: asaClientId,
        ...(includeSecret ? { clientSecret: asaClientSecret } : {}),
        orgId: asaOrgId || undefined,
      });
      asaClientSecret = '';
      asaReplacingSecret = false;
      asaMessage = 'Saved.';
    } catch (err) {
      asaError = err instanceof Error ? err.message : String(err);
    } finally {
      asaBusy = false;
    }
  }

  async function clearASA() {
    if (!confirm('Disconnect the Apple Search Ads integration?')) return;
    asaBusy = true;
    asaError = null;
    try {
      await deleteASASettings();
      asaStatus = await getASASettings();
      asaClientId = '';
      asaClientSecret = '';
      asaOrgId = '';
      asaMessage = 'Disconnected.';
    } catch (err) {
      asaError = err instanceof Error ? err.message : String(err);
    } finally {
      asaBusy = false;
    }
  }
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && onClose()} />

<aside
  class="fixed inset-y-0 right-0 z-40 flex w-[600px] max-w-full flex-col border-l border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-950 shadow-2xl"
>
  <header class="flex items-baseline justify-between border-b border-zinc-200 dark:border-zinc-800 px-6 py-4">
    <div>
      <h2 class="text-base font-semibold text-zinc-900 dark:text-zinc-100">Settings</h2>
      <p class="text-sm text-zinc-500">Appearance and API credentials</p>
    </div>
    <button onclick={onClose} class="text-sm text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300">Close</button>
  </header>

  <div class="flex-1 space-y-3 overflow-auto px-6 py-6">
    <!-- Appearance ──────────────────────────────────────────────────────── -->
    <section class="rounded-lg border border-zinc-200 dark:border-zinc-800 p-4">
      <div class="mb-3 flex items-baseline justify-between">
        <h3 class="text-sm font-semibold text-zinc-800 dark:text-zinc-200">Appearance</h3>
      </div>
      <div class="flex items-center justify-between gap-4">
        <div>
          <p class="text-sm text-zinc-700 dark:text-zinc-300">Theme</p>
          <p class="text-xs text-zinc-500">
            Pick a colour scheme. <em>System</em> follows your OS preference.
          </p>
        </div>
        <ThemePicker value={theme} onchange={handleThemeChange} />
      </div>
    </section>

    <!-- ASC ─────────────────────────────────────────────────────────────── -->
    <section class="rounded-lg border border-zinc-200 dark:border-zinc-800 p-4">
      <button
        type="button"
        onclick={() => (ascExpanded = !ascExpanded)}
        aria-expanded={ascExpanded}
        aria-controls="asc-section-body"
        class="flex w-full items-center justify-between gap-2 text-left"
      >
        <span class="flex items-center gap-2">
          <svg
            class="h-3 w-3 text-zinc-500 transition-transform {ascExpanded ? 'rotate-90' : ''}"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2.5"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <polyline points="9 6 15 12 9 18" />
          </svg>
          <h3 class="text-sm font-semibold text-zinc-800 dark:text-zinc-200">App Store Connect API</h3>
        </span>
        {#if ascStatus?.configured}
          <span class="flex items-center gap-1 text-xs text-emerald-600 dark:text-emerald-400">
            <svg
              class="h-3.5 w-3.5"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="3"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <polyline points="5 12 10 17 19 8" />
            </svg>
            Connected
          </span>
        {:else}
          <span class="text-xs text-zinc-500">Not connected</span>
        {/if}
      </button>
      {#if ascExpanded}
        <div id="asc-section-body" class="mt-3" transition:slide={{ duration: 200 }}>
      <p class="mb-3 text-xs text-zinc-500">
        Used for fetching the keywords field you set in App Store Connect (developer keywords).
        Generate a key in App Store Connect → Users and Access → Integrations → App Store Connect API.
      </p>

      <form onsubmit={saveASC} class="space-y-3">
        <label class="block space-y-1">
          <span class="text-xs uppercase tracking-wide text-zinc-500">Key ID</span>
          <input
            type="text"
            placeholder="ABCDE12345"
            bind:value={ascKeyId}
            class="w-full rounded-md border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-950 px-3 py-2 font-mono text-sm text-zinc-900 dark:text-zinc-100 focus:border-zinc-400 dark:focus:border-zinc-600 focus:outline-none"
          />
        </label>

        <label class="block space-y-1">
          <span class="text-xs uppercase tracking-wide text-zinc-500">Issuer ID</span>
          <input
            type="text"
            placeholder="00000000-0000-0000-0000-000000000000"
            bind:value={ascIssuerId}
            class="w-full rounded-md border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-950 px-3 py-2 font-mono text-sm text-zinc-900 dark:text-zinc-100 focus:border-zinc-400 dark:focus:border-zinc-600 focus:outline-none"
          />
        </label>

        <div class="space-y-1">
          <div class="flex items-baseline justify-between">
            <span class="text-xs uppercase tracking-wide text-zinc-500">Private key (.p8)</span>
            {#if ascStatus?.hasPrivateKey && !ascReplacing}
              <button
                type="button"
                onclick={() => (ascReplacing = true)}
                class="text-xs text-amber-600 dark:text-amber-400 hover:underline"
              >
                Replace
              </button>
            {/if}
          </div>
          {#if ascStatus?.hasPrivateKey && !ascReplacing}
            <div class="rounded-md border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900 px-3 py-2 font-mono text-xs text-zinc-500">
              •••• stored
            </div>
          {:else}
            <textarea
              rows="6"
              placeholder={'-----BEGIN PRIVATE KEY-----\n…paste the full .p8 contents…\n-----END PRIVATE KEY-----'}
              bind:value={ascPrivateKey}
              class="w-full rounded-md border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-950 px-3 py-2 font-mono text-xs text-zinc-900 dark:text-zinc-100 focus:border-zinc-400 dark:focus:border-zinc-600 focus:outline-none"
            ></textarea>
          {/if}
        </div>

        {#if ascError}<p class="text-sm text-red-600 dark:text-red-400">{ascError}</p>{/if}
        {#if ascMessage}<p class="text-sm text-emerald-600 dark:text-emerald-400">{ascMessage}</p>{/if}

        <div class="flex items-center gap-2">
          <button
            type="submit"
            disabled={ascBusy}
            class="rounded-md bg-zinc-900 dark:bg-zinc-100 px-3 py-1.5 text-sm font-medium text-zinc-50 dark:text-zinc-950 hover:bg-black dark:hover:bg-white disabled:opacity-50"
          >
            {ascBusy ? 'Saving…' : 'Save'}
          </button>
          {#if ascStatus?.configured}
            <button
              type="button"
              onclick={clearASC}
              disabled={ascBusy}
              class="text-xs text-zinc-500 hover:text-red-700 dark:hover:text-red-300"
            >
              Disconnect
            </button>
          {/if}
        </div>
      </form>

      <!-- Developer keywords summary — proof the integration works ─────── -->
      {#if ascStatus?.configured}
        <div class="mt-4 rounded-md border border-zinc-200 dark:border-zinc-800 bg-zinc-50/40 dark:bg-zinc-900/40 p-3">
          <div class="flex items-baseline justify-between">
            <h4 class="text-xs font-semibold uppercase tracking-wide text-zinc-600 dark:text-zinc-400">
              Your App Store keywords
            </h4>
            <button
              type="button"
              onclick={refreshDevKeywords}
              disabled={devKwBusy}
              class="text-xs text-amber-600 dark:text-amber-400 hover:underline disabled:opacity-50"
            >
              {devKwBusy ? 'Fetching…' : 'Refresh now'}
            </button>
          </div>

          {#if $developerKeywordsError}
            <p class="mt-2 text-xs text-red-600 dark:text-red-400">{$developerKeywordsError}</p>
          {/if}

          {#if devKwSummary.length === 0}
            <p class="mt-2 text-xs text-zinc-500">Add an app to start tracking keywords.</p>
          {:else}
            <ul class="mt-2 space-y-1 text-xs">
              {#each devKwSummary as row}
                <li class="flex items-baseline justify-between text-zinc-700 dark:text-zinc-300">
                  <span class="truncate">{row.name}</span>
                  <span class="font-mono text-zinc-500">
                    {row.total} keywords / {row.storefronts} storefronts
                  </span>
                </li>
              {/each}
            </ul>
          {/if}

          {#if $developerKeywordsLastFetchedAt}
            <p class="mt-2 text-xs text-zinc-500">
              Last refreshed {timeAgo($developerKeywordsLastFetchedAt.toISOString())}.
            </p>
          {:else}
            <p class="mt-2 text-xs text-zinc-500">
              Click "Refresh now" to pull the latest keyword list from App Store Connect.
            </p>
          {/if}
        </div>
      {/if}
        </div>
      {/if}
    </section>

    <!-- ASA ─────────────────────────────────────────────────────────────── -->
    <section class="rounded-lg border border-zinc-200 dark:border-zinc-800 p-4">
      <button
        type="button"
        onclick={() => (asaExpanded = !asaExpanded)}
        aria-expanded={asaExpanded}
        aria-controls="asa-section-body"
        class="flex w-full items-center justify-between gap-2 text-left"
      >
        <span class="flex items-center gap-2">
          <svg
            class="h-3 w-3 text-zinc-500 transition-transform {asaExpanded ? 'rotate-90' : ''}"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2.5"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <polyline points="9 6 15 12 9 18" />
          </svg>
          <h3 class="text-sm font-semibold text-zinc-800 dark:text-zinc-200">Apple Search Ads API</h3>
        </span>
        {#if asaStatus?.configured}
          <span class="flex items-center gap-1 text-xs text-emerald-600 dark:text-emerald-400">
            <svg
              class="h-3.5 w-3.5"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="3"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <polyline points="5 12 10 17 19 8" />
            </svg>
            Connected
          </span>
        {:else}
          <span class="text-xs text-zinc-500">Not connected</span>
        {/if}
      </button>
      {#if asaExpanded}
        <div id="asa-section-body" class="mt-3" transition:slide={{ duration: 200 }}>
      <p class="mb-3 text-xs text-zinc-500">
        Used for keyword suggestions for any app. Create a Search Ads account at
        <code class="rounded bg-zinc-800 px-1 text-zinc-300">searchads.apple.com</code>. See Apple's
        <a
          href="https://developer.apple.com/documentation/apple_ads/implementing-oauth-for-the-apple-search-ads-api"
          target="_blank"
          rel="noopener noreferrer"
          class="text-amber-400 hover:underline"
        >
          OAuth setup guide&nbsp;↗
        </a>
        for the Client ID / Client Secret details.
      </p>

      <form onsubmit={saveASA} class="space-y-3">
        <label class="block space-y-1">
          <span class="text-xs uppercase tracking-wide text-zinc-500">Client ID</span>
          <input
            type="text"
            placeholder="SEARCHADS.00000000-0000-0000-0000-000000000000"
            bind:value={asaClientId}
            class="w-full rounded-md border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-950 px-3 py-2 font-mono text-sm text-zinc-900 dark:text-zinc-100 focus:border-zinc-400 dark:focus:border-zinc-600 focus:outline-none"
          />
        </label>

        <div class="space-y-1">
          <div class="flex items-baseline justify-between">
            <span class="text-xs uppercase tracking-wide text-zinc-500">Client Secret</span>
            {#if asaStatus?.hasClientSecret && !asaReplacingSecret}
              <button
                type="button"
                onclick={() => (asaReplacingSecret = true)}
                class="text-xs text-amber-600 dark:text-amber-400 hover:underline"
              >
                Replace
              </button>
            {/if}
          </div>
          {#if asaStatus?.hasClientSecret && !asaReplacingSecret}
            <div class="rounded-md border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900 px-3 py-2 font-mono text-xs text-zinc-500">
              •••• stored
            </div>
          {:else}
            <input
              type="password"
              autocomplete="off"
              placeholder="Paste the client secret"
              bind:value={asaClientSecret}
              class="w-full rounded-md border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-950 px-3 py-2 font-mono text-sm text-zinc-900 dark:text-zinc-100 focus:border-zinc-400 dark:focus:border-zinc-600 focus:outline-none"
            />
          {/if}
        </div>

        <label class="block space-y-1">
          <span class="text-xs uppercase tracking-wide text-zinc-500">Org ID (optional)</span>
          <input
            type="text"
            placeholder="12345"
            bind:value={asaOrgId}
            class="w-full rounded-md border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-950 px-3 py-2 font-mono text-sm text-zinc-900 dark:text-zinc-100 focus:border-zinc-400 dark:focus:border-zinc-600 focus:outline-none"
          />
        </label>

        {#if asaError}<p class="text-sm text-red-600 dark:text-red-400">{asaError}</p>{/if}
        {#if asaMessage}<p class="text-sm text-emerald-600 dark:text-emerald-400">{asaMessage}</p>{/if}

        <div class="flex items-center gap-2">
          <button
            type="submit"
            disabled={asaBusy}
            class="rounded-md bg-zinc-900 dark:bg-zinc-100 px-3 py-1.5 text-sm font-medium text-zinc-50 dark:text-zinc-950 hover:bg-black dark:hover:bg-white disabled:opacity-50"
          >
            {asaBusy ? 'Saving…' : 'Save'}
          </button>
          {#if asaStatus?.configured}
            <button
              type="button"
              onclick={clearASA}
              disabled={asaBusy}
              class="text-xs text-zinc-500 hover:text-red-700 dark:hover:text-red-300"
            >
              Disconnect
            </button>
          {/if}
        </div>
      </form>
        </div>
      {/if}
    </section>
  </div>
</aside>
