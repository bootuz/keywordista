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
    // Optional rich projection — set explicitly for tests that exercise
    // the snapshot pipeline. Defaults to a minimal projection of the
    // thin `canned` so older tests don't have to construct it.
    private var cannedRich: RichLookupResultApp?
    private(set) var calls: [(appStoreId: Int64, country: String)] = []
    private(set) var richCalls: [(appStoreId: Int64, country: String)] = []

    init(canned: LookupResultApp, cannedRich: RichLookupResultApp? = nil) {
        self.canned = canned
        self.cannedRich = cannedRich
    }

    func lookup(appStoreId: Int64, country: String) async throws -> LookupResultApp {
        calls.append((appStoreId, country))
        return canned
    }

    func lookupRich(appStoreId: Int64, country: String) async throws -> RichLookupResultApp {
        richCalls.append((appStoreId, country))
        // Default rich projection: lift the thin `canned` into the rich
        // shape. Tests that need richer fields (description, subtitle-
        // adjacent ASO copy, ratings) override via the initializer.
        if let r = cannedRich { return r }
        return RichLookupResultApp(
            trackId: canned.trackId,
            bundleId: canned.bundleId,
            trackName: canned.trackName,
            version: nil,
            currentVersionReleaseDate: nil,
            releaseNotes: nil,
            releaseDate: nil,
            description: nil,
            sellerName: nil,
            primaryGenreName: nil,
            primaryGenreId: canned.primaryGenreId,
            genres: nil,
            artworkUrl100: canned.artworkUrl100,
            artworkUrl512: nil,
            screenshotUrls: nil,
            ipadScreenshotUrls: nil,
            price: nil,
            currency: nil,
            formattedPrice: nil,
            averageUserRating: nil,
            userRatingCount: nil,
            averageUserRatingForCurrentVersion: nil,
            userRatingCountForCurrentVersion: nil,
            contentAdvisoryRating: nil,
            languageCodesISO2A: nil,
            fileSizeBytes: nil,
            minimumOsVersion: nil
        )
    }

    func setCannedRich(_ rich: RichLookupResultApp) { cannedRich = rich }
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
