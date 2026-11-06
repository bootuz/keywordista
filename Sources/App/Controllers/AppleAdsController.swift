import Vapor

/// The Apple Ads area. Any signed-in member may read it and press Sync now;
/// credentials stay admin-only under `SettingsController`.
struct AppleAdsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let ads = routes.grouped("apple-ads")
        ads.post("sync", use: syncNow)
        ads.get("sync-status", use: syncStatus)
        ads.get("overview", use: overview)
        ads.get("keywords", use: keywords)
        ads.get("bid-ideas", use: bidIdeas)
    }

    @Sendable func syncNow(req: Request) async throws -> Response {
        try await Self.requireConnected(req)
        await req.application.appleAdsSyncCoordinator.start(trigger: .manual)
        let response = Response(status: .accepted)
        try response.content.encode(try await Self.status(req))
        return response
    }

    @Sendable func syncStatus(req: Request) async throws -> AppleAdsSyncStatus {
        try await Self.status(req)
    }

    @Sendable func overview(req: Request) async throws -> AppleAdsOverviewDTO {
        try await Self.requireConnected(req)
        let query = try req.query.decode(OverviewQuery.self)
        return try await req.appleAdsInsightsService().overview(watchedAppId: query.appId, days: query.days ?? 30)
    }

    @Sendable func keywords(req: Request) async throws -> [AppleAdsKeywordRowDTO] {
        try await Self.requireConnected(req)
        let query = try req.query.decode(OverviewQuery.self)
        return try await req.appleAdsInsightsService().keywords(watchedAppId: query.appId, days: query.days ?? 30)
    }

    @Sendable func bidIdeas(req: Request) async throws -> AppleAdsBidIdeasDTO {
        try await Self.requireConnected(req)
        let query = try req.query.decode(OverviewQuery.self)
        return try await req.appleAdsInsightsService().bidIdeas(watchedAppId: query.appId, days: query.days ?? 30)
    }

    /// `appId` is the watched app's UUID; `days` is 7 or 30 (default 30).
    struct OverviewQuery: Content {
        let appId: UUID
        let days: Int?
    }

    /// The screens read the local copy, but without credentials there is
    /// nothing to keep it current, so they show Setup instead.
    static func requireConnected(_ req: Request) async throws {
        guard try await req.settingsService().getASACredentials() != nil else {
            throw Abort(.conflict, reason: AppleAdsError.notConnected.description)
        }
    }

    static func status(_ req: Request) async throws -> AppleAdsSyncStatus {
        try await req.appleAdsInsightsService().syncStatus()
    }
}
