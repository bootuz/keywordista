import Vapor

/// Routes for competitor apps — the apps the user wants to compare against
/// their own. Backed by the same `AppService` + `WatchedApp` storage as
/// own apps; the `kind` flag is the only distinguishing field.
///
/// Why this is a separate controller from `AppsController` (rather than a
/// `?kind=competitor` filter on /apps): URL space is reserved for future
/// visibility / sharing rules (e.g. "private competitors per user")
/// without a breaking change to the established /apps shape. The two
/// controllers share a single backing service.
struct CompetitorsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let competitors = routes.grouped("competitors")
        competitors.get(use: index)
        competitors.post(use: create)
        competitors.delete(":id", use: delete)
        competitors.get("search", use: search)
        competitors.get("suggestions", use: suggestions)
    }

    struct CreatePayload: Content {
        let appStoreId: Int64
        let lookupCountry: String?
    }

    @Sendable func index(req: Request) async throws -> [WatchedApp] {
        // We list ALL competitors (not just user-scoped) for the same
        // reason `AppsController` lists all own apps — the existing
        // server-mode convention is "team-shared per instance" with
        // creator_user_id as audit-only attribution.
        try await req.appService().list().filter { $0.typedKind == .competitor }
    }

    @Sendable func create(req: Request) async throws -> WatchedApp {
        let payload = try req.content.decode(CreatePayload.self)
        let lookupCountry = payload.lookupCountry ?? "us"
        let creatorID = req.auth.get(User.self)?.id
        let app = try await req.appService().create(
            appStoreId: payload.appStoreId,
            lookupCountry: lookupCountry,
            kind: .competitor,
            creatorID: creatorID
        )
        // Detached first-snapshot fetch — same posture as
        // `AppsController.create` for own apps. The HTTP response
        // returns immediately; lazy backfill on `/compare` covers any
        // race where the user opens compare before the snapshot lands.
        // No availability prober for competitors (would be a 60s
        // 175-storefront sweep with no payoff — competitors don't
        // participate in chart watching).
        if let appID = app.id {
            let snapshotService = req.appMetadataSnapshotService()
            let logger = req.logger
            Task.detached {
                do {
                    _ = try await snapshotService.snapshot(watchedAppID: appID, country: lookupCountry)
                } catch {
                    logger.warning("Initial competitor metadata snapshot failed for app=\(appID): \(error)")
                }
            }
        }
        return app
    }

    @Sendable func delete(req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("id", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid id")
        }
        // Confirm the row is actually a competitor before deleting. This
        // is defense-in-depth — if a client mistakenly sends an own
        // app's UUID to /competitors/:id, we refuse rather than silently
        // delete a tracked own app + all its rank history (the cascade
        // on `RankCheck` is unforgiving).
        let appService = req.appService()
        let existing = try await appService.list().first { $0.id == id }
        guard let existing else {
            throw Abort(.notFound, reason: "competitor \(id) not found")
        }
        guard existing.typedKind == .competitor else {
            throw Abort(.badRequest, reason: "id \(id) is an own app, not a competitor — use DELETE /apps/:id")
        }
        try await appService.delete(id: id)
        return .noContent
    }

    /// Search for apps on the App Store, suitable for picking a
    /// competitor to add. Wraps `ITunesSearchClient`. Annotates each
    /// result with `alreadyTracked` so the UI can disable the "Add"
    /// button for apps that are already in `watched_apps` (regardless
    /// of kind — adding the same id twice would fail uniqueness).
    struct SearchHit: Content {
        let appStoreId: Int64
        let name: String
        let iconURL: String?
        let averageRating: Double?
        let ratingCount: Int?
        let alreadyTracked: Bool
        // If alreadyTracked, the kind of the existing row — helps the
        // UI explain "you've already added this as a competitor" vs.
        // "you've already added this as your own app".
        let existingKind: String?
    }

    @Sendable func search(req: Request) async throws -> [SearchHit] {
        guard let term = try? req.query.get(String.self, at: "term"), !term.isEmpty else {
            throw Abort(.badRequest, reason: "missing query param: term")
        }
        let country = (try? req.query.get(String.self, at: "country")) ?? "us"
        let limit = (try? req.query.get(Int.self, at: "limit")) ?? 20

        let searcher = ITunesSearchClient(client: req.client, logger: req.logger)
        let results = try await searcher.search(term: term, country: country, limit: limit)

        // Cross-reference against existing watched_apps so the UI can
        // disable already-added rows. One round trip; for the single-
        // user product this is trivially small.
        let existing = try await req.appService().list()
        let existingByID = Dictionary(uniqueKeysWithValues: existing.compactMap { app -> (Int64, WatchedAppKind)? in
            return (app.appStoreId, app.typedKind)
        })

        return results.map { hit in
            let existingKind = existingByID[hit.trackId]
            return SearchHit(
                appStoreId: hit.trackId,
                name: hit.trackName,
                iconURL: hit.artworkUrl100,
                averageRating: hit.averageUserRating,
                ratingCount: hit.userRatingCount,
                alreadyTracked: existingKind != nil,
                existingKind: existingKind?.rawValue
            )
        }
    }

    /// Phase-2 placeholder. The plan reserves this surface for an
    /// "auto-suggest competitors from top-results frequency" feature
    /// (the Q4 auto-suggest decision deferred from v1). Returns an
    /// empty list so the SPA's Suggestions panel collapses gracefully.
    /// When phase 2 ships, replace this with a real implementation that
    /// inspects `TopResultSnapshot` rows.
    @Sendable func suggestions(req: Request) async throws -> [SearchHit] {
        []
    }
}
