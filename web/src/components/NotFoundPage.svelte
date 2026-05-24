<script lang="ts">
  import { push } from 'svelte-spa-router';
  // Wildcard fallback for unmatched routes (a user hand-typed
  // /#/typo, an old bookmark, etc.). Keeps the SPA from rendering
  // a blank screen — the SPAFallbackMiddleware already gets us
  // index.html for any path; this is the in-app equivalent.
</script>

<div class="flex flex-col items-center justify-center min-h-[60vh] gap-4">
  <h1 class="text-2xl font-medium">Page not found</h1>
  <p class="text-gray-500">The page you're looking for doesn't exist.</p>
  <button
    type="button"
    onclick={() => push('/')}
    class="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700"
  >
    Go to dashboard
  </button>
</div>
