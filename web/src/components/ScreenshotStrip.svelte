<script lang="ts">
  // Horizontal strip of an app's iPhone screenshots. URLs are loaded
  // directly from Apple's CDN — no proxy. If the URLs change, the
  // snapshot's content hash naturally reflects that (the URL itself
  // changes when Apple mints a new hash for a swapped asset).
  //
  // We accept the screenshots as the raw JSON-encoded string the server
  // sends (matching the AppMetadataSnapshot shape) so callers don't have
  // to remember to parse before passing in. Falls back to an empty list
  // for null / malformed JSON.

  interface Props {
    /// Raw JSON-encoded string of screenshot URLs from the snapshot row.
    /// Server-side this is `screenshot_urls_json`.
    json: string | null;
    /// Empty-state label (e.g. "No iPhone screenshots") for parity with
    /// the iPad strip rendering.
    emptyLabel?: string;
  }
  let { json, emptyLabel = 'No screenshots available' }: Props = $props();

  // Parse defensively — a malformed JSON would otherwise throw at
  // render time and blank out the whole compare row.
  const urls: string[] = $derived.by(() => {
    if (!json) return [];
    try {
      const parsed: unknown = JSON.parse(json);
      if (!Array.isArray(parsed)) return [];
      return parsed.filter((v): v is string => typeof v === 'string');
    } catch {
      return [];
    }
  });
</script>

{#if urls.length === 0}
  <p class="text-xs text-zinc-500 italic">{emptyLabel}</p>
{:else}
  <div class="flex gap-2 overflow-x-auto py-2">
    {#each urls.slice(0, 10) as src, i (src)}
      <!-- max 10 screenshots: Apple caps at 10 per app anyway, and
           bounding the render avoids surprise scroll lag on apps with
           weirdly long arrays from older API shapes. -->
      <img
        {src}
        alt="Screenshot {i + 1}"
        loading="lazy"
        class="h-40 w-auto rounded-md border border-zinc-200 dark:border-zinc-800 flex-shrink-0 bg-zinc-100 dark:bg-zinc-900"
      />
    {/each}
  </div>
{/if}
