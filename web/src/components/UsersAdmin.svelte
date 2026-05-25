<script lang="ts">
  // /#/settings/users — admin-only team management.
  //
  // Backend (UsersController) returns 403 to non-admins on every
  // endpoint here, so client-side role gating is purely cosmetic.
  // M2.10's route guard will redirect members away before they
  // reach this page; this component still renders a graceful
  // "Access denied" panel if someone gets here anyway (e.g.
  // navigated manually with a stale role assumption).
  //
  // Self-protection safeguards (you can't revoke yourself, can't
  // demote the only admin) are enforced server-side and return 409
  // with explanatory reason strings. We surface those strings
  // directly rather than trying to second-guess them client-side
  // — the server is the source of truth for "what's allowed."

  import { onMount } from 'svelte';
  import { slide } from 'svelte/transition';
  import {
    listUsers,
    inviteUser,
    revokeUser,
    changeRole,
  } from '../lib/auth';
  import { currentUser, isAdmin } from '../lib/authStore';
  import { ApiError } from '../lib/api';
  import type { InviteCreated, UserListItem } from '../lib/types';
  import { timeAgo } from '../lib/time';

  // ── Data loading ──────────────────────────────────────────────
  let users = $state<UserListItem[]>([]);
  let loading = $state(true);
  let loadError = $state<string | null>(null);
  // Set of user IDs currently in-flight (revoke or role change) so
  // we can disable the row's buttons + show a busy hint without a
  // global "busy" gate that would block other rows.
  let pendingIds = $state<Set<string>>(new Set());

  onMount(() => { void refresh(); });

  async function refresh() {
    loading = true;
    loadError = null;
    try {
      users = await listUsers();
    } catch (e) {
      if (e instanceof ApiError && e.status === 403) {
        loadError = 'forbidden';
      } else {
        loadError = 'Could not load users. Refresh to try again.';
      }
    } finally {
      loading = false;
    }
  }

  // ── Invite-modal state ─────────────────────────────────────────
  // Three discrete phases — the response token must be shown only
  // ONCE so we never re-render it after the user dismisses.
  type InviteUI =
    | { phase: 'closed' }
    | { phase: 'form'; role: 'admin' | 'member'; email: string; busy: boolean; error: string | null }
    | { phase: 'created'; result: InviteCreated; copied: boolean };

  let inviteUI = $state<InviteUI>({ phase: 'closed' });

  function openInvite() {
    inviteUI = { phase: 'form', role: 'member', email: '', busy: false, error: null };
  }

  function closeInvite() {
    inviteUI = { phase: 'closed' };
  }

  async function submitInvite(event: SubmitEvent) {
    event.preventDefault();
    if (inviteUI.phase !== 'form' || inviteUI.busy) return;
    const { role, email } = inviteUI;
    inviteUI = { ...inviteUI, busy: true, error: null };
    try {
      const result = await inviteUser(role, email.trim() || undefined);
      inviteUI = { phase: 'created', result, copied: false };
    } catch (e) {
      const msg =
        e instanceof ApiError && e.body ? e.body :
        'Could not create the invite. Try again.';
      inviteUI = { phase: 'form', role, email, busy: false, error: msg };
    }
  }

  async function copyAcceptUrl() {
    if (inviteUI.phase !== 'created') return;
    try {
      await navigator.clipboard.writeText(inviteUI.result.acceptUrl);
      inviteUI = { ...inviteUI, copied: true };
      setTimeout(() => {
        if (inviteUI.phase === 'created') inviteUI = { ...inviteUI, copied: false };
      }, 1500);
    } catch {
      // Clipboard API can fail in non-secure contexts (HTTP). The
      // URL is still visible in the input below for manual copy.
    }
  }

  // ── Row actions ────────────────────────────────────────────────
  async function handleRevoke(user: UserListItem) {
    // Belt-and-suspenders client check matching the server's 409.
    // The server is the boundary; this just saves a round-trip
    // for the obvious-no case.
    if (user.id === $currentUser?.id) return;
    if (!confirm(`Remove ${user.email}? This cannot be undone.`)) return;

    pendingIds.add(user.id);
    pendingIds = new Set(pendingIds);
    try {
      await revokeUser(user.id);
      users = users.filter((u) => u.id !== user.id);
    } catch (e) {
      const msg =
        e instanceof ApiError && e.status === 409 && e.body ? e.body :
        'Could not remove this user. Try again.';
      alert(msg);
    } finally {
      pendingIds.delete(user.id);
      pendingIds = new Set(pendingIds);
    }
  }

  async function handleRoleToggle(user: UserListItem) {
    if (user.id === $currentUser?.id) return;
    const nextRole: 'admin' | 'member' = user.role === 'admin' ? 'member' : 'admin';

    pendingIds.add(user.id);
    pendingIds = new Set(pendingIds);
    try {
      const updated = await changeRole(user.id, nextRole);
      users = users.map((u) => u.id === user.id ? updated : u);
    } catch (e) {
      const msg =
        e instanceof ApiError && e.status === 409 && e.body ? e.body :
        'Could not change this role. Try again.';
      alert(msg);
    } finally {
      pendingIds.delete(user.id);
      pendingIds = new Set(pendingIds);
    }
  }

  function formatLogin(iso: string | null): string {
    if (!iso) return 'Never';
    return timeAgo(iso);
  }
</script>

<!-- Escape closes the invite modal regardless of phase. svelte:window
     must live at the top level (can't be nested inside {#if}). -->
<svelte:window onkeydown={(e) => { if (e.key === 'Escape' && inviteUI.phase !== 'closed') closeInvite(); }} />

<!-- ── Access-denied short-circuit ────────────────────────────── -->
{#if loadError === 'forbidden' || (!$isAdmin && !loading)}
  <div class="flex items-center justify-center min-h-[60vh] p-6">
    <div class="max-w-md text-center space-y-2">
      <h1 class="text-xl font-semibold text-gray-900 dark:text-gray-100">Access denied</h1>
      <p class="text-sm text-gray-500 dark:text-gray-400">
        Only admins can manage team members.
      </p>
    </div>
  </div>

{:else}
  <div class="max-w-4xl mx-auto p-6 space-y-6">
    <header class="flex items-center justify-between gap-4">
      <div>
        <h1 class="text-2xl font-semibold text-gray-900 dark:text-gray-100">Team members</h1>
        <p class="text-sm text-gray-500 dark:text-gray-400 mt-1">
          {users.length} {users.length === 1 ? 'member' : 'members'} in this deployment.
        </p>
      </div>
      <button
        type="button"
        onclick={openInvite}
        class="rounded-md bg-blue-600 hover:bg-blue-700 text-white text-sm font-medium px-4 py-2 transition-colors"
      >
        + Invite member
      </button>
    </header>

    {#if loading}
      <div class="text-center py-12 text-gray-500 dark:text-gray-400">Loading…</div>
    {:else if loadError}
      <div role="alert" class="text-sm rounded-md px-3 py-2 bg-red-50 dark:bg-red-900/30 text-red-700 dark:text-red-300 border border-red-200 dark:border-red-800">
        {loadError}
      </div>
    {:else}
      <div class="rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 overflow-hidden">
        <table class="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
          <thead class="bg-gray-50 dark:bg-gray-900/40">
            <tr>
              <th class="px-4 py-2 text-left font-medium text-gray-600 dark:text-gray-300">Email</th>
              <th class="px-4 py-2 text-left font-medium text-gray-600 dark:text-gray-300">Role</th>
              <th class="px-4 py-2 text-left font-medium text-gray-600 dark:text-gray-300 hidden sm:table-cell">Last login</th>
              <th class="px-4 py-2 text-right font-medium text-gray-600 dark:text-gray-300">Actions</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-100 dark:divide-gray-700">
            {#each users as user (user.id)}
              {@const isMe = user.id === $currentUser?.id}
              {@const isPending = pendingIds.has(user.id)}
              <tr class="hover:bg-gray-50 dark:hover:bg-gray-900/30">
                <td class="px-4 py-3 text-gray-900 dark:text-gray-100">
                  {user.email}
                  {#if isMe}
                    <span class="ml-2 text-xs text-gray-500 dark:text-gray-400">(you)</span>
                  {/if}
                </td>
                <td class="px-4 py-3">
                  <!-- Svelte's `class:` directive can't host Tailwind's
                       `dark:` variants because of the colon conflict;
                       use a conditional class string instead. -->
                  <span
                    class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium {user.role === 'admin' ? 'bg-amber-100 dark:bg-amber-900/40 text-amber-800 dark:text-amber-300' : 'bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300'}"
                  >
                    {user.role}
                  </span>
                </td>
                <td class="px-4 py-3 text-gray-500 dark:text-gray-400 hidden sm:table-cell">
                  {formatLogin(user.lastLoginAt)}
                </td>
                <td class="px-4 py-3 text-right space-x-2 whitespace-nowrap">
                  <button
                    type="button"
                    onclick={() => handleRoleToggle(user)}
                    disabled={isMe || isPending}
                    title={isMe ? "You can't change your own role" : ''}
                    class="text-xs px-2 py-1 rounded border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-700 disabled:opacity-50 disabled:cursor-not-allowed"
                  >
                    Make {user.role === 'admin' ? 'member' : 'admin'}
                  </button>
                  <button
                    type="button"
                    onclick={() => handleRevoke(user)}
                    disabled={isMe || isPending}
                    title={isMe ? "You can't remove yourself" : ''}
                    class="text-xs px-2 py-1 rounded border border-red-300 dark:border-red-700 text-red-700 dark:text-red-300 hover:bg-red-50 dark:hover:bg-red-900/30 disabled:opacity-50 disabled:cursor-not-allowed"
                  >
                    Remove
                  </button>
                </td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {/if}
  </div>

  <!-- ── Invite modal ────────────────────────────────────────── -->
  {#if inviteUI.phase !== 'closed'}
    <div class="fixed inset-0 z-50 flex items-center justify-center">
      <button
        type="button"
        aria-label="Close"
        onclick={closeInvite}
        class="absolute inset-0 bg-black/60 backdrop-blur-sm"
      ></button>

      <div
        role="dialog"
        aria-modal="true"
        class="relative w-full max-w-md mx-4 bg-white dark:bg-gray-800 rounded-lg shadow-xl p-6 space-y-5"
      >
        {#if inviteUI.phase === 'form'}
          <h2 class="text-lg font-semibold text-gray-900 dark:text-gray-100">Invite a teammate</h2>

          {#if inviteUI.error}
            <div role="alert" class="text-sm rounded-md px-3 py-2 bg-red-50 dark:bg-red-900/30 text-red-700 dark:text-red-300 border border-red-200 dark:border-red-800">
              {inviteUI.error}
            </div>
          {/if}

          <form onsubmit={submitInvite} class="space-y-4">
            <label class="block">
              <span class="text-sm font-medium text-gray-700 dark:text-gray-300">Role</span>
              <select
                bind:value={inviteUI.role}
                disabled={inviteUI.busy}
                class="mt-1 block w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-2 text-sm shadow-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500 disabled:opacity-60"
              >
                <option value="member">Member — can view + edit dashboard, apps, keywords</option>
                <option value="admin">Admin — also manages settings + team</option>
              </select>
            </label>

            <label class="block">
              <span class="text-sm font-medium text-gray-700 dark:text-gray-300">
                Email <span class="text-gray-400 font-normal">(optional)</span>
              </span>
              <input
                type="email"
                bind:value={inviteUI.email}
                disabled={inviteUI.busy}
                placeholder="teammate@example.com"
                class="mt-1 block w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-2 text-sm shadow-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500 disabled:opacity-60"
              />
              <span class="block mt-1 text-xs text-gray-500 dark:text-gray-400">
                If set, the invite is locked to this address. Leave empty for an open invite that anyone with the link can claim.
              </span>
            </label>

            <div class="flex justify-end gap-2 pt-2">
              <button
                type="button"
                onclick={closeInvite}
                disabled={inviteUI.busy}
                class="px-3 py-1.5 text-sm rounded-md border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-700 disabled:opacity-60"
              >
                Cancel
              </button>
              <button
                type="submit"
                disabled={inviteUI.busy}
                class="px-3 py-1.5 text-sm rounded-md bg-blue-600 hover:bg-blue-700 disabled:bg-blue-400 text-white font-medium"
              >
                {inviteUI.busy ? 'Creating…' : 'Create invite'}
              </button>
            </div>
          </form>

        {:else if inviteUI.phase === 'created'}
          <h2 class="text-lg font-semibold text-gray-900 dark:text-gray-100">Invite ready</h2>

          <div
            role="alert"
            transition:slide={{ duration: 150 }}
            class="text-sm rounded-md px-3 py-2 bg-amber-50 dark:bg-amber-900/30 text-amber-800 dark:text-amber-200 border border-amber-200 dark:border-amber-800"
          >
            <strong>Save this link now.</strong> It won't be shown again.
            {#if inviteUI.result.email}
              Locked to <span class="font-mono">{inviteUI.result.email}</span>.
            {/if}
          </div>

          <div class="space-y-2">
            <input
              type="text"
              readonly
              value={inviteUI.result.acceptUrl}
              onclick={(e) => (e.currentTarget as HTMLInputElement).select()}
              class="block w-full rounded-md border border-gray-300 dark:border-gray-600 bg-gray-50 dark:bg-gray-900 px-3 py-2 text-xs font-mono shadow-sm select-all"
            />
            <div class="flex justify-end gap-2 pt-2">
              <button
                type="button"
                onclick={copyAcceptUrl}
                class="px-3 py-1.5 text-sm rounded-md border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-700"
              >
                {inviteUI.copied ? '✓ Copied' : 'Copy link'}
              </button>
              <button
                type="button"
                onclick={openInvite}
                class="px-3 py-1.5 text-sm rounded-md border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-700"
              >
                Invite another
              </button>
              <button
                type="button"
                onclick={() => { closeInvite(); void refresh(); }}
                class="px-3 py-1.5 text-sm rounded-md bg-blue-600 hover:bg-blue-700 text-white font-medium"
              >
                Done
              </button>
            </div>
          </div>
        {/if}
      </div>
    </div>
  {/if}
{/if}
