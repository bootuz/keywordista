import Foundation
import os.log

/// Coordinator that owns the two destructive actions on remote
/// instances: Disconnect (forget locally, leave server running) and
/// Delete (call provider.destroy then forget). Lives outside MenuView_v2
/// because the menu can't easily run async + show confirmation dialogs;
/// KeywordistaApp wires NSAlert-based confirms around these calls.
///
/// **Why a separate class** vs. methods on InstanceStore: this needs
/// access to HealthCoordinator + [any Provider] + KeychainStore. Putting
/// it on InstanceStore would force the store to know about providers
/// (it shouldn't — InstanceStore is pure persistence). This is the
/// "orchestrator" sitting above stored state.
@MainActor
final class InstanceLifecycle {

    let instanceStore: InstanceStore
    let health: HealthCoordinator
    let providers: [any Provider]
    private let logger = Logger(subsystem: "app.keywordista.menubar", category: "InstanceLifecycle")

    init(
        instanceStore: InstanceStore,
        health: HealthCoordinator,
        providers: [any Provider]
    ) {
        self.instanceStore = instanceStore
        self.health = health
        self.providers = providers
    }

    /// Removes the instance from local state — InstanceStore +
    /// HealthCoordinator + session-cookie Keychain entry — but leaves
    /// the provider-side service running. Use for: "I want to stop
    /// tracking this from my menubar but my team is still using it."
    ///
    /// Provider API tokens are NOT removed because they may be shared
    /// across multiple instances on the same provider account.
    /// (M5's "list deployments under this token" UI will use this.)
    func disconnect(_ instance: Instance) {
        logger.info("disconnecting instance \(instance.id.uuidString, privacy: .public)")
        health.detach(id: instance.id)
        try? instanceStore.remove(id: instance.id)
        // Best-effort — Keychain may have no entry for this instance,
        // which is fine (idempotent).
        try? KeychainStore.removeSessionCookie(instanceID: instance.id)
    }

    /// Calls provider.destroy() to tear down the service (and its
    /// managed Postgres, if any), THEN runs disconnect. Throws if:
    ///   • The instance is local (use ServiceSupervisor.stop instead)
    ///   • The instance was imported (M3.10) and has no
    ///     providerAccountId — we have no API token to call destroy
    ///   • The provider implementation is missing from `providers`
    ///   • The provider's destroy() call throws (network, 403, etc.)
    ///
    /// On thrown error, local state is UNCHANGED — user can retry or
    /// Disconnect to give up.
    func delete(_ instance: Instance) async throws {
        guard case .remote(let remote) = instance.kind else {
            throw LifecycleError.localInstance
        }
        guard let accountId = remote.providerAccountId else {
            throw LifecycleError.importedInstance
        }
        guard let provider = providers.first(where: { $0.kind == remote.providerKind }) else {
            throw LifecycleError.providerNotAvailable(remote.providerKind)
        }
        guard let token = try? KeychainStore.providerToken(
            kind: remote.providerKind,
            account: accountId
        ) else {
            throw LifecycleError.missingToken
        }

        // Reconstruct the ProviderService handle from what we
        // persisted. We persisted enough to call destroy but not the
        // full original metadata; only the keys destroy() looks at
        // need to be present (id, managed_postgres_id).
        var serviceMetadata: [String: String] = [:]
        if let pgID = remote.providerManagedDatabaseId {
            serviceMetadata["managed_postgres_id"] = pgID
        }
        let service = ProviderService(
            id: remote.providerServiceId,
            metadata: serviceMetadata
        )

        logger.info("destroying instance \(instance.id.uuidString, privacy: .public) on provider \(remote.providerKind.rawValue, privacy: .public)")
        try await provider.destroy(service: service, token: token)

        // Only disconnect AFTER provider.destroy succeeds — if destroy
        // failed mid-way, we want the menubar to keep showing it so
        // the user can retry. Disconnecting now would orphan provider
        // resources silently.
        disconnect(instance)
    }
}

enum LifecycleError: Error, CustomStringConvertible {
    case localInstance
    case importedInstance
    case providerNotAvailable(ProviderKind)
    case missingToken

    var description: String {
        switch self {
        case .localInstance:
            return "Can't delete the local instance — use Stop instead."
        case .importedInstance:
            return "Can't delete deployments you imported via 'Add existing' — Disconnect removes them from the menubar instead."
        case .providerNotAvailable(let kind):
            return "No provider implementation for \(kind.rawValue) is registered."
        case .missingToken:
            return "API token for this deployment isn't in Keychain. The menubar can disconnect it but can't ask the provider to destroy it."
        }
    }
}
