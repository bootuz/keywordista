import Vapor

/// Application-scoped storage for the runtime SecretBox.
///
/// Constructed once at boot in configure.swift (after the encryption
/// key resolves from the manifest), stashed here so per-request DI
/// in Container.swift can hand the same instance to every
/// SettingsService construction without re-running the
/// IOKit-touching key resolver per request.
///
/// **Mode behavior**:
///   • Server mode: key comes from KEYWORDISTA_ENCRYPTION_KEY env;
///     boot fails fast if missing (manifest's requiredIn check).
///   • Local mode: key derives from IOPlatformUUID via
///     EncryptionKeyResolver; deterministic across boots on the
///     same Mac, so existing SQLite stays decryptable.
extension Application {

    /// Read the runtime SecretBox if it's been set. Nil during the
    /// brief window between `Application` init and configure.swift's
    /// boot-time setup; should never be nil after that.
    var secretBox: SecretBox? {
        get { storage[SecretBoxKey.self] }
        set { storage[SecretBoxKey.self] = newValue }
    }

    /// Same as `secretBox` but `fatalError`s if unset. Use this
    /// from per-request service factories where 'unset' would
    /// indicate a configure.swift bug — failing fast at the
    /// access site beats a confusing nil-credential later.
    func requireSecretBox() -> SecretBox {
        guard let box = secretBox else {
            fatalError(
                "Application.secretBox was not set before a request asked for it. " +
                "configure.swift must call `app.secretBox = SecretBox(key: ...)` " +
                "before routes(_:) registers controllers that touch credentials."
            )
        }
        return box
    }

    private struct SecretBoxKey: StorageKey {
        typealias Value = SecretBox
    }
}
