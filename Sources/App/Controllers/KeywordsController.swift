import Vapor

struct KeywordsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let kw = routes.grouped("keywords")
        kw.get(use: index)
        kw.post(use: create)
        kw.delete(":id", use: delete)
        kw.post(":id", "refresh", use: refresh)
        // Mines Apple Search Ads search-term reports for terms related to
        // this seed keyword. Returns [] when ASA isn't configured or the
        // user has no campaigns serving the seed's storefront — that's the
        // common case until a discovery campaign accumulates data.
        kw.get(":id", "suggestions", use: suggestions)

        routes.post("refresh-all", use: refreshAll)
        routes.get("refresh-status", use: refreshStatus)
    }

    struct CreatePayload: Content {
        let term: String
        let countryCode: String
    }

    struct RefreshResponse: Content { let enqueued: Int }

    @Sendable func index(req: Request) async throws -> [Keyword] {
        try await req.keywordService().list()
    }

    @Sendable func create(req: Request) async throws -> Keyword {
        let payload = try req.content.decode(CreatePayload.self)
        // M1.10 auth attribution — see AppsController.create.
        let creatorID = req.auth.get(User.self)?.id
        do {
            return try await req.keywordService().create(
                term: payload.term,
                countryCode: payload.countryCode,
                creatorID: creatorID
            )
        } catch KeywordServiceError.emptyTerm {
            throw Abort(.badRequest, reason: "term empty")
        } catch KeywordServiceError.invalidCountryCode {
            throw Abort(.badRequest, reason: "countryCode must be ISO 3166-1 alpha-2")
        }
    }

    @Sendable func delete(req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        try await req.keywordService().delete(id: id)
        return .noContent
    }

    @Sendable func refresh(req: Request) async throws -> Response {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        do {
            try await req.keywordService().enqueueRefresh(id: id)
        } catch KeywordServiceError.notFound {
            throw Abort(.notFound)
        }
        let response = Response(status: .accepted)
        try response.content.encode(RefreshResponse(enqueued: 1))
        return response
    }

    @Sendable func refreshAll(req: Request) async throws -> Response {
        let enqueued = try await req.keywordService().enqueueRefreshAll()
        let response = Response(status: .accepted)
        try response.content.encode(RefreshResponse(enqueued: enqueued))
        return response
    }

    @Sendable func refreshStatus(req: Request) async throws -> QueueStatus {
        try await req.queueStatusService().status()
    }

    @Sendable func suggestions(req: Request) async throws -> [SuggestionRow] {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        do {
            return try await req.keywordSuggestionService().suggest(seedKeywordId: id)
        } catch let failure as AppleSearchAdsClient.Failure {
            // Surface Apple's reason text so the panel can render it.
            throw Abort(.badGateway, reason: failure.description)
        }
    }
}
