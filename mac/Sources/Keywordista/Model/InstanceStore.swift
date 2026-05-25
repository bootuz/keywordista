import Foundation
import os.log

/// Source-of-truth for the menubar app's known instances. Backed by a
/// JSON file at ~/Library/Application Support/Keywordista/instances.json.
///
/// **Why a file instead of UserDefaults**: instances.json is ~1-5 KB of
/// stable structured data that benefits from being inspectable (`cat
/// instances.json` in Terminal during support). UserDefaults would
/// require parsing plist + dealing with prefs caching daemon quirks
/// for marginal storage savings.
///
/// **Why not SQLite**: 5-10 rows max, no querying needed. SQLite would
/// be 50 KB of dependency overhead for a glorified array.
///
/// **Sensitive material**: provider API tokens + per-instance session
/// cookies live in Keychain, NOT in this file. The file is
/// world-readable to anything running as the user — losing it (or
/// having a malicious app read it) leaks the deployment topology,
/// not the secrets that protect it.
@MainActor
final class InstanceStore: ObservableObject {

    /// Observed by views via SwiftUI's environment + @Published. Always
    /// reflects the current persisted state; mutations go through the
    /// store's add/update/remove methods so the disk + memory stay in sync.
    @Published private(set) var instances: [Instance] = []

    private let url: URL
    private let logger = Logger(subsystem: "app.keywordista.menubar", category: "InstanceStore")

    /// Default init reads from the conventional location. Tests inject
    /// a tmpdir URL.
    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent("Keywordista", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: appSupport,
                withIntermediateDirectories: true
            )
            self.url = appSupport.appendingPathComponent("instances.json")
        }
        self.instances = Self.read(from: self.url)
    }

    // MARK: - Mutations

    /// Adds a new instance. Persists synchronously to disk before
    /// returning so a crash immediately after returning still has the
    /// instance recorded (otherwise: cockpit creates a $7/mo Render
    /// service, crashes, user has no record of what to clean up).
    func add(_ instance: Instance) throws {
        guard !instances.contains(where: { $0.id == instance.id }) else {
            throw InstanceStoreError.duplicateID(instance.id)
        }
        instances.append(instance)
        try persist()
    }

    /// Replaces the matching instance (by id). Throws `notFound` if the
    /// id doesn't exist — callers should add-or-update intentionally,
    /// not by accident.
    func update(_ instance: Instance) throws {
        guard let idx = instances.firstIndex(where: { $0.id == instance.id }) else {
            throw InstanceStoreError.notFound(instance.id)
        }
        instances[idx] = instance
        try persist()
    }

    /// Removes by id. Idempotent — removing a non-existent id is a no-op
    /// (matches the "Disconnect" UX where a stale menu item could fire
    /// twice before the menu re-renders).
    func remove(id: UUID) throws {
        let before = instances.count
        instances.removeAll { $0.id == id }
        if instances.count != before {
            try persist()
        }
    }

    // MARK: - Persistence

    /// Atomic write: encode to a sibling .tmp file, fsync, rename over
    /// the real file. POSIX guarantees rename is atomic — readers see
    /// either the old file or the new one, never a half-written mess.
    ///
    /// Catches the worst-case failure mode: power loss mid-write
    /// orphaning a $7/mo Render deployment because cockpit forgot it
    /// existed. Costs one extra inode briefly during the swap.
    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(instances)

        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: [.atomic])
        // .atomic on Data.write already does the rename trick on Darwin,
        // but we then move our .tmp file to the canonical path so future
        // reads find it. (Could just write directly to `url` with .atomic
        // — but the explicit tmp lets us reason about the failure modes.)
        try FileManager.default.replaceItem(
            at: url,
            withItemAt: tmp,
            backupItemName: nil,
            options: [],
            resultingItemURL: nil
        )
    }

    /// Read at boot. Missing file is normal (first run); corrupted file
    /// is logged at error level and treated as empty. We DON'T crash —
    /// the menubar app must always boot, even if the user's data dir
    /// was corrupted by an unrelated process. Worst case: they reconnect
    /// their existing deployments via "Add existing deployment…".
    private static func read(from url: URL) -> [Instance] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Instance].self, from: data)
        } catch {
            Logger(subsystem: "app.keywordista.menubar", category: "InstanceStore")
                .error("corrupt instances.json at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

enum InstanceStoreError: Error, CustomStringConvertible {
    case duplicateID(UUID)
    case notFound(UUID)

    var description: String {
        switch self {
        case .duplicateID(let id): return "instance \(id) already exists"
        case .notFound(let id): return "no instance with id \(id)"
        }
    }
}
