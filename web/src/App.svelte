<script lang="ts">
  // Router shell. Auth-state hydration + route guards land in M2.10;
  // for now this is the pure "match URL → render component" wiring
  // so the rest of M2 has a place to plug their pages in.
  //
  // Hash-based: URLs are `#/`, `#/login`, `#/invite/:token`, etc.
  // Anything not matched falls through to NotFoundPage via the '*'
  // entry in `routes`.
  import Router from 'svelte-spa-router';
  import { routes } from './lib/router';
</script>

<Router {routes} />
