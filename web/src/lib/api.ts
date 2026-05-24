import type {
  WatchedApp,
  Keyword,
  DashboardRow,
  HistoryPoint,
  AppKeywordRow,
  RefreshResponse,
  QueueStatus,
  ASCStatus,
  ASAStatus,
  DeveloperKeywordsResponse,
  SuggestionRow,
  ChartPosition,
  ChartEvent,
} from './types';

export const BASE = '/api/v1';

export class ApiError extends Error {
  constructor(public status: number, public body: string) {
    super(`API ${status}: ${body}`);
  }
}

// ── 401 hook (M2.4) ──────────────────────────────────────────────
//
// Inversion of control: api.ts doesn't know about routing or auth
// stores. App.svelte registers a handler at boot that does the
// real work (push('/login'), clear authStore). On 401, apiFetch
// calls the handler (if any) and then still throws — so callers
// that want to display an error UI can.
//
// `/auth/*` paths are excluded: the LoginPage MUST see a real 401
// from /auth/login to show "invalid credentials" instead of being
// silently bounced. Same logic for /auth/setup, /auth/accept-invite,
// /auth/state, /auth/invite/:token. These endpoints either don't
// require auth at all, or are themselves the auth flow.
type UnauthorizedHandler = (path: string) => void | Promise<void>;
let unauthorizedHandler: UnauthorizedHandler | null = null;

export function setUnauthorizedHandler(handler: UnauthorizedHandler | null): void {
  unauthorizedHandler = handler;
}

// Single fetch wrapper: sets a JSON content-type when there's a body, parses
// the response as JSON unless it's a 204. In server mode the cookie is HttpOnly
// + SameSite=Strict so it ships back automatically on same-origin requests; we
// never inject auth headers explicitly. Local mode has no auth layer at all —
// server binds 127.0.0.1 and the menubar app is the sole client.
export async function apiFetch<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers);
  if (init.body && !headers.has('Content-Type')) {
    headers.set('Content-Type', 'application/json');
  }

  const response = await fetch(BASE + path, { ...init, headers });

  if (response.status === 401 && !path.startsWith('/auth/') && unauthorizedHandler) {
    // Fire-and-forget — we still throw below so the caller can render
    // an error toast if it wants. The handler runs whatever cleanup
    // it needs (clear authState, push to /login) in the background.
    void unauthorizedHandler(path);
  }

  if (!response.ok) {
    const text = await response.text();
    throw new ApiError(response.status, text);
  }

  if (response.status === 204) return undefined as T;
  return (await response.json()) as T;
}

// Apps -------------------------------------------------------------
export const listApps = () => apiFetch<WatchedApp[]>('/apps');

export const addApp = (appStoreId: number, lookupCountry?: string) =>
  apiFetch<WatchedApp>('/apps', {
    method: 'POST',
    body: JSON.stringify({ appStoreId, lookupCountry: lookupCountry ?? 'us' }),
  });

export const deleteApp = (id: string) =>
  apiFetch<void>(`/apps/${id}`, { method: 'DELETE' });

// Keywords ---------------------------------------------------------
export const listKeywords = () => apiFetch<Keyword[]>('/keywords');

export const addKeyword = (term: string, countryCode: string) =>
  apiFetch<Keyword>('/keywords', {
    method: 'POST',
    body: JSON.stringify({ term, countryCode }),
  });

export const deleteKeyword = (id: string) =>
  apiFetch<void>(`/keywords/${id}`, { method: 'DELETE' });

export const refreshKeyword = (id: string) =>
  apiFetch<RefreshResponse>(`/keywords/${id}/refresh`, { method: 'POST' });

export const refreshAll = () =>
  apiFetch<RefreshResponse>('/refresh-all', { method: 'POST' });

export const getRefreshStatus = () => apiFetch<QueueStatus>('/refresh-status');

// Dashboard --------------------------------------------------------
// The web UI filters client-side now; we always fetch the full set.
// The backend's `?country=` filter remains supported for ad-hoc curl usage.
export const getDashboard = () => apiFetch<DashboardRow[]>('/dashboard');

export const getHistory = (keywordId: string, watchedAppId: string) =>
  apiFetch<HistoryPoint[]>(
    `/keywords/${keywordId}/history?watchedAppId=${watchedAppId}`,
  );

export const getAppKeywords = (appId: string) =>
  apiFetch<AppKeywordRow[]>(`/apps/${appId}/keywords`);

// Settings — secrets never come back from GET.
export const getASCSettings = () => apiFetch<ASCStatus>('/settings/asc');
export const putASCSettings = (body: { keyId: string; issuerId: string; privateKey?: string }) =>
  apiFetch<ASCStatus>('/settings/asc', { method: 'PUT', body: JSON.stringify(body) });
export const deleteASCSettings = () => apiFetch<void>('/settings/asc', { method: 'DELETE' });

// Live-fetches the developer's per-locale keyword list from App Store Connect
// using the stored credentials. Returns {} when ASC isn't configured.
export const getDeveloperKeywords = () =>
  apiFetch<DeveloperKeywordsResponse>('/settings/asc/keywords');

// Mines Apple Search Ads search-term reports for terms related to this
// tracked keyword. Returns [] when ASA isn't configured, no campaigns serve
// the seed's storefront, or the campaign hasn't accumulated data yet.
export const getKeywordSuggestions = (id: string) =>
  apiFetch<SuggestionRow[]>(`/keywords/${id}/suggestions`);

export const getASASettings = () => apiFetch<ASAStatus>('/settings/asa');
export const putASASettings = (body: { clientId: string; clientSecret?: string; orgId?: string }) =>
  apiFetch<ASAStatus>('/settings/asa', { method: 'PUT', body: JSON.stringify(body) });
export const deleteASASettings = () => apiFetch<void>('/settings/asa', { method: 'DELETE' });

// Charts -----------------------------------------------------------
export const getChartPositions = () =>
  apiFetch<ChartPosition[]>('/chart-positions');

// Newest-first feed of chart-transition events. `sinceIso` makes the polling
// loop cheap by only returning events newer than what we've already shown.
export const getChartEvents = (sinceIso?: string, limit = 50) => {
  const params = new URLSearchParams();
  if (sinceIso) params.set('since', sinceIso);
  params.set('limit', String(limit));
  return apiFetch<ChartEvent[]>(`/chart-events?${params.toString()}`);
};

export const refreshCharts = () =>
  apiFetch<{ queued: boolean }>('/charts/refresh', { method: 'POST' });

export const refreshAvailability = (appId: string) =>
  apiFetch<{ queued: boolean }>(`/apps/${appId}/availability/refresh`, { method: 'POST' });

// Auth probe -------------------------------------------------------
// Cheap way to validate the token without side effects.
export async function ping(): Promise<boolean> {
  try {
    await listApps();
    return true;
  } catch (err) {
    if (err instanceof ApiError && err.status === 401) return false;
    throw err;
  }
}
