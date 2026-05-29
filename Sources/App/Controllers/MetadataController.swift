import Vapor

/// Read + manual-refresh surface for the per-app metadata snapshot
/// timeline, plus the `/compare` aggregate endpoint that drives the SPA's
/// side-by-side comparison page.
///
/// Lazy backfill is the load-bearing UX choice for /compare: when the
/// user picks a storefront for which no snapshot exists yet (e.g. they
/// just added a competitor and immediately opened the JP compare view,
/// or the daily job hasn't covered this storefront yet), the controller
/// synchronously fetches one inline. ~300ms one-time tax per
/// (app, country) pair; cached forever after.
struct MetadataController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let apps = routes.grouped("apps", ":id")
        apps.get("metadata", use: latest)
        apps.get("metadata", "history", use: history)
        apps.get("metadata", "lint", use: lint)
        apps.post("metadata", "refresh", use: refresh)

        routes.get("compare", use: compare)
    }

    // Metadata-optimizer findings for this app's listing in one storefront.
    @Sendable func lint(req: Request) async throws -> [LintFinding] {
        let appID = try Self.appID(from: req)
        let country = Self.country(from: req)
        return try await req.metadataOptimizerService().findings(watchedAppID: appID, country: country)
    }

    // MARK: - Per-app endpoints

    @Sendable func latest(req: Request) async throws -> AppMetadataSnapshot {
        let appID = try Self.appID(from: req)
        let country = Self.country(from: req)
        let service = req.appMetadataSnapshotService()
        // Lazy backfill — the same posture as /compare. A user
        // navigating directly to /apps/:id/metadata?country=jp on a
        // freshly-added app shouldn't see an empty 404.
        if let existing = try await service.latest(watchedAppID: appID, country: country) {
            return existing
        }
        return try await service.snapshot(watchedAppID: appID, country: country)
    }

    @Sendable func history(req: Request) async throws -> [AppMetadataSnapshot] {
        let appID = try Self.appID(from: req)
        let country = Self.country(from: req)
        let requested = (try? req.query.get(Int.self, at: "limit")) ?? 50
        // Cap user-supplied limit. Without this a `?limit=10_000_000`
        // pulls every snapshot row for (app, country) into memory →
        // trivial DoS surface. 200 matches the existing search/refresh
        // cap (`RefreshService.searchLimit`) so the project has one
        // pagination ceiling across endpoints. Lower bound of 1 stops
        // a `?limit=-1` from inverting the SQL LIMIT semantics.
        let limit = max(1, min(requested, Self.historyLimitCap))
        return try await req.appMetadataSnapshotService().history(
            watchedAppID: appID, country: country, limit: limit
        )
    }

    /// Inclusive upper bound on `/metadata/history?limit=`. Mirrors
    /// `RefreshService.searchLimit` so the API has one ceiling for
    /// "newest-first paginated history" responses.
    static let historyLimitCap = 200

    @Sendable func refresh(req: Request) async throws -> AppMetadataSnapshot {
        let appID = try Self.appID(from: req)
        let country = Self.country(from: req)
        return try await req.appMetadataSnapshotService().snapshot(
            watchedAppID: appID, country: country
        )
    }

    // MARK: - /compare

    struct CompareResponse: Content {
        let country: String
        let fetchedAt: Date
        let ownApp: AppEntry?
        let competitors: [AppEntry]

        struct AppEntry: Content {
            let id: UUID
            let name: String
            let kind: String
            let latest: AppMetadataSnapshot?
            let recentChanges: [Change]
        }

        struct Change: Content {
            let field: String
            let from: String?
            let to: String?
            let at: Date
        }
    }

    @Sendable func compare(req: Request) async throws -> CompareResponse {
        guard let ownIDString = try? req.query.get(String.self, at: "own"),
              let ownID = UUID(uuidString: ownIDString) else {
            throw Abort(.badRequest, reason: "missing or invalid query param: own (uuid)")
        }
        let country = Self.country(from: req)
        let competitorIDs = Self.uuidList(req.query[String.self, at: "competitors"])

        let appService = req.appService()
        let metadataService = req.appMetadataSnapshotService()
        let all = try await appService.list()
        let byID = Dictionary(uniqueKeysWithValues: all.compactMap { app -> (UUID, WatchedApp)? in
            guard let id = app.id else { return nil }
            return (id, app)
        })

        // Resolve own app (must exist).
        let ownApp = byID[ownID]
        let ownEntry: CompareResponse.AppEntry?
        if let ownApp {
            ownEntry = try await Self.entry(for: ownApp, country: country, service: metadataService)
        } else {
            ownEntry = nil
        }

        // Resolve competitors (silently drop missing ids — the SPA may
        // have a stale selection if a competitor was deleted in
        // another tab, which shouldn't fail the whole page).
        var competitorEntries: [CompareResponse.AppEntry] = []
        for id in competitorIDs {
            guard let app = byID[id] else { continue }
            let entry = try await Self.entry(for: app, country: country, service: metadataService)
            competitorEntries.append(entry)
        }

        return CompareResponse(
            country: country,
            fetchedAt: Date(),
            ownApp: ownEntry,
            competitors: competitorEntries
        )
    }

    // MARK: - Helpers

    /// Build the per-app entry: latest snapshot (with lazy backfill) +
    /// recent change list. Pulled out so own and competitor paths share
    /// exactly the same rendering — the diff UI doesn't distinguish.
    private static func entry(
        for app: WatchedApp,
        country: String,
        service: any AppMetadataSnapshotServiceProtocol
    ) async throws -> CompareResponse.AppEntry {
        let appID = try app.requireID()
        var latest = try await service.latest(watchedAppID: appID, country: country)
        if latest == nil {
            // Lazy backfill. Fail-soft: if the fetch errors, we still
            // return the app entry with `latest: nil` so the SPA can
            // render an empty cell rather than 502 the whole compare.
            latest = try? await service.snapshot(watchedAppID: appID, country: country)
        }
        let history = try await service.history(watchedAppID: appID, country: country, limit: changeWindow)
        let changes = Self.deriveChanges(history: history)
        return CompareResponse.AppEntry(
            id: appID,
            name: app.name,
            kind: app.typedKind.rawValue,
            latest: latest,
            recentChanges: changes
        )
    }

    /// Max number of historical rows to scan when deriving the
    /// recent-changes timeline. 30 covers ~30 daily updates — about a
    /// month at the daily-job cadence — which is the relevant window for
    /// ASO listing analysis. Bounded so the payload size stays small.
    private static let changeWindow = 30

    /// Walk the (newest → oldest) snapshot history and emit per-field
    /// changes. Rows with `scrape_failed_at` non-nil are skipped — their
    /// subtitle was carried forward and they don't represent a real
    /// observation event.
    static func deriveChanges(history: [AppMetadataSnapshot]) -> [CompareResponse.Change] {
        // Drop carry-forward rows from the change derivation. Their
        // `subtitle` was reused from the prior real observation, so
        // including them would either produce zero diffs (when reused
        // verbatim) or false ones (impossible here because the dedupe
        // path collapsed them — but defense-in-depth).
        let real = history.filter { $0.scrapeFailedAt == nil }
        guard real.count >= 2 else { return [] }

        // Walk newest-first, comparing each row to the next-older.
        var out: [CompareResponse.Change] = []
        for i in 0..<(real.count - 1) {
            let newer = real[i]
            let older = real[i + 1]
            out.append(contentsOf: Self.diff(newer: newer, older: older))
        }
        return out
    }

    /// Per-pair diff. Only surface fields that actually moved the
    /// listing on the App Store — version bumps, copy edits, screenshot
    /// reshuffles, price changes. Counter-style fields (rating counts)
    /// are excluded; they drift constantly and would drown the timeline.
    private static func diff(
        newer: AppMetadataSnapshot,
        older: AppMetadataSnapshot
    ) -> [CompareResponse.Change] {
        var out: [CompareResponse.Change] = []
        let at = newer.firstSeenAt
        func add(_ field: String, _ a: String?, _ b: String?) {
            if a != b {
                out.append(CompareResponse.Change(field: field, from: b, to: a, at: at))
            }
        }
        add("track_name", newer.trackName, older.trackName)
        add("subtitle", newer.subtitle, older.subtitle)
        add("description", newer.appDescription, older.appDescription)
        add("version", newer.version, older.version)
        add("release_notes", newer.releaseNotes, older.releaseNotes)
        add("formatted_price", newer.formattedPrice, older.formattedPrice)
        // Screenshots and genres compare on their JSON projections — a
        // single change indicator is more useful than per-element diffs
        // for a timeline. The SPA can render the full lists separately.
        add("screenshot_urls", newer.screenshotURLsJSON, older.screenshotURLsJSON)
        add("ipad_screenshot_urls", newer.ipadScreenshotURLsJSON, older.ipadScreenshotURLsJSON)
        add("genres", newer.genresJSON, older.genresJSON)
        return out
    }

    private static func appID(from req: Request) throws -> UUID {
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "invalid app id")
        }
        return id
    }

    private static func country(from req: Request) -> String {
        ((try? req.query.get(String.self, at: "country")) ?? "us").lowercased()
    }

    /// Parse a comma-separated list of UUIDs from a query param.
    /// Silently drops malformed ids and de-duplicates while preserving
    /// first-seen order. Without dedup, `?competitors=X,X` would render
    /// X twice in the diff table; with it, repeated ids collapse to a
    /// single column. We pick first-seen order over set-order so the
    /// query param's ordering still controls the column layout.
    private static func uuidList(_ value: String?) -> [UUID] {
        guard let value, !value.isEmpty else { return [] }
        var seen: Set<UUID> = []
        var out: [UUID] = []
        for chunk in value.split(separator: ",") {
            guard let id = UUID(uuidString: chunk.trimmingCharacters(in: .whitespaces)) else { continue }
            if seen.insert(id).inserted { out.append(id) }
        }
        return out
    }
}
