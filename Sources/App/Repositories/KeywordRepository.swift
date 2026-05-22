import Fluent
import Foundation

protocol KeywordRepositoryProtocol: Sendable {
    func all() async throws -> [Keyword]
    func filtered(country: String?) async throws -> [Keyword]
    func find(id: UUID) async throws -> Keyword?
    func save(_ keyword: Keyword) async throws
    func delete(id: UUID) async throws
}

struct FluentKeywordRepository: KeywordRepositoryProtocol {
    let db: any Database

    func all() async throws -> [Keyword] {
        try await Keyword.query(on: db).sort(\.$term).all()
    }

    func filtered(country: String?) async throws -> [Keyword] {
        var query = Keyword.query(on: db)
        if let country {
            query = query.filter(\.$countryCode == country.lowercased())
        }
        return try await query.sort(\.$term).all()
    }

    func find(id: UUID) async throws -> Keyword? {
        try await Keyword.find(id, on: db)
    }

    func save(_ keyword: Keyword) async throws {
        try await keyword.save(on: db)
    }

    func delete(id: UUID) async throws {
        guard let keyword = try await Keyword.find(id, on: db) else { return }
        try await keyword.delete(on: db)
    }
}
