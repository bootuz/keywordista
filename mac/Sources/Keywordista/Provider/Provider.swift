import Foundation

/// The contract every PaaS provider implementation conforms to. The
/// cockpit (M3.7's DeployFlowCoordinator + M3.8's views) is provider-
/// agnostic — it walks `[any Provider]`, asks each one for regions /
/// plans / costs, and the picked one's `createService` runs the
/// deploy. M3.6's RenderProvider is the canonical implementation;
/// M4's FlyProvider, M5's RailwayProvider + DigitalOceanProvider +
/// CustomDockerHostProvider all conform.
///
/// **Why instance methods instead of static**: the cockpit needs to
/// enumerate `[any Provider]` (the picker view). Static methods on
/// `Provider.Type` would force a central registry that every new
/// provider has to be hand-added to. Instance singletons let the
/// cockpit own a plain `let providers: [any Provider]` array and
/// iterate without ceremony.
///
/// **Why no associatedtype Account**: same reason. An associated
/// type would prevent `any Provider` from being usable without
/// generic gymnastics. ProviderAccount is a concrete struct with
/// a free-form `metadata: [String: String]` field for provider-
/// specific bits (Render owner ID, Fly org slug, etc.).
///
/// **Concurrency**: protocol is Sendable so providers can be
/// captured across actor boundaries. Implementations should be
/// value types or use proper actor isolation. Every method that
/// touches the network is async — there's no synchronous "is this
/// token valid" shortcut.
protocol Provider: Sendable {

    // ── Metadata (for the picker view) ────────────────────────────

    /// Identity matching the persisted ProviderKind in instances.json.
    /// Used to route a RemoteInstance back to its owning Provider at
    /// boot time (no provider stores its own instances — they're all
    /// in one InstanceStore).
    var kind: ProviderKind { get }

    /// Human-facing name in the picker: "Render", "Fly.io", etc.
    var displayName: String { get }

    /// One-line marketing-style hint: "$7/mo, 90s deploy". Shown in
    /// the picker beneath displayName. Should give enough info that
    /// a user can decide without opening the provider's website.
    var marketingTagline: String { get }

    /// Tier indicator. Influences picker grouping (first-class
    /// providers appear under "Recommended"; template-link ones
    /// under "More providers"; docs-only under "Advanced").
    var supportLevel: ProviderSupport { get }

    // ── Step 2: Authenticate ──────────────────────────────────────

    /// Validates a user-supplied API token by making one cheap
    /// authenticated call (Render's GET /owners, Fly's GET /apps,
    /// etc.). Returns the resolved account info for display in
    /// Step 3's "Owner" picker, OR throws ProviderError.
    /// authenticationFailed on 401.
    func validateToken(_ token: String) async throws -> ProviderAccount

    // ── Step 3: Configure ────────────────────────────────────────

    /// Regions the user can deploy to with this token. Some
    /// providers gate certain regions by plan tier; this returns
    /// what the *account* can use, not the universal list.
    func availableRegions(account: ProviderAccount, token: String) async throws -> [Region]

    /// Service plans (instance sizes / tiers). Sorted cheapest-first;
    /// providers should put their recommended-starter plan at index 0.
    func availablePlans(account: ProviderAccount, token: String) async throws -> [Plan]

    /// Database options for THIS provider. Render returns
    /// [.sqliteOnDisk, .providerManagedPostgres(plans:[...]),
    /// .externalPostgres]; Fly returns the same shape with different
    /// plan IDs; CustomDockerHost returns just sqliteOnDisk +
    /// externalPostgres (no provider-managed option).
    func availableDatabases(account: ProviderAccount, token: String) async throws -> [DatabaseOption]

    /// Best-effort monthly cost preview. Used by the Confirm step
    /// to show "$7.25/mo" before the user commits. Computed locally
    /// from plan/disk/region pricing — no network call.
    func estimateMonthlyCost(spec: DeploymentSpec) -> Money

    /// Validates a candidate service name against the provider's
    /// naming rules. Synchronous — no network, just regex. Used by
    /// ConfigureView for live keystroke feedback AND by
    /// DeployFlowCoordinator.proceedToConfirm as the final guard.
    ///
    /// **Why this matters**: Render normalizes underscores to
    /// hyphens for the URL's DNS-safe subdomain (Render's rule:
    /// `^[a-z0-9][a-z0-9-]*$`). Without client-side validation, a
    /// user typing `studio_prod` would get a service at
    /// `studio-prod.onrender.com` BUT the cockpit's URL prediction
    /// (`https://<name>.onrender.com`) would bake `studio_prod`
    /// into KEYWORDISTA_PUBLIC_BASE_URL — and invite links sent to
    /// teammates would resolve to a non-existent host. Caught the
    /// hard way during the first real Render deploy attempt.
    ///
    /// Returns `.ok` if valid; `.invalid(message)` with provider-
    /// specific remediation copy otherwise.
    func validateServiceName(_ name: String) -> ServiceNameValidation

    // ── Step 5: Deploy ───────────────────────────────────────────

    /// Creates the service per the spec. Sequenced per database
    /// choice — provider-managed Postgres is provisioned first
    /// (its DATABASE_URL injected into the web service's env),
    /// THEN the web service. Returns the opaque ProviderService
    /// handle the cockpit persists as RemoteInstance.providerServiceId.
    ///
    /// Throws on failure with a typed ProviderError. Partial
    /// state (Postgres created, web service failed) is the caller's
    /// responsibility to clean up by checking ProviderError for
    /// a `partial` payload — the provider does NOT auto-rollback
    /// because the user might want to retry the web service
    /// against the existing PG.
    func createService(
        spec: DeploymentSpec,
        token: String
    ) async throws -> ProviderService

    /// Live stream of deploy events for the DeployingView log tail.
    /// Each provider implements this differently — Render polls
    /// /services/:id/deploys/:deployId/events every 2s; Fly opens
    /// a real SSE stream against /apps/:name/machines/:id/events.
    /// Both adapt to the same AsyncStream<DeployEvent> shape so
    /// the view code is identical.
    ///
    /// Terminates the stream when the deploy reaches a terminal
    /// state (healthCheckPassed OR failed) so the consumer can
    /// `for await event in stream { … }` and exit naturally.
    func streamDeployEvents(
        service: ProviderService,
        token: String
    ) -> AsyncStream<DeployEvent>

    /// Current image tag the deployment is running. RemoteUpdateChecker
    /// (M5) calls this to detect "is there a newer image available?"
    /// Returns a digest-pinned string ideally; falls back to a tag
    /// like "1.0.0" for providers that don't expose digests.
    func currentImageTag(
        service: ProviderService,
        token: String
    ) async throws -> String

    // ── Lifecycle ────────────────────────────────────────────────

    /// Rolling redeploy with a new image tag. The cockpit calls this
    /// for the "Update to 1.0.1 →" menubar entry. Most providers
    /// implement this as a PATCH on the service spec; some require
    /// a full re-deploy.
    func updateImage(
        service: ProviderService,
        toTag tag: String,
        token: String
    ) async throws

    /// Recent log lines for the "View deploy logs…" menubar entry.
    /// `since` is the high-water mark from the last fetch so the
    /// menubar doesn't re-fetch the same lines on every refresh.
    func fetchLogs(
        service: ProviderService,
        since: Date,
        token: String
    ) async throws -> [LogLine]

    /// Destroys the service AND its provisioned managed Postgres
    /// (if one exists; provider tracks this internally via the
    /// service handle). Idempotent — destroying an already-destroyed
    /// service returns normally.
    ///
    /// **Cost guarantee**: after this returns, the provider must
    /// be charging $0 for anything created by createService. Any
    /// orphan that survives is a bug.
    func destroy(
        service: ProviderService,
        token: String
    ) async throws
}

// MARK: - Provider metadata types

/// Synchronous service-name validation result. Each provider exposes
/// its own naming rules via `validateServiceName(_:)`.
enum ServiceNameValidation: Sendable, Equatable {
    case ok
    /// Provider-specific human-friendly message — surfaces in the
    /// Configure step's inline error under the name field.
    case invalid(String)

    var isValid: Bool { if case .ok = self { return true } else { return false } }

    /// Convenience for views that want to render the error string OR
    /// nil for the "no error" case.
    var errorMessage: String? {
        if case .invalid(let msg) = self { return msg } else { return nil }
    }
}

/// Tier indicator influencing the picker view's grouping.
enum ProviderSupport: Sendable, Equatable {
    /// Full API integration. Picker shows under "Recommended".
    /// Render (M3.6) and Fly (M4) are first-class.
    case firstClass

    /// "Open in browser" template URL. The cockpit opens the URL
    /// and waits for the user to paste back the resulting deployment
    /// URL. Railway and DigitalOcean (M5).
    case templateLink

    /// "Generates a docker-compose.yml + walks you through scp/ssh."
    /// No provider API at all. CustomDockerHostProvider (M5).
    case docsOnly
}

/// Resolved account identity returned by validateToken. Display info
/// for the configure step's "Owner: [...]" dropdown, plus a free-form
/// metadata dictionary for provider-specific identifiers the cockpit
/// shouldn't have to know the shape of.
struct ProviderAccount: Sendable, Equatable {
    /// Provider-opaque account identifier. Render uses owner ID
    /// ("tea-cl12345"); Fly uses org slug ("personal"). Treated as
    /// black-box by the cockpit.
    let id: String

    /// User-facing label for the account in the picker. Email +
    /// org name combination ideally; falls back to id if that's
    /// all the provider exposes.
    let displayName: String

    /// Provider-specific fields the cockpit shouldn't care about
    /// but the provider needs in subsequent calls. Render stuffs
    /// "owner_slug" here; Fly stuffs "org_id". Read by the
    /// originating provider's other methods.
    let metadata: [String: String]
}

// MARK: - Deployment configuration

/// What the user can deploy to. Returned by availableRegions().
struct Region: Sendable, Equatable, Hashable, Identifiable {
    let id: String          // provider-opaque ("oregon", "fra")
    let displayName: String // "Oregon (US West)", "Frankfurt"
}

/// Service tier the user picks in Configure step. Pricing baked in
/// here (vs. fetched dynamically) because provider price lists don't
/// change weekly and a stale display is better than a network round-
/// trip in the picker UI.
struct Plan: Sendable, Equatable, Hashable, Identifiable {
    let id: String                  // "starter", "standard", "pro"
    let displayName: String         // "Starter"
    let monthlyCostCents: Int       // 700 → $7.00/mo
    let descriptionShort: String    // "0.5 CPU, 512MB RAM"
}

/// Database choice the user picks. Drives RenderProvider's sequenced
/// createService — provider-managed Postgres is provisioned FIRST,
/// its DATABASE_URL injected into the web service env, then the web
/// service is created.
enum DatabaseOption: Sendable, Equatable, Hashable, Identifiable {
    /// SQLite at $KEYWORDISTA_DATA_DIR/db.sqlite on a persistent
    /// disk attached to the web service. The associated value is
    /// the available disk sizes the user can pick from in
    /// Configure step. Picked one becomes the disk's sizeGB.
    case sqliteOnDisk(sizes: [DiskSize])

    /// Provider's managed Postgres add-on. Render Managed Postgres,
    /// Fly Postgres, etc. The associated array is the available
    /// PG plan IDs + their per-month cost.
    case providerManagedPostgres(plans: [Plan])

    /// User-supplied DATABASE_URL (Neon, Supabase, RDS, self-
    /// hosted PG). No associated value — the URL is collected at
    /// Configure-step submit time and stuffed into env vars.
    case externalPostgres

    /// Stable identifier for the picker — bound directly to the
    /// case so SwiftUI's List/Picker can use it.
    var id: String {
        switch self {
        case .sqliteOnDisk: return "sqlite_on_disk"
        case .providerManagedPostgres: return "provider_managed_postgres"
        case .externalPostgres: return "external_postgres"
        }
    }
}

/// Disk size + monthly cost combo for sqliteOnDisk option.
struct DiskSize: Sendable, Equatable, Hashable, Identifiable {
    let sizeGB: Int
    let monthlyCostCents: Int       // e.g. 25 → $0.25/mo for 1GB on Render

    var id: Int { sizeGB }
    var displayName: String { "\(sizeGB) GB" }
}

/// The full configuration the user has assembled by the time they
/// click "Deploy" in the Confirm step. Cockpit-built, provider-
/// agnostic — providers translate this into their own API shapes
/// inside createService.
struct DeploymentSpec: Sendable, Equatable {
    /// Pinned image ref. Cockpit always uses digest pinning
    /// (`ghcr.io/.../keywordista@sha256:...`) for repeatability —
    /// "deploy now" and "deploy six months from now from the same
    /// recipe" should produce bit-identical containers.
    let imageRef: String

    /// User-typed service name. Validated at Configure-step to
    /// match the provider's naming rules (DNS-safe slug, length
    /// caps, etc. — providers throw on invalid at createService
    /// time if the client missed it).
    let serviceName: String

    let region: Region
    let plan: Plan
    let database: DatabaseChoice

    /// Pre-baked env vars including KEYWORDISTA_MODE=server,
    /// KEYWORDISTA_ENCRYPTION_KEY (generated by SecretsGenerator,
    /// M3.5), KEYWORDISTA_PUBLIC_BASE_URL, KEYWORDISTA_ADMIN_EMAIL,
    /// KEYWORDISTA_ADMIN_PASSWORD_HASH (bcrypted on the Mac, M3.5).
    /// Provider injects DATABASE_URL or DATABASE_PATH per database
    /// choice — that's why it's not in this dict.
    let envVars: [String: String]
}

/// Concrete choice made by the user, with the picked sizing baked
/// in. Distinct from DatabaseOption (which describes available
/// choices). Passed to createService.
enum DatabaseChoice: Sendable, Equatable {
    case sqliteOnDisk(size: DiskSize)
    case providerManagedPostgres(plan: Plan)
    case externalPostgres(connectionURL: String)
}

// MARK: - Deploy events

/// Opaque handle returned by createService and persisted as
/// RemoteInstance.providerServiceId. Provider parses its own id
/// shape on subsequent calls; the cockpit treats it as black-box.
struct ProviderService: Sendable, Equatable, Codable {
    let id: String

    /// Provider-specific bits the cockpit shouldn't care about but
    /// the provider needs later — Render stores managed-PG ID here,
    /// Fly stores app + machine ID, etc. Persisted in RemoteInstance.
    let metadata: [String: String]
}

/// Streamed during a deploy. The DeployingView (M3.8) reads from
/// `streamDeployEvents` and re-renders on each event.
enum DeployEvent: Sendable, Equatable {
    /// User-visible phase change: "Pulling image", "Starting service",
    /// "Waiting for /health". Lowercased; the view title-cases.
    case statusChanged(String)

    /// Raw log line from the provider (build log, runtime log).
    /// Streamed verbatim into the log tail.
    case logLine(String)

    /// /health returned 200. Terminal — stream ends after this event.
    case healthCheckPassed

    /// Deploy failed for whatever reason. Terminal. The reason
    /// string is surfaced in the Failed view + "Rollback" option.
    case failed(reason: String)
}

/// Returned by fetchLogs. Minimal shape — providers vary in what
/// they expose, but timestamp + level + message is the common
/// denominator.
struct LogLine: Sendable, Equatable, Hashable {
    let timestamp: Date
    let level: LogLevel?
    let message: String

    enum LogLevel: String, Sendable, Codable {
        case debug, info, warning, error
    }
}

// MARK: - Money

/// Currency-aware money type. Stored as integer cents to dodge
/// floating-point drift (a $7.00 plan + $0.25 disk should be
/// exactly $7.25, not $7.249999…). Currency string lives at the
/// formatter level — every provider so far is USD.
struct Money: Sendable, Equatable, Hashable {
    let cents: Int
    let currency: String    // "USD", "EUR"

    static let zero = Money(cents: 0, currency: "USD")

    static func usd(_ cents: Int) -> Money {
        Money(cents: cents, currency: "USD")
    }

    /// "+" for assembling line items in the Confirm step. Crashes
    /// on currency mismatch — we never mix currencies in v1, so
    /// the assertion is the right contract.
    static func + (lhs: Money, rhs: Money) -> Money {
        precondition(lhs.currency == rhs.currency, "currency mismatch")
        return Money(cents: lhs.cents + rhs.cents, currency: lhs.currency)
    }

    /// Display like "$7.25/mo" (caller appends the "/mo" suffix).
    var formatted: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        let amount = Decimal(cents) / 100
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(currency) \(cents)¢"
    }
}

// MARK: - Errors

/// Typed errors thrown by Provider methods. The cockpit branches
/// on these to show appropriate UI ("invalid token" → back to Auth
/// step; "rate limited" → retry banner; "partial deploy" → cleanup
/// prompt).
enum ProviderError: Error, CustomStringConvertible {
    /// 401 from the provider. Cockpit should clear the cached
    /// token and bounce the user back to Authenticate step.
    case authenticationFailed(detail: String)

    /// 429 or 503. Cockpit shows "Try again in a minute" + a
    /// retry button.
    case rateLimited(retryAfter: TimeInterval?)

    /// Server-side validation (e.g., service name already exists,
    /// region not available on free tier). The detail string is
    /// shown to the user verbatim.
    case invalidRequest(detail: String)

    /// Network error, timeout, DNS failure.
    case network(underlying: Error)

    /// Partial success — managed PG provisioned but web service
    /// creation failed (or vice versa). Cockpit prompts the user
    /// to confirm cleanup of the orphan resources before retrying.
    case partial(created: [String], failed: String)

    /// Anything we didn't anticipate. Provider should log the raw
    /// response and surface a generic message.
    case unknown(detail: String)

    var description: String {
        switch self {
        case .authenticationFailed(let d): return "authentication failed: \(d)"
        case .rateLimited(let after):
            if let after { return "rate limited (retry in \(Int(after))s)" }
            return "rate limited"
        case .invalidRequest(let d): return "invalid request: \(d)"
        case .network(let e): return "network error: \(e.localizedDescription)"
        case .partial(let created, let failed):
            return "partial deploy: created \(created.joined(separator: ", ")); failed at \(failed)"
        case .unknown(let d): return "unknown error: \(d)"
        }
    }
}
