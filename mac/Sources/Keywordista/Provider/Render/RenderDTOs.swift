import Foundation

/// Codable mirrors of the Render API request/response JSON shapes used
/// by RenderProvider's 8 operations. Naming convention: `Render<Thing>`.
/// All fields explicitly named via CodingKeys to dodge Swift's
/// camelCase-to-snake_case ambiguity (Render mostly camelCases but a
/// few fields like `databaseName` would round-trip differently if
/// JSONDecoder's keyDecodingStrategy was anything but `.useDefaultKeys`).
///
/// Scope: ONLY the fields RenderProvider reads or writes. Render's
/// actual responses include 20+ other fields per object; we ignore
/// them, which means schema additions on Render's side never break us.

// MARK: - GET /owners (workspace listing for validateToken)

struct RenderOwnerEntry: Codable {
    let owner: RenderOwner
    let cursor: String?
}

struct RenderOwner: Codable {
    let id: String
    let name: String
    let email: String
    /// "team" | "user"
    let type: String
}

// MARK: - POST /services (create web service)

struct RenderServiceCreateRequest: Codable {
    let type: String                          // always "web_service"
    let name: String
    let ownerId: String
    let autoDeploy: String                    // "no" — cockpit drives deploys
    let image: RenderImageRef
    let envVars: [RenderEnvVar]
    let serviceDetails: RenderServiceDetails
}

struct RenderImageRef: Codable {
    /// Must match the parent service's ownerId. Render enforces this
    /// at validate time; we set them from the same source so they
    /// always agree.
    let ownerId: String
    /// Full image path including tag, e.g. "ghcr.io/me/keywordista:1.0.0"
    /// OR digest-pinned "ghcr.io/me/keywordista@sha256:abc..."
    let imagePath: String
    /// Set only for private registries. Public images (our case, GHCR
    /// public) leave this nil. Coded out of the JSON when nil so
    /// Render's validator doesn't reject empty string.
    let registryCredentialId: String?
}

/// Render accepts either {key,value} OR {key,generateValue:true}.
/// We always use the former — generated values are our job (M3.5's
/// SecretsGenerator), not Render's.
struct RenderEnvVar: Codable {
    let key: String
    let value: String
}

struct RenderServiceDetails: Codable {
    /// Always "image" for our deploys.
    let runtime: String
    /// Plan ID from RenderCatalog.webServicePlans.
    let plan: String
    /// Region ID from RenderCatalog.regions.
    let region: String
    /// We force 1 — single-instance is the iTunes-API-throttling
    /// invariant Keywordista's worker depends on.
    let numInstances: Int
    /// We always set this to "/health" — matches the backend's
    /// public health endpoint.
    let healthCheckPath: String
    /// Optional — only set when DatabaseChoice is .sqliteOnDisk.
    let disk: RenderDisk?
    let envSpecificDetails: RenderEnvSpecificDetails
}

struct RenderDisk: Codable {
    let name: String          // "data"
    let mountPath: String     // "/data" — matches KEYWORDISTA_DATA_DIR default
    let sizeGB: Int
}

/// Empty for image-runtime services. Required by Render's schema even
/// when empty — sending an empty object is the documented contract.
struct RenderEnvSpecificDetails: Codable {
    let dockerCommand: String       // "" — image's ENTRYPOINT takes over
}

/// Response from POST /services. The `deployId` sibling of `service`
/// is the killer feature here — we get the first deploy's ID for free
/// without having to list deploys.
struct RenderServiceAndDeploy: Codable {
    let service: RenderService
    let deployId: String
}

struct RenderService: Codable {
    let id: String
    let name: String
    let ownerId: String
    let serviceDetails: RenderServiceResponseDetails
}

struct RenderServiceResponseDetails: Codable {
    /// "https://<name>.onrender.com" — the public URL of the deployed
    /// service. Matches the prediction we make at spec-assembly time
    /// (we set KEYWORDISTA_PUBLIC_BASE_URL based on the same template
    /// since we can't know the URL until after create).
    let url: String
}

// MARK: - GET /services/{id}/deploys/{deployId}

struct RenderDeploy: Codable {
    let id: String
    let status: String          // RenderDeployStatus.allValues
    let trigger: String?
    let createdAt: String?
    let startedAt: String?
    let finishedAt: String?
}

/// Maps Render's deploy status enum to terminal-vs-in-flight.
/// Centralized so the polling loop reads as `if status.isTerminal {…}`
/// instead of stringly-typed comparisons everywhere.
enum RenderDeployStatus {
    static let inFlight: Set<String> = [
        "created",
        "queued",
        "pre_deploy_in_progress",
        "build_in_progress",
        "update_in_progress",
    ]
    static let success: String = "live"
    static let failures: Set<String> = [
        "build_failed",
        "update_failed",
        "canceled",
        "pre_deploy_failed",
        "deactivated",
    ]

    static func isTerminal(_ status: String) -> Bool {
        status == success || failures.contains(status)
    }

    /// Human-friendly phase label for the DeployingView title row.
    static func displayName(_ status: String) -> String {
        switch status {
        case "created", "queued": return "Queued"
        case "pre_deploy_in_progress": return "Running pre-deploy"
        case "build_in_progress": return "Pulling image"
        case "update_in_progress": return "Starting service"
        case "live": return "Healthy"
        case "build_failed": return "Build failed"
        case "update_failed": return "Update failed"
        case "canceled": return "Canceled"
        case "pre_deploy_failed": return "Pre-deploy failed"
        case "deactivated": return "Deactivated"
        default: return status
        }
    }
}

// MARK: - POST /postgres + GET /postgres/{id} + connection-info

struct RenderPostgresCreateRequest: Codable {
    let name: String
    let ownerId: String
    /// Plan ID from RenderCatalog.postgresPlans.
    let plan: String
    /// "16" — see RenderCatalog.defaultPostgresVersion.
    let version: String
    /// Region ID — usually the same region as the web service for
    /// intra-region traffic (no egress cost, lower latency).
    let region: String
    /// Render will generate one if unset, but specifying matches the
    /// service name for sanity.
    let databaseName: String?
    let databaseUser: String?
}

struct RenderPostgres: Codable {
    let id: String
    let name: String
    let status: String          // RenderPostgresStatus.allValues
    let region: String
    let plan: String
}

/// Postgres lifecycle status. We only care about "available" (ready
/// to accept connections) vs everything else.
enum RenderPostgresStatus {
    static let ready: String = "available"
    static let failures: Set<String> = [
        "unavailable",
        "recovery_failed",
    ]

    static func isReady(_ status: String) -> Bool { status == ready }
    static func isFailed(_ status: String) -> Bool { failures.contains(status) }
}

struct RenderConnectionInfo: Codable {
    let password: String
    /// Use this one — intra-region, no egress, what the web service
    /// connects to. Format: postgres://user:pass@dpg-xxx-a/dbname
    let internalConnectionString: String
    /// External form (for local psql). Not used here.
    let externalConnectionString: String
}

// MARK: - PATCH /services/{id}

/// Subset of servicePATCH for our use case: bump the image tag.
/// Other fields (name, autoDeploy, etc.) intentionally not exposed.
struct RenderServiceUpdateRequest: Codable {
    let image: RenderImageRef
}

// MARK: - POST /services/{id}/deploys (used after PATCH to actually roll out)

struct RenderDeployCreateRequest: Codable {
    let imageUrl: String
    let clearCache: String  // "do_not_clear" | "clear"
}

// MARK: - GET /services/{id}/events

struct RenderEventEntry: Codable {
    let event: RenderEvent
}

struct RenderEvent: Codable {
    let id: String
    let timestamp: String
    let type: String
    /// `details` is a discriminated union keyed off `type`. We decode
    /// it as a free-form dict and let the consumer pull what it needs.
    /// Keeps us forward-compatible with new event types.
    let details: [String: AnyCodable]?
}

/// Eraser around heterogeneous JSON values. Render's event `details`
/// object can contain strings, numbers, booleans, nested objects;
/// rather than write a full union encoder we accept the lot via
/// AnyCodable. Decoded values are inspectable via `value` for display.
struct AnyCodable: Codable {
    let value: Any

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(String.self) { value = v; return }
        if let v = try? c.decode(Int.self) { value = v; return }
        if let v = try? c.decode(Double.self) { value = v; return }
        if let v = try? c.decode(Bool.self) { value = v; return }
        if let v = try? c.decode([String: AnyCodable].self) { value = v; return }
        if let v = try? c.decode([AnyCodable].self) { value = v; return }
        value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as String: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as Bool: try c.encode(v)
        case let v as [String: AnyCodable]: try c.encode(v)
        case let v as [AnyCodable]: try c.encode(v)
        default: try c.encodeNil()
        }
    }
}

// MARK: - Error envelope (every non-2xx)

struct RenderErrorEnvelope: Codable {
    let id: String?
    let message: String
}
