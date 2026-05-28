@testable import App
import Foundation

/// In-memory analogue of `FluentAppMetadataSnapshotRepository` for unit
/// tests. Tracks every save + bump separately so tests can assert the
/// dedupe path was taken (only bumps changed) vs. a real insert (rows
/// appended to `saved`).
actor InMemoryAppMetadataSnapshotRepository: AppMetadataSnapshotRepositoryProtocol {
    private(set) var saved: [AppMetadataSnapshot] = []
    private(set) var bumps: [(id: UUID, lastSeenAt: Date)] = []

    init() {}

    func save(_ snapshot: AppMetadataSnapshot) async throws {
        // Ensure the row has an ID so tests can compare across reads.
        if snapshot.id == nil { snapshot.id = UUID() }
        saved.append(snapshot)
    }

    func bumpLastSeenAt(id: UUID, lastSeenAt: Date) async throws {
        bumps.append((id, lastSeenAt))
        if let i = saved.firstIndex(where: { $0.id == id }) {
            saved[i].lastSeenAt = lastSeenAt
            // Intentionally do NOT touch scrapeFailedAt — preserving the
            // row's original provenance flag is the whole point of the
            // protocol contract change.
        }
    }

    func latest(watchedAppID: UUID, country: String) async throws -> AppMetadataSnapshot? {
        saved
            .filter { $0.$watchedApp.id == watchedAppID && $0.countryCode == country.lowercased() }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
            .first
    }

    func latestPerCountry(watchedAppID: UUID) async throws -> [String: AppMetadataSnapshot] {
        var out: [String: AppMetadataSnapshot] = [:]
        for row in saved.filter({ $0.$watchedApp.id == watchedAppID })
                        .sorted(by: { $0.lastSeenAt > $1.lastSeenAt })
            where out[row.countryCode] == nil {
            out[row.countryCode] = row
        }
        return out
    }

    func history(watchedAppID: UUID, country: String, limit: Int) async throws -> [AppMetadataSnapshot] {
        Array(
            saved
                .filter { $0.$watchedApp.id == watchedAppID && $0.countryCode == country.lowercased() }
                .sorted(by: { $0.lastSeenAt > $1.lastSeenAt })
                .prefix(limit)
        )
    }

    func snapshottedCountries(watchedAppID: UUID) async throws -> [String] {
        Array(Set(saved.filter { $0.$watchedApp.id == watchedAppID }.map(\.countryCode))).sorted()
    }

    nonisolated func withTransaction<T: Sendable>(
        _ body: @Sendable @escaping (any AppMetadataSnapshotRepositoryProtocol) async throws -> T
    ) async throws -> T {
        // Actor isolation already serializes writers in the in-memory
        // fake; "transactions" collapse to a direct passthrough. We
        // can't capture `self` strongly here without crossing actor
        // boundaries inside the closure, so we mark this nonisolated
        // and rely on the body's own async access to re-enter the
        // actor as needed. The body must access this repo via the
        // parameter, not via captured `self`.
        try await body(self)
    }
}

/// Tiny stub that implements the scraper protocol with a programmable
/// outcome queue. Snapshot tests script the sequence of scrape results
/// the service should observe across multiple `snapshot(...)` calls.
actor StubHTMLScraper: AppStoreHTMLScraperProtocol {
    private var outcomes: [ScrapeOutcome]
    private(set) var calls: [(appStoreId: Int64, country: String)] = []

    init(outcomes: [ScrapeOutcome]) { self.outcomes = outcomes }

    func scrapeSubtitle(appStoreId: Int64, country: String) async throws -> ScrapeOutcome {
        calls.append((appStoreId, country))
        // Pop the next outcome; if exhausted, repeat the last (or fall
        // back to a benign "no subtitle, succeeded" so tests that don't
        // care about late calls aren't surprised).
        if outcomes.isEmpty { return .succeeded(subtitle: nil) }
        return outcomes.removeFirst()
    }
}
