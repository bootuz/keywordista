import Vapor

struct AppsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let apps = routes.grouped("apps")
        apps.get(use: index)
        apps.post(use: create)
        apps.delete(":id", use: delete)
    }

    struct CreatePayload: Content {
        let appStoreId: Int64
        let lookupCountry: String?
    }

    @Sendable func index(req: Request) async throws -> [WatchedApp] {
        try await req.appService().list()
    }

    @Sendable func create(req: Request) async throws -> WatchedApp {
        let payload = try req.content.decode(CreatePayload.self)
        let app = try await req.appService().create(
            appStoreId: payload.appStoreId,
            lookupCountry: payload.lookupCountry ?? "us"
        )
        // Kick off the 175-storefront availability probe in the background so
        // the chart-watchdog has a narrowed sweep target on its next pass.
        // The HTTP response shouldn't wait on this — it can take ~60s.
        if let appID = app.id {
            let prober = req.availabilityProber()
            let logger = req.logger
            Task.detached {
                do {
                    _ = try await prober.probe(watchedAppID: appID)
                } catch {
                    logger.error("Initial availability probe failed for app=\(appID): \(error)")
                }
            }
        }
        return app
    }

    @Sendable func delete(req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid id")
        }
        try await req.appService().delete(id: id)
        return .noContent
    }
}
