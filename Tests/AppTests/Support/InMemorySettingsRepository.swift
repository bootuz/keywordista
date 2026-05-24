@testable import App
import Foundation

/// In-memory SettingsRepositoryProtocol for tests that need to inspect
/// stored values directly (e.g. "did SettingsService actually store
/// the asc.privateKey value as an `enc:v1:...` envelope?").
///
/// Backed by a serial actor so concurrent test sites don't race —
/// matches the FluentSettingsRepository's "one DB statement at a
/// time" semantics under contention.
actor InMemorySettingsRepository: SettingsRepositoryProtocol {
    private var storage: [String: String] = [:]

    init(seed: [String: String] = [:]) {
        self.storage = seed
    }

    func get(_ key: String) async throws -> String? {
        storage[key]
    }

    func getMany(keys: [String]) async throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            storage[key].map { (key, $0) }
        })
    }

    func set(_ key: String, value: String) async throws {
        storage[key] = value
    }

    func delete(_ key: String) async throws {
        storage.removeValue(forKey: key)
    }

    /// Test-only: peek at the raw stored value (skips the unwrap that
    /// SettingsService would do on a read). Used to assert "the
    /// service stored this as an envelope, not as plaintext."
    func rawValue(of key: String) async -> String? {
        storage[key]
    }

    /// Test-only: snapshot the whole store. Useful for "the migration
    /// touched only the secret-shaped rows" assertions.
    func snapshot() async -> [String: String] {
        storage
    }
}
