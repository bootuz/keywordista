import XCTest

@testable import Keywordista

/// Round-trip + persistence guarantees for InstanceStore.
///
/// The integration-y aspects (real Keychain, real provider APIs) are
/// deliberately out of scope here — those live in the release-pipeline
/// manual-E2E pass. This file pins the pure-Swift contract: encode,
/// write atomically, read, decode, get the same instances back.
final class InstanceStoreTests: XCTestCase {

    // ── Fixtures ─────────────────────────────────────────────────────

    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "instances-\(UUID().uuidString).json"
        )
    }

    private func makeLocal() -> Instance {
        Instance(
            id: UUID(),
            kind: .local(LocalInstance(baseURL: URL(string: "http://127.0.0.1:8080")!))
        )
    }

    private func makeRemote(name: String = "Studio (Render)") -> Instance {
        Instance(
            id: UUID(),
            kind: .remote(RemoteInstance(
                displayName: name,
                providerKind: .render,
                providerServiceId: "srv-abc123",
                providerAccountId: "tea-test",
                baseURL: URL(string: "https://example.onrender.com")!,
                imageTag: "1.0.0",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                providerManagedDatabaseId: nil
            ))
        )
    }

    // ── Round-trip ───────────────────────────────────────────────────

    @MainActor
    func testAddAndReadBack() async throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = InstanceStore(url: url)
        let local = makeLocal()
        let remote = makeRemote()

        try store.add(local)
        try store.add(remote)

        // Fresh store reads the persisted file. Same shape back.
        let reread = InstanceStore(url: url)
        XCTAssertEqual(reread.instances.count, 2)
        XCTAssertEqual(reread.instances[0].id, local.id)
        XCTAssertEqual(reread.instances[1].id, remote.id)
    }

    @MainActor
    func testKindRoundTripsLocalAndRemoteDistinctly() async throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = InstanceStore(url: url)
        try store.add(makeLocal())
        try store.add(makeRemote())

        let reread = InstanceStore(url: url)
        guard case .local = reread.instances[0].kind else {
            XCTFail("expected .local at index 0, got \(reread.instances[0].kind)")
            return
        }
        guard case .remote(let r) = reread.instances[1].kind else {
            XCTFail("expected .remote at index 1, got \(reread.instances[1].kind)")
            return
        }
        XCTAssertEqual(r.providerKind, .render)
        XCTAssertEqual(r.imageTag, "1.0.0")
    }

    // ── Mutation semantics ───────────────────────────────────────────

    @MainActor
    func testAddRejectsDuplicateID() throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = InstanceStore(url: url)
        let instance = makeRemote()
        try store.add(instance)
        XCTAssertThrowsError(try store.add(instance)) { err in
            guard case InstanceStoreError.duplicateID = err else {
                XCTFail("expected .duplicateID, got \(err)")
                return
            }
        }
    }

    @MainActor
    func testUpdateReplacesMatchingInstance() throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = InstanceStore(url: url)
        let original = makeRemote(name: "Original")
        try store.add(original)

        // Mutate the displayName and update.
        var mutated = original
        if case .remote(var r) = mutated.kind {
            r.displayName = "Renamed"
            mutated = Instance(id: original.id, kind: .remote(r))
        }
        try store.update(mutated)

        let reread = InstanceStore(url: url)
        XCTAssertEqual(reread.instances.first?.displayName, "Renamed")
    }

    @MainActor
    func testUpdateThrowsForMissingID() throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = InstanceStore(url: url)
        XCTAssertThrowsError(try store.update(makeRemote())) { err in
            guard case InstanceStoreError.notFound = err else {
                XCTFail("expected .notFound, got \(err)")
                return
            }
        }
    }

    @MainActor
    func testRemoveIsIdempotent() throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = InstanceStore(url: url)
        let instance = makeRemote()
        try store.add(instance)
        try store.remove(id: instance.id)
        // Second remove is a no-op, not an error.
        try store.remove(id: instance.id)
        XCTAssertTrue(store.instances.isEmpty)
    }

    // ── Resilience ───────────────────────────────────────────────────

    @MainActor
    func testCorruptFileReadsAsEmptyRatherThanCrashing() throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Plant garbage at the canonical path.
        try Data("not json at all { ] }".utf8).write(to: url)

        // Store boots successfully with empty instances — the user can
        // recover via "Add existing deployment". Crashing on a corrupt
        // file would lock them out of the app entirely.
        let store = InstanceStore(url: url)
        XCTAssertTrue(store.instances.isEmpty)
    }

    @MainActor
    func testMissingFileIsTreatedAsEmpty() throws {
        let url = tmpURL()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let store = InstanceStore(url: url)
        XCTAssertTrue(store.instances.isEmpty)
    }
}
