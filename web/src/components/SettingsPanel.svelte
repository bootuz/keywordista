<script lang="ts">
  import { onMount } from 'svelte';
  import {
    getASCSettings,
    putASCSettings,
    deleteASCSettings,
    getASASettings,
    putASASettings,
    deleteASASettings,
  } from '../lib/api';
  import type { ASCStatus, ASAStatus } from '../lib/types';

  interface Props {
    onClose: () => void;
  }
  let { onClose }: Props = $props();

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
    } catch (e) {
      ascError = e instanceof Error ? e.message : String(e);
    }
  }

  async function loadASA() {
    try {
      asaStatus = await getASASettings();
      asaClientId = asaStatus.clientId ?? '';
      asaOrgId = asaStatus.orgId ?? '';
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
  class="fixed inset-y-0 right-0 z-40 flex w-[600px] max-w-full flex-col border-l border-zinc-800 bg-zinc-950 shadow-2xl"
>
  <header class="flex items-baseline justify-between border-b border-zinc-800 px-6 py-4">
    <div>
      <h2 class="text-base font-semibold text-zinc-100">Settings</h2>
      <p class="text-sm text-zinc-500">API credentials for App Store Connect and Apple Search Ads</p>
    </div>
    <button onclick={onClose} class="text-sm text-zinc-500 hover:text-zinc-300">Close</button>
  </header>

  <div class="flex-1 space-y-8 overflow-auto px-6 py-6">
    <!-- ASC ─────────────────────────────────────────────────────────────── -->
    <section>
      <div class="mb-3 flex items-baseline justify-between">
        <h3 class="text-sm font-semibold text-zinc-200">App Store Connect API</h3>
        {#if ascStatus?.configured}
          <span class="text-xs text-emerald-400">Connected</span>
        {:else}
          <span class="text-xs text-zinc-500">Not connected</span>
        {/if}
      </div>
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
            class="w-full rounded-md border border-zinc-800 bg-zinc-950 px-3 py-2 font-mono text-sm text-zinc-100 focus:border-zinc-600 focus:outline-none"
          />
        </label>

        <label class="block space-y-1">
          <span class="text-xs uppercase tracking-wide text-zinc-500">Issuer ID</span>
          <input
            type="text"
            placeholder="00000000-0000-0000-0000-000000000000"
            bind:value={ascIssuerId}
            class="w-full rounded-md border border-zinc-800 bg-zinc-950 px-3 py-2 font-mono text-sm text-zinc-100 focus:border-zinc-600 focus:outline-none"
          />
        </label>

        <div class="space-y-1">
          <div class="flex items-baseline justify-between">
            <span class="text-xs uppercase tracking-wide text-zinc-500">Private key (.p8)</span>
            {#if ascStatus?.hasPrivateKey && !ascReplacing}
              <button
                type="button"
                onclick={() => (ascReplacing = true)}
                class="text-xs text-amber-400 hover:underline"
              >
                Replace
              </button>
            {/if}
          </div>
          {#if ascStatus?.hasPrivateKey && !ascReplacing}
            <div class="rounded-md border border-zinc-800 bg-zinc-900 px-3 py-2 font-mono text-xs text-zinc-500">
              •••• stored
            </div>
          {:else}
            <textarea
              rows="6"
              placeholder={'-----BEGIN PRIVATE KEY-----\n…paste the full .p8 contents…\n-----END PRIVATE KEY-----'}
              bind:value={ascPrivateKey}
              class="w-full rounded-md border border-zinc-800 bg-zinc-950 px-3 py-2 font-mono text-xs text-zinc-100 focus:border-zinc-600 focus:outline-none"
            ></textarea>
          {/if}
        </div>

        {#if ascError}<p class="text-sm text-red-400">{ascError}</p>{/if}
        {#if ascMessage}<p class="text-sm text-emerald-400">{ascMessage}</p>{/if}

        <div class="flex items-center gap-2">
          <button
            type="submit"
            disabled={ascBusy}
            class="rounded-md bg-zinc-100 px-3 py-1.5 text-sm font-medium text-zinc-950 hover:bg-white disabled:opacity-50"
          >
            {ascBusy ? 'Saving…' : 'Save'}
          </button>
          {#if ascStatus?.configured}
            <button
              type="button"
              onclick={clearASC}
              disabled={ascBusy}
              class="text-xs text-zinc-500 hover:text-red-300"
            >
              Disconnect
            </button>
          {/if}
        </div>
      </form>
    </section>

    <!-- ASA ─────────────────────────────────────────────────────────────── -->
    <section>
      <div class="mb-3 flex items-baseline justify-between">
        <h3 class="text-sm font-semibold text-zinc-200">Apple Search Ads API</h3>
        {#if asaStatus?.configured}
          <span class="text-xs text-emerald-400">Connected</span>
        {:else}
          <span class="text-xs text-zinc-500">Not connected</span>
        {/if}
      </div>
      <p class="mb-3 text-xs text-zinc-500">
        Used for keyword suggestions for any app. Create a Search Ads account at
        <code class="rounded bg-zinc-800 px-1 text-zinc-300">searchads.apple.com</code> (free, no
        budget required), then Settings → API → Create New Client.
      </p>

      <form onsubmit={saveASA} class="space-y-3">
        <label class="block space-y-1">
          <span class="text-xs uppercase tracking-wide text-zinc-500">Client ID</span>
          <input
            type="text"
            placeholder="SEARCHADS.00000000-0000-0000-0000-000000000000"
            bind:value={asaClientId}
            class="w-full rounded-md border border-zinc-800 bg-zinc-950 px-3 py-2 font-mono text-sm text-zinc-100 focus:border-zinc-600 focus:outline-none"
          />
        </label>

        <div class="space-y-1">
          <div class="flex items-baseline justify-between">
            <span class="text-xs uppercase tracking-wide text-zinc-500">Client Secret</span>
            {#if asaStatus?.hasClientSecret && !asaReplacingSecret}
              <button
                type="button"
                onclick={() => (asaReplacingSecret = true)}
                class="text-xs text-amber-400 hover:underline"
              >
                Replace
              </button>
            {/if}
          </div>
          {#if asaStatus?.hasClientSecret && !asaReplacingSecret}
            <div class="rounded-md border border-zinc-800 bg-zinc-900 px-3 py-2 font-mono text-xs text-zinc-500">
              •••• stored
            </div>
          {:else}
            <input
              type="password"
              autocomplete="off"
              placeholder="Paste the client secret"
              bind:value={asaClientSecret}
              class="w-full rounded-md border border-zinc-800 bg-zinc-950 px-3 py-2 font-mono text-sm text-zinc-100 focus:border-zinc-600 focus:outline-none"
            />
          {/if}
        </div>

        <label class="block space-y-1">
          <span class="text-xs uppercase tracking-wide text-zinc-500">Org ID (optional)</span>
          <input
            type="text"
            placeholder="12345"
            bind:value={asaOrgId}
            class="w-full rounded-md border border-zinc-800 bg-zinc-950 px-3 py-2 font-mono text-sm text-zinc-100 focus:border-zinc-600 focus:outline-none"
          />
        </label>

        {#if asaError}<p class="text-sm text-red-400">{asaError}</p>{/if}
        {#if asaMessage}<p class="text-sm text-emerald-400">{asaMessage}</p>{/if}

        <div class="flex items-center gap-2">
          <button
            type="submit"
            disabled={asaBusy}
            class="rounded-md bg-zinc-100 px-3 py-1.5 text-sm font-medium text-zinc-950 hover:bg-white disabled:opacity-50"
          >
            {asaBusy ? 'Saving…' : 'Save'}
          </button>
          {#if asaStatus?.configured}
            <button
              type="button"
              onclick={clearASA}
              disabled={asaBusy}
              class="text-xs text-zinc-500 hover:text-red-300"
            >
              Disconnect
            </button>
          {/if}
        </div>
      </form>
    </section>
  </div>
</aside>
