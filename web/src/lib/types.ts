// Mirrors Sources/App/Domain/DomainTypes.swift.
// Keep in sync manually — small surface, low churn.

export interface WatchedApp {
  id: string;
  appStoreId: number;
  bundleId: string;
  name: string;
  iconURL: string | null;
  addedAt: string | null;
}

export interface Keyword {
  id: string;
  term: string;
  countryCode: string;
  createdAt: string | null;
}

export interface TopResultDTO {
  position: number;
  appStoreId: number;
  name: string;
  iconURL: string | null;
}

export interface DashboardRow {
  keywordId: string;
  term: string;
  countryCode: string;
  watchedAppId: string;
  watchedAppName: string;
  rank: number | null;
  // The rank from the previous check, for delta rendering. Null = previous
  // check had no rank (outside top 200). Use hasPreviousCheck to distinguish
  // from "no previous check at all".
  previousRank: number | null;
  hasPreviousCheck: boolean;
  difficulty: number;
  entryBarrier: number;
  checkedAt: string | null;
  topResults: TopResultDTO[];
}

export interface HistoryPoint {
  checkedAt: string;
  rank: number | null;
  difficulty: number;
  entryBarrier: number;
}

export interface AppKeywordRow {
  keywordId: string;
  term: string;
  countryCode: string;
  rank: number | null;
  difficulty: number;
  entryBarrier: number;
  checkedAt: string | null;
}

// Settings DTOs — what the API returns. Secrets never come back; the server
// only tells us whether they're present.
export interface ASCStatus {
  keyId: string | null;
  issuerId: string | null;
  hasPrivateKey: boolean;
  configured: boolean;
}

export interface ASAStatus {
  clientId: string | null;
  orgId: string | null;
  hasClientSecret: boolean;
  configured: boolean;
}

export interface RefreshResponse {
  enqueued: number;
}

export interface QueueStatus {
  pending: number;
}

// Map of watchedAppId → countryCode → list of normalized keyword terms that
// appear in the developer's App Store Connect keywords field for the latest
// version localization mapped to that storefront.
export type DeveloperKeywordsResponse = Record<string, Record<string, string[]>>;

// A single row in the HistoryPanel "Related" tab — mined from the user's
// Apple Search Ads search-term reports for campaigns in the same country
// as the seed keyword.
export interface SuggestionRow {
  term: string;
  source: string;          // "AUTO" (Search Match) | "TARGETED" | "UNKNOWN"
  impressions: number;
  taps: number;
  ttr: number;             // 0…1
  alreadyTracked: boolean;
  currentRank: number | null;
}

// Aggregated counters for Apple's LOW_VOLUME placeholder rows. Apple
// anonymizes individual search terms when their underlying query volume
// is below a k-anonymity threshold — the impressions/taps are still real
// and billable, but the term text is replaced with the literal
// "LOW_VOLUME". The Related panel surfaces these totals as a banner so
// the user knows the campaign is producing signal even when no single
// term passes the relevance filter.
export interface AnonymizedSummary {
  impressions: number;
  taps: number;
  /// Number of campaign × match-type combos that contributed a
  /// LOW_VOLUME row.
  sourceCount: number;
}

// Shape of GET /api/v1/keywords/:id/suggestions.
export interface SuggestionsResponse {
  rows: SuggestionRow[];
  anonymized: AnonymizedSummary | null;
}

// Chart-position watchdog DTOs. Mirror Sources/App/Controllers/ChartsController.swift.

export interface ChartPosition {
  appId: string;
  appName: string;
  country: string;
  chartType: string;
  genreId: number;
  position: number;
  observedAt: string;
}

export type ChartEventKind = 'entered' | 'moved' | 'exited';

export interface ChartEvent {
  id: string;
  appId: string;
  appName: string;
  country: string;
  chartType: string;
  genreId: number;
  kind: ChartEventKind;
  position: number | null;
  prevPosition: number | null;
  createdAt: string;
}

// ─────────────────────────────────────────────────────────────────
// Auth — mirrors Sources/App/Auth/*.swift
// ─────────────────────────────────────────────────────────────────

export type RuntimeMode = 'local' | 'server';
export type UserRole = 'admin' | 'member';

export interface UserSummary {
  id: string;
  email: string;
  role: string;   // 'admin' | 'member' — kept as string to match Swift's rawValue
}

/// Response shape of GET /api/v1/auth/state.
/// Drives every routing decision in the SPA — local-mode renders
/// Dashboard directly (no auth UI), firstRun pushes to
/// BootstrapInstructions (M3.25 — was SetupWizard pre-M3.25),
/// signedIn=false (server mode) pushes to LoginPage.
export interface AuthState {
  mode: RuntimeMode;
  /// True when the `users` table is empty. SPA shows the bootstrap-
  /// instructions page (with the docker-exec createsuperuser recipe)
  /// when true. Flips to false once any admin exists.
  firstRun: boolean;
  signedIn: boolean;
  user: UserSummary | null;
}

/// Response shape of the success path of /setup, /login, /accept-invite.
/// The cookie itself is in the Set-Cookie header (HttpOnly so JS can't
/// read it; browser ships it back on the next same-origin request).
export interface AuthSuccess {
  user: UserSummary;
}

/// Body of GET /api/v1/auth/invite/:token. See AuthController.
export interface InviteSummary {
  email: string | null;
  role: string;         // 'admin' | 'member'
  expiresAt: string;    // ISO 8601
}

/// Body of POST /api/v1/users/invite (admin-only). The token is
/// shown ONCE to the admin in the UsersAdmin UI — once dismissed
/// it can only be regenerated by issuing a new invite. The
/// acceptUrl is the full URL the admin sends to the recipient.
export interface InviteCreated {
  token: string;
  acceptUrl: string;
  role: string;
  email: string | null;
  expiresAt: string;
}

/// Row shape returned by GET /api/v1/users. Matches Swift's
/// UserListItem in UsersController.
export interface UserListItem {
  id: string;
  email: string;
  role: string;
  createdAt: string;
  lastLoginAt: string | null;
}
