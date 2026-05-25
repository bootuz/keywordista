import Foundation

/// One of N Keywordista deployments the menubar app tracks.
///
/// **Why this exists**: pre-M3 the menubar app supervised exactly one local
/// backend. M3 turns it into a multi-instance orchestrator (local + any
/// number of remote PaaS deployments). Instance is the abstraction every
/// downstream system iterates over: the menu rendering (MenuView_v2),
/// health polling (HealthCoordinator), the "Open dashboard" / "View logs" /
/// "Update" actions, persistence (InstanceStore).
///
/// **Why a sum type (`InstanceKind`)**: local and remote instances have
/// genuinely different identity. The local one is "the supervisor's child
/// process" — there's exactly one, identified by the running PID, owning
/// secrets in macOS Keychain via MachineUUID-derived crypto. A remote one
/// is "a service we created on someone's PaaS account" — many possible,
/// identified by provider service ID, owning provider API tokens AND a
/// session cookie for the deployed instance. The pattern-matching
/// exhaustiveness check at every consumer (`switch instance.kind`) is the
/// strongest enforcement against "did we forget the remote case here?"
/// bugs as the orchestrator grows.
struct Instance: Identifiable, Sendable, Codable, Equatable {
    /// Stable identifier persisted in `instances.json`. Used as the key
    /// in HealthCoordinator's monitor map and as the account-name in
    /// Keychain entries (so deleting an instance can wipe its secrets
    /// without touching others'). UUID generated at instance creation,
    /// never mutated.
    let id: UUID
    let kind: InstanceKind

    /// User-facing name shown in the menu. For local it's hardcoded to
    /// "Local Instance"; for remote it's whatever the user typed in the
    /// "Service name" field of the deploy wizard (e.g. "Studio (Render)").
    var displayName: String {
        switch kind {
        case .local: return "Local Instance"
        case .remote(let r): return r.displayName
        }
    }

    /// Base URL of the deployment's API. For local: http://127.0.0.1:<port>
    /// (port resolved at ServiceSupervisor start time, captured here at
    /// instance-creation). For remote: the provider-assigned public URL,
    /// e.g. https://keywordista-studio-a8x21.onrender.com.
    var baseURL: URL {
        switch kind {
        case .local(let l): return l.baseURL
        case .remote(let r): return r.baseURL
        }
    }
}

/// Sum type discriminator. Switch-exhaustive at every consumer.
enum InstanceKind: Sendable, Codable, Equatable {
    case local(LocalInstance)
    case remote(RemoteInstance)
}

// MARK: - Local

/// The menubar-supervised backend. There's exactly one of these per
/// machine (enforced by ServiceSupervisor binding to a fixed local
/// port range). Its baseURL is captured at supervisor start so the
/// menu's "Open dashboard" link stays correct even when the port
/// fallback (8080 → 8090) kicks in.
struct LocalInstance: Sendable, Codable, Equatable {
    let baseURL: URL
}

// MARK: - Remote

/// A deployment created by the cockpit (or imported via "Add existing").
/// Identifies the resource on the provider side via `providerServiceId`
/// — never assumes we can re-derive it from the URL.
///
/// **What's NOT in this struct** and why:
///   • Provider API token → Keychain (service: app.keywordista.providers.<kind>).
///     Lives next to the user, not in the JSON; rotating the token doesn't
///     require touching instances.json.
///   • Session cookie for /api/v1/* against this deployment → Keychain
///     (service: app.keywordista.sessions, account: instance UUID).
///   • Provisioned managed-DB metadata → see `providerManagedDatabaseId`.
///     Tracked here because destroying the web service needs to also
///     destroy the PG (otherwise the user keeps paying $7/mo for an
///     orphan database).
struct RemoteInstance: Sendable, Codable, Equatable {
    var displayName: String
    let providerKind: ProviderKind
    /// The provider's opaque service identifier. Render uses "srv-xxxxxxxx";
    /// Fly uses the app name; etc. Treated as a black-box string here —
    /// providers parse it themselves.
    let providerServiceId: String
    /// The provider-account ID the API token in Keychain is filed under.
    /// Needed for Delete (destroy → provider.destroy needs the token).
    /// nil for instances added via "Add existing deployment" (M3.10) —
    /// the cockpit didn't provision them and has no token, so Delete
    /// is unavailable for those (Disconnect still works).
    let providerAccountId: String?
    let baseURL: URL
    /// Image tag the deployment was created with (e.g. "1.0.0" or a
    /// digest). Surfaced by RemoteUpdateChecker (M5) when comparing
    /// to the latest published tag.
    var imageTag: String
    let createdAt: Date
    /// Non-nil iff the cockpit provisioned a managed Postgres alongside
    /// this service (DatabaseChoice.providerManagedPostgres). Destroying
    /// the instance must destroy this database too — otherwise the
    /// user's provider bill keeps charging for an orphan DB.
    var providerManagedDatabaseId: String?
}

// MARK: - Provider identity

/// Stable identifier for which Provider implementation owns a given
/// remote instance. Lives in `Model/` rather than `Provider/` because
/// it's persisted in instances.json — every Provider-protocol method
/// has to be looked up from this value at read time.
///
/// Strings (not Int rawValue) so adding a new case in M4 doesn't
/// renumber existing ones and corrupt persisted state.
enum ProviderKind: String, Sendable, Codable, CaseIterable {
    case render
    case fly
    case railway
    case digitalOcean = "digital_ocean"
    case customDockerHost = "custom_docker_host"
}
