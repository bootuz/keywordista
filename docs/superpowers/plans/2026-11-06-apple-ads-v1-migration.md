# Apple Ads Platform API v1 Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hand-rolled Apple Search Ads Campaign Management API v5 client (retired by Apple on 2027-01-26) with Apple's official `AppleAdsClient` Swift package on Platform API v1, keeping keyword suggestions and the opportunity score working, and add ad-account selection.

**Architecture:** The consumer-facing seam `AppleSearchAdsClientProtocol` (`listCampaigns()`, `searchTermsReport(campaignId:startDate:endDate:)`) stays byte-for-byte the same, so `KeywordSuggestionService`, `KeywordPopularityService`, `OpportunityService` and their tests don't change. Behind it, a new adapter `AppleAdsPlatformClient` calls the generated v1 operations through a process-wide `AppleAdsSession` actor that owns one long-lived `AppleAdsClient` per credential set (run under a `ServiceGroup`, shut down gracefully on credential change and app shutdown). Adopting the package forces macOS 15 + Swift 6.2, so the server/menubar floor and toolchains move too, and server releases move to a new tag prefix so macOS 13/14 installs are never offered a binary they can't launch.

**Tech Stack:** Swift 6.2 toolchain (Swift 5 language mode), Vapor 4, `apple/apple-ads-platform-api-swift` 1.109.0 (`AppleAdsClient`, swift-openapi-runtime, swift-service-lifecycle), Swift Testing; Svelte 5 SPA; XCTest for `mac/`.

**Spec:** No separate design doc — the user opted out of brainstorming ("dive in") and chose (a) migrate to v1, (b) use `apple/apple-ads-platform-api-swift`, (c) require macOS 15. Wire-level facts: `docs/superpowers/specs/2026-11-06-apple-ads-platform-api-v1-reference.md` (cited below as REF §n). Phases 2 (Apple Ads space in the SPA) and 3 (guarded operations) get their own plans after this lands — see the end of this file.

## Global Constraints

- Package: `.package(url: "https://github.com/apple/apple-ads-platform-api-swift", exact: "1.109.0")`, product `AppleAdsClient`. Pin exact: it's generated from a moving spec.
- Platform floor: `.macOS(.v15)` in root `Package.swift` and `mac/Package.swift`; `LSMinimumSystemVersion` `15.0`.
- Toolchain: root manifest `// swift-tools-version:6.2` with `swiftLanguageModes: [.v5]` (no Swift 6 language-mode migration in this plan). Docker `swift:6.2-jammy` / `swift:6.2-jammy-slim`.
- Server release tags move from `service-v*` to `server-v*`. The menubar updater accepts only `server-v*`. Never re-tag `service-v*` after this lands.
- v1 context header: `XApContext(adAccountID:)` from the package; never hand-format it.
- Search-terms report: `timeZone` `ORTZ`, `granularity` `DAILY`, window 30 days, `pageSize` 5000 (REF §7.3). Campaign query `pageSize` 1000 with `fetchTotalCount: true` (REF §3.1).
- Apple's privacy-suppressed search terms are represented to consumers as the literal text `LOW_VOLUME` (existing consumer contract).
- Secrets stay in `SecretEnvelope` via `SettingsService`; ad-account ID is not a secret.
- No mention of Claude/AI in commits or PR text (project rule). CI must stay green: `swift test`, `cd web && npm run check && npm run build`, `cd mac && swift build && swift test`, `./scripts/check-env-manifest.sh`, Docker image-size gate.

## Review Focus

1. **Several ad accounts, none matching the stored v5 org ID** → a typed `adAccountSelectionRequired` error carrying the account list, surfaced to the UI as "pick an ad account" — never silently the first one. (Task 5 test `resolvesAmbiguousAccountsAsSelectionRequired`.)
2. **New campaign with no report data** (`result` is `{}` / no `rows`) → empty array, no throw. (Task 5 test `emptyReportYieldsNoRows`.)
3. **Search-term rows with null `searchTermText`** → counted under `LOW_VOLUME`, not dropped and not crashing. (Task 5 test `nullSearchTermTextMapsToLowVolume`.)
4. **Credentials edited in Settings while a client is alive** → next call uses the new credentials; old client shut down without an AsyncHTTPClient deinit crash. (Task 3 test `changedCredentialsReplaceAndShutDownClient`.)
5. **HTTP 429 from Apple** → retried after `Retry-After` (max 3 attempts, ≤16 s each) on reads and `/query` POSTs only; a response body Apple's spec doesn't match (e.g. an ID as string) → a readable "Apple Ads returned data Keywordista couldn't read" error, not a 500 with a decoding dump. (Task 5 tests `retriesQueryOn429ThenSucceeds`, `decodeFailureIsReadable`.)

---

### Task 1: Toolchain, platform floor, and dependency

**Files:**
- Modify: `Package.swift` (tools version, platforms, `swiftLanguageModes`, add package + product to `App`)
- Modify: `mac/Package.swift` (tools `6.2`, `.macOS(.v15)`, `swiftLanguageModes: [.v5]`)
- Modify: `mac/Resources/Info.plist` (`LSMinimumSystemVersion` → `15.0`)
- Modify: `Dockerfile` (both `swift:6.1-jammy*` → `swift:6.2-jammy*`, header comment)
- Modify: `.github/workflows/ci.yml`, `release-service.yml`, `release-app.yml` (select an Xcode whose Swift is ≥ 6.2 on `macos-15` runners, e.g. a `sudo xcode-select -s /Applications/Xcode_26*.app` step guarded by a `swift --version` print; ubuntu jobs that build Swift use `swift:6.2`)
- Modify: `README.md` (macOS badge 15+, "Swift 6.2+" build-from-source line), `CLAUDE.md` (toolchain line)

**Interfaces:**
- Produces: `import AppleAdsClient` compiles in the `App` target on macOS and Linux.

- [ ] **Step 1:** Edit manifests/plist/Dockerfile/workflows as listed. Keep existing `swiftSettings` on `App`.
- [ ] **Step 2:** Run `swift build 2>&1 | tail -5` → `Build complete!`; `swift test 2>&1 | tail -3` → all pass (same count as `main`).
- [ ] **Step 3:** Run `cd mac && swift build && swift test` → pass.
- [ ] **Step 4:** Run `make docker-build` then the CI size check from `ci.yml` locally (`docker image inspect keywordista:dev --format '{{.Size}}'` vs the ceiling in `ci.yml`). Record before/after MB in the PR description. If over the ceiling, stop and report — do not raise the ceiling silently.
- [ ] **Step 5:** Commit `Require macOS 15 and Swift 6.2 for the Apple Ads client`.

### Task 2: Move server releases to the `server-v*` channel

**Files:**
- Modify: `mac/Sources/Keywordista/UpdateChecker.swift` (`pickLatestStableRelease`: prefix `server-v`)
- Modify: `.github/workflows/release-service.yml` (trigger `server-v*`; asset/release naming), `.github/RELEASING.md`, `docs/env-vars.md` or README sections that name `service-v*`
- Test: `mac/Tests/KeywordistaTests/UpdateCheckerPreReleaseTests.swift`

**Interfaces:**
- Produces: `UpdateChecker.serverTagPrefix = "server-v"` (`nonisolated static let`).

- [ ] **Step 1: Write failing tests** in `UpdateCheckerPreReleaseTests`:
  - `testPicksServerChannelTag`: releases `[server-v0.8.0]` → picks `0.8.0`.
  - `testIgnoresLegacyServiceChannel`: releases `[service-v0.9.0, server-v0.8.0]` → picks `0.8.0` (legacy macOS-13 channel is never offered to new apps).
  - Update existing fixtures from `service-v` to `server-v`.
- [ ] **Step 2:** `cd mac && swift test --filter UpdateCheckerPreReleaseTests` → the two new tests FAIL.
- [ ] **Step 3:** Implement the prefix change; update the release workflow trigger and docs. Comment the *why*: old menubar builds (macOS 13+) poll `service-v*` and would install a macOS-15-only binary that can't launch.
- [ ] **Step 4:** Re-run → PASS; full `swift test` in `mac/` → pass.
- [ ] **Step 5:** Commit `Publish server releases on a server-v channel`.

### Task 3: `AppleAdsSession` — long-lived client ownership

**Files:**
- Create: `Sources/App/Clients/AppleAds/AppleAdsSession.swift`
- Create: `Sources/App/Clients/AppleAds/StoredClientSecretProvider.swift`
- Modify: `Sources/App/Composition/Container.swift` (replace `asaTokenCache` storage with `appleAdsSession`), `Sources/App/configure.swift` (register a `LifecycleHandler` that calls `shutdown()`)
- Test: `Tests/AppTests/AppleAdsSessionTests.swift`

**Interfaces:**
- Consumes: `ASACredentials` (Task 4 adds `adAccountId`; fingerprint uses `clientId` + `clientSecret` only).
- Produces:
  - `struct StoredClientSecretProvider: ClientSecretProvider` — returns the stored JWT verbatim (existing users' pasted secret).
  - `actor AppleAdsSession` with
    `init(makeClient: @escaping @Sendable (ASACredentials) async throws -> AppleAdsClient)`,
    `func client(for credentials: ASACredentials) async throws -> Client` (generated `Client`),
    `func shutdown() async`.
  - Production factory `AppleAdsSession.live(logger:)` builds `AppleAdsClient(configuration: .init(clientId:, authMode: .clientSecretProvider(StoredClientSecretProvider(...))))` and runs it in a `ServiceGroup(services: [client], gracefulShutdownSignals: [], logger:)` inside a stored `Task`; replacement/shutdown calls `triggerGracefulShutdown()` and awaits the task.

- [ ] **Step 1: Write failing tests** (factory builds clients with `.tokenProvider(StaticTokenProvider("t"))` + a stub `ClientTransport`, and counts calls):
  - `reusesClientForSameCredentials`: two `client(for:)` calls, same creds → factory called once.
  - `changedCredentialsReplaceAndShutDownClient`: creds A then B → factory called twice; A's service group observed shut down (expose a test hook: the session records shutdown completions).
  - `shutdownIsIdempotent`: `shutdown()` twice → no throw, no crash.
- [ ] **Step 2:** `swift test --filter AppleAdsSessionTests` → FAIL (types missing).
- [ ] **Step 3:** Implement. Concurrent first calls for the same creds must share one in-flight construction (store the creation `Task`, like `CachingTokenProvider.refresh()`).
- [ ] **Step 4:** Tests PASS; `swift test` → pass.
- [ ] **Step 5:** Commit `Own the Apple Ads client in a long-lived session`.

### Task 4: Ad-account ID in credentials and settings

**Files:**
- Modify: `Sources/App/Services/SettingsService.swift` (`ASACredentials.adAccountId: String?`, key `asa.adAccountId` in `Keys.asa`, `ASAStatus.adAccountId`)
- Modify: `Sources/App/Controllers/SettingsController.swift` (`ASAUpdatePayload.adAccountId: String?`)
- Modify: `Tests/AppTests/Support/InMemorySettingsRepository.swift` only if needed; update call sites constructing `ASACredentials(...)` in tests
- Test: `Tests/AppTests/SettingsServiceASATests.swift` (new)

**Interfaces:**
- Produces: `ASACredentials(clientId:clientSecret:orgId:adAccountId:)` (`adAccountId` defaults to `nil` so existing call sites compile); `ASAStatus.adAccountId: String?`.

- [ ] **Step 1: Failing tests:** `adAccountIdRoundTrips` (set with `"123"`, get returns `"123"`, stored plaintext — not enveloped); `clearingRemovesAdAccountId`; `statusExposesAdAccountId`; PUT without `adAccountId` keeps the stored one (mirror the existing keep-secret behavior).
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS, full suite green.
- [ ] **Step 5:** Commit `Store the Apple Ads ad account ID`.

### Task 5: `AppleAdsPlatformClient` — v1 adapter behind the existing protocol

**Files:**
- Create: `Sources/App/Clients/AppleAds/AppleAdsPlatformClient.swift`
- Create: `Sources/App/Clients/AppleAds/AppleAdsRetryMiddleware.swift`
- Create: `Sources/App/Clients/AppleAds/AppleAdsError.swift`
- Delete: `Sources/App/Clients/AppleSearchAdsClient.swift` (keep `AppleSearchAdsClientProtocol`, `ASACampaign`, `ASASearchTerm` by moving them into `AppleAdsPlatformClient.swift` unchanged)
- Modify: `Sources/App/Composition/Container.swift` (`makeClient` closures for suggestion + popularity services return `AppleAdsPlatformClient(credentials:session:logger:)`)
- Delete/replace: `Tests/AppTests/AppleSearchAdsClientTests.swift` → `Tests/AppTests/AppleAdsPlatformClientTests.swift` (stub `ClientTransport` returning canned JSON from REF examples; static token provider)

**Interfaces:**
- Consumes: `AppleAdsSession.client(for:)` (Task 3), `ASACredentials.adAccountId` (Task 4).
- Produces:
  - `struct ASAAdAccount: Content, Equatable { let id: String; let name: String; let orgId: String; let roles: [String] }`
  - `struct AppleAdsPlatformClient: AppleSearchAdsClientProtocol` with `init(credentials: ASACredentials, session: AppleAdsSession, logger: Logger)`, plus `func listAdAccounts() async throws -> [ASAAdAccount]` (`getUserAcls`, no context header) and `func resolveAdAccountId() async throws -> Int64`.
  - `enum AppleAdsError: Error, CustomStringConvertible { case unauthorized, forbidden, rateLimited, adAccountSelectionRequired([ASAAdAccount]), unreadableResponse(String), http(status: Int, message: String) }` — messages are user-facing copy for the settings panel.
  - Account resolution: explicit `adAccountId` → use it; else ACLs: exactly one account → it; else the one whose `orgId == credentials.orgId` → it; else throw `.adAccountSelectionRequired(accounts)`. Cache the resolved ID in-process per `clientId` (no persistence — Phase 2's setup UI persists the user's choice).
  - `listCampaigns()`: `postCampaignsQuery` with filter `promotedObjectType EQUALS APPSTORE_APP`, paginate until `offset + pageSize >= totalCount`; map `id`, `name`, `targeting.countryOrRegion.include` (uppercased), `displayStatus`.
  - `searchTermsReport(...)`: `appsSearchTermReports` with filter `campaignId EQUALS <id>`, `timeRange` (`start`/`end` as `yyyy-MM-dd` in UTC from the given dates, `ORTZ`, `DAILY`), no `groupBy`, paginate `pageSize` 5000; map each row → `ASASearchTerm(text: metadata.searchTermText ?? "LOW_VOLUME", source: metadata.searchTermSource ?? "AUTO", impressions:, taps:, ttr:, localSpend: Double(localSpend.amount) ?? 0)` from `totalMetrics`, treating absent metrics as 0.
  - `AppleAdsRetryMiddleware: ClientMiddleware` — on 429 for GET or paths ending `/query`: wait `Retry-After` seconds (default 2, doubling, cap 16), max 3 attempts. Injected via `Configuration.middleware` in `AppleAdsSession.live`.

- [ ] **Step 1: Failing tests** (`AppleAdsPlatformClientTests`):
  - `listCampaignsPaginatesAndMapsCountries` (two pages: 1000 + 1 rows, totalCount 1001 → 1001 campaigns; `["us"]` → `["US"]`).
  - `campaignQuerySendsAdAccountContextHeader` (`X-AP-Context` equals `XApContext(adAccountID: 42).rawValue`).
  - `searchTermsReportMapsRowsAndSendsCampaignFilter` (asserts request body has `campaignId` filter, `ORTZ`, `DAILY`, 30-day dates; row fields mapped).
  - `nullSearchTermTextMapsToLowVolume`, `emptyReportYieldsNoRows`.
  - `resolvesSingleAccount`, `resolvesAccountByLegacyOrgId`, `resolvesAmbiguousAccountsAsSelectionRequired`, `explicitAdAccountIdSkipsAcls` (no ACL request recorded).
  - `retriesQueryOn429ThenSucceeds` (429 with `Retry-After: 0` then 200), `doesNotRetryPut` (429 on a PUT → error after one attempt; use `putCampaignsId` via the raw generated client).
  - `unauthorizedMapsToReadableError`, `decodeFailureIsReadable`.
- [ ] **Step 2:** Run `swift test --filter AppleAdsPlatformClientTests` → FAIL.
- [ ] **Step 3:** Implement. Read generated type names from `.build/checkouts/apple-ads-platform-api-swift/Sources/AppleAdsClient/Generated/Types.swift` (`Operations.PostCampaignsQuery`, `Operations.AppsSearchTermReports`, `Operations.GetUserAcls`); don't redeclare wire types.
- [ ] **Step 4:** Run → PASS. Run full `swift test` — `KeywordSuggestionServiceTests`, `KeywordPopularityServiceTests`, `OpportunityServiceTests` must pass **unchanged** (proves the seam held).
- [ ] **Step 5:** Commit `Move Apple Ads reads to Platform API v1`.

### Task 6: Ad-account picker in settings

**Files:**
- Modify: `Sources/App/Controllers/SettingsController.swift` (`GET settings/asa/accounts` → `[ASAAdAccount]`; maps `AppleAdsError` to 4xx with its description)
- Modify: `web/src/lib/api.ts`, `web/src/lib/types.ts` (`ASAAdAccount`, `getASAAccounts()`, `adAccountId` on `ASAStatus` and the PUT body)
- Modify: `web/src/components/SettingsPanel.svelte` (after credentials are saved: "Ad account" select populated from `getASAAccounts()`, preselecting `asaStatus.adAccountId`; saving PUTs `adAccountId`; copy says "Apple Ads", drops v5-era wording; shows `AppleAdsError` text on failure)
- Modify: `mcp/` — none (MCP reads `/keywords/opportunity` only).
- Test: `Tests/AppTests/SettingsControllerASAAccountsTests.swift` (controller with a stub client factory)

**Interfaces:**
- Consumes: `AppleAdsPlatformClient.listAdAccounts()` (Task 5).
- Produces: `GET /api/v1/settings/asa/accounts` (admin-only in server mode — it's under `SettingsController`, already admin-gated).

- [ ] **Step 1: Failing tests:** `accountsEndpointListsAccounts` (200, JSON array with `id`, `name`, `orgId`, `roles`); `accountsEndpointWithoutCredentialsIs409` (409, reason "Connect Apple Ads first").
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement server + SPA. **Step 4:** `swift test` and `cd web && npm run check && npm run build` → pass.
- [ ] **Step 5:** Commit `Let users pick their Apple Ads ad account`.

### Task 7: Docs and final verification

**Files:** `README.md` ("What's not here": ASA is no longer unused; Apple Ads section mentions v1 + macOS 15), `CLAUDE.md` (Apple Ads client lives in `Sources/App/Clients/AppleAds/`; session lifecycle; `server-v*` channel), `docs/env-vars.md` (unchanged unless a var was added).

- [ ] **Step 1:** Update docs.
- [ ] **Step 2:** Run every CI check listed in Global Constraints; all green. Delete any private build folders.
- [ ] **Step 3:** Commit `Document the Apple Ads v1 client`, push, open PR against `main` with the size numbers from Task 1 and a "not verified against a live Apple Ads account" note listing REF open questions 1–4.

---

## Later phases (separate plans, written after this merges)

- **Phase 2 — Apple Ads space:** a sidebar "Apple Ads" page: connection status + setup (add private-key auth via `.key(teamId:keyId:privateKeyPEM:)` so secrets never expire; persist the chosen ad account), campaign overview with v1 report metrics (spend, taps, installs, `tapInstallCPI`, `ttr`), and the Related suggestions + opportunity table moved there. Investigate `searchTermPopularityQuery` as a real popularity signal for keywords that no campaign covers.
- **Phase 3 — Operations:** pause/resume campaigns and ad groups, daily budget and bid edits, add/remove targeting and negative keywords (bulk endpoints), each behind an explicit confirm showing the exact change and money amount; admin-only in server mode; MCP write tools only with `confirm: true`.
