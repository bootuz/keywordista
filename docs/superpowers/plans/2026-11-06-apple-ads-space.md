# Apple Ads Space (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Apple Ads area (Overview, Keywords, Bid ideas, Setup) that reads Apple Ads data synced daily, and on demand, into Keywordista's own database.

**Architecture:** A sync service pulls campaign, keyword and search-term daily reports, popularity and keyword suggestions through the Phase 1 client, and writes them into ad-account-scoped mirror tables in one transaction. It runs outside the queue worker: a 04:30 UTC schedule plus a guarded "Sync now". Read services join the mirror with the existing rank history and serve four endpoints. The SPA gets an `/apple-ads/:tab?` page, and the existing suggestion and opportunity features read the mirror instead of calling Apple live.

**Tech Stack:** Swift 6.2 (Swift 5 mode), Vapor, Fluent (SQLite/Postgres), `AppleAdsClient` 1.109.0, Swift Testing; Svelte 5 + Tailwind.

**Spec:** `docs/superpowers/specs/2026-11-06-apple-ads-space-design.md`. Wire facts: `docs/superpowers/specs/2026-11-06-apple-ads-platform-api-v1-reference.md`.

**Branch:** `feat/apple-ads-space`, stacked on `feat/apple-ads-v1` (PR #60, not yet merged). The PR targets `feat/apple-ads-v1` until #60 merges.

## Global Constraints

- **Layering:** CLAUDE.md applies. Controllers stay slim and call services through protocols; services use repositories through protocols. Factories live in `Container.swift`. Tests use in-memory `actor` fakes and Swift Testing (`@Test`, `#expect`).
- **Reads only:** no write call ever reaches the user's Apple Ads account in this phase.
- **Queue:** `workerCount = 1` stays. The sync does not run on the queue worker.
- **Env vars:** no new ones, and no direct `Environment.get`.
- **Copy:** user-facing text says "Apple Ads", never "Search Ads" or "ASA", including strings that move.
- **Installs** means tap installs:
  - CPI = spend ÷ tap installs
  - CR = tap installs ÷ taps
  - CPT = spend ÷ taps
  - TTR = taps ÷ impressions
  - Total installs (tap + view) appears only as a labelled secondary column on Overview.
- **Thresholds:**
  - Low data: taps < 50 in the row's period.
  - "Already ranks well": organic rank 1–5 in the same country, from the latest rank check.
  - Wasted spend: taps ≥ 50 and tap installs == 0.
  - Converted: tap installs ≥ 1, and the term isn't already an exact-match bid keyword in any campaign (case-insensitive).
- **Dates:** report dates are the org's reporting-timezone day (`ORTZ`), stored as `yyyy-MM-dd` strings.
- **Mirror, not append-only:**
  - Each sync replaces its date window for the ad account.
  - The models say why, because this differs from `RankCheck`.
- **Sync windows:**
  - Backfill 90 days (today−89 … today) when there's no successful sync for the account, or the last one ended more than 7 days ago.
  - Otherwise re-pull the last 7 days (today−6 … today).
  - Daily schedule at 04:30 UTC.
- **Retention:**
  - Keep every synced day while connected.
  - On disconnect, delete every synced Apple Ads row.
  - When the ad account changes, delete the other accounts' rows.
  - Every synced row carries `ad_account_id`.
- **Server mode:**
  - The data and sync endpoints sit in the authenticated group, open to every member.
  - Setup stays under the admin-only `SettingsController`.
- **Commits:** imperative subject, 72 chars or fewer, no mention of AI or assistants.
- **SPA checks:** `svelte-check` must report 0 errors and 0 warnings.

## Review Focus

1. **Disconnect while a sync is running** → once the delete returns, no synced rows exist, and none reappear when the sync finishes. (Task 4 `disconnectDuringSyncLeavesNoData`.)
2. **A sync that fails partway** (e.g. the search-term report returns 500 after campaigns succeeded) → every previously synced row is unchanged, and the run is recorded as failed with readable copy. (Task 3 `failedSyncKeepsPreviousData`.)
3. **Apple revises a day inside the window** → re-syncing replaces that day's numbers instead of adding to them. (Task 3 `resyncReplacesRevisedDays`.)
4. **The same term tracked or bid in two countries** → each country's row shows that country's organic rank, never the other's. (Task 6 `organicRankMatchesCountry`.)
5. **The ad account also runs campaigns for an app the user doesn't watch** → none of those numbers enter the current app's totals; they're only counted in `otherAppsCampaignCount`. (Task 5 `otherAppsCampaignsExcluded`.)

---

### Task 1: Mirror tables and repository

**Files:**
- Create: `Sources/App/Models/AppleAdsMirror.swift`: Fluent models plus `CreateAppleAdsMirror` migration
- Create: `Sources/App/Repositories/AppleAdsDataRepository.swift`: protocol and Fluent implementation
- Create: `Sources/App/Domain/AppleAdsRecords.swift`: plain value types shared by the client, sync and read layers
- Modify: `Sources/App/configure.swift`: register the migration after `CreateAppMetadataSnapshot`
- Modify: `Tests/AppTests/Support/InMemoryRepositories.swift`: add `InMemoryAppleAdsDataRepository`
- Test: `Tests/AppTests/AppleAdsDataRepositoryTests.swift`, run against Fluent on in-memory SQLite

**Interfaces:**
- Produces, in `AppleAdsRecords.swift`. All are `Sendable, Equatable`; dates are `String` `yyyy-MM-dd`, and money is `Double` plus a `currency: String?`.
  - `struct AppleAdsMetrics { impressions, taps, tapInstalls, viewInstalls, totalInstalls: Int; spend: Double }` with `static let zero` and `+`.
  - `struct AppleAdsCampaignInfo { id: Int64; appStoreId: Int64; name: String; status: String; countries: [String]; dailyBudget: Double?; currency: String? }`
  - `struct AppleAdsKeywordInfo { id, campaignId, adGroupId: Int64; text, matchType, status: String; bid: Double?; currency: String? }`
  - `struct AppleAdsCampaignDay { campaignId: Int64; date: String; metrics: AppleAdsMetrics; currency: String? }`
  - `struct AppleAdsKeywordDay { keywordId, campaignId: Int64; country, date: String; metrics: AppleAdsMetrics; suggestedBid: Double? }`
  - `struct AppleAdsSearchTermDay { campaignId, adGroupId: Int64; keywordId: Int64?; term, source, country, date: String; metrics: AppleAdsMetrics }`. `term` is `"LOW_VOLUME"` when Apple sends none.
  - `struct AppleAdsTermPopularity { term, country, genre, week: String; popularity100: Int?; popularity5: Int?; rankInGenre: Int? }`. `term` is lowercased and `country` uppercased.
  - `struct AppleAdsKeywordIdea { appStoreId: Int64; country: String; text: String; popularity: Int? }`
  - `struct AppleAdsSnapshot { campaigns: [AppleAdsCampaignInfo]; keywords: [AppleAdsKeywordInfo]; campaignDays: [AppleAdsCampaignDay]; keywordDays: [AppleAdsKeywordDay]; searchTermDays: [AppleAdsSearchTermDay]; popularity: [AppleAdsTermPopularity]; ideas: [AppleAdsKeywordIdea] }`
  - `enum AppleAdsSyncTrigger: String, Codable { case scheduled, manual }`
  - `enum AppleAdsSyncOutcome: String, Codable { case running, succeeded, failed }`
  - `struct AppleAdsSyncRun: Content, Equatable { id: UUID; adAccountId: Int64?; trigger; outcome; startedAt: Date; finishedAt: Date?; fromDate: String?; toDate: String?; error: String? }`
- Produces `protocol AppleAdsDataRepositoryProtocol: Sendable`:
  - `func replace(adAccountId: Int64, from: String, to: String, with snapshot: AppleAdsSnapshot) async throws`. In one transaction it:
    - replaces all campaigns, keywords and ideas for the account;
    - deletes and reinserts the account's day rows with `from ≤ date ≤ to`;
    - upserts popularity by (term, country, genre, week).
  - `func purgeAll() async throws`: every mirror table and every sync run.
  - `func purge(exceptAdAccountId: Int64) async throws`
  - Read methods:
    - `campaigns(adAccountId:)`
    - `keywords(adAccountId:)`
    - `campaignDays(adAccountId:from:to:)`
    - `keywordDays(adAccountId:from:to:)`
    - `searchTermDays(adAccountId:from:to:)`
    - `popularity(terms: Set<String>, countries: Set<String>) -> [AppleAdsTermPopularity]`, latest week per (term, country)
    - `ideas(adAccountId:appStoreId:)`
    - `latestDate(adAccountId:) -> String?`
  - Sync runs:
    - `func startRun(trigger:) -> AppleAdsSyncRun`
    - `func finishRun(id: UUID, adAccountId: Int64?, outcome:, fromDate:, toDate:, error:) async throws`
    - `func latestRun() -> AppleAdsSyncRun?`
    - `func lastSuccessfulRun(adAccountId: Int64) -> AppleAdsSyncRun?`
- Tables:
  - `apple_ads_campaigns`, `apple_ads_keywords`, `apple_ads_keyword_ideas`
  - `apple_ads_campaign_days`, `apple_ads_keyword_days`, `apple_ads_search_term_days`
  - `apple_ads_term_popularity`, `apple_ads_sync_runs`
  - Countries are stored as comma-joined uppercase codes.

- [ ] **Step 1: Failing tests** (`AppleAdsDataRepositoryTests`):
  - `replaceSwapsOnlyTheWindow`: insert days 01–10, then replace 06–10 with new values; days 01–05 are unchanged and 06–10 equal the new values.
  - `replaceIsAtomic`: a snapshot whose second table insert violates a unique key throws, and every table still holds the pre-call rows.
  - `purgeExceptKeepsOnlyThatAccount`
  - `purgeAllRemovesRunsToo`
  - `popularityReturnsLatestWeekPerTermAndCountry`
  - `lastSuccessfulRunIgnoresFailedAndOtherAccounts`
- [ ] **Step 2:** `swift test --filter AppleAdsDataRepositoryTests` → FAIL (types missing).
- [ ] **Step 3:** Implement the models, the migration (with unique indexes on each day table's natural key, which includes `ad_account_id`), the Fluent repository and the in-memory fake.
- [ ] **Step 4:** Run → PASS; full `swift test` → PASS.
- [ ] **Step 5:** Commit `Add Apple Ads mirror tables and repository`.

### Task 2: Reporting reads on the v1 client

**Files:**
- Create: `Sources/App/Clients/AppleAds/AppleAdsReportingClient.swift`: protocol plus an `AppleAdsPlatformClient` extension
- Create: `Sources/App/Domain/AppleAdsGenre.swift`
- Test: `Tests/AppTests/AppleAdsReportingClientTests.swift`, using the stub transport from `Tests/AppTests/Support/AppleAdsTestSupport.swift`

**Interfaces:**
- Consumes: from Phase 1, `AppleAdsPlatformClient` and its `call` mapping, `resolveAdAccountId()`, `AppleAdsError`. From Task 1, the record types.
- Produces `protocol AppleAdsReportingClientProtocol: Sendable`, which `AppleAdsPlatformClient` conforms to:
  - `func resolveAdAccountId() async throws -> Int64`
  - `func campaignInfos() async throws -> [AppleAdsCampaignInfo]`: same query as `listCampaigns`, adding `promotedObjectId` and `dailyBudgetAmount` to the tolerant decoder.
  - `func keywords(campaignId: Int64) async throws -> [AppleAdsKeywordInfo]`: `postKeywordsQuery`, filtered on `campaignId`, paginated.
  - `func campaignDays(campaignIds: [Int64], from: String, to: String) async throws -> [AppleAdsCampaignDay]`: `appsCampaignReports`, `DAILY`, `ORTZ`, one row per `granularMetrics` entry.
  - `func keywordDays(campaignId: Int64, from: String, to: String) async throws -> [AppleAdsKeywordDay]`: `appsKeywordReports`, `groupBy ["countryOrRegion"]`, `DAILY`, `ORTZ`. `suggestedBid` comes from `insights.bidRecommendation.suggestedBidAmount`.
  - `func searchTermDays(campaignId: Int64, from: String, to: String) async throws -> [AppleAdsSearchTermDay]`: `appsSearchTermReports`, `groupBy ["countryOrRegion"]`, `DAILY`, `ORTZ`. A null term becomes `LOW_VOLUME`.
  - `func termPopularity(terms: [String], country: String, genre: String) async throws -> [AppleAdsTermPopularity]`: `searchTermPopularityQuery`, `WEEKLY`, covering the last 3 weeks, with filters `searchTerm IN`, `countryOrRegion EQUALS` and `genre EQUALS`. Batches of at most 100 terms.
  - `func keywordIdeas(appStoreId: Int64, country: String) async throws -> [AppleAdsKeywordIdea]`: `queryKeywordSuggestions`, with `promotedObjectId`, `promotedObjectType APPSTORE_APP` and `countriesOrRegions`.
- Produces `enum AppleAdsGenre { static func forITunesGenreId(_ id: Int?) -> String? }`. It maps iTunes primary genre IDs to the genre values the popularity endpoint accepts. Read those values from Apple's page `query-app-search-term-popularity-data`. If a value can't be confirmed, return nil for that ID, which skips popularity for it.

- [ ] **Step 1: Failing tests:**
  - `campaignInfosMapsAppAndBudget`: `promotedObjectId` maps to `appStoreId`, and a budget of `"12.50"` maps to 12.5.
  - `keywordsPaginates`
  - `campaignDaysExplodesGranularRows`: one row with 3 dated granular metrics yields 3 days.
  - `keywordDaysCarriesCountryAndSuggestedBid`: the request body has `groupBy` `countryOrRegion`, `ORTZ` and `DAILY`.
  - `searchTermDaysNullTermIsLowVolume`
  - `popularityBatchesAndFilters`: 150 terms make 2 requests, and the filters include `searchTerm`, `countryOrRegion` and `genre`.
  - `keywordIdeasSendsAppAndCountry`
  - `unknownGenreIsNil`
- [ ] **Step 2:** Run `swift test --filter AppleAdsReportingClientTests` → FAIL.
- [ ] **Step 3:** Implement against the generated `Operations.*` types. Do not redeclare wire types. Every call goes through the existing `call` so errors stay `AppleAdsError`.
- [ ] **Step 4:** Run → PASS; full suite → PASS.
- [ ] **Step 5:** Commit `Read Apple Ads reports, popularity and suggestions`.

### Task 3: Sync service

**Files:**
- Create: `Sources/App/Services/AppleAdsSyncService.swift`
- Test: `Tests/AppTests/AppleAdsSyncServiceTests.swift`. Uses a scripted fake `AppleAdsReportingClientProtocol` plus `InMemoryAppleAdsDataRepository`.

**Interfaces:**
- Consumes:
  - Task 1's repository and records.
  - Task 2's `AppleAdsReportingClientProtocol`.
  - `SettingsServiceProtocol.getASACredentials()`.
  - `WatchedAppRepositoryProtocol`, for own apps and `primaryGenreId`.
  - `KeywordRepositoryProtocol`, for tracked terms and countries.
- Produces `protocol AppleAdsSyncServiceProtocol: Sendable { func sync(trigger: AppleAdsSyncTrigger) async throws -> AppleAdsSyncRun }`. Its init takes `settings:`, `repository:`, `watchedApps:`, `keywords:`, `makeClient: @Sendable (ASACredentials) -> any AppleAdsReportingClientProtocol`, `today: @Sendable () -> String`, and `logger:`.
- Behaviour:
  1. No credentials → return without recording a run. `sync` then throws `AppleAdsError.notConnected`; add that case, with copy "Connect Apple Ads first".
  2. Start a run. Resolve the ad account. If that fails, finish the run as `failed` with the error's description and rethrow.
  3. `purge(exceptAdAccountId:)`.
  4. Choose the window: 90 days or 7, by the Global Constraints rule.
  5. Fetch everything into an `AppleAdsSnapshot` in memory:
     - campaigns;
     - per campaign: keywords, keyword days and search-term days;
     - campaign days for all campaigns.
  6. Popularity and ideas are best-effort: on failure, log and continue.
     - **Popularity** covers bid keyword texts, tracked terms, converted search terms and idea texts. It runs per country of the campaigns and the app's genre from `AppleAdsGenre`.
     - **Ideas** run for each own watched app that has a campaign, for each of that campaign's countries.
  7. `replace(...)` once, then finish the run as `succeeded`.
  8. Any error in step 5 or 7 finishes the run as `failed` with `AppleAdsError.from(error).description` and doesn't write the snapshot.

- [ ] **Step 1: Failing tests:**
  - `firstSyncBackfills90Days`: the requested `from` is today−89.
  - `recentSyncPullsLast7Days`
  - `staleSyncBackfills90Days`: the last success ended 8 days ago.
  - `resyncReplacesRevisedDays`: a day's taps go from 10 to 12 and the stored value is 12, not 22.
  - `failedSyncKeepsPreviousData`: the search-term report throws `.http(500)`; prior rows are unchanged, and the run is `failed` with readable copy.
  - `popularityFailureDoesNotFailSync`
  - `accountSwitchPurgesOtherAccount`
  - `noCredentialsRecordsNoRun`
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS; full suite → PASS.
- [ ] **Step 5:** Commit `Sync Apple Ads data into the local mirror`.

### Task 4: Scheduling, Sync now, and purge on disconnect

**Files:**
- Create: `Sources/App/Services/AppleAdsSyncCoordinator.swift`. An actor on `Application`, created in `configure.swift` like `appleAdsSession`.
- Create: `Sources/App/Jobs/AppleAdsSyncScheduler.swift` (`AsyncScheduledJob`)
- Create: `Sources/App/Controllers/AppleAdsController.swift`
- Modify:
  - `Sources/App/Composition/Container.swift`: factories `appleAdsSyncService()`, `appleAdsDataRepository()`, and `Application.appleAdsSyncCoordinator`.
  - `Sources/App/configure.swift`: schedule `.daily().at("4:30am")` and add a comment on the 04:30 slot.
  - `Sources/App/routes.swift`: register `AppleAdsController` bare in local mode and in the `authenticated` group in server mode.
  - `Sources/App/Controllers/SettingsController.swift`:
    - `deleteASA`: cancel the coordinator, then `purgeAll()`, then shut down the session.
    - `putASA`: when the resulting `adAccountId` or `clientId` differs from the stored one, cancel and `purgeAll()`.
- Test: `Tests/AppTests/AppleAdsSyncControllerTests.swift`

**Interfaces:**
- Consumes: Task 3 `AppleAdsSyncServiceProtocol`; Task 1 repository.
- Produces:
  - `actor AppleAdsSyncCoordinator`:
    - `init(makeService: @Sendable () -> any AppleAdsSyncServiceProtocol)`
    - `func start(trigger:) async -> Bool`: false if a sync is already running.
    - `func runNow(trigger:) async`: awaits; used by the scheduler.
    - `func cancelAndWait() async`
    - `var isRunning: Bool`
  - `struct AppleAdsSyncStatus: Content { running: Bool; lastRun: AppleAdsSyncRun?; lastSuccessAt: Date? }`
  - `POST /api/v1/apple-ads/sync` → 202 with `AppleAdsSyncStatus`; 409 "Connect Apple Ads first" without credentials.
  - `GET /api/v1/apple-ads/sync-status` → `AppleAdsSyncStatus`.

- [ ] **Step 1: Failing tests:**
  - `syncNowReturns202AndRunsOnce`: two POSTs in a row start one sync.
  - `syncStatusReportsRunningThenFinished`
  - `syncWithoutCredentialsIs409`
  - `disconnectDuringSyncLeavesNoData`: the fake client blocks on a continuation. DELETE returns while the sync is mid-fetch, the client is released, and all mirror reads are then empty and no run exists.
  - `changingClientIdPurgesMirror`
  - `serverModeMemberCanSync`: uses the server-mode route registration with a non-admin session. Follow the existing auth integration tests.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. The scheduler calls `runNow(trigger: .scheduled)`, and errors are logged only. **Step 4:** Run → PASS; full suite → PASS.
- [ ] **Step 5:** Commit `Schedule Apple Ads sync and add Sync now`.

### Task 5: Metrics math and the Overview endpoint

**Files:**
- Create: `Sources/App/Domain/AppleAdsMath.swift`
- Create: `Sources/App/Services/AppleAdsInsightsService.swift`: holds Overview, Keywords and Bid ideas; Tasks 6 and 7 add to it.
- Modify: `AppleAdsController.swift` (`GET /apple-ads/overview`), `Container.swift`
- Test: `Tests/AppTests/AppleAdsMathTests.swift`, `Tests/AppTests/AppleAdsInsightsServiceTests.swift`

**Interfaces:**
- Produces:
  - `struct AppleAdsMetricsDTO: Content, Equatable { impressions, taps, tapInstalls, totalInstalls: Int; spend: Double; cpt: Double?; cpi: Double?; ttr: Double?; cr: Double?; lowData: Bool }`.
  - `AppleAdsMath.dto(_ m: AppleAdsMetrics) -> AppleAdsMetricsDTO`. A ratio is nil when its denominator is 0, and `lowData` is `taps < 50`.
  - `AppleAdsMath.periods(endingAt: String, days: Int) -> (current: ClosedRange<String>, previous: ClosedRange<String>)`
  - `protocol AppleAdsInsightsServiceProtocol: Sendable` with `func overview(watchedAppId: UUID, days: Int) async throws -> AppleAdsOverviewDTO`
  - `AppleAdsOverviewDTO`:
    - `currency: String?`
    - `from`, `to`, `previousFrom`, `previousTo: String`
    - `totals`, `previousTotals: AppleAdsMetricsDTO`
    - `campaigns: [{ id: String; name; status; metrics; previous }]`
    - `daily: [{ date; spend: Double; tapInstalls: Int }]`
    - `otherAppsCampaignCount: Int`
    - `lastSync: AppleAdsSyncStatus`
  - IDs go out as strings.
  - The period ends at `latestDate(adAccountId:)`, falling back to today. `days` must be 7 or 30, otherwise 400.
  - The ad account comes from the last successful run. With none, return an empty overview carrying `lastSync`.
  - `GET /api/v1/apple-ads/overview?appId=<WatchedApp UUID>&days=7|30`; 409 without credentials.

- [ ] **Step 1: Failing tests:**
  - `dtoComputesRatiosFromTapInstalls`: 200 taps, 10 tap installs, 5 view installs and $50 spend give CPI 5.0, CR 0.05, CPT 0.25 and `totalInstalls` 15.
  - `dtoMarksLowDataBelow50Taps`
  - `zeroDenominatorsAreNil`
  - `periodsAreContiguous`
  - `overviewSumsCurrentAndPreviousPeriods`
  - `otherAppsCampaignsExcluded`
  - `overviewWithoutSyncIsEmptyWithStatus`
  - `daysMustBe7Or30`
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS; full suite → PASS.
- [ ] **Step 5:** Commit `Add the Apple Ads overview`.

### Task 6: Keywords endpoint (paid next to organic)

**Files:**
- Modify: `AppleAdsInsightsService.swift`, `AppleAdsController.swift` (`GET /apple-ads/keywords`)
- Test: `Tests/AppTests/AppleAdsInsightsServiceTests.swift`

**Interfaces:**
- Consumes: `KeywordRepositoryProtocol` and `RankCheckRepositoryProtocol.latest(keywordID:watchedAppID:)`.
- Produces `func keywords(watchedAppId: UUID, days: Int) async throws -> [AppleAdsKeywordRowDTO]`. Each row:
  - `keywordId: String`, `text`, `matchType`, `status`, `campaignName`, `country`
  - `bid: Double?`, `suggestedBid: Double?`
  - `metrics: AppleAdsMetricsDTO`
  - `organicRank: Int?`, `trackedKeywordId: UUID?`, `alreadyRanksWell: Bool`
- Rows are one per (keyword, country) with metrics summed over the period. Only campaigns for the watched app are included. They're sorted by spend descending.
- Organic rank matches a tracked keyword when the term is the same (case-insensitive) and the country is the same.
- `alreadyRanksWell` is true when the organic rank is 1–5.

- [ ] **Step 1: Failing tests:**
  - `keywordRowsSumPeriodPerCountry`
  - `organicRankMatchesCountry`: "flashcards" is tracked in US at rank 3 and in DE at rank 40. The US row shows 3 with `alreadyRanksWell`; the DE row shows 40 without it.
  - `untrackedKeywordHasNoRank`
  - `suggestedBidIsLatestDays`: the most recent non-nil value in the period.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS; full suite → PASS.
- [ ] **Step 5:** Commit `Show Apple Ads keywords next to organic rank`.

### Task 7: Bid ideas, and existing features read the mirror

**Files:**
- Modify: `AppleAdsInsightsService.swift`, `AppleAdsController.swift` (`GET /apple-ads/bid-ideas`)
- Modify: `Sources/App/Services/KeywordSuggestionService.swift` and `KeywordPopularityService.swift`:
  - take `AppleAdsDataRepositoryProtocol` instead of `makeClient`;
  - sum the seed country's search-term rows over the last 30 days;
  - drop the "all reports failed" rethrow.
- Modify: `Container.swift`
- Modify: their tests. Delete `AppleSearchAdsClientProtocol`, `ASACampaign`, `listCampaigns` and `searchTermsReport` if nothing references them any more.
- Test: `Tests/AppTests/AppleAdsInsightsServiceTests.swift` and the two existing service test files.

**Interfaces:**
- Produces `func bidIdeas(watchedAppId: UUID, days: Int) async throws -> AppleAdsBidIdeasDTO`, where `AppleAdsBidIdeasDTO { converted: [IdeaDTO]; suggestions: [IdeaDTO]; wasted: [IdeaDTO] }`. Each `IdeaDTO` has:
  - `term`, `country`
  - `metrics: AppleAdsMetricsDTO?`
  - `popularity: Int?`, the 1–100 value
  - `organicRank: Int?`, `difficulty: Int?`, `trackedKeywordId: UUID?`
- How each list is built:
  - **converted:** aggregate per (term, country), excluding `LOW_VOLUME`; sort by tap installs descending.
  - **wasted:** sort by spend descending.
  - **suggestions:** the app's ideas, minus any already bid.
  - `difficulty` comes from the latest rank check when the term is tracked.
- New behaviour shared by both services:
  - Credentials but no successful sync, and the latest run failed → throw `AppleAdsError.syncFailed(String)` (new case; copy: "The last Apple Ads sync failed: <reason>").
  - No run at all → empty result.
- The suggestions endpoint `/keywords/:id/suggestions` keeps its response shape.

- [ ] **Step 1: Failing tests:**
  - `convertedExcludesExactBidTerms`: "flashcards app" with 2 installs, and "flashcards" with 3 installs that is an exact bid → only "flashcards app".
  - `wastedNeeds50TapsAndZeroInstalls`: 49 taps → absent; 50 taps → present.
  - `ideasCarryPopularityRankAndDifficulty`
  - `suggestionsExcludeBidKeywords`
  - `suggestionServiceReadsMirror`
  - `popularityServiceReadsMirror`
  - `failedLastSyncWithoutDataThrowsSyncFailed`
  - Existing suggestion and popularity behaviour tests adapted to seed the mirror instead of a stub client. Their assertions stay unchanged.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS; full suite → PASS.
- [ ] **Step 5:** Commit `Add Apple Ads bid ideas and read suggestions from the mirror`.

### Task 8: The Apple Ads area in the SPA

**Files:**
- Create in `web/src/components/` (flat):
  - `AppleAdsPage.svelte`: tabs, plus a sync chip that polls `sync-status` every 2 s while running and reloads the tab when done.
  - `AppleAdsOverview.svelte`
  - `AppleAdsKeywords.svelte`
  - `AppleAdsBidIdeas.svelte`: three lists, plus a "Related to a keyword" picker over tracked keywords that calls the existing suggestions endpoint.
  - `AppleAdsSetup.svelte`: the credentials form and account picker moved from `SettingsPanel`, plus sync status, the last error and **Sync now**.
  - `AppleAdsTrend.svelte`: hand-rolled SVG of daily spend and tap installs.
- Modify:
  - `web/src/lib/router.ts`: `'/apple-ads/:tab?'`, plus `ROUTES.appleAds`.
  - `web/src/components/Sidebar.svelte`: an "Apple Ads" entry with an icon.
  - `web/src/lib/api.ts`, `web/src/lib/types.ts`: DTOs from Tasks 4–7.
  - `web/src/components/SettingsPanel.svelte`: the Apple Ads section becomes one line linking to `#/apple-ads/setup`.
  - `web/src/components/HistoryPanel.svelte`: the Related tab keeps working; its copy says "Apple Ads".
- Tabs: `overview` (default), `keywords`, `ideas`, `setup`.
- Every tab except Setup shows an empty state linking to Setup when Apple Ads isn't connected (409), and a "Sync now" prompt when nothing has synced.
- Low-data cells render the number muted, with a "not enough data" tooltip; they're never hidden.
- Overview shows a one-line notice when the last sync failed, with the time of the last good sync. It also shows "N campaigns for apps you don't watch aren't included" when `otherAppsCampaignCount > 0`, and total installs as a labelled secondary column.
- The "Track" button calls the existing `addKeyword(term, country)`.
- Setup's form fields stay admin-only, through `canMutateSettings`.

- [ ] **Step 1:** Implement, then run `cd web && npm run check && npm run build` → 0 errors and 0 warnings; build OK.
- [ ] **Step 2: Browser check.**
  - Start `make dev-backend` and `make dev-web` with a scratch data dir (no Apple Ads credentials). In the built-in browser, open `http://localhost:5173/#/apple-ads`.
  - Confirm the sidebar entry, all four tabs, each empty state, and that Setup renders the credentials form. Confirm Settings shows the link instead of the old section.
  - Take a screenshot of each tab. Stop the servers and delete the scratch data dir afterwards.
- [ ] **Step 3:** Commit `Add the Apple Ads area`.

### Task 9: Docs and final verification

**Files:** `CLAUDE.md` (Apple Ads section), `README.md` (API table).
- CLAUDE.md gets:
  - the mirror tables and the "mirror, not append-only" rule;
  - the 04:30 sync outside the worker;
  - retention and purge;
  - the insights endpoints.
- README gets four rows: `GET /apple-ads/overview|keywords|bid-ideas` and `POST /apple-ads/sync` plus `GET /apple-ads/sync-status`.

- [ ] **Step 1:** Update the docs.
- [ ] **Step 2:** Run every CI check, all green, and delete any private build output:
  - `swift test`
  - `cd web && npm run check && npm run build`
  - `cd mac && swift build && swift test`
  - `./scripts/check-env-manifest.sh`
- [ ] **Step 3:** Commit `Document the Apple Ads area`.
- [ ] **Step 4:** Push `feat/apple-ads-space` and open a PR against `feat/apple-ads-v1`.
  - The description includes the screenshots.
  - It says nothing was verified against a live Apple Ads account, and lists the spec's three open questions.
