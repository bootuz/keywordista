<script lang="ts">
  import { developerKeywords, isInDeveloperKeywords } from '../lib/stores';

  interface Props {
    term: string;
    countryCode: string;
    appId: string;
  }
  let { term, countryCode, appId }: Props = $props();

  const inMetadata = $derived(isInDeveloperKeywords($developerKeywords, appId, countryCode, term));
</script>

{#if inMetadata}
  <span
    title="In your App Store Connect keywords field for this storefront"
    class="ml-1.5 inline-flex items-center rounded bg-amber-500/20 px-1 py-0.5 text-[10px] font-medium uppercase tracking-wide text-amber-400 ring-1 ring-amber-500/30"
  >
    ASC
  </span>
{/if}
