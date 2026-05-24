// Theme preference: what the user picked.
//   'dark'   — force dark (the app's default — see `loadTheme`)
//   'light'  — force light
//   'system' — follow the OS preference live via prefers-color-scheme
export type Theme = 'light' | 'dark' | 'system';

const STORAGE_KEY = 'theme';
const DEFAULT_THEME: Theme = 'dark';

/// `media` is initialised lazily because this module is also imported during
/// build (SSR / prerender style cases) where `window` doesn't exist.
let media: MediaQueryList | null = null;
let systemListener: ((e: MediaQueryListEvent) => void) | null = null;

function getMedia(): MediaQueryList | null {
  if (typeof window === 'undefined') return null;
  if (!media) media = window.matchMedia('(prefers-color-scheme: dark)');
  return media;
}

/// Returns whether the *effective* theme should be dark right now.
/// For 'system' this is read at the moment of call.
export function resolveIsDark(theme: Theme): boolean {
  if (theme === 'dark') return true;
  if (theme === 'light') return false;
  return getMedia()?.matches ?? true; // fall back to dark if matchMedia unavailable
}

/// Reads the saved preference from localStorage. Defaults to 'dark' when
/// nothing is stored — the brand is dark-first; users opt into light/system.
export function loadTheme(): Theme {
  if (typeof window === 'undefined') return DEFAULT_THEME;
  const raw = window.localStorage.getItem(STORAGE_KEY);
  if (raw === 'light' || raw === 'dark' || raw === 'system') return raw;
  return DEFAULT_THEME;
}

/// Applies the effective theme by toggling `dark` on <html>. Tailwind's
/// `darkMode: 'class'` config (see tailwind.config.ts) picks it up.
function applyToDocument(isDark: boolean): void {
  if (typeof document === 'undefined') return;
  document.documentElement.classList.toggle('dark', isDark);
}

/// Persists the user's choice and re-applies the class. When switching to
/// 'system' we attach a live media listener so the UI flips in real time
/// if the OS preference changes (e.g. macOS auto-night-shift at sunset).
export function setTheme(theme: Theme): void {
  if (typeof window !== 'undefined') {
    window.localStorage.setItem(STORAGE_KEY, theme);
  }
  applyToDocument(resolveIsDark(theme));
  bindSystemListener(theme);
}

function bindSystemListener(theme: Theme): void {
  const m = getMedia();
  if (!m) return;
  // Always detach the old listener before deciding whether to attach a new
  // one — keeps state idempotent across rapid theme changes.
  if (systemListener) {
    m.removeEventListener('change', systemListener);
    systemListener = null;
  }
  if (theme === 'system') {
    systemListener = (e) => applyToDocument(e.matches);
    m.addEventListener('change', systemListener);
  }
}

/// Boot-time hook. Call once from main.ts before mounting the app so the
/// correct theme class is set before first paint (avoids a light-mode flash).
export function initTheme(): Theme {
  const theme = loadTheme();
  applyToDocument(resolveIsDark(theme));
  bindSystemListener(theme);
  return theme;
}
