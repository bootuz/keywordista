import Foundation

protocol AppServiceProtocol: Sendable {
    func list() async throws -> [WatchedApp]
    func create(appStoreId: Int64, lookupCountry: String, creatorID: UUID?) async throws -> WatchedApp
    func delete(id: UUID) async throws
}

extension AppServiceProtocol {
    /// Backwards-compat default — keeps existing call sites
    /// (and tests) that don't pass creatorID compiling unchanged.
    /// New auth-aware call sites pass req.auth.get(User.self)?.id.
    func create(appStoreId: Int64, lookupCountry: String) async throws -> WatchedApp {
        try await create(appStoreId: appStoreId, lookupCountry: lookupCountry, creatorID: nil)
    }
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
    //
    // `creatorID` is the M1.8 auth attribution. In server mode the controller
    // threads `req.auth.get(User.self)?.id`; in local mode it's always nil
    // (no auth middleware → no logged-in user). The default-extension above
    // keeps non-controller call sites + tests on the simpler 2-arg form.
    func create(appStoreId: Int64, lookupCountry: String, creatorID: UUID?) async throws -> WatchedApp {
        let country = lookupCountry.lowercased()
        let info = try await lookupClient.lookup(appStoreId: appStoreId, country: country)
        let app = WatchedApp(
            appStoreId: info.trackId,
            bundleId: info.bundleId,
            name: info.trackName,
            iconURL: info.artworkUrl100,
            primaryGenreId: info.primaryGenreId,
            creatorID: creatorID
        )
        try await repository.save(app)
        return app
    }

    func delete(id: UUID) async throws {
        try await repository.delete(id: id)
    }
}
