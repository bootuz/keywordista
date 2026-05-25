<script lang="ts">
  // /#/invite/:token — set password + claim an invite.
  //
  // Two-phase UX:
  //   1. Pre-validate the token via GET /auth/invite/:token (M2.0)
  //      so we can show "Invalid link" / "Expired" / "Already
  //      accepted" up front, BEFORE the user types a password.
  //   2. On success, render a set-password form; submit calls
  //      POST /auth/accept-invite which consumes the invite + creates
  //      the user + sets the session cookie.
  //
  // For "open" invites (no pre-pinned email) we also collect an email
  // in the form. For "pinned" invites the email is locked + displayed
  // read-only so the recipient sees what they're signing up as.

  import { onMount } from 'svelte';
  import { push } from 'svelte-spa-router';
  import { acceptInvite, validateInvite } from '../lib/auth';
  import { hydrateAuthState } from '../lib/authStore';
  import { ApiError } from '../lib/api';
  import { ROUTES } from '../lib/router';
  import type { InviteSummary } from '../lib/types';

  // svelte-spa-router injects `params` for routes with `:token`.
  let { params }: { params?: { token?: string } } = $props();

  const MIN_PASSWORD_LENGTH = 8;

  // ── Phase 1: pre-validation ────────────────────────────────────
  let loading = $state(true);
  let invite = $state<InviteSummary | null>(null);
  // Why a separate validation-failure state rather than reusing the
  // submit error: the page wants to show ONLY the error banner if
  // the token is bad — no password form at all. Two states is
  // cleaner than one with a "hide-the-form-if-this-is-set" toggle.
  let validationError = $state<{ title: string; detail: string } | null>(null);

  onMount(async () => {
    const token = params?.token;
    if (!token) {
      validationError = {
        title: 'Invalid invite link',
        detail: 'No token in the URL. Ask your admin for a fresh link.',
      };
      loading = false;
      return;
    }
    try {
      invite = await validateInvite(token);
      // Pre-fill email if the invite is pinned. The input renders
      // as read-only in that case so the recipient sees but can't
      // edit the address.
      if (invite.email) email = invite.email;
    } catch (e) {
      validationError = mapValidationError(e);
    } finally {
      loading = false;
    }
  });

  // Maps a validateInvite() rejection to a banner-shaped error.
  // Status-code semantics match the backend's deliberate choices
  // — see AuthController.validateInvite.
  function mapValidationError(e: unknown): { title: string; detail: string } {
    if (e instanceof ApiError) {
      switch (e.status) {
        case 404:
          return {
            title: 'Invite not found',
            detail: 'This link is either wrong or has been deleted. Ask your admin for a new one.',
          };
        case 410:
          return {
            title: 'Already accepted',
            detail: 'This invite has been used. If you already have an account, sign in instead.',
          };
        case 422:
          return {
            title: 'Invite expired',
            detail: 'Invite links expire for security. Ask your admin to send you a fresh one.',
          };
        case 400:
          return {
            title: 'Invalid invite link',
            detail: 'The link looks malformed. Make sure you copied the whole URL.',
          };
      }
    }
    return {
      title: "Couldn't load this invite",
      detail: 'Network or server error. Refresh the page to try again.',
    };
  }

  // ── Phase 2: set-password form ─────────────────────────────────
  let email = $state('');
  let password = $state('');
  let confirmPassword = $state('');
  let busy = $state(false);
  let submitError = $state<string | null>(null);

  const passwordsMatch = $derived(
    confirmPassword.length === 0 || password === confirmPassword,
  );
  const passwordLongEnough = $derived(
    password.length >= MIN_PASSWORD_LENGTH,
  );
  // Email is required if the invite was open (no pinned address).
  // For pinned invites the field is read-only and always satisfied.
  const emailValid = $derived(email.trim().length > 0);
  const canSubmit = $derived(
    emailValid
    && passwordLongEnough
    && passwordsMatch
    && confirmPassword.length > 0,
  );

  async function handleSubmit(event: SubmitEvent) {
    event.preventDefault();
    if (!invite || busy || !canSubmit) return;
    const token = params?.token;
    if (!token) return;

    busy = true;
    submitError = null;

    try {
      // For pinned invites we still send the email — the server
      // validates it matches the pin and 422s on mismatch (which
      // can't happen here because we pre-filled it, but the
      // contract works either way).
      await acceptInvite(token, password, email.trim());
      await hydrateAuthState();
      push(ROUTES.dashboard);
    } catch (e) {
      if (e instanceof ApiError) {
        // The submit-time error codes overlap with the validation
        // codes (the token could be consumed between phase 1 and
        // phase 2 if the admin races us). Re-render the validation
        // banner in those cases so the user gets the explanatory
        // text rather than a tiny inline error.
        if (e.status === 404 || e.status === 410 || e.status === 422) {
          validationError = mapValidationError(e);
          invite = null; // hide the form
          return;
        }
        if (e.status === 409) {
          submitError = 'An account with that email already exists. Try signing in instead.';
        } else if (e.status === 400) {
          submitError = e.body || 'Please check your input and try again.';
        } else {
          submitError = 'Something went wrong. Please try again.';
        }
      } else {
        submitError = 'Network error. Try again.';
      }
    } finally {
      busy = false;
    }
  }
</script>

<div class="flex items-center justify-center min-h-screen bg-gray-50 dark:bg-gray-900 px-4">
  <div class="w-full max-w-sm bg-white dark:bg-gray-800 rounded-lg shadow-sm p-8 space-y-6">

    {#if loading}
      <div class="text-center py-8 text-gray-500 dark:text-gray-400">
        Loading invite…
      </div>

    {:else if validationError}
      <div class="space-y-3 text-center">
        <h1 class="text-xl font-semibold text-gray-900 dark:text-gray-100">
          {validationError.title}
        </h1>
        <p class="text-sm text-gray-500 dark:text-gray-400">
          {validationError.detail}
        </p>
        <a href="#/login" class="inline-block mt-2 text-sm text-blue-600 hover:underline">
          Go to sign in
        </a>
      </div>

    {:else if invite}
      <form onsubmit={handleSubmit} class="space-y-6">
        <div class="text-center space-y-2">
          <h1 class="text-2xl font-semibold text-gray-900 dark:text-gray-100">
            Join Keywordista
          </h1>
          <p class="text-sm text-gray-500 dark:text-gray-400">
            You're being invited as <span class="font-medium">{invite.role}</span>.
            Set a password to finish creating your account.
          </p>
        </div>

        {#if submitError}
          <div
            role="alert"
            class="text-sm rounded-md px-3 py-2 bg-red-50 dark:bg-red-900/30 text-red-700 dark:text-red-300 border border-red-200 dark:border-red-800"
          >
            {submitError}
          </div>
        {/if}

        <div class="space-y-4">
          <label class="block">
            <span class="text-sm font-medium text-gray-700 dark:text-gray-300">Email</span>
            <input
              type="email"
              autocomplete="email"
              required
              readonly={invite.email !== null}
              bind:value={email}
              disabled={busy}
              class="mt-1 block w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-2 text-sm shadow-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500 disabled:opacity-60 read-only:bg-gray-50 read-only:dark:bg-gray-700 read-only:text-gray-600 read-only:dark:text-gray-300"
            />
            {#if invite.email !== null}
              <span class="block mt-1 text-xs text-gray-500">
                Locked — this invite was sent specifically to you.
              </span>
            {/if}
          </label>

          <label class="block">
            <span class="text-sm font-medium text-gray-700 dark:text-gray-300">Password</span>
            <input
              type="password"
              autocomplete="new-password"
              required
              minlength={MIN_PASSWORD_LENGTH}
              bind:value={password}
              disabled={busy}
              class="mt-1 block w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-2 text-sm shadow-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500 disabled:opacity-60"
            />
            <span
              class="block mt-1 text-xs"
              class:text-gray-500={password.length === 0}
              class:text-amber-600={password.length > 0 && !passwordLongEnough}
              class:text-emerald-600={passwordLongEnough}
            >
              {#if password.length === 0}
                At least {MIN_PASSWORD_LENGTH} characters.
              {:else if !passwordLongEnough}
                {MIN_PASSWORD_LENGTH - password.length} more
                {MIN_PASSWORD_LENGTH - password.length === 1 ? 'character' : 'characters'} needed.
              {:else}
                ✓ Long enough.
              {/if}
            </span>
          </label>

          <label class="block">
            <span class="text-sm font-medium text-gray-700 dark:text-gray-300">Confirm password</span>
            <input
              type="password"
              autocomplete="new-password"
              required
              bind:value={confirmPassword}
              disabled={busy}
              class="mt-1 block w-full rounded-md border bg-white dark:bg-gray-900 px-3 py-2 text-sm shadow-sm focus:ring-1 disabled:opacity-60"
              class:border-gray-300={passwordsMatch}
              class:dark:border-gray-600={passwordsMatch}
              class:focus:border-blue-500={passwordsMatch}
              class:focus:ring-blue-500={passwordsMatch}
              class:border-red-400={!passwordsMatch}
              class:focus:border-red-500={!passwordsMatch}
              class:focus:ring-red-500={!passwordsMatch}
            />
            {#if !passwordsMatch}
              <span class="block mt-1 text-xs text-red-600 dark:text-red-400">
                Passwords don't match.
              </span>
            {/if}
          </label>
        </div>

        <button
          type="submit"
          disabled={!canSubmit || busy}
          class="w-full flex justify-center items-center rounded-md bg-blue-600 hover:bg-blue-700 disabled:bg-blue-400 disabled:cursor-not-allowed text-white text-sm font-medium px-4 py-2 transition-colors"
        >
          {busy ? 'Creating account…' : 'Create account'}
        </button>
      </form>
    {/if}
  </div>
</div>
