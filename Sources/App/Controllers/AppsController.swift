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
        let lookupCountry = payload.lookupCountry ?? "us"
        // M1.10 auth attribution: in server mode AuthMiddleware has
        // logged the user in by now; in local mode req.auth is empty
        // and `.get(User.self)?.id` returns nil — both correct, since
        // WatchedApp.creator is @OptionalParent (NULL = pre-auth /
        // system-created / local mode).
        let creatorID = req.auth.get(User.self)?.id
        let app = try await req.appService().create(
            appStoreId: payload.appStoreId,
            lookupCountry: lookupCountry,
            kind: .own,
            creatorID: creatorID
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
            // Competitor analysis (v2): dispatch the first metadata
            // snapshot as a detached task, matching the prober pattern.
            // The HTTP response shouldn't wait on the ~600ms iTunes +
            // HTML round-trip; lazy backfill on /compare covers the
            // harmless race if the user opens compare before this
            // finishes. Failure is swallowed because the daily job
            // re-attempts on the next cycle.
            let snapshotService = req.appMetadataSnapshotService()
            let snapshotLogger = req.logger
            Task.detached {
                do {
                    _ = try await snapshotService.snapshot(watchedAppID: appID, country: lookupCountry)
                } catch {
                    snapshotLogger.warning("Initial metadata snapshot failed for app=\(appID): \(error)")
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
