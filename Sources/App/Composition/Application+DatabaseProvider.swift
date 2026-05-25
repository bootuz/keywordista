import Vapor

/// Application-scoped storage for the resolved `DatabaseProvider`.
///
/// configure.swift resolves the SQLite-vs-Postgres choice once at
/// boot (§4.10); stashing the resolved enum here lets per-request
/// code (BackupController in particular) ask "am I running against
/// SQLite or Postgres?" without re-resolving from the manifest.
///
/// Same pattern as `Application.secretBox` (M1.9).
extension Application {

    var databaseProvider: DatabaseProvider? {
        get { storage[DatabaseProviderKey.self] }
        set { storage[DatabaseProviderKey.self] = newValue }
    }

    /// Non-optional variant — fatalErrors if unset. By the time a
    /// request lands, configure.swift must have set this.
    func requireDatabaseProvider() -> DatabaseProvider {
        guard let provider = databaseProvider else {
            fatalError(
                "Application.databaseProvider was not set before a request asked for it. " +
                "configure.swift must call `app.databaseProvider = ...` before routes() registers."
            )
        }
        return provider
    }

    private struct DatabaseProviderKey: StorageKey {
        typealias Value = DatabaseProvider
    }
}
