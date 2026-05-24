<script lang="ts">
  // /#/login — email + password sign-in form.
  //
  // Renders only in server mode. In local mode the route guard in
  // M2.10 prevents this from being reached (Dashboard is rendered
  // immediately). If someone navigates here manually in local mode
  // anyway, the form would just hang on submit since /auth/login
  // would 401 the empty user table — not a security concern, just
  // a worse UX. M2.10's guard makes it unreachable.
  //
  // The session cookie set by /auth/login is HttpOnly + SameSite=Strict —
  // we never see it from JS. The browser ships it back on the next
  // request, which is why the post-login flow can immediately
  // hydrateAuthState() and find signedIn=true.

  import { push } from 'svelte-spa-router';
  import { login } from '../lib/auth';
  import { hydrateAuthState } from '../lib/authStore';
  import { ApiError } from '../lib/api';
  import { ROUTES } from '../lib/router';

  let email = $state('');
  let password = $state('');
  let busy = $state(false);
  let error = $state<string | null>(null);

  async function handleSubmit(event: SubmitEvent) {
    event.preventDefault();
    if (busy) return;
    busy = true;
    error = null;

    try {
      await login(email.trim(), password);
      // Re-hydrate so currentUser / serverMode / isFirstRun update
      // throughout the app. Has to await; otherwise the dashboard
      // could mount before the store sees the new user and flash
      // its "loading" state for a frame.
      await hydrateAuthState();
      push(ROUTES.dashboard);
    } catch (e) {
      // Backend returns a generic 401 for any failure (anti-
      // enumeration). Surface the same generic message — never
      // try to be clever about "looks like a wrong email vs.
      // wrong password" because the server deliberately won't
      // tell us which it was.
      if (e instanceof ApiError && e.status === 401) {
        error = 'Invalid email or password.';
      } else if (e instanceof ApiError && e.status === 400) {
        // Input validation (too-short password, malformed email)
        // bubbles the server's reason string up.
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
        Sign in to Keywordista
      </h1>
      <p class="text-sm text-gray-500 dark:text-gray-400">
        Use the account your team admin set up for you.
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
          autocomplete="current-password"
          required
          bind:value={password}
          disabled={busy}
          class="mt-1 block w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-2 text-sm shadow-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500 disabled:opacity-60"
        />
      </label>
    </div>

    <button
      type="submit"
      disabled={busy || !email || !password}
      class="w-full flex justify-center items-center rounded-md bg-blue-600 hover:bg-blue-700 disabled:bg-blue-400 text-white text-sm font-medium px-4 py-2 transition-colors"
    >
      {busy ? 'Signing in…' : 'Sign in'}
    </button>
  </form>
</div>
