import XCTest

@testable import Keywordista

/// Covers the disconnect + delete orchestration. The destructive
/// network call (provider.destroy) is exercised against a stub
/// provider — same pattern as M3.7's DeployFlowCoordinator tests.
final class InstanceLifecycleTests: XCTestCase {

    /// Spy provider — records destroy calls so tests can assert the
    /// right ProviderService was passed through.
    final class SpyProvider: Provider, @unchecked Sendable {
        var kind: ProviderKind = .render
        var displayName: String = "Spy"
        var marketingTagline: String = ""
        var supportLevel: ProviderSupport = .firstClass

        var destroyError: ProviderError?
        var destroyCalls: [(ProviderService, String)] = []

        func validateToken(_ token: String) async throws -> ProviderAccount { fatalError() }
        func availableRegions(account: ProviderAccount, token: String) async throws -> [Region] { [] }
        func availablePlans(account: ProviderAccount, token: String) async throws -> [Plan] { [] }
        func availableDatabases(account: ProviderAccount, token: String) async throws -> [DatabaseOption] { [] }
        func estimateMonthlyCost(spec: DeploymentSpec) -> Money { .zero }
        func validateServiceName(_ name: String) -> ServiceNameValidation { .ok }
        func publicURLPattern(serviceName: String) -> URL? { nil }   // M3.22
        func createService(spec: DeploymentSpec, token: String) async throws -> ProviderService { fatalError() }
        func streamDeployEvents(service: ProviderService, token: String) -> AsyncStream<DeployEvent> {
            AsyncStream { $0.finish() }
        }
        func currentImageTag(service: ProviderService, token: String) async throws -> String { "" }
        func updateImage(service: ProviderService, toTag tag: String, token: String) async throws {}
        func fetchLogs(service: ProviderService, since: Date, token: String) async throws -> [LogLine] { [] }
        func destroy(service: ProviderService, token: String) async throws {
            destroyCalls.append((service, token))
            if let destroyError { throw destroyError }
        }
    }

    // ── Disconnect ───────────────────────────────────────────────────

    @MainActor
    func testDisconnectRemovesInstanceFromStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inst-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = InstanceStore(url: url)
        let health = HealthCoordinator()
        let provider = SpyProvider()
        let lifecycle = InstanceLifecycle(
            instanceStore: store,
            health: health,
            providers: [provider]
        )

        let instance = remoteInstance(accountId: "tea-x")
        try store.add(instance)
        health.attach(instance)

        lifecycle.disconnect(instance)

        XCTAssertTrue(store.instances.isEmpty)
        XCTAssertNil(health.monitor(for: instance.id))
        // Disconnect didn't call destroy — provider should be untouched.
        XCTAssertTrue(provider.destroyCalls.isEmpty)
    }

    @MainActor
    func testDisconnectOnUnknownIDIsNoop() {
        let store = InstanceStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID()).json"))
        let lifecycle = InstanceLifecycle(
            instanceStore: store,
            health: HealthCoordinator(),
            providers: []
        )
        // Must not crash on a never-added instance — matches the
        // InstanceStore.remove idempotency contract.
        lifecycle.disconnect(remoteInstance(accountId: "tea-x"))
    }

    // ── Delete ───────────────────────────────────────────────────────

    @MainActor
    func testDeleteCallsProviderDestroyThenDisconnects() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inst-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        // Seed a token in Keychain so the lifecycle can find it.
        let accountId = "tea-\(UUID().uuidString)"
        try KeychainStore.setProviderToken("test-token", kind: .render, account: accountId)
        defer { try? KeychainStore.removeProviderToken(kind: .render, account: accountId) }

        let store = InstanceStore(url: url)
        let provider = SpyProvider()
        let lifecycle = InstanceLifecycle(
            instanceStore: store,
            health: HealthCoordinator(),
            providers: [provider]
        )

        let instance = remoteInstance(accountId: accountId)
        try store.add(instance)

        try await lifecycle.delete(instance)

        // Destroy was called once with the right service id + token.
        XCTAssertEqual(provider.destroyCalls.count, 1)
        XCTAssertEqual(provider.destroyCalls[0].0.id, "srv-test")
        XCTAssertEqual(provider.destroyCalls[0].1, "test-token")
        // ...and the instance is gone from local state.
        XCTAssertTrue(store.instances.isEmpty)
    }

    @MainActor
    func testDeletePassesManagedPostgresIDIfPresent() async throws {
        // Cockpit-provisioned instances with a managed PG carry the
        // PG ID in providerManagedDatabaseId. Lifecycle must forward
        // it into ProviderService.metadata so destroy can tear down
        // the PG too — otherwise the user keeps paying $7+/mo for an
        // orphan database.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inst-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let accountId = "tea-\(UUID().uuidString)"
        try KeychainStore.setProviderToken("tok", kind: .render, account: accountId)
        defer { try? KeychainStore.removeProviderToken(kind: .render, account: accountId) }

        let store = InstanceStore(url: url)
        let provider = SpyProvider()
        let lifecycle = InstanceLifecycle(
            instanceStore: store,
            health: HealthCoordinator(),
            providers: [provider]
        )

        var remote = remoteInstanceRemote(accountId: accountId)
        remote.providerManagedDatabaseId = "dpg-managed"
        let instance = Instance(id: UUID(), kind: .remote(remote))
        try store.add(instance)

        try await lifecycle.delete(instance)

        XCTAssertEqual(
            provider.destroyCalls[0].0.metadata["managed_postgres_id"],
            "dpg-managed",
            "managed_postgres_id must flow into the destroy call so the PG gets cleaned up"
        )
    }

    @MainActor
    func testDeleteLeavesLocalStateAloneOnProviderFailure() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inst-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let accountId = "tea-\(UUID().uuidString)"
        try KeychainStore.setProviderToken("tok", kind: .render, account: accountId)
        defer { try? KeychainStore.removeProviderToken(kind: .render, account: accountId) }

        let store = InstanceStore(url: url)
        let provider = SpyProvider()
        // Force destroy to fail — simulates Render returning 500.
        provider.destroyError = .unknown(detail: "render is down")

        let lifecycle = InstanceLifecycle(
            instanceStore: store,
            health: HealthCoordinator(),
            providers: [provider]
        )

        let instance = remoteInstance(accountId: accountId)
        try store.add(instance)

        do {
            try await lifecycle.delete(instance)
            XCTFail("expected throw")
        } catch is ProviderError {
            // expected
        }
        // Critical: local state UNCHANGED on destroy failure. User
        // can retry. The alternative (silent disconnect on failure)
        // would orphan the provider-side service.
        XCTAssertEqual(store.instances.count, 1)
    }

    @MainActor
    func testDeleteThrowsForLocalInstance() async throws {
        let store = InstanceStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID()).json"))
        let lifecycle = InstanceLifecycle(
            instanceStore: store,
            health: HealthCoordinator(),
            providers: []
        )
        let local = Instance(
            id: UUID(),
            kind: .local(LocalInstance(baseURL: URL(string: "http://127.0.0.1:8080")!))
        )

        do {
            try await lifecycle.delete(local)
            XCTFail("expected throw")
        } catch LifecycleError.localInstance {
            // expected
        }
    }

    @MainActor
    func testDeleteThrowsForImportedInstanceWithoutAccountId() async throws {
        let store = InstanceStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID()).json"))
        let lifecycle = InstanceLifecycle(
            instanceStore: store,
            health: HealthCoordinator(),
            providers: [SpyProvider()]
        )
        let imported = Instance(
            id: UUID(),
            kind: .remote(RemoteInstance(
                displayName: "imported",
                providerKind: .customDockerHost,
                providerServiceId: "imported",
                providerAccountId: nil,  // imported instances have no token
                baseURL: URL(string: "https://example.com")!,
                imageTag: "unknown",
                createdAt: Date(),
                providerManagedDatabaseId: nil
            ))
        )

        do {
            try await lifecycle.delete(imported)
            XCTFail("expected throw")
        } catch LifecycleError.importedInstance {
            // expected — user must use Disconnect instead
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────

    @MainActor
    private func remoteInstanceRemote(accountId: String) -> RemoteInstance {
        RemoteInstance(
            displayName: "Test",
            providerKind: .render,
            providerServiceId: "srv-test",
            providerAccountId: accountId,
            baseURL: URL(string: "https://test.onrender.com")!,
            imageTag: "1.0.0",
            createdAt: Date(),
            providerManagedDatabaseId: nil
        )
    }

    @MainActor
    private func remoteInstance(accountId: String) -> Instance {
        Instance(id: UUID(), kind: .remote(remoteInstanceRemote(accountId: accountId)))
    }
}
