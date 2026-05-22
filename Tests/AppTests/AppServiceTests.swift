@testable import App
import Foundation
import Testing

@Suite("AppService")
struct AppServiceTests {
    @Test("create enriches via lookup client and persists")
    func create_enrichesAndPersists() async throws {
        let lookup = LookupResultApp(trackId: 42, bundleId: "com.azri", trackName: "Azri", artworkUrl100: "https://icon")
        let repo = InMemoryWatchedAppRepository()
        let service = AppService(repository: repo, lookupClient: StubLookupClient(canned: lookup))

        let result = try await service.create(appStoreId: 42, lookupCountry: "US")

        #expect(result.appStoreId == 42)
        #expect(result.name == "Azri")
        #expect(result.bundleId == "com.azri")
        #expect(result.iconURL == "https://icon")

        let all = try await repo.all()
        #expect(all.count == 1)
    }

    @Test("list passes through repository state")
    func list_returnsRepository() async throws {
        let app = WatchedApp(id: UUID(), appStoreId: 1, bundleId: "a", name: "A", iconURL: nil)
        let repo = InMemoryWatchedAppRepository([app])
        let lookup = LookupResultApp(trackId: 1, bundleId: "a", trackName: "A", artworkUrl100: nil)
        let service = AppService(repository: repo, lookupClient: StubLookupClient(canned: lookup))

        let result = try await service.list()
        #expect(result.map(\.appStoreId) == [1])
    }
}
