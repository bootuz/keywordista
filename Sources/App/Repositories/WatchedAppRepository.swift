import Fluent
import Foundation

protocol WatchedAppRepositoryProtocol: Sendable {
    func all() async throws -> [WatchedApp]
    func find(id: UUID) async throws -> WatchedApp?
    func save(_ app: WatchedApp) async throws
    func delete(id: UUID) async throws
}

struct FluentWatchedAppRepository: WatchedAppRepositoryProtocol {
    let db: any Database

    func all() async throws -> [WatchedApp] {
        try await WatchedApp.query(on: db).sort(\.$addedAt).all()
    }

    func find(id: UUID) async throws -> WatchedApp? {
        try await WatchedApp.find(id, on: db)
    }

    func save(_ app: WatchedApp) async throws {
        try await app.save(on: db)
    }

    func delete(id: UUID) async throws {
        guard let app = try await WatchedApp.find(id, on: db) else { return }
        try await app.delete(on: db)
    }
}
