import Vapor

struct DashboardController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("dashboard", use: dashboard)
        routes.get("keywords", ":id", "history", use: history)
        routes.get("apps", ":id", "keywords", use: appKeywords)
        routes.get("apps", ":id", "gaps", use: competitorGaps)
    }

    @Sendable func dashboard(req: Request) async throws -> [DashboardRow] {
        let country = try? req.query.get(String.self, at: "country")
        return try await req.dashboardService().dashboard(country: country)
    }

    @Sendable func history(req: Request) async throws -> [HistoryPoint] {
        guard let keywordID = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        guard let appIDString = try? req.query.get(String.self, at: "watchedAppId"),
              let watchedAppID = UUID(uuidString: appIDString) else {
            throw Abort(.badRequest, reason: "watchedAppId query parameter required")
        }
        return try await req.dashboardService().history(keywordID: keywordID, watchedAppID: watchedAppID)
    }

    @Sendable func appKeywords(req: Request) async throws -> [AppKeywordRow] {
        guard let watchedAppID = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        return try await req.dashboardService().appKeywords(watchedAppID: watchedAppID)
    }

    // The competitor gap matrix for one of the user's own apps (`:id`):
    // every (tracked keyword × competitor) cell with my rank vs theirs.
    @Sendable func competitorGaps(req: Request) async throws -> [CompetitorGapRow] {
        guard let ownAppID = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        let country = try? req.query.get(String.self, at: "country")
        return try await req.competitorGapService().gaps(ownAppID: ownAppID, country: country)
    }
}
