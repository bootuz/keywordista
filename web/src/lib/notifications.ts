// Browser-notification wrapper used by the chart-watchdog. The native
// Notification API is straightforward, but two ergonomic wrinkles:
//   1. requestPermission() can only be called from a user gesture in some
//      browsers. We expose it but don't auto-call it on page load.
//   2. localStorage tracks whether the user has explicitly opted out so we
//      don't re-prompt on every visit to /charts.

import type { ChartEvent } from './types';
import { isoCountryToFlag } from './time';

const STORAGE_KEY = 'keywordista:notification-permission';

export type LocalPermission = 'default' | 'granted' | 'denied' | 'unsupported';

export function isSupported(): boolean {
  return typeof window !== 'undefined' && 'Notification' in window;
}

// Reads the live browser state (the authoritative source). localStorage is
// only used to remember "user clicked Later" so the /charts page can hide
// the CTA without re-prompting.
export function permissionState(): LocalPermission {
  if (!isSupported()) return 'unsupported';
  return Notification.permission as LocalPermission;
}

export function userDismissed(): boolean {
  try {
    return localStorage.getItem(STORAGE_KEY) === 'dismissed';
  } catch {
    return false;
  }
}

export function markDismissed(): void {
  try {
    localStorage.setItem(STORAGE_KEY, 'dismissed');
  } catch {
    /* storage disabled */
  }
}

export async function requestPermission(): Promise<NotificationPermission | 'unsupported'> {
  if (!isSupported()) return 'unsupported';
  try {
    const result = await Notification.requestPermission();
    if (result === 'granted') {
      // Clear any stale "dismissed" flag so subsequent visits don't suggest
      // the user opted out.
      try { localStorage.removeItem(STORAGE_KEY); } catch { /* */ }
    }
    return result;
  } catch {
    return 'denied';
  }
}

export function notify(event: ChartEvent): void {
  if (!isSupported() || Notification.permission !== 'granted') return;
  const flag = isoCountryToFlag(event.country);
  const country = event.country.toUpperCase();
  let body: string;
  switch (event.kind) {
    case 'entered':
      body = `📈 ${event.appName} entered ${flag} ${country} at #${event.position}`;
      break;
    case 'moved':
      body = `${event.appName} moved in ${flag} ${country}: #${event.prevPosition} → #${event.position}`;
      break;
    case 'exited':
      body = `📉 ${event.appName} exited ${flag} ${country} (was #${event.prevPosition})`;
      break;
  }
  try {
    const n = new Notification('Keywordista', { body, tag: event.id });
    n.onclick = () => {
      window.focus();
      n.close();
    };
  } catch {
    /* Some browsers throw when called outside a service worker — silently ignore. */
  }
}
