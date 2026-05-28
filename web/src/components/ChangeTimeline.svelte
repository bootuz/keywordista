<script lang="ts">
  import type { MetadataChange } from '../lib/types';

  // Renders a chronological list (newest first) of per-field changes
  // computed server-side. The server already excludes carry-forward
  // rows from the derivation; we just render whatever it sends.

  interface Props {
    changes: MetadataChange[];
    /// Optional title; defaults to "Recent changes". Pass null to
    /// suppress the header entirely (compose into a larger section).
    title?: string | null;
  }
  let { changes, title = 'Recent changes' }: Props = $props();

  // Friendly labels for the canonical field names. Anything missing
  // falls back to the raw field name — better than a blank.
  const labels: Record<string, string> = {
    track_name: 'App name',
    subtitle: 'Subtitle',
    description: 'Description',
    version: 'Version',
    release_notes: "What's new",
    formatted_price: 'Price',
    screenshot_urls: 'Screenshots',
    ipad_screenshot_urls: 'iPad screenshots',
    genres: 'Genres',
  };

  function label(field: string): string {
    return labels[field] ?? field;
  }

  function fmt(date: string): string {
    // Same convention as the rest of the SPA: human date, no time.
    // The change-derivation is daily-cadence so HH:MM would be noise.
    try {
      return new Date(date).toLocaleDateString(undefined, {
        year: 'numeric',
        month: 'short',
        day: 'numeric',
      });
    } catch {
      return date;
    }
  }

  // Truncate long text (description, releaseNotes) for the timeline —
  // the user can open the full diff via the detail panel if they care
  // about the exact wording. Bare-minimum truncation; preserves the
  // signal "the description changed on X" without forcing a wall of
  // text into the timeline.
  function truncate(value: string | null, max = 80): string {
    if (!value) return '—';
    return value.length > max ? value.slice(0, max - 1) + '…' : value;
  }
</script>

<section class="space-y-3">
  {#if title}
    <h3 class="text-sm font-semibold text-zinc-700 dark:text-zinc-300 uppercase tracking-wide">
      {title}
    </h3>
  {/if}

  {#if changes.length === 0}
    <p class="text-sm text-zinc-500 italic">
      No tracked changes yet. Snapshots are taken daily; once a field
      changes between two runs it'll show up here.
    </p>
  {:else}
    <ul class="space-y-2">
      {#each changes as change, i (`${change.field}-${change.at}-${i}`)}
        <li class="rounded-md border border-zinc-200 dark:border-zinc-800 p-3 text-sm">
          <header class="flex items-baseline justify-between gap-2 mb-1">
            <span class="font-medium text-zinc-800 dark:text-zinc-200">
              {label(change.field)} changed
            </span>
            <time class="text-xs text-zinc-500" datetime={change.at}>
              {fmt(change.at)}
            </time>
          </header>
          <div class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-xs">
            <span class="text-zinc-500">From:</span>
            <span class="text-zinc-700 dark:text-zinc-300 line-through decoration-zinc-400/60">
              {truncate(change.from)}
            </span>
            <span class="text-zinc-500">To:</span>
            <span class="text-zinc-900 dark:text-zinc-100 font-medium">
              {truncate(change.to)}
            </span>
          </div>
        </li>
      {/each}
    </ul>
  {/if}
</section>
