<script lang="ts">
  // M3.25 — Empty-state page shown when the server's /auth/state
  // returns { firstRun: true }. Replaces the M2.6 SetupWizard.svelte
  // (which is deleted alongside the /api/v1/auth/setup endpoint).
  //
  // Reached automatically by App.svelte's routing guard: when
  // firstRun is true, all other routes redirect here. Once the
  // operator runs `createsuperuser` and reloads the page,
  // firstRun goes false and the guard sends them to /login.
  //
  // The page is intentionally documentation-flavored, not interactive:
  // there's no form to fill out — admin creation is now strictly an
  // out-of-band CLI action. The operator must shell into the
  // container (raw-docker) OR the menubar app must have set
  // KEYWORDISTA_ADMIN_* env vars (cockpit path).

  import { authState } from '../lib/authStore';

  // Pre-formatted snippet that operators can copy verbatim into
  // their terminal. Container name "keywordista" matches the docs
  // throughout — using the literal name (vs. <container>) makes
  // copy-paste actually work for the canonical install.
  const dockerExecCmd = 'docker exec -it keywordista keywordista createsuperuser';

  // M3.25-future: provider-specific recipes (Render shell, Fly ssh
  // console, k8s exec) belong here when M4/M5 lands. For now we
  // document the canonical raw-docker path + acknowledge the
  // cockpit-misconfiguration scenario.
</script>

<div class="flex items-center justify-center min-h-screen bg-gray-50 dark:bg-gray-900 px-4">
  <div class="w-full max-w-xl bg-white dark:bg-gray-800 rounded-lg shadow-sm p-8 space-y-6">
    <div class="space-y-2">
      <h1 class="text-2xl font-semibold text-gray-900 dark:text-gray-100">
        No admin user yet
      </h1>
      <p class="text-sm text-gray-500 dark:text-gray-400">
        This Keywordista instance is running, but no admin account exists.
        Bootstrap one with the <code class="px-1.5 py-0.5 bg-gray-100 dark:bg-gray-900 rounded text-gray-700 dark:text-gray-200 text-xs">createsuperuser</code> CLI
        command, then reload this page to sign in.
      </p>
    </div>

    <!-- Primary path: raw-docker operator runs the CLI -->
    <div class="space-y-3">
      <h2 class="text-sm font-medium text-gray-700 dark:text-gray-300">
        If you started this with Docker
      </h2>
      <p class="text-sm text-gray-500 dark:text-gray-400">
        Run this in your terminal:
      </p>
      <!--
        Block-style code: not inside a form because there's nothing
        to submit. select-all on the pre lets the operator triple-
        click to grab the whole command without a copy button.
      -->
      <pre class="bg-gray-900 text-gray-100 text-xs rounded-md p-4 overflow-x-auto select-all">
{dockerExecCmd}</pre>
      <p class="text-xs text-gray-500 dark:text-gray-400">
        The command will prompt for an email and password, hash the password,
        and create the admin user. Once it succeeds, reload this page.
      </p>
    </div>

    <hr class="border-gray-200 dark:border-gray-700" />

    <!-- Secondary path: cockpit operator whose env vars didn't seed -->
    <div class="space-y-2">
      <h2 class="text-sm font-medium text-gray-700 dark:text-gray-300">
        If you deployed via the Keywordista menubar app
      </h2>
      <p class="text-sm text-gray-500 dark:text-gray-400">
        The cockpit was supposed to pre-seed your admin via
        <code class="px-1 py-0.5 bg-gray-100 dark:bg-gray-900 rounded text-gray-700 dark:text-gray-200 text-xs">KEYWORDISTA_ADMIN_EMAIL</code> +
        <code class="px-1 py-0.5 bg-gray-100 dark:bg-gray-900 rounded text-gray-700 dark:text-gray-200 text-xs">KEYWORDISTA_ADMIN_PASSWORD_HASH</code>.
        Since you're seeing this page, those env vars are missing on the
        server. Re-deploy from the menubar app, or shell in and run the
        CLI command above as a workaround.
      </p>
    </div>

    <div class="pt-2">
      <p class="text-xs text-gray-400 dark:text-gray-500">
        <a
          href="https://github.com/bootuz/keywordista/blob/main/docs/deploy/raw-docker.md"
          target="_blank"
          rel="noopener"
          class="text-blue-600 hover:underline"
        >Read the full deployment docs →</a>
      </p>
    </div>

    {#if $authState && !$authState.firstRun}
      <!-- Defensive: if authState updates while this page is mounted
           (operator ran the CLI in another terminal, page rehydrated),
           nudge them at the login link explicitly. Normally the
           router-level guard handles the redirect, but this catches
           the racy case. -->
      <div role="alert" class="text-sm rounded-md px-3 py-2 bg-emerald-50 dark:bg-emerald-900/30 text-emerald-700 dark:text-emerald-300 border border-emerald-200 dark:border-emerald-800">
        Admin user now exists — <a href="#/login" class="underline font-medium">sign in</a>.
      </div>
    {/if}
  </div>
</div>
