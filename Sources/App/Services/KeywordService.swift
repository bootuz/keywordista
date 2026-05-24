import Foundation

enum KeywordServiceError: Error, Equatable {
    case emptyTerm
    case invalidCountryCode
    case notFound
}

protocol KeywordServiceProtocol: Sendable {
    func list() async throws -> [Keyword]
    func create(term: String, countryCode: String, creatorID: UUID?) async throws -> Keyword
    func delete(id: UUID) async throws
    func enqueueRefresh(id: UUID) async throws
    func enqueueRefreshAll() async throws -> Int
}

extension KeywordServiceProtocol {
    /// Backwards-compat default — keeps existing test call sites
    /// on the simpler 2-arg form. New auth-aware call sites pass
    /// req.auth.get(User.self)?.id explicitly.
    func create(term: String, countryCode: String) async throws -> Keyword {
        try await create(term: term, countryCode: countryCode, creatorID: nil)
    }
}

struct KeywordService: KeywordServiceProtocol {
    let repository: any KeywordRepositoryProtocol
    let dispatcher: any RefreshDispatcherProtocol

    func list() async throws -> [Keyword] {
        try await repository.all()
    }

    func create(term: String, countryCode: String, creatorID: UUID?) async throws -> Keyword {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeywordServiceError.emptyTerm }
        let cc = countryCode.lowercased()
        guard cc.count == 2 else { throw KeywordServiceError.invalidCountryCode }

        let keyword = Keyword(term: trimmed, countryCode: cc, creatorID: creatorID)
        try await repository.save(keyword)
        try await dispatcher.dispatch(keywordID: try keyword.requireID())
        return keyword
    }

    func delete(id: UUID) async throws {
        try await repository.delete(id: id)
    }

    func enqueueRefresh(id: UUID) async throws {
        guard try await repository.find(id: id) != nil else { throw KeywordServiceError.notFound }
        try await dispatcher.dispatch(keywordID: id)
    }

    func enqueueRefreshAll() async throws -> Int {
        let keywords = try await repository.all()
        for keyword in keywords {
            try await dispatcher.dispatch(keywordID: try keyword.requireID())
        }
        return keywords.count
    }
}
