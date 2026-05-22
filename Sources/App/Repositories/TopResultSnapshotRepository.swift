import Fluent
import Foundation

protocol TopResultSnapshotRepositoryProtocol: Sendable {
    func save(_ snapshot: TopResultSnapshot) async throws
    func latestSnapshot(keywordID: UUID) async throws -> [TopResultSnapshot]
}

struct FluentTopResultSnapshotRepository: TopResultSnapshotRepositoryProtocol {
    let db: any Database

    func save(_ snapshot: TopResultSnapshot) async throws {
        try await snapshot.save(on: db)
    }

    // Returns the most recent batch of position-1..5 rows for a keyword.
    // Fluent doesn't make "find the latest checkedAt then return all rows
    // at that timestamp" a single query, so do it in two hops.
    func latestSnapshot(keywordID: UUID) async throws -> [TopResultSnapshot] {
        guard let latestAt = try await TopResultSnapshot.query(on: db)
            .filter(\.$keyword.$id == keywordID)
            .sort(\.$checkedAt, .descending)
            .first()?.checkedAt
        else { return [] }

        return try await TopResultSnapshot.query(on: db)
            .filter(\.$keyword.$id == keywordID)
            .filter(\.$checkedAt == latestAt)
            .sort(\.$position)
            .all()
    }
}
