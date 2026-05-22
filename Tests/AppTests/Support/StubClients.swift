@testable import App
import Foundation

actor StubSearchClient: ITunesSearchClientProtocol {
    private let canned: [SearchResultApp]
    private(set) var calls: [(term: String, country: String, limit: Int)] = []

    init(canned: [SearchResultApp]) { self.canned = canned }

    func search(term: String, country: String, limit: Int) async throws -> [SearchResultApp] {
        calls.append((term, country, limit))
        return canned
    }
}

actor StubLookupClient: ITunesLookupClientProtocol {
    private let canned: LookupResultApp
    private(set) var calls: [(appStoreId: Int64, country: String)] = []

    init(canned: LookupResultApp) { self.canned = canned }

    func lookup(appStoreId: Int64, country: String) async throws -> LookupResultApp {
        calls.append((appStoreId, country))
        return canned
    }
}

actor RecordingDispatcher: RefreshDispatcherProtocol {
    private(set) var dispatched: [UUID] = []

    func dispatch(keywordID: UUID) async throws {
        dispatched.append(keywordID)
    }
}

extension SearchResultApp {
    static func fixture(
        id: Int64,
        name: String? = nil,
        ratings: Int? = nil,
        avgRating: Double? = nil,
        release: Date? = nil
    ) -> SearchResultApp {
        SearchResultApp(
            trackId: id,
            bundleId: "com.test.\(id)",
            trackName: name ?? "App \(id)",
            artworkUrl100: "https://icon/\(id).png",
            userRatingCount: ratings,
            averageUserRating: avgRating,
            releaseDate: release
        )
    }
}
