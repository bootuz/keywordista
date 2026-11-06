import AppleAdsClient
import Crypto
import Foundation
import Logging
import OpenAPIRuntime
import ServiceLifecycle
import Vapor

/// Owns the process's one live `AppleAdsClient`.
///
/// Why long-lived: the library authenticates when a client is created, so a
/// client per request would mean an OAuth exchange on every dashboard load.
/// Why a `ServiceGroup`: the client holds an AsyncHTTPClient for token
/// refresh that must be shut down before it's released (AsyncHTTPClient
/// traps otherwise); the library only does that cleanup at the end of its
/// `Service.run()`, so each client runs in a group we can stop gracefully
/// when credentials change or the server shuts down.
actor AppleAdsSession {
    typealias Factory = @Sendable (ASACredentials) async throws -> AppleAdsClient

    private struct Live {
        let fingerprint: String
        let client: AppleAdsClient
        let group: ServiceGroup
        let runTask: Task<Void, Never>
    }

    private let makeClient: Factory
    private let logger: Logger
    private var live: Live?
    private var pending: (fingerprint: String, task: Task<AppleAdsClient, any Error>)?

    /// Number of clients fully shut down. Lets tests prove the old client
    /// was released rather than leaked.
    private(set) var completedShutdowns = 0

    /// Ad accounts resolved from the ACL list, keyed by credentials + legacy
    /// org ID. In memory only: the user's explicit choice is what persists
    /// (in settings), this just saves an ACL round-trip per request.
    private var resolvedAccounts: [String: Int64] = [:]

    init(logger: Logger, makeClient: @escaping Factory) {
        self.logger = logger
        self.makeClient = makeClient
    }

    /// Production wiring: the stored client-secret JWT, plus `middleware`
    /// (the 429 retry policy) on every request.
    static func live(
        logger: Logger,
        middleware: [any ClientMiddleware] = [AppleAdsRetryMiddleware()]
    ) -> AppleAdsSession {
        AppleAdsSession(logger: logger) { creds in
            try await AppleAdsClient(configuration: .init(
                clientId: creds.clientId,
                authMode: .clientSecretProvider(StoredClientSecretProvider(secret: creds.clientSecret)),
                middleware: middleware
            ))
        }
    }

    /// The generated API client for `credentials`, reusing the live one when
    /// the credentials haven't changed.
    func client(for credentials: ASACredentials) async throws -> AppleAdsAPI {
        let fingerprint = Self.fingerprint(credentials)
        if let live, live.fingerprint == fingerprint { return live.client.client }
        // Concurrent first calls share one construction (one OAuth exchange).
        if let pending, pending.fingerprint == fingerprint {
            return try await pending.task.value.client
        }

        let factory = makeClient
        let task = Task { try await factory(credentials) }
        pending = (fingerprint, task)
        let made: AppleAdsClient
        do {
            made = try await task.value
        } catch {
            if pending?.fingerprint == fingerprint { pending = nil }
            throw error
        }
        if pending?.fingerprint == fingerprint { pending = nil }

        let previous = live
        live = start(made, fingerprint: fingerprint)
        if let previous { await stop(previous) }
        return made.client
    }

    func resolvedAdAccount(for credentials: ASACredentials) -> Int64? {
        resolvedAccounts[Self.accountKey(credentials)]
    }

    func rememberAdAccount(_ id: Int64, for credentials: ASACredentials) {
        resolvedAccounts[Self.accountKey(credentials)] = id
    }

    /// Stops the live client. Safe to call more than once.
    func shutdown() async {
        guard let current = live else { return }
        live = nil
        await stop(current)
    }

    private func start(_ client: AppleAdsClient, fingerprint: String) -> Live {
        let group = ServiceGroup(services: [client], gracefulShutdownSignals: [], logger: logger)
        let log = logger
        let runTask = Task {
            do { try await group.run() } catch {
                log.warning("Apple Ads client stopped with error: \(error)")
            }
        }
        return Live(fingerprint: fingerprint, client: client, group: group, runTask: runTask)
    }

    private func stop(_ entry: Live) async {
        await entry.group.triggerGracefulShutdown()
        await entry.runTask.value
        completedShutdowns += 1
    }

    private static func accountKey(_ credentials: ASACredentials) -> String {
        "\(fingerprint(credentials))\u{0}\(credentials.orgId ?? "")"
    }

    /// Hash rather than the raw secret, so the JWT isn't kept around as a key.
    private static func fingerprint(_ credentials: ASACredentials) -> String {
        let digest = SHA256.hash(data: Data("\(credentials.clientId)\u{0}\(credentials.clientSecret)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Stops the Apple Ads client when Vapor shuts down.
struct AppleAdsSessionShutdown: LifecycleHandler {
    func shutdownAsync(_ application: Application) async {
        await application.appleAdsSession.shutdown()
    }
}
