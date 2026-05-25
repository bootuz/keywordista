import XCTest

@testable import Keywordista

/// Coverage for HealthCoordinator's lifecycle + reconciliation.
///
/// We don't exercise the actual polling here (would require a stub
/// HTTP server) — that's an integration concern. These tests pin
/// the attach/detach/reconcile contract, which is the part that
/// most often regresses as the menubar app gains features.
final class HealthCoordinatorTests: XCTestCase {

    @MainActor
    private func makeLocal(port: UInt16 = 8080) -> Instance {
        Instance(
            id: UUID(),
            kind: .local(LocalInstance(baseURL: URL(string: "http://127.0.0.1:\(port)")!))
        )
    }

    @MainActor
    private func makeRemote() -> Instance {
        Instance(
            id: UUID(),
            kind: .remote(RemoteInstance(
                displayName: "Test",
                providerKind: .render,
                providerServiceId: "srv-xxxxx",
                baseURL: URL(string: "https://example.onrender.com")!,
                imageTag: "1.0.0",
                createdAt: Date(),
                providerManagedDatabaseId: nil
            ))
        )
    }

    @MainActor
    func testAttachStoresMonitor() {
        let coord = HealthCoordinator()
        let instance = makeLocal()
        coord.attach(instance)
        XCTAssertNotNil(coord.monitor(for: instance.id))
        coord.detach(id: instance.id)
    }

    @MainActor
    func testAttachTwiceReplacesPreviousMonitor() {
        // Pin the "idempotent re-attach" contract — important so the
        // boot wiring can attach repeatedly during state reconciliation
        // without leaking Tasks. Test by checking the monitor object
        // identity changes on second attach.
        let coord = HealthCoordinator()
        let instance = makeLocal()
        coord.attach(instance)
        let first = coord.monitor(for: instance.id)
        coord.attach(instance)
        let second = coord.monitor(for: instance.id)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertFalse(first === second, "re-attach should create a fresh monitor")
        coord.detach(id: instance.id)
    }

    @MainActor
    func testDetachUnknownIDIsNoOp() {
        let coord = HealthCoordinator()
        coord.detach(id: UUID())  // must not crash
        XCTAssertTrue(coord.monitors.isEmpty)
    }

    @MainActor
    func testReconcileAttachesNewInstancesAndDetachesRemoved() {
        let coord = HealthCoordinator()
        let a = makeLocal(port: 8080)
        let b = makeRemote()

        coord.reconcile(with: [a, b])
        XCTAssertEqual(coord.monitors.count, 2)
        XCTAssertNotNil(coord.monitor(for: a.id))
        XCTAssertNotNil(coord.monitor(for: b.id))

        // Drop `a`, keep `b`.
        coord.reconcile(with: [b])
        XCTAssertEqual(coord.monitors.count, 1)
        XCTAssertNil(coord.monitor(for: a.id))
        XCTAssertNotNil(coord.monitor(for: b.id))

        coord.detach(id: b.id)
    }

    @MainActor
    func testReconcilePreservesExistingMonitorsForUnchangedInstances() {
        // The critical "don't flicker the green dot" contract: a
        // reconcile that includes the same instance must NOT replace
        // its monitor (which would reset lastPingOk → isHealthy=false
        // for a brief moment, painting a red dot for one frame).
        let coord = HealthCoordinator()
        let a = makeLocal()
        coord.reconcile(with: [a])
        let original = coord.monitor(for: a.id)

        coord.reconcile(with: [a])  // same instance again
        let after = coord.monitor(for: a.id)

        XCTAssertTrue(original === after, "unchanged instance should keep its monitor")
        coord.detach(id: a.id)
    }

    @MainActor
    func testRollupEmptyIsGreen() {
        // First-run state — no instances yet, no sad icon.
        let coord = HealthCoordinator()
        XCTAssertEqual(coord.rollupStatus, .green)
    }

    // ── HealthPollInterval policy ────────────────────────────────────

    func testLocalPollIntervalIs2s() {
        XCTAssertEqual(HealthPollInterval.local, 2)
    }

    func testRemotePollIntervalIs30s() {
        XCTAssertEqual(HealthPollInterval.remote, 30)
    }
}
