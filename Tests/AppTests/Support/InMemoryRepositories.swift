@testable import App
import Foundation

actor InMemoryWatchedAppRepository: WatchedAppRepositoryProtocol {
    private var storage: [UUID: WatchedApp] = [:]

    init(_ initial: [WatchedApp] = []) {
        for app in initial {
            if let id = app.id { storage[id] = app }
        }
    }

    func all() async throws -> [WatchedApp] { Array(storage.values) }

    func find(id: UUID) async throws -> WatchedApp? { storage[id] }

    func save(_ app: WatchedApp) async throws {
        let id = app.id ?? UUID()
        app.id = id
        storage[id] = app
    }

    func delete(id: UUID) async throws { storage.removeValue(forKey: id) }
}

actor InMemoryKeywordRepository: KeywordRepositoryProtocol {
    private var storage: [UUID: Keyword] = [:]

    init(_ initial: [Keyword] = []) {
        for kw in initial {
            if let id = kw.id { storage[id] = kw }
        }
    }

    func all() async throws -> [Keyword] { Array(storage.values) }

    func filtered(country: String?) async throws -> [Keyword] {
        guard let country else { return Array(storage.values) }
        return storage.values.filter { $0.countryCode == country.lowercased() }
    }

    func find(id: UUID) async throws -> Keyword? { storage[id] }

    func save(_ keyword: Keyword) async throws {
        let id = keyword.id ?? UUID()
        keyword.id = id
        storage[id] = keyword
    }

    func delete(id: UUID) async throws { storage.removeValue(forKey: id) }
}

actor InMemoryRankCheckRepository: RankCheckRepositoryProtocol {
    private(set) var saved: [RankCheck] = []
    // Tracks every checkedAt-bump triggered by no-change refreshes. Tests
    // can inspect this to verify the dedupe path was taken instead of an
    // insert (which would land in `saved`).
    private(set) var bumps: [(id: UUID, checkedAt: Date)] = []

    func save(_ check: RankCheck) async throws {
        if check.id == nil { check.id = UUID() }
        saved.append(check)
    }

    func updateCheckedAt(id: UUID, checkedAt: Date) async throws {
        bumps.append((id, checkedAt))
        if let idx = saved.firstIndex(where: { $0.id == id }) {
            saved[idx].checkedAt = checkedAt
        }
    }

    func latest(keywordID: UUID, watchedAppID: UUID) async throws -> RankCheck? {
        saved
            .filter { $0.$keyword.id == keywordID && $0.$watchedApp.id == watchedAppID }
            .max(by: { $0.checkedAt < $1.checkedAt })
    }

    func recent(keywordID: UUID, watchedAppID: UUID, limit: Int) async throws -> [RankCheck] {
        Array(
            saved
                .filter { $0.$keyword.id == keywordID && $0.$watchedApp.id == watchedAppID }
                .sorted(by: { $0.checkedAt > $1.checkedAt })
                .prefix(limit),
        )
    }

    func history(keywordID: UUID, watchedAppID: UUID) async throws -> [RankCheck] {
        saved
            .filter { $0.$keyword.id == keywordID && $0.$watchedApp.id == watchedAppID }
            .sorted(by: { $0.checkedAt < $1.checkedAt })
    }
}

actor InMemoryTopResultSnapshotRepository: TopResultSnapshotRepositoryProtocol {
    private(set) var saved: [TopResultSnapshot] = []

    func save(_ snapshot: TopResultSnapshot) async throws { saved.append(snapshot) }

    func latestSnapshot(keywordID: UUID) async throws -> [TopResultSnapshot] {
        let forKeyword = saved.filter { $0.$keyword.id == keywordID }
        guard let latest = forKeyword.map(\.checkedAt).max() else { return [] }
        return forKeyword
            .filter { $0.checkedAt == latest }
            .sorted(by: { $0.position < $1.position })
    }
}
