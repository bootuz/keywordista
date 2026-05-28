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
    /// Bumps `last_seen_at` to `lastSeenAt` for a single row. INTENTIONALLY
    /// does NOT touch `scrape_failed_at` — that field is set on insert
    /// (it's a row-creation property recording "was this row's subtitle
    /// carried-forward at observation time?") and should never be
    /// overwritten by a later bump, because doing so would corrupt the
    /// historical provenance of a previously-clean observation.
    func bumpLastSeenAt(id: UUID, lastSeenAt: Date) async throws
    func latest(watchedAppID: UUID, country: String) async throws -> AppMetadataSnapshot?
    /// Latest snapshot per storefront for one app — keyed by country code.
    /// Used by the `/apps/:id/metadata` endpoint to render the per-storefront
    /// dropdown without N round-trips.
    func latestPerCountry(watchedAppID: UUID) async throws -> [String: AppMetadataSnapshot]
    /// Newest-first paginated history for the change-timeline view.
    func history(watchedAppID: UUID, country: String, limit: Int) async throws -> [AppMetadataSnapshot]
    /// Distinct country codes ever snapshotted for one app. Used by the
    /// daily job to keep the at-add `lookupCountry` fresh on subsequent
    /// passes, even when no keyword exists in that storefront.
    func snapshottedCountries(watchedAppID: UUID) async throws -> [String]
    /// Runs `body` inside a database transaction. The transacted repo
    /// passed in MUST be used for all DB calls inside the closure so the
    /// reads and writes share the same connection — otherwise the
    /// transaction's serialization guarantee doesn't apply. The Fluent
    /// impl wraps in `db.transaction`; the in-memory fake just runs the
    /// body directly because actor isolation already serializes writers.
    func withTransaction<T: Sendable>(
        _ body: @Sendable @escaping (any AppMetadataSnapshotRepositoryProtocol) async throws -> T
    ) async throws -> T
}

struct FluentAppMetadataSnapshotRepository: AppMetadataSnapshotRepositoryProtocol {
    let db: any Database

    func save(_ snapshot: AppMetadataSnapshot) async throws {
        try await snapshot.save(on: db)
    }

    func bumpLastSeenAt(id: UUID, lastSeenAt: Date) async throws {
        // Single-column UPDATE via query builder. INTENTIONALLY does not
        // touch `scrape_failed_at` — see the protocol's doc comment.
        try await AppMetadataSnapshot.query(on: db)
            .filter(\.$id == id)
            .set(\.$lastSeenAt, to: lastSeenAt)
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

    func snapshottedCountries(watchedAppID: UUID) async throws -> [String] {
        // DISTINCT country_code via Fluent's `.unique()` aggregate; the
        // single-user scale keeps this cheap (≤ ~10 distinct countries
        // per app in practice).
        let rows = try await AppMetadataSnapshot.query(on: db)
            .filter(\.$watchedApp.$id == watchedAppID)
            .field(\.$countryCode)
            .unique()
            .all()
        return rows.map { $0.countryCode }
    }

    func withTransaction<T: Sendable>(
        _ body: @Sendable @escaping (any AppMetadataSnapshotRepositoryProtocol) async throws -> T
    ) async throws -> T {
        try await db.transaction { tx in
            // Critical: hand the transacted DB to a fresh repo so all
            // operations inside the closure share the connection. If
            // `body` received `self`, the queries would route through
            // the outer `self.db` and the transaction's serialization
            // would not apply.
            let txRepo = FluentAppMetadataSnapshotRepository(db: tx)
            return try await body(txRepo)
        }
    }
}
