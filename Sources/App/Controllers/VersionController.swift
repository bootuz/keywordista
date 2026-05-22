import Vapor

// Exposes the running service's version and what GitHub's latest tagged
// release is. Used by the menubar app to decide whether to show an
// "update available" badge.
//
// Mounted under /api/v1/version (see routes.swift). No auth — matches the
// rest of the API after Phase 5b.
struct VersionController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("version", use: index)
    }

    @Sendable func index(req: Request) async throws -> VersionInfo {
        try await req.versionService().status()
    }
}
