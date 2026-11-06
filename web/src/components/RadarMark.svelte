<script lang="ts">
  // Flat version of the app icon's radar: no tile, no glass. Drawn in
  // currentColor so the caller picks the tint; the default classes give
  // teal on light backgrounds (the draft's mint washes out on white) and
  // the icon's mint on dark. public/favicon.svg is the same drawing — keep
  // the two in step if the shape changes.
  interface Props {
    size?: number;
    class?: string;
  }
  let { size = 20, class: className = 'text-teal-600 dark:text-[#5EF0C2]' }: Props = $props();

  // Per-instance gradient id so two marks on one page don't share a def.
  const gradId = `kw-radar-sweep-${Math.random().toString(36).slice(2, 8)}`;
</script>

<svg
  width={size}
  height={size}
  viewBox="184 184 656 656"
  class={className}
  aria-hidden="true"
>
  <defs>
    <linearGradient id={gradId} gradientUnits="userSpaceOnUse" x1="429" y1="203" x2="757" y2="306">
      <stop offset="0" stop-color="currentColor" stop-opacity="0" />
      <stop offset="1" stop-color="currentColor" stop-opacity="0.55" />
    </linearGradient>
  </defs>
  <g fill="none" stroke="currentColor" stroke-opacity="0.4" stroke-width="18">
    <circle cx="512" cy="512" r="112" />
    <circle cx="512" cy="512" r="216" />
    <circle cx="512" cy="512" r="318" />
  </g>
  <path d="M512 512 L429.2 202.9 A320 320 0 0 1 757.1 306.3 Z" fill="url(#{gradId})" />
  <path d="M512 512 L757.1 306.3" stroke="currentColor" stroke-width="24" stroke-linecap="round" />
  <circle cx="325" cy="620" r="24" fill="currentColor" opacity="0.5" />
  <circle cx="568" cy="609" r="22" fill="currentColor" opacity="0.45" />
  <circle cx="636" cy="335" r="62" fill="currentColor" opacity="0.2" />
  <circle cx="636" cy="335" r="34" fill="currentColor" />
  <circle cx="512" cy="512" r="30" fill="currentColor" />
</svg>
