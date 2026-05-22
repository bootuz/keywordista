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
} from './types';

const BASE = '/api/v1';

export class ApiError extends Error {
  constructor(public status: number, public body: string) {
    super(`API ${status}: ${body}`);
  }
}

// Single fetch wrapper: sets a JSON content-type when there's a body, parses
// the response as JSON unless it's a 204. The server runs on 127.0.0.1 only
// and has no auth layer (see Phase 5b in the plan) so there's no header
// injection here.
async function apiFetch<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers);
  if (init.body && !headers.has('Content-Type')) {
    headers.set('Content-Type', 'application/json');
  }

  const response = await fetch(BASE + path, { ...init, headers });

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
