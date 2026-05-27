import Fluent
import Foundation

/// Read/write contract for the metadata snapshot timeline. Three reads:
/// the dedupe path needs the latest row for `(app, country)` to compare
/// hashes; the SPA needs the latest-per-storefront map; the timeline view
/// needs paginated history. One write — `save` — appends a row.
/// `bumpLastSeenAt` is the dedupe-extension write that avoids inserting
/// identical rows on a no-change refresh, mirroring `RankCheck`'s
/// `updateCheckedAt`.
protocol AppMetadataSnapshotRepositoryProtocol: Sendable {
    func save(_ snapshot: AppMetadataSnapshot) async throws
    func bumpLastSeenAt(id: UUID, lastSeenAt: Date, scrapeFailedAt: Date?) async throws
    func latest(watchedAppID: UUID, country: String) async throws -> AppMetadataSnapshot?
    /// Latest snapshot per storefront for one app — keyed by country code.
    /// Used by the `/apps/:id/metadata` endpoint to render the per-storefront
    /// dropdown without N round-trips.
    func latestPerCountry(watchedAppID: UUID) async throws -> [String: AppMetadataSnapshot]
    /// Newest-first paginated history for the change-timeline view.
    func history(watchedAppID: UUID, country: String, limit: Int) async throws -> [AppMetadataSnapshot]
}

struct FluentAppMetadataSnapshotRepository: AppMetadataSnapshotRepositoryProtocol {
    let db: any Database

    func save(_ snapshot: AppMetadataSnapshot) async throws {
        try await snapshot.save(on: db)
    }

    func bumpLastSeenAt(id: UUID, lastSeenAt: Date, scrapeFailedAt: Date?) async throws {
        // Single-row UPDATE via query builder — narrower than a model
        // round-trip. We also persist `scrapeFailedAt` here because the
        // dedupe path needs to record "we tried to refresh on date X
        // and the scrape failed" even though we didn't insert a new row.
        try await AppMetadataSnapshot.query(on: db)
            .filter(\.$id == id)
            .set(\.$lastSeenAt, to: lastSeenAt)
            .set(\.$scrapeFailedAt, to: scrapeFailedAt)
            .update()
    }

    func latest(watchedAppID: UUID, country: String) async throws -> AppMetadataSnapshot? {
        try await AppMetadataSnapshot.query(on: db)
            .filter(\.$watchedApp.$id == watchedAppID)
            .filter(\.$countryCode == country.lowercased())
            .sort(\.$lastSeenAt, .descending)
            .first()
    }

    func latestPerCountry(watchedAppID: UUID) async throws -> [String: AppMetadataSnapshot] {
        // Naive implementation: pull all rows for the app, fold to the
        // newest per country in memory. The app+country composite index
        // makes this fast; alternative would be a per-country subquery
        // that's harder to read for no practical perf gain at single-
        // user scale.
        let rows = try await AppMetadataSnapshot.query(on: db)
            .filter(\.$watchedApp.$id == watchedAppID)
            .sort(\.$lastSeenAt, .descending)
            .all()
        var out: [String: AppMetadataSnapshot] = [:]
        for row in rows where out[row.countryCode] == nil {
            out[row.countryCode] = row
        }
        return out
    }

    func history(watchedAppID: UUID, country: String, limit: Int) async throws -> [AppMetadataSnapshot] {
        try await AppMetadataSnapshot.query(on: db)
            .filter(\.$watchedApp.$id == watchedAppID)
            .filter(\.$countryCode == country.lowercased())
            .sort(\.$lastSeenAt, .descending)
            .limit(limit)
            .all()
    }
}
