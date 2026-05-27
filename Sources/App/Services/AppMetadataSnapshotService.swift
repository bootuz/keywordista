import Crypto
import Foundation
import Vapor

protocol AppMetadataSnapshotServiceProtocol: Sendable {
    /// Fetch fresh metadata for `(watchedAppID, country)` from iTunes +
    /// HTML scrape, dedupe against the last snapshot via content hash,
    /// and either bump `lastSeenAt` on the existing row or insert a new
    /// one. Returns the row that represents "now" — the same row the
    /// caller would see by reading `latest(...)`.
    func snapshot(watchedAppID: UUID, country: String) async throws -> AppMetadataSnapshot

    func latest(watchedAppID: UUID, country: String) async throws -> AppMetadataSnapshot?
    func latestPerCountry(watchedAppID: UUID) async throws -> [String: AppMetadataSnapshot]
    func history(watchedAppID: UUID, country: String, limit: Int) async throws -> [AppMetadataSnapshot]
}

struct AppMetadataSnapshotService: AppMetadataSnapshotServiceProtocol {
    let snapshots: any AppMetadataSnapshotRepositoryProtocol
    let watchedApps: any WatchedAppRepositoryProtocol
    let lookupClient: any ITunesLookupClientProtocol
    let scraper: any AppStoreHTMLScraperProtocol
    let logger: Logger
    let clock: @Sendable () -> Date

    init(
        snapshots: any AppMetadataSnapshotRepositoryProtocol,
        watchedApps: any WatchedAppRepositoryProtocol,
        lookupClient: any ITunesLookupClientProtocol,
        scraper: any AppStoreHTMLScraperProtocol,
        logger: Logger,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.snapshots = snapshots
        self.watchedApps = watchedApps
        self.lookupClient = lookupClient
        self.scraper = scraper
        self.logger = logger
        self.clock = clock
    }

    func snapshot(watchedAppID: UUID, country: String) async throws -> AppMetadataSnapshot {
        guard let app = try await watchedApps.find(id: watchedAppID) else {
            throw Abort(.notFound, reason: "watched app \(watchedAppID) not found")
        }
        let normalizedCountry = country.lowercased()
        let now = clock()

        // Fetch both data sources concurrently. The HTML scrape and the
        // iTunes lookup are independent network calls; running them in
        // parallel halves the wall-clock cost. Failures on either side
        // are non-fatal — see the carry-forward logic below.
        async let richTask = lookupClient.lookupRich(appStoreId: app.appStoreId, country: normalizedCountry)
        async let scrapeTask = scraper.scrapeSubtitle(appStoreId: app.appStoreId, country: normalizedCountry)

        let rich: RichLookupResultApp
        do {
            rich = try await richTask
        } catch {
            // iTunes lookup failure is fatal for this run — without the
            // lookup data we have no snapshot to dedupe against. Cancel
            // the scrape (waste of bandwidth) and surface.
            _ = try? await scrapeTask
            throw error
        }

        let scrapeOutcome: ScrapeOutcome
        do {
            scrapeOutcome = try await scrapeTask
        } catch {
            scrapeOutcome = .failed(reason: String(describing: error))
        }

        let latest = try await snapshots.latest(watchedAppID: watchedAppID, country: normalizedCountry)

        // Carry-forward on scrape failure: reuse the previous row's
        // subtitle so a transient HTML blip doesn't churn the timeline.
        // The content hash sees the carried-forward value, so dedupe
        // continues to behave correctly when the next successful scrape
        // matches the carried value.
        let resolvedSubtitle: String?
        let scrapeFailedAt: Date?
        switch scrapeOutcome {
        case .succeeded(let subtitle):
            resolvedSubtitle = subtitle
            scrapeFailedAt = nil
        case .failed(let reason):
            logger.warning("html scrape failed for app=\(watchedAppID) country=\(normalizedCountry): \(reason); carrying forward prior subtitle")
            resolvedSubtitle = latest?.subtitle
            scrapeFailedAt = now
        }

        let snapshot = Self.makeSnapshot(
            watchedAppID: watchedAppID,
            country: normalizedCountry,
            rich: rich,
            subtitle: resolvedSubtitle,
            // promotionalText + IAPs are NULL in v1 (scaffolded for the
            // phase-2 AMP fetch path).
            promotionalText: latest?.promotionalText,
            inAppPurchasesJSON: latest?.inAppPurchasesJSON,
            scrapeFailedAt: scrapeFailedAt,
            now: now
        )

        let hash = Self.contentHash(snapshot)
        snapshot.contentHash = hash

        if let latest, latest.contentHash == hash, let latestID = latest.id {
            // Dedupe path. Bump `lastSeenAt`; record the scrape failure
            // marker on the surviving row so the change-derivation logic
            // can skip rows whose subtitle was carried forward.
            try await snapshots.bumpLastSeenAt(id: latestID, lastSeenAt: now, scrapeFailedAt: scrapeFailedAt)
            // Reload to return the up-to-date row (avoids the caller
            // seeing stale `lastSeenAt`).
            return try await snapshots.latest(watchedAppID: watchedAppID, country: normalizedCountry) ?? latest
        }

        // New row.
        snapshot.firstSeenAt = now
        snapshot.lastSeenAt = now
        snapshot.fetchedAt = now
        try await snapshots.save(snapshot)
        return snapshot
    }

    func latest(watchedAppID: UUID, country: String) async throws -> AppMetadataSnapshot? {
        try await snapshots.latest(watchedAppID: watchedAppID, country: country.lowercased())
    }

    func latestPerCountry(watchedAppID: UUID) async throws -> [String: AppMetadataSnapshot] {
        try await snapshots.latestPerCountry(watchedAppID: watchedAppID)
    }

    func history(watchedAppID: UUID, country: String, limit: Int) async throws -> [AppMetadataSnapshot] {
        try await snapshots.history(watchedAppID: watchedAppID, country: country.lowercased(), limit: limit)
    }

    // MARK: - Snapshot construction

    /// Maps the rich lookup result + scraped subtitle onto a fresh
    /// `AppMetadataSnapshot` instance. Pulled out as a `static` so tests
    /// can reach it for hashing without going through the network path.
    static func makeSnapshot(
        watchedAppID: UUID,
        country: String,
        rich: RichLookupResultApp,
        subtitle: String?,
        promotionalText: String?,
        inAppPurchasesJSON: String?,
        scrapeFailedAt: Date?,
        now: Date
    ) -> AppMetadataSnapshot {
        let s = AppMetadataSnapshot()
        s.$watchedApp.id = watchedAppID
        s.countryCode = country.lowercased()

        s.trackName = rich.trackName
        s.bundleId = rich.bundleId
        s.version = rich.version
        s.currentVersionReleaseDate = rich.currentVersionReleaseDate
        s.releaseNotes = rich.releaseNotes

        s.subtitle = subtitle
        s.appDescription = rich.description
        s.promotionalText = promotionalText
        s.sellerName = rich.sellerName
        s.primaryGenreName = rich.primaryGenreName
        s.genresJSON = rich.genres.flatMap(Self.encodeArray)

        s.artworkURL512 = rich.artworkUrl512 ?? rich.artworkUrl100
        s.screenshotURLsJSON = rich.screenshotUrls.flatMap(Self.encodeArray)
        s.ipadScreenshotURLsJSON = rich.ipadScreenshotUrls.flatMap(Self.encodeArray)

        s.price = rich.price
        s.currency = rich.currency
        s.formattedPrice = rich.formattedPrice
        s.inAppPurchasesJSON = inAppPurchasesJSON

        s.averageUserRating = rich.averageUserRating
        s.userRatingCount = rich.userRatingCount
        s.averageUserRatingForCurrentVersion = rich.averageUserRatingForCurrentVersion
        s.userRatingCountForCurrentVersion = rich.userRatingCountForCurrentVersion
        s.contentAdvisoryRating = rich.contentAdvisoryRating
        s.languagesJSON = rich.languageCodesISO2A.flatMap(Self.encodeArray)
        s.fileSizeBytes = rich.fileSizeBytes
        s.minimumOSVersion = rich.minimumOsVersion

        s.scrapeFailedAt = scrapeFailedAt
        s.contentHash = "" // filled by caller after hashing
        s.firstSeenAt = now
        s.lastSeenAt = now
        s.fetchedAt = now
        return s
    }

    private static func encodeArray(_ array: [String]) -> String? {
        // Canonical encoding: sorted is NOT applied because order is
        // semantically meaningful for screenshots (Apple cares about
        // the position) and for genres (primary first). Plain JSON
        // encoding preserves order; the encoder is deterministic for
        // arrays of strings.
        guard let data = try? JSONEncoder().encode(array) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Content hashing

    /// SHA256 of a canonical JSON projection of the snapshottable fields.
    /// Provenance metadata (`id`, `firstSeenAt`, `lastSeenAt`, `fetchedAt`,
    /// `contentHash`, `scrapeFailedAt`) is intentionally excluded so the
    /// hash represents "what does this app look like" rather than "when
    /// did we look". Carry-forward subtitle values participate in the
    /// hash (they're already in `s.subtitle` by the time we hash), so a
    /// scrape that fails after a successful one produces the same hash
    /// as the prior row — that's how dedupe survives transient failures.
    static func contentHash(_ s: AppMetadataSnapshot) -> String {
        // Build a stable, sorted-key dictionary. We must NOT use the
        // default JSONEncoder because its key order isn't guaranteed
        // across runs; building the canonical string manually gives a
        // deterministic byte sequence to hash.
        let parts: [(String, String)] = [
            ("watched_app_id", s.$watchedApp.id.uuidString),
            ("country_code", s.countryCode),
            ("track_name", s.trackName),
            ("bundle_id", s.bundleId),
            ("version", s.version ?? ""),
            ("current_version_release_date", s.currentVersionReleaseDate.map(Self.isoString) ?? ""),
            ("release_notes", s.releaseNotes ?? ""),
            ("subtitle", s.subtitle ?? ""),
            ("description", s.appDescription ?? ""),
            ("promotional_text", s.promotionalText ?? ""),
            ("seller_name", s.sellerName ?? ""),
            ("primary_genre_name", s.primaryGenreName ?? ""),
            ("genres_json", s.genresJSON ?? ""),
            ("artwork_url_512", s.artworkURL512 ?? ""),
            ("screenshot_urls_json", s.screenshotURLsJSON ?? ""),
            ("ipad_screenshot_urls_json", s.ipadScreenshotURLsJSON ?? ""),
            ("price", s.price.map { String($0) } ?? ""),
            ("currency", s.currency ?? ""),
            ("formatted_price", s.formattedPrice ?? ""),
            ("in_app_purchases_json", s.inAppPurchasesJSON ?? ""),
            ("average_user_rating", s.averageUserRating.map { String($0) } ?? ""),
            ("user_rating_count", s.userRatingCount.map { String($0) } ?? ""),
            ("average_user_rating_for_current_version", s.averageUserRatingForCurrentVersion.map { String($0) } ?? ""),
            ("user_rating_count_for_current_version", s.userRatingCountForCurrentVersion.map { String($0) } ?? ""),
            ("content_advisory_rating", s.contentAdvisoryRating ?? ""),
            ("languages_json", s.languagesJSON ?? ""),
            ("file_size_bytes", s.fileSizeBytes.map { String($0) } ?? ""),
            ("minimum_os_version", s.minimumOSVersion ?? ""),
        ]
        // `parts` is already in fixed order by construction — the
        // declaration order IS the canonical order. Adding a new field
        // in the future must append (or insert) and bump downstream
        // hashes uniformly, which is the desired property.
        let canonical = parts.map { "\($0.0)=\($0.1)" }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
