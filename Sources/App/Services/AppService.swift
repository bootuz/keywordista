import Foundation

protocol AppServiceProtocol: Sendable {
    func list() async throws -> [WatchedApp]
    func create(appStoreId: Int64, lookupCountry: String) async throws -> WatchedApp
    func delete(id: UUID) async throws
}

struct AppService: AppServiceProtocol {
    let repository: any WatchedAppRepositoryProtocol
    let lookupClient: any ITunesLookupClientProtocol

    func list() async throws -> [WatchedApp] {
        try await repository.all()
    }

    // `lookupCountry` only chooses which storefront's localized name + icon
    // to cache on the row. It does NOT constrain refreshes — the app gets
    // ranked in every country where a keyword exists.
    func create(appStoreId: Int64, lookupCountry: String) async throws -> WatchedApp {
        let country = lookupCountry.lowercased()
        let info = try await lookupClient.lookup(appStoreId: appStoreId, country: country)
        let app = WatchedApp(
            appStoreId: info.trackId,
            bundleId: info.bundleId,
            name: info.trackName,
            iconURL: info.artworkUrl100,
            primaryGenreId: info.primaryGenreId
        )
        try await repository.save(app)
        return app
    }

    func delete(id: UUID) async throws {
        try await repository.delete(id: id)
    }
}
