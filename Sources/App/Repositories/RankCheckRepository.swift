import Fluent
import Foundation

protocol RankCheckRepositoryProtocol: Sendable {
    func save(_ check: RankCheck) async throws
    // Bump `checked_at` on an existing row without otherwise mutating it.
    // Used by RefreshService when a no-change refresh extends the current
    // observation run instead of inserting a duplicate row.
    func updateCheckedAt(id: UUID, checkedAt: Date) async throws
    func latest(keywordID: UUID, watchedAppID: UUID) async throws -> RankCheck?
    func recent(keywordID: UUID, watchedAppID: UUID, limit: Int) async throws -> [RankCheck]
    func history(keywordID: UUID, watchedAppID: UUID) async throws -> [RankCheck]
}

struct FluentRankCheckRepository: RankCheckRepositoryProtocol {
    let db: any Database

    func save(_ check: RankCheck) async throws {
        try await check.save(on: db)
    }

    func updateCheckedAt(id: UUID, checkedAt: Date) async throws {
        // Single-column update via the query builder — cheaper than loading
        // the row, mutating, saving (which would issue a wider UPDATE).
        try await RankCheck.query(on: db)
            .filter(\.$id == id)
            .set(\.$checkedAt, to: checkedAt)
            .update()
    }

    func latest(keywordID: UUID, watchedAppID: UUID) async throws -> RankCheck? {
        try await RankCheck.query(on: db)
            .filter(\.$keyword.$id == keywordID)
            .filter(\.$watchedApp.$id == watchedAppID)
            .sort(\.$checkedAt, .descending)
            .first()
    }

    func recent(keywordID: UUID, watchedAppID: UUID, limit: Int) async throws -> [RankCheck] {
        try await RankCheck.query(on: db)
            .filter(\.$keyword.$id == keywordID)
            .filter(\.$watchedApp.$id == watchedAppID)
            .sort(\.$checkedAt, .descending)
            .limit(limit)
            .all()
    }

    func history(keywordID: UUID, watchedAppID: UUID) async throws -> [RankCheck] {
        try await RankCheck.query(on: db)
            .filter(\.$keyword.$id == keywordID)
            .filter(\.$watchedApp.$id == watchedAppID)
            .sort(\.$checkedAt, .ascending)
            .all()
    }
}
