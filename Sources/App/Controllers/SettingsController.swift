import Vapor

struct SettingsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let settings = routes.grouped("settings")
        settings.get("asc", use: getASC)
        settings.put("asc", use: putASC)
        settings.delete("asc", use: deleteASC)
        // Live-fetches the developer's per-locale keyword list from ASC using
        // the stored credentials. Returns {} when no creds are configured so
        // the SPA can call this unconditionally on every load.
        settings.get("asc", "keywords", use: getASCKeywords)
        settings.get("asa", use: getASA)
        settings.put("asa", use: putASA)
        settings.delete("asa", use: deleteASA)
    }

    // ── ASC ───────────────────────────────────────────────────────────────

    @Sendable func getASC(req: Request) async throws -> ASCStatus {
        try await req.settingsService().getASCStatus()
    }

    // `privateKey` is optional — when omitted/empty the existing stored key is
    // preserved. This lets the UI submit changes to keyId/issuerId without
    // requiring the user to re-paste the .p8 every time.
    struct ASCUpdatePayload: Content {
        let keyId: String
        let issuerId: String
        let privateKey: String?
    }

    @Sendable func putASC(req: Request) async throws -> ASCStatus {
        let payload = try req.content.decode(ASCUpdatePayload.self)
        let service = req.settingsService()

        let keyId = payload.keyId.trimmingCharacters(in: .whitespacesAndNewlines)
        let issuerId = payload.issuerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyId.isEmpty else { throw Abort(.badRequest, reason: "keyId is required") }
        guard !issuerId.isEmpty else { throw Abort(.badRequest, reason: "issuerId is required") }

        let resolvedPrivateKey: String
        if let pasted = payload.privateKey, !pasted.isEmpty {
            guard pasted.contains("BEGIN PRIVATE KEY") else {
                throw Abort(.badRequest, reason: "privateKey must be a PEM-formatted .p8 file content")
            }
            resolvedPrivateKey = pasted
        } else if let existing = try await service.getASCCredentials() {
            resolvedPrivateKey = existing.privateKey
        } else {
            throw Abort(.badRequest, reason: "privateKey is required for first-time setup")
        }

        try await service.setASCCredentials(ASCCredentials(
            keyId: keyId,
            issuerId: issuerId,
            privateKey: resolvedPrivateKey
        ))
        return try await service.getASCStatus()
    }

    @Sendable func deleteASC(req: Request) async throws -> HTTPStatus {
        try await req.settingsService().clearASCCredentials()
        return .noContent
    }

    // Response shape mirrors the SPA's `developerKeywords` store:
    //   { "<watchedAppUUID>": { "us": [...], "jp": [...] } }
    // Empty map (`{}`) is a valid, non-error response when ASC isn't
    // configured or the user has no watched apps yet.
    @Sendable func getASCKeywords(req: Request) async throws -> [String: [String: [String]]] {
        do {
            return try await req.developerKeywordsService().fetchAll()
        } catch let failure as AppStoreConnectClient.Failure {
            // Surface ASC-side errors as 502 so the SPA can render the
            // message in the Settings panel rather than swallowing it.
            throw Abort(.badGateway, reason: failure.description)
        }
    }

    // ── ASA ───────────────────────────────────────────────────────────────

    @Sendable func getASA(req: Request) async throws -> ASAStatus {
        try await req.settingsService().getASAStatus()
    }

    // `clientSecret` is optional — when omitted/empty the existing stored
    // secret is preserved.
    struct ASAUpdatePayload: Content {
        let clientId: String
        let clientSecret: String?
        let orgId: String?
    }

    @Sendable func putASA(req: Request) async throws -> ASAStatus {
        let payload = try req.content.decode(ASAUpdatePayload.self)
        let service = req.settingsService()

        let clientId = payload.clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientId.isEmpty else { throw Abort(.badRequest, reason: "clientId is required") }

        let resolvedSecret: String
        if let pasted = payload.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty {
            resolvedSecret = pasted
        } else if let existing = try await service.getASACredentials() {
            resolvedSecret = existing.clientSecret
        } else {
            throw Abort(.badRequest, reason: "clientSecret is required for first-time setup")
        }

        try await service.setASACredentials(ASACredentials(
            clientId: clientId,
            clientSecret: resolvedSecret,
            orgId: payload.orgId?.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        return try await service.getASAStatus()
    }

    @Sendable func deleteASA(req: Request) async throws -> HTTPStatus {
        try await req.settingsService().clearASACredentials()
        return .noContent
    }
}
