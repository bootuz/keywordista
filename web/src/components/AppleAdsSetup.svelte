<script lang="ts">
  // Connecting Apple Ads, picking the ad account, and the sync's state.
  // The form is admin-only in server mode; members see the status only.
  import { onMount } from 'svelte';
  import {
    getASASettings,
    putASASettings,
    deleteASASettings,
    getASAAccounts,
    errorMessage,
  } from '../lib/api';
  import type { ASAStatus, ASAAdAccount, AppleAdsSyncStatus } from '../lib/types';
  import { isAdmin, serverMode } from '../lib/authStore';
  import { timeAgo } from '../lib/time';

  let {
    status,
    onSyncNow,
    onChanged,
  }: { status: AppleAdsSyncStatus | null; onSyncNow: () => void; onChanged: () => void } = $props();

  const canMutateSettings = $derived(!$serverMode || $isAdmin);

  let asaStatus = $state<ASAStatus | null>(null);
  let asaClientId = $state('');
  let asaClientSecret = $state('');
  // Legacy v5 org ID: kept so a pre-v1 setup still resolves its ad account.
  let asaOrgId = $state('');
  let asaAdAccountId = $state('');
  let asaAccounts = $state<ASAAdAccount[] | null>(null);
  let asaAccountsLoading = $state(false);
  let asaAccountsError = $state<string | null>(null);
  let asaReplacingSecret = $state(false);
  let asaBusy = $state(false);
  let asaError = $state<string | null>(null);
  let asaMessage = $state<string | null>(null);

  onMount(() => {
    if (canMutateSettings) void loadASA();
  });

  async function loadASA() {
    try {
      asaStatus = await getASASettings();
      asaClientId = asaStatus.clientId ?? '';
      asaOrgId = asaStatus.orgId ?? '';
      asaAdAccountId = asaStatus.adAccountId ?? '';
      if (asaStatus.configured) void loadASAAccounts();
    } catch (e) {
      asaError = errorMessage(e);
    }
  }

  async function loadASAAccounts() {
    asaAccountsLoading = true;
    asaAccountsError = null;
    try {
      asaAccounts = await getASAAccounts();
    } catch (err) {
      asaAccounts = null;
      asaAccountsError = errorMessage(err);
    } finally {
      asaAccountsLoading = false;
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
        // Only send a choice the user could see, and only for the same API
        // user: a new client ID's accounts haven't been listed yet, and the
        // server drops the old choice when the client ID changes.
        ...(asaAccounts && asaClientId.trim() === (asaStatus?.clientId ?? '') ? { adAccountId: asaAdAccountId } : {}),
      });
      asaClientSecret = '';
      asaReplacingSecret = false;
      asaMessage = 'Saved.';
      void loadASAAccounts();
      onChanged();
    } catch (err) {
      asaError = errorMessage(err);
    } finally {
      asaBusy = false;
    }
  }

  async function clearASA() {
    if (!confirm('Disconnect Apple Ads? This also deletes the synced Apple Ads data.')) return;
    asaBusy = true;
    asaError = null;
    try {
      await deleteASASettings();
      asaStatus = await getASASettings();
      asaClientId = '';
      asaClientSecret = '';
      asaOrgId = '';
      asaAdAccountId = '';
      asaAccounts = null;
      asaAccountsError = null;
      asaMessage = 'Disconnected.';
      onChanged();
    } catch (err) {
      asaError = errorMessage(err);
    } finally {
      asaBusy = false;
    }
  }

  const run = $derived(status?.lastRun ?? null);
</script>

<div class="grid gap-5 lg:grid-cols-[minmax(0,1fr)_minmax(0,22rem)]">
  <section class="rounded-lg border border-zinc-200 dark:border-zinc-800 p-4">
    <div class="mb-3 flex items-center justify-between gap-2">
      <h2 class="text-sm font-semibold text-zinc-800 dark:text-zinc-200">Apple Ads API</h2>
      {#if asaStatus?.configured}
        <span class="text-xs text-emerald-600 dark:text-emerald-400">Connected</span>
      {:else if asaStatus}
        <span class="text-xs text-zinc-500">Not connected</span>
      {/if}
    </div>
    {#if canMutateSettings}
      <p class="mb-3 text-xs text-zinc-500">
        Keywordista reads your campaigns, keywords and search terms once a day (and when you press
        Sync now). In
        <code class="rounded bg-zinc-800 px-1 text-zinc-300">ads.apple.com</code>, create an API user
        and its client credentials; Apple's
        <a
          href="https://developer.apple.com/documentation/apple-ads-platform-api/implementing-oauth-for-the-apple-ads-platform-api"
          target="_blank"
          rel="noopener noreferrer"
          class="text-amber-400 hover:underline"
        >
          OAuth guide&nbsp;↗
        </a>
        explains the Client ID and Client Secret.
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

        {#if asaStatus?.configured}
          <label class="block space-y-1">
            <span class="text-xs uppercase tracking-wide text-zinc-500">Ad account</span>
            {#if asaAccounts}
              <select
                bind:value={asaAdAccountId}
                class="w-full rounded-md border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-950 px-3 py-2 text-sm text-zinc-900 dark:text-zinc-100 focus:border-zinc-400 dark:focus:border-zinc-600 focus:outline-none"
              >
                <option value="">Automatic{asaAccounts.length === 1 ? ` (${asaAccounts[0].name})` : ''}</option>
                {#each asaAccounts as account (account.id)}
                  <option value={account.id}>{account.name || account.id} · {account.id}</option>
                {/each}
              </select>
              {#if asaAccounts.length > 1 && !asaAdAccountId}
                <p class="text-xs text-amber-600 dark:text-amber-400">
                  These credentials reach {asaAccounts.length} ad accounts. Pick the one that runs your app's campaigns.
                </p>
              {/if}
            {:else if asaAccountsLoading}
              <p class="text-xs text-zinc-500">Loading ad accounts…</p>
            {:else if asaAccountsError}
              <p class="text-xs text-red-600 dark:text-red-400">{asaAccountsError}</p>
            {/if}
          </label>
        {/if}

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
    {:else}
      <p class="text-sm text-zinc-500">Only an admin can change the Apple Ads connection.</p>
    {/if}
  </section>

  <section class="rounded-lg border border-zinc-200 dark:border-zinc-800 p-4 space-y-3 self-start">
    <h2 class="text-sm font-semibold text-zinc-800 dark:text-zinc-200">Sync</h2>
    <p class="text-xs text-zinc-500">
      Runs daily at 04:30 UTC. The first sync copies 90 days; later ones refresh the last 7, since Apple revises
      recent days.
    </p>
    <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
      <dt class="text-zinc-500">Last good sync</dt>
      <dd class="text-zinc-800 dark:text-zinc-200">{status?.lastSuccessAt ? timeAgo(status.lastSuccessAt) : 'Never'}</dd>
      {#if run}
        <dt class="text-zinc-500">Last run</dt>
        <dd class="text-zinc-800 dark:text-zinc-200">
          {run.outcome === 'running' ? 'Running' : run.outcome === 'failed' ? 'Failed' : 'Succeeded'},
          {timeAgo(run.finishedAt ?? run.startedAt).toLowerCase()} ({run.trigger})
        </dd>
      {/if}
    </dl>
    {#if run?.outcome === 'failed' && run.error}
      <p class="rounded-md border border-red-200 dark:border-red-900 bg-red-50 dark:bg-red-900/20 p-2 text-sm text-red-700 dark:text-red-300">
        {run.error}
      </p>
    {/if}
    <button
      type="button"
      onclick={onSyncNow}
      disabled={status?.running}
      class="rounded-md border border-zinc-300 dark:border-zinc-700 px-3 py-1.5 text-sm text-zinc-700 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 disabled:opacity-50"
    >
      {status?.running ? 'Syncing…' : 'Sync now'}
    </button>
  </section>
</div>
