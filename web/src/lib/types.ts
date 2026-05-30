// Mirrors Sources/App/Domain/DomainTypes.swift.
// Keep in sync manually — small surface, low churn.

/// The server-side enum is `own | competitor`. We accept any string
/// over the wire so an older SPA against a newer server (or vice-versa)
/// gracefully ignores unknown kinds rather than crashing — the diff UI
/// treats unknown as `own`, matching the Swift accessor's coercion.
export type WatchedAppKind = 'own' | 'competitor';

export interface WatchedApp {
  id: string;
  appStoreId: number;
  bundleId: string;
  name: string;
  iconURL: string | null;
  kind: WatchedAppKind;
  addedAt: string | null;
}

// ── Competitor analysis (v2) ────────────────────────────────────────
//
// Mirrors Sources/App/Models/AppMetadataSnapshot.swift's column shape
// and Sources/App/Controllers/MetadataController.swift's response DTOs.
// Most fields are nullable because Apple's iTunes lookup is permissive
// (free apps omit `price`, apps without subtitles omit `subtitle`, etc.).
// Array-shaped fields are stored server-side as JSON strings; the API
// emits them as the raw JSON in the wire payload, so they arrive as the
// string here and the SPA parses with `JSON.parse(...)` on demand.
export interface AppMetadataSnapshot {
  id: string;
  watchedAppId: string;
  countryCode: string;

  trackName: string;
  bundleId: string;
  version: string | null;
  currentVersionReleaseDate: string | null;
  releaseNotes: string | null;

  subtitle: string | null;
  // `appDescription` over `description` because `description` is reserved
  // on many DOM types and IDE autocomplete in Svelte components would
  // otherwise nudge developers toward the wrong field.
  appDescription: string | null;
  promotionalText: string | null;        // always null in v1 (phase-2 AMP fetch)
  sellerName: string | null;
  primaryGenreName: string | null;
  genresJSON: string | null;             // JSON-encoded string[]

  artworkURL512: string | null;
  screenshotURLsJSON: string | null;     // JSON-encoded string[] of Apple CDN URLs
  ipadScreenshotURLsJSON: string | null;

  price: number | null;
  currency: string | null;
  formattedPrice: string | null;
  inAppPurchasesJSON: string | null;     // always null in v1 (phase-2 AMP fetch)

  averageUserRating: number | null;
  userRatingCount: number | null;
  averageUserRatingForCurrentVersion: number | null;
  userRatingCountForCurrentVersion: number | null;
  contentAdvisoryRating: string | null;
  languagesJSON: string | null;          // JSON-encoded string[]
  fileSizeBytes: number | null;
  minimumOSVersion: string | null;

  scrapeFailedAt: string | null;
  contentHash: string;
  firstSeenAt: string;
  lastSeenAt: string;
  fetchedAt: string;
}

/// One per-field change in the recentChanges timeline.
export interface MetadataChange {
  field: string;             // canonical column name, e.g. "subtitle", "version"
  from: string | null;       // prior value (stringified for transport)
  to: string | null;         // new value
  at: string;                // ISO 8601 — the firstSeenAt of the new row
}

/// One app's slice of the /compare response.
export interface CompareAppEntry {
  id: string;
  name: string;
  kind: WatchedAppKind;
  latest: AppMetadataSnapshot | null;    // null only on hard fetch failure
  recentChanges: MetadataChange[];
}

/// Response shape of GET /api/v1/compare.
export interface CompareResponse {
  country: string;
  fetchedAt: string;
  ownApp: CompareAppEntry | null;        // null if `own` was unknown id
  competitors: CompareAppEntry[];
}

/// Search hit returned by GET /api/v1/competitors/search.
/// `alreadyTracked` lets the UI gray out the "Add" button for apps
/// already in the watched_apps table; `existingKind` explains whether
/// it's already an own app or already a competitor.
export interface CompetitorSearchHit {
  appStoreId: number;
  name: string;
  iconURL: string | null;
  averageRating: number | null;
  ratingCount: number | null;
  alreadyTracked: boolean;
  existingKind: WatchedAppKind | null;
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

// How my app stands vs a competitor on a keyword. `score` drives the
// "most urgent first" sort — higher = act on it sooner. Mirrors the
// server's GapVerdict (Sources/App/Domain/DomainTypes.swift).
export interface GapVerdict {
  kind: 'behind' | 'ahead' | 'pureGap' | 'neither' | 'tied';
  score: number;
}

// One cell of the competitor gap matrix: my rank vs a single competitor's
// on a single tracked keyword. `myRank`/`competitorRank` are null when the
// app is outside the top 200 for that keyword.
export interface CompetitorGapRow {
  keywordId: string;
  term: string;
  countryCode: string;
  competitorAppId: string;
  competitorName: string;
  myRank: number | null;
  competitorRank: number | null;
  verdict: GapVerdict;
}

// Opportunity score for a tracked keyword (server: KeywordOpportunity).
// Present only for ASA-covered keywords — no fabricated popularity.
export interface KeywordOpportunity {
  keywordId: string;
  impressions: number;
  difficulty: number;
  opportunity: number;
}

// A metadata-optimizer finding for an app's listing (title + subtitle).
// Mirrors the server's LintFinding (Sources/App/Domain/DomainTypes.swift).
export interface LintFinding {
  rule: 'duplicateWord' | 'wastedBudget' | 'untrackedWord';
  severity: 'warning' | 'info';
  field: string;
  message: string;
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
