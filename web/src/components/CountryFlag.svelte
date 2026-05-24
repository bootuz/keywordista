<script lang="ts">
  import { isoCountryToFlag } from '../lib/time';
  interface Props {
    code: string;
  }
  let { code }: Props = $props();
</script>

<span class="inline-flex items-center gap-1.5 text-sm text-zinc-700 dark:text-zinc-300">
  <span class="text-base leading-none">{isoCountryToFlag(code)}</span>
  <span class="font-mono uppercase tracking-wide text-zinc-500">{code}</span>
</span>
