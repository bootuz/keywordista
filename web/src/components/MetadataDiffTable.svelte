<script lang="ts">
  import type { AppMetadataSnapshot, CompareAppEntry } from '../lib/types';

  // Renders the side-by-side metadata table — the centerpiece of the
  // compare page. Rows are fields, columns are (own + competitors).
  // Cells whose value differs from the own column are highlighted so
  // the user's eye can find the deltas at a glance.

  interface Props {
    own: CompareAppEntry | null;
    competitors: CompareAppEntry[];
  }
  let { own, competitors }: Props = $props();

  // Canonical row definitions. One per surfaced field — adding a row
  // here is the single edit needed to surface a new field in the diff.
  // Each row carries a `value` accessor so the rendering loop stays
  // dumb. Long-form fields (description, releaseNotes) get a
  // collapsible cell; the rest render inline.
  interface Row {
    label: string;
    /// Pulls the displayable string from a snapshot row. `null` is
    /// rendered as "—" by the table; the diff highlighter treats
    /// nulls as equal across columns.
    value: (s: AppMetadataSnapshot | null) => string | null;
    /// When true, the cell uses the expandable text component (truncate
    /// with "show more"); when false it renders inline. Description and
    /// releaseNotes are the only multi-paragraph fields in practice.
    long?: boolean;
  }

  const rows: Row[] = [
    { label: 'Name', value: (s) => s?.trackName ?? null },
    { label: 'Subtitle', value: (s) => s?.subtitle ?? null },
    { label: 'Seller', value: (s) => s?.sellerName ?? null },
    { label: 'Genre', value: (s) => s?.primaryGenreName ?? null },
    { label: 'Price', value: (s) => s?.formattedPrice ?? null },
    { label: 'Version', value: (s) => s?.version ?? null },
    {
      label: 'Last updated',
      value: (s) => {
        if (!s?.currentVersionReleaseDate) return null;
        try {
          return new Date(s.currentVersionReleaseDate).toLocaleDateString(undefined, {
            year: 'numeric',
            month: 'short',
            day: 'numeric',
          });
        } catch {
          return s.currentVersionReleaseDate;
        }
      },
    },
    { label: 'Age rating', value: (s) => s?.contentAdvisoryRating ?? null },
    {
      label: 'Avg rating',
      value: (s) => {
        if (s?.averageUserRating == null) return null;
        return `${s.averageUserRating.toFixed(2)} (${s.userRatingCount?.toLocaleString() ?? 0} ratings)`;
      },
    },
    {
      label: 'File size',
      value: (s) => {
        if (s?.fileSizeBytes == null) return null;
        const mb = s.fileSizeBytes / (1024 * 1024);
        return mb < 1000 ? `${mb.toFixed(1)} MB` : `${(mb / 1024).toFixed(2)} GB`;
      },
    },
    {
      label: 'Languages',
      value: (s) => {
        if (!s?.languagesJSON) return null;
        try {
          const arr = JSON.parse(s.languagesJSON) as string[];
          return arr.slice(0, 6).join(', ') + (arr.length > 6 ? ` +${arr.length - 6}` : '');
        } catch {
          return null;
        }
      },
    },
    { label: 'Minimum OS', value: (s) => s?.minimumOSVersion ?? null },
    { label: 'Description', value: (s) => s?.appDescription ?? null, long: true },
    { label: "What's new", value: (s) => s?.releaseNotes ?? null, long: true },
    // Phase-2 fields (always null in v1; render "—" with a tooltip
    // explaining why so users know it's an intentional gap not a bug).
    { label: 'Promotional text', value: (s) => s?.promotionalText ?? null, long: true },
  ];

  // All entries in column order: [own, ...competitors]. The own column
  // is the comparison baseline — cells in other columns that don't
  // match it get highlighted.
  const columns: CompareAppEntry[] = $derived(
    own ? [own, ...competitors] : competitors,
  );

  // Track which long-row cells the user has expanded — keyed by
  // `${rowLabel}::${columnId}`. Reset on column change is unnecessary;
  // the keys are unique per cell.
  let expanded: Set<string> = $state(new Set());
  function toggleExpanded(rowLabel: string, columnId: string): void {
    const key = `${rowLabel}::${columnId}`;
    const next = new Set(expanded);
    if (next.has(key)) next.delete(key);
    else next.add(key);
    expanded = next;
  }

  function isDifferentFromOwn(row: Row, column: CompareAppEntry): boolean {
    if (!own || column.id === own.id) return false;
    return row.value(column.latest) !== row.value(own.latest);
  }
</script>

{#if columns.length === 0}
  <p class="text-sm text-zinc-500 italic">Select an app to begin comparing.</p>
{:else}
  <div class="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
    <table class="w-full text-sm">
      <thead class="bg-zinc-50 dark:bg-zinc-900/50">
        <tr>
          <th class="text-left px-3 py-2 text-xs uppercase tracking-wide text-zinc-500 w-32"
            >Field</th
          >
          {#each columns as column (column.id)}
            <th class="text-left px-3 py-2 font-semibold text-zinc-800 dark:text-zinc-200">
              <div class="flex items-center gap-2">
                <span class="truncate">{column.name}</span>
                {#if column.kind === 'own'}
                  <span class="text-[10px] uppercase tracking-wider rounded bg-emerald-100 dark:bg-emerald-900/40 text-emerald-700 dark:text-emerald-300 px-1.5 py-0.5"
                    >You</span
                  >
                {/if}
              </div>
              <div class="text-xs text-zinc-500 font-normal">
                {#if column.latest?.scrapeFailedAt}
                  <span title="Last scrape failed — subtitle carried forward.">⚠ stale</span>
                {/if}
              </div>
            </th>
          {/each}
        </tr>
      </thead>
      <tbody>
        {#each rows as row (row.label)}
          <tr class="border-t border-zinc-100 dark:border-zinc-800/60 align-top">
            <td class="px-3 py-2 text-xs text-zinc-500 uppercase tracking-wide">{row.label}</td>
            {#each columns as column (column.id)}
              {@const value = row.value(column.latest)}
              {@const diff = isDifferentFromOwn(row, column)}
              {@const isExpanded = expanded.has(`${row.label}::${column.id}`)}
              <td
                class="px-3 py-2"
                class:bg-amber-50={diff}
                class:dark:bg-amber-900={diff}
              >
                {#if value === null}
                  <span
                    class="text-zinc-400 italic"
                    title={row.label === 'Promotional text'
                      ? "Apple's lookup API doesn't expose promotional text — requires the AMP-API token flow (deferred to a future release)."
                      : 'No data'}
                  >
                    —
                  </span>
                {:else if row.long && value.length > 200 && !isExpanded}
                  <span class="text-zinc-800 dark:text-zinc-200">{value.slice(0, 200)}…</span>
                  <button
                    type="button"
                    class="ml-1 text-xs text-zinc-500 underline hover:text-zinc-700 dark:hover:text-zinc-300"
                    onclick={() => toggleExpanded(row.label, column.id)}
                  >
                    show more
                  </button>
                {:else if row.long}
                  <span class="text-zinc-800 dark:text-zinc-200 whitespace-pre-line">{value}</span>
                  {#if value.length > 200}
                    <button
                      type="button"
                      class="ml-1 text-xs text-zinc-500 underline hover:text-zinc-700 dark:hover:text-zinc-300"
                      onclick={() => toggleExpanded(row.label, column.id)}
                    >
                      show less
                    </button>
                  {/if}
                {:else}
                  <span class="text-zinc-800 dark:text-zinc-200">{value}</span>
                {/if}
              </td>
            {/each}
          </tr>
        {/each}
      </tbody>
    </table>
  </div>
{/if}
