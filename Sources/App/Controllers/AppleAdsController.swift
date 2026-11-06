import Vapor

/// The Apple Ads area. Any signed-in member may read it and press Sync now;
/// credentials stay admin-only under `SettingsController`.
struct AppleAdsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let ads = routes.grouped("apple-ads")
        ads.post("sync", use: syncNow)
        ads.get("sync-status", use: syncStatus)
    }

    @Sendable func syncNow(req: Request) async throws -> Response {
        guard try await req.settingsService().getASACredentials() != nil else {
            throw Abort(.conflict, reason: AppleAdsError.notConnected.description)
        }
        await req.application.appleAdsSyncCoordinator.start(trigger: .manual)
        let response = Response(status: .accepted)
        try response.content.encode(try await Self.status(req))
        return response
    }

    @Sendable func syncStatus(req: Request) async throws -> AppleAdsSyncStatus {
        try await Self.status(req)
    }

    static func status(_ req: Request) async throws -> AppleAdsSyncStatus {
        let repository = req.appleAdsDataRepository()
        let lastRun = try await repository.latestRun()
        var lastSuccessAt: Date?
        if let account = lastRun?.adAccountId {
            lastSuccessAt = try await repository.lastSuccessfulRun(adAccountId: account)?.finishedAt
        }
        return AppleAdsSyncStatus(
            running: await req.application.appleAdsSyncCoordinator.isRunning,
            lastRun: lastRun,
            lastSuccessAt: lastSuccessAt
        )
    }
}
