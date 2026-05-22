@testable import App
import Foundation
import Testing

@Suite("KeywordService")
struct KeywordServiceTests {
    @Test("create saves the keyword and dispatches a refresh")
    func create_savesAndDispatches() async throws {
        let repo = InMemoryKeywordRepository()
        let dispatcher = RecordingDispatcher()
        let service = KeywordService(repository: repo, dispatcher: dispatcher)

        let keyword = try await service.create(term: "  flashcards  ", countryCode: "US")

        #expect(keyword.term == "flashcards")
        #expect(keyword.countryCode == "us")
        let dispatched = await dispatcher.dispatched
        #expect(dispatched == [try keyword.requireID()])
    }

    @Test("create rejects empty term")
    func create_emptyTerm() async {
        let service = KeywordService(repository: InMemoryKeywordRepository(), dispatcher: RecordingDispatcher())
        await #expect(throws: KeywordServiceError.emptyTerm) {
            try await service.create(term: "   ", countryCode: "us")
        }
    }

    @Test("create rejects invalid country code")
    func create_invalidCountry() async {
        let service = KeywordService(repository: InMemoryKeywordRepository(), dispatcher: RecordingDispatcher())
        await #expect(throws: KeywordServiceError.invalidCountryCode) {
            try await service.create(term: "flashcards", countryCode: "USA")
        }
    }

    @Test("enqueueRefresh throws notFound for unknown id")
    func refresh_notFound() async {
        let service = KeywordService(repository: InMemoryKeywordRepository(), dispatcher: RecordingDispatcher())
        await #expect(throws: KeywordServiceError.notFound) {
            try await service.enqueueRefresh(id: UUID())
        }
    }

    @Test("enqueueRefreshAll dispatches one job per keyword and returns the count")
    func refreshAll_dispatchesEach() async throws {
        let kw1 = Keyword(id: UUID(), term: "a", countryCode: "us")
        let kw2 = Keyword(id: UUID(), term: "b", countryCode: "us")
        let repo = InMemoryKeywordRepository([kw1, kw2])
        let dispatcher = RecordingDispatcher()
        let service = KeywordService(repository: repo, dispatcher: dispatcher)

        let count = try await service.enqueueRefreshAll()

        #expect(count == 2)
        let dispatched = await dispatcher.dispatched
        #expect(Set(dispatched) == Set([try kw1.requireID(), try kw2.requireID()]))
    }
}
