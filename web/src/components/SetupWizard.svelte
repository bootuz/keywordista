<script lang="ts">
  // /#/setup — first-run admin creation.
  //
  // Reachable only when /auth/state returns firstRun=true (no users
  // exist yet). M2.10's route guard pushes the user here automatically;
  // if someone navigates here manually after setup is done they'll get
  // a 410 from the server and be bounced to /login.
  //
  // The created user is hardcoded to role=admin on the backend
  // (AuthController.setup), so this page doesn't ask about roles.

  import { push } from 'svelte-spa-router';
  import { setupAdmin } from '../lib/auth';
  import { authState, hydrateAuthState } from '../lib/authStore';
  import { ApiError } from '../lib/api';
  import { ROUTES } from '../lib/router';

  // Mirror AuthInputs.passwordMinLength on the backend. Hardcoded
  // duplicate is acceptable here — the server is the real boundary
  // and submission would 400 if we got this wrong.
  const MIN_PASSWORD_LENGTH = 8;

  let email = $state('');
  let password = $state('');
  let confirmPassword = $state('');
  // M3.21: when KEYWORDISTA_SETUP_TOKEN is configured server-side,
  // the SPA learns it via authState.setupTokenRequired and must
  // collect + send the value in X-Keywordista-Setup-Token. The
  // operator copies it from their docker run env or password manager.
  let setupToken = $state('');
  let busy = $state(false);
  let error = $state<string | null>(null);

  const tokenRequired = $derived($authState?.setupTokenRequired ?? false);

  // Live mismatch indicator without nagging — only fires once the
  // user has actually started typing the confirmation.
  const passwordsMatch = $derived(
    confirmPassword.length === 0 || password === confirmPassword,
  );
  const passwordLongEnough = $derived(
    password.length >= MIN_PASSWORD_LENGTH,
  );
  const canSubmit = $derived(
    email.trim().length > 0
    && passwordLongEnough
    && passwordsMatch
    && password === confirmPassword
    && confirmPassword.length > 0
    // M3.21: if the deploy was booted with a setup token, the
    // operator must provide it before we can even attempt the
    // request. Server min-length is 16; we mirror that to give
    // immediate feedback instead of a round-trip.
    && (!tokenRequired || setupToken.trim().length >= 16),
  );

  async function handleSubmit(event: SubmitEvent) {
    event.preventDefault();
    if (busy || !canSubmit) return;
    busy = true;
    error = null;

    try {
      await setupAdmin(
        email.trim(),
        password,
        tokenRequired ? setupToken.trim() : undefined,
      );
      await hydrateAuthState();
      push(ROUTES.dashboard);
    } catch (e) {
      if (e instanceof ApiError && e.status === 410) {
        // Setup race: someone else completed first-run between this
        // page mounting and the submit. Bounce to /login so they can
        // sign in with whatever credentials the OTHER person created.
        push(ROUTES.login);
        return;
      }
      // M3.21: 401 means setup token wrong or missing — the only
      // production /setup endpoint shape that 401s. Show a specific
      // message rather than the generic catch-all.
      if (e instanceof ApiError && e.status === 401) {
        error = 'Setup token is missing or incorrect. Copy the value of '
              + 'KEYWORDISTA_SETUP_TOKEN from your container environment.';
      } else if (e instanceof ApiError && e.status === 400) {
        error = e.body || 'Please check your input and try again.';
      } else {
        error = 'Something went wrong. Please try again.';
      }
    } finally {
      busy = false;
    }
  }
</script>

<div class="flex items-center justify-center min-h-screen bg-gray-50 dark:bg-gray-900 px-4">
  <form
    onsubmit={handleSubmit}
    class="w-full max-w-sm bg-white dark:bg-gray-800 rounded-lg shadow-sm p-8 space-y-6"
  >
    <div class="text-center space-y-2">
      <h1 class="text-2xl font-semibold text-gray-900 dark:text-gray-100">
        Welcome to Keywordista
      </h1>
      <p class="text-sm text-gray-500 dark:text-gray-400">
        Create the first admin account for this deployment. You can
        invite teammates afterwards.
      </p>
    </div>

    {#if error}
      <div
        role="alert"
        class="text-sm rounded-md px-3 py-2 bg-red-50 dark:bg-red-900/30 text-red-700 dark:text-red-300 border border-red-200 dark:border-red-800"
      >
        {error}
      </div>
    {/if}

    <div class="space-y-4">
      {#if tokenRequired}
        <!-- M3.21: only rendered when the server-side env var is set.
             The notice + autocomplete=off is intentional: this is an
             out-of-band shared secret, not a remembered credential. -->
        <label class="block">
          <span class="text-sm font-medium text-gray-700 dark:text-gray-300">
            Setup token
          </span>
          <input
            type="password"
            autocomplete="off"
            required
            minlength={16}
            placeholder="From KEYWORDISTA_SETUP_TOKEN"
            bind:value={setupToken}
            disabled={busy}
            class="mt-1 block w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-2 text-sm shadow-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500 disabled:opacity-60"
          />
          <span class="block mt-1 text-xs text-gray-500 dark:text-gray-400">
            This deploy requires a one-time token to claim the admin
            account. Copy it from the container's environment.
          </span>
        </label>
      {/if}

      <label class="block">
        <span class="text-sm font-medium text-gray-700 dark:text-gray-300">Email</span>
        <input
          type="email"
          autocomplete="email"
          required
          bind:value={email}
          disabled={busy}
          class="mt-1 block w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-2 text-sm shadow-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500 disabled:opacity-60"
        />
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
            {MIN_PASSWORD_LENGTH - password.length === 1 ? 'character' : 'characters'}
            needed.
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
      {busy ? 'Creating admin account…' : 'Create admin account'}
    </button>

    <p class="text-xs text-center text-gray-500 dark:text-gray-400">
      Already set this up? <a href="#/login" class="text-blue-600 hover:underline">Sign in</a>.
    </p>
  </form>
</div>
