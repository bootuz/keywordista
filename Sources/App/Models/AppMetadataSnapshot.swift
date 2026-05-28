import Fluent
import SQLKit
import Vapor

/// One row per "the state of <app> on <country>'s App Store at some point in
/// time, as observed by Keywordista." Append-only with content-hash dedupe:
/// a refresh that finds nothing changed bumps `lastSeenAt` instead of
/// inserting an identical row. This is the same `firstSeenAt`/`checkedAt`
/// posture as `RankCheck` — load-bearing for the project's append-only
/// timeline contract.
///
/// Field provenance:
///   • Most fields are sourced from `https://itunes.apple.com/lookup` and
///     decoded via `RichLookupResultApp`.
///   • `subtitle` is scraped from the `<p class="subtitle …">` element on
///     `https://apps.apple.com/<country>/app/-/id<N>` because iTunes lookup
///     omits it (verified via probing — see plan).
///   • `promotionalText` and `inAppPurchasesJSON` are NULL in v1. The
///     columns exist so the phase-2 AMP-API fetcher can populate them
///     without a schema migration.
///   • `scrapeFailedAt` is non-NULL when this row's `subtitle` was carried
///     forward from the previous row because the HTML scrape failed. The
///     content-hash projection in `AppMetadataSnapshotService.snapshot()`
///     carries the prior subtitle into the hash so a transient scrape blip
///     doesn't produce a spurious "subtitle changed → and back" pair in
///     the recent-changes timeline.
final class AppMetadataSnapshot: Model, Content, @unchecked Sendable {
    static let schema = "app_metadata_snapshots"

    @ID(key: .id) var id: UUID?
    @Parent(key: "watched_app_id") var watchedApp: WatchedApp
    @Field(key: "country_code") var countryCode: String

    // ── identity & versioning ──────────────────────────────────────────
    @Field(key: "track_name") var trackName: String
    @Field(key: "bundle_id") var bundleId: String
    @OptionalField(key: "version") var version: String?
    @OptionalField(key: "current_version_release_date") var currentVersionReleaseDate: Date?
    @OptionalField(key: "release_notes") var releaseNotes: String?

    // ── ASO copy ───────────────────────────────────────────────────────
    @OptionalField(key: "subtitle") var subtitle: String?
    @OptionalField(key: "description") var appDescription: String?
    @OptionalField(key: "promotional_text") var promotionalText: String?
    @OptionalField(key: "seller_name") var sellerName: String?
    @OptionalField(key: "primary_genre_name") var primaryGenreName: String?
    @OptionalField(key: "genres_json") var genresJSON: String?

    // ── visual assets (we keep URLs only; images live on Apple's CDN) ──
    @OptionalField(key: "artwork_url_512") var artworkURL512: String?
    @OptionalField(key: "screenshot_urls_json") var screenshotURLsJSON: String?
    @OptionalField(key: "ipad_screenshot_urls_json") var ipadScreenshotURLsJSON: String?

    // ── commercial ─────────────────────────────────────────────────────
    @OptionalField(key: "price") var price: Double?
    @OptionalField(key: "currency") var currency: String?
    @OptionalField(key: "formatted_price") var formattedPrice: String?
    @OptionalField(key: "in_app_purchases_json") var inAppPurchasesJSON: String?

    // ── quality signals ────────────────────────────────────────────────
    @OptionalField(key: "average_user_rating") var averageUserRating: Double?
    @OptionalField(key: "user_rating_count") var userRatingCount: Int?
    @OptionalField(key: "average_user_rating_for_current_version") var averageUserRatingForCurrentVersion: Double?
    @OptionalField(key: "user_rating_count_for_current_version") var userRatingCountForCurrentVersion: Int?
    @OptionalField(key: "content_advisory_rating") var contentAdvisoryRating: String?
    @OptionalField(key: "languages_json") var languagesJSON: String?
    @OptionalField(key: "file_size_bytes") var fileSizeBytes: Int64?
    @OptionalField(key: "minimum_os_version") var minimumOSVersion: String?

    // ── provenance / dedupe ────────────────────────────────────────────
    @OptionalField(key: "scrape_failed_at") var scrapeFailedAt: Date?
    @Field(key: "content_hash") var contentHash: String
    @Field(key: "first_seen_at") var firstSeenAt: Date
    @Field(key: "last_seen_at") var lastSeenAt: Date
    @Field(key: "fetched_at") var fetchedAt: Date

    init() {}

    // No convenience initializer here — `AppMetadataSnapshotService` builds
    // these from a `RichLookupResultApp` + scraper output via its static
    // `makeSnapshot(watchedAppID:country:rich:subtitle:...)` factory, so
    // the field-by-field mapping lives in one place.
}

struct CreateAppMetadataSnapshot: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(AppMetadataSnapshot.schema)
            .id()
            .field(
                "watched_app_id",
                .uuid,
                .required,
                .references(WatchedApp.schema, "id", onDelete: .cascade)
            )
            .field("country_code", .string, .required)

            .field("track_name", .string, .required)
            .field("bundle_id", .string, .required)
            .field("version", .string)
            .field("current_version_release_date", .datetime)
            .field("release_notes", .string)

            .field("subtitle", .string)
            .field("description", .string)
            .field("promotional_text", .string)
            .field("seller_name", .string)
            .field("primary_genre_name", .string)
            .field("genres_json", .string)

            .field("artwork_url_512", .string)
            .field("screenshot_urls_json", .string)
            .field("ipad_screenshot_urls_json", .string)

            .field("price", .double)
            .field("currency", .string)
            .field("formatted_price", .string)
            .field("in_app_purchases_json", .string)

            .field("average_user_rating", .double)
            .field("user_rating_count", .int)
            .field("average_user_rating_for_current_version", .double)
            .field("user_rating_count_for_current_version", .int)
            .field("content_advisory_rating", .string)
            .field("languages_json", .string)
            .field("file_size_bytes", .int64)
            .field("minimum_os_version", .string)

            .field("scrape_failed_at", .datetime)
            .field("content_hash", .string, .required)
            .field("first_seen_at", .datetime, .required)
            .field("last_seen_at", .datetime, .required)
            .field("fetched_at", .datetime, .required)
            .create()

        // Composite index for "latest snapshot per (app, country)" —
        // exactly the lookup the dedupe path makes on every refresh, and
        // the read path `/apps/:id/metadata?country=` makes on every
        // compare-page render. Matching the RankCheck pattern.
        if let sql = database as? SQLDatabase {
            try await sql.raw("""
            CREATE INDEX IF NOT EXISTS app_metadata_snapshots_app_country_time
                ON app_metadata_snapshots (watched_app_id, country_code, last_seen_at DESC)
            """).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema(AppMetadataSnapshot.schema).delete()
    }
}
