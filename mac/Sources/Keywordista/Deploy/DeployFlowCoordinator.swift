import Foundation
import SwiftUI

/// Drives the 5-step deploy wizard. The 6 SwiftUI views (M3.8) bind
/// to this object's @Observable properties for both reads (current
/// phase, list of providers, in-flight events) and writes (user input
/// fields). Transitions between phases happen ONLY via the public
/// methods on this class — views never set `phase` directly.
///
/// **State shape** — phase enum + flat fields, not a sum-type state.
/// Trade-off: less type-safe (some fields are nil in some phases) but
/// SwiftUI bindings (`$coordinator.serviceName`) work natively without
/// enum-unwrapping gymnastics, and going backward through the wizard
/// preserves field choices for free. The discipline that keeps this
/// safe: transition logic lives in named methods on the coordinator,
/// not at the view layer.
///
/// **Lifetime**: one coordinator per deploy attempt. KeywordistaApp
/// (M3.13) opens a fresh WindowGroup with a fresh coordinator each
/// time the user clicks "Deploy to a server…". On `success`, the
/// coordinator emits the new Instance via `onCompletion`; the caller
/// is responsible for persisting it into InstanceStore + closing the
/// window.
@MainActor
final class DeployFlowCoordinator: ObservableObject {

    // MARK: - Inputs

    /// All providers the picker can offer. Injected so tests can pass
    /// a single stub provider, and so M4's FlyProvider just gets
    /// appended at the wiring layer.
    let providers: [any Provider]

    /// Invoked when the wizard reaches the `success` phase and the
    /// user clicks "Done". Owner is responsible for persisting the
    /// Instance + closing the deploy window. We don't persist or
    /// close from inside here — the coordinator stays UI-agnostic.
    let onCompletion: (Instance) -> Void

    // MARK: - Phase

    /// Discriminator across the 6 wizard screens. Mutated only by the
    /// transition methods below; views observe via `coordinator.phase`.
    @Published var phase: DeployFlowPhase = .pickProvider

    // MARK: - Step 1: Provider picker

    /// nil until the user picks. Set by `selectProvider`. Not
    /// `@Published` because views don't bind to the protocol existential
    /// directly — they read `selectedProvider?.displayName` etc.
    /// inside other property reads, which already drive re-renders.
    var selectedProvider: (any Provider)?

    // MARK: - Step 2: Authenticate

    /// User-typed API token. Bound from AuthenticateView.
    @Published var token: String = ""

    /// Inline error from the most recent authenticate attempt. Cleared
    /// when the user starts typing again (via the bind handler in the
    /// view). nil = no current error.
    @Published var authError: String?

    /// `true` while validateToken is in flight. Disables the button +
    /// shows a spinner.
    @Published var authenticating: Bool = false

    /// Resolved account info from validateToken. Drives the "Owner: X"
    /// label in the Configure step.
    @Published var account: ProviderAccount?

    // MARK: - Step 3: Configure

    /// Catalog data fetched once after successful authenticate. Used to
    /// populate the region/plan/database pickers in ConfigureView.
    @Published var regions: [Region] = []
    @Published var plans: [Plan] = []
    @Published var databases: [DatabaseOption] = []

    /// User picks in ConfigureView. Pre-populated to sensible defaults
    /// after authenticate so the wizard can be one-click for the
    /// "just give me the cheapest thing" case.
    @Published var selectedRegion: Region?
    @Published var selectedPlan: Plan?
    @Published var selectedDatabase: DatabaseChoice?
    @Published var serviceName: String = ""
    @Published var adminEmail: String = ""

    /// External-PG-only field; the URL the user pastes when they pick
    /// `.externalPostgres`. Validated at proceed-to-confirm time —
    /// must parse as postgres://
    @Published var externalPostgresURL: String = ""

    // MARK: - Step 4: Confirm

    /// Computed once at the transition from Configure → Confirm.
    /// Carries the assembled spec + the generated admin password.
    /// adminPassword is part of this struct so it doesn't get lost
    /// if the user clicks Back from Confirm to Configure and forward
    /// again — we regenerate only if they change inputs that affect it.
    @Published var confirmation: ConfirmationContext?

    // MARK: - Step 5: Deploying

    /// In-progress deploy state. Mutated as events arrive from
    /// streamDeployEvents. Latest status drives the title row;
    /// events array drives the scrollable log tail.
    @Published var deployingService: ProviderService?
    @Published var currentDeployStatus: String = "Preparing…"
    @Published var deployEvents: [DeployEvent] = []

    /// Background task that consumes the AsyncStream. Cancelled on
    /// user-initiated cancel or when we move to a terminal phase.
    private var deployStreamTask: Task<Void, Never>?

    // MARK: - Step 6: Success / Failure

    /// Set on transition to `.success`. The view reads `instance` for
    /// the URL + the admin password for the "save this now" banner.
    @Published var successContext: SuccessContext?

    /// Set on transition to `.failed`. Reason string from the provider;
    /// `retryable` indicates whether the user has a sensible Retry
    /// button (auth errors → no; network blips → yes).
    @Published var failure: FailureContext?

    // MARK: - Init

    init(
        providers: [any Provider],
        onCompletion: @escaping (Instance) -> Void
    ) {
        self.providers = providers
        self.onCompletion = onCompletion
    }

    // MARK: - Transitions

    /// Step 1 → Step 2. Records the provider choice, advances phase,
    /// clears any stale fields from a previous attempt.
    func selectProvider(_ provider: any Provider) {
        selectedProvider = provider
        // Reset transient fields so picking Render then Fly then
        // Render again doesn't leak stale state from the prior pass.
        token = ""
        authError = nil
        account = nil
        phase = .authenticate
    }

    /// Step 2 → Step 3. Validates the user-typed token against the
    /// provider, fetches catalogs (regions/plans/databases), pre-
    /// populates picker defaults. Stays on `.authenticate` and sets
    /// `authError` on validation failure.
    func authenticate() async {
        guard let provider = selectedProvider, !token.isEmpty else { return }
        authenticating = true
        authError = nil
        defer { authenticating = false }

        do {
            let resolvedAccount = try await provider.validateToken(token)
            // Fetch the three catalogs in parallel — independent
            // calls, so awaiting them concurrently is ~3x faster
            // than serial for the user's perceived "Continue →"
            // latency.
            async let regionsTask = provider.availableRegions(
                account: resolvedAccount, token: token
            )
            async let plansTask = provider.availablePlans(
                account: resolvedAccount, token: token
            )
            async let databasesTask = provider.availableDatabases(
                account: resolvedAccount, token: token
            )
            let fetchedRegions = try await regionsTask
            let fetchedPlans = try await plansTask
            let fetchedDatabases = try await databasesTask

            account = resolvedAccount
            regions = fetchedRegions
            plans = fetchedPlans
            databases = fetchedDatabases

            // Sensible defaults: closest-likely region + cheapest plan
            // + cheapest database. The user can override in Configure
            // step; defaulting cuts most users to one click.
            selectedRegion = fetchedRegions.first
            selectedPlan = fetchedPlans.first
            // Database default = first option in the catalog
            // (sqliteOnDisk for Render, which is also the cheapest).
            // Pre-pick the smallest disk size within that option.
            if let firstDB = fetchedDatabases.first {
                selectedDatabase = defaultChoice(for: firstDB)
            }
            phase = .configure
        } catch let err as ProviderError {
            authError = userFacingMessage(err)
        } catch {
            authError = "Couldn't reach \(provider.displayName). Check your connection and try again."
        }
    }

    /// Step 3 → Step 4. Assembles the DeploymentSpec from form fields
    /// and the locally-generated secrets, computes the cost preview,
    /// advances to Confirm. Throws back to the view as an inline error
    /// if validation fails (e.g. missing service name).
    func proceedToConfirm() throws {
        guard let provider = selectedProvider else { return }
        guard let region = selectedRegion else {
            throw DeployFlowError.missingField("region")
        }
        guard let plan = selectedPlan else {
            throw DeployFlowError.missingField("plan")
        }
        guard let database = selectedDatabase else {
            throw DeployFlowError.missingField("database")
        }
        guard !serviceName.isEmpty else {
            throw DeployFlowError.missingField("service name")
        }
        guard !adminEmail.isEmpty else {
            throw DeployFlowError.missingField("admin email")
        }

        // External PG sanity check — fail-fast here rather than at
        // createService time with a confusing Render 400.
        if case .externalPostgres = database {
            guard externalPostgresURL.hasPrefix("postgres://")
                || externalPostgresURL.hasPrefix("postgresql://") else {
                throw DeployFlowError.invalidField(
                    "external Postgres URL must start with postgres://"
                )
            }
        }

        // Locally-generated secrets — see M3.5 SecretsGenerator. The
        // plaintext admin password EXISTS ONLY here (and in the success
        // banner). The hash goes to the provider; the plaintext is
        // shown to the user once, copied to clipboard, never persisted.
        let adminPassword = SecretsGenerator.generateAdminPassword()
        let adminPasswordHash: String
        do {
            adminPasswordHash = try SecretsGenerator.bcryptHash(adminPassword)
        } catch {
            throw DeployFlowError.localCryptoFailure(
                "couldn't prepare admin password: \(error.localizedDescription)"
            )
        }
        let encryptionKey = SecretsGenerator.generateEncryptionKey()

        // Public URL: predicted from the service name. Render gives
        // every web service a URL of the form
        // https://<name>.onrender.com — predictable when no naming
        // collision (Render returns 409 at create time on collision).
        let publicURL = predictedPublicURL(serviceName: serviceName, provider: provider)

        // Resolve the concrete DatabaseChoice from the picker state.
        // For external PG we plug in the user-supplied URL here.
        let finalDatabase: DatabaseChoice
        switch database {
        case .externalPostgres:
            finalDatabase = .externalPostgres(connectionURL: externalPostgresURL)
        default:
            finalDatabase = database
        }

        // The env vars Render will inject into the running container.
        // Order matters: KEYWORDISTA_RENDER_OWNER_ID is provider-
        // internal plumbing that RenderProvider.createService strips
        // before sending. DATABASE_URL / DATABASE_PATH are added by
        // RenderProvider based on the database choice.
        var envVars: [String: String] = [
            "KEYWORDISTA_MODE": "server",
            "KEYWORDISTA_ENCRYPTION_KEY": encryptionKey,
            "KEYWORDISTA_PUBLIC_BASE_URL": publicURL,
            "KEYWORDISTA_ADMIN_EMAIL": adminEmail,
            "KEYWORDISTA_ADMIN_PASSWORD_HASH": adminPasswordHash,
        ]
        if let accountID = account?.id {
            envVars["KEYWORDISTA_RENDER_OWNER_ID"] = accountID
        }

        // For v1, image ref is pinned to the latest published tag.
        // Future: cockpit fetches the manifest from GHCR and pins to
        // digest. For now, plain tag.
        let imageRef = "ghcr.io/bootuz/keywordista:latest"

        let spec = DeploymentSpec(
            imageRef: imageRef,
            serviceName: serviceName,
            region: region,
            plan: plan,
            database: finalDatabase,
            envVars: envVars
        )
        let cost = provider.estimateMonthlyCost(spec: spec)

        confirmation = ConfirmationContext(
            spec: spec,
            estimatedMonthlyCost: cost,
            adminPassword: adminPassword
        )
        phase = .confirm
    }

    /// Step 4 → Step 5. Triggers the actual createService + starts the
    /// deploy-event stream consumer. On success transitions to Step 6.
    func deploy() async {
        guard let provider = selectedProvider,
              let confirmation else { return }

        phase = .deploying
        currentDeployStatus = "Creating service…"
        deployEvents = []

        do {
            let service = try await provider.createService(
                spec: confirmation.spec,
                token: token
            )
            deployingService = service

            // Kick off the deploy-event stream consumer. We marshal
            // each event back to MainActor and append to deployEvents
            // so the view re-renders.
            startConsumingDeployEvents(service: service, provider: provider)
        } catch let err as ProviderError {
            // Partial deploy → user has an orphan PG. The failure
            // context's `retryable` is false because retry would
            // create a second PG; the cockpit's manual cleanup flow
            // (M3.12) handles tear-down.
            if case .partial(let created, _) = err {
                failure = FailureContext(
                    reason: """
                        \(userFacingMessage(err))

                        Render-side resources that need manual cleanup:
                        \(created.joined(separator: "\n"))
                        """,
                    retryable: false
                )
            } else {
                failure = FailureContext(
                    reason: userFacingMessage(err),
                    retryable: isRetryable(err)
                )
            }
            phase = .failed
        } catch {
            failure = FailureContext(
                reason: "Unexpected error: \(error.localizedDescription)",
                retryable: true
            )
            phase = .failed
        }
    }

    /// Step 5 → Step 6 (.success). Called after the deploy stream
    /// yields .healthCheckPassed. Builds the RemoteInstance + the
    /// SuccessContext.
    private func transitionToSuccess() {
        guard let provider = selectedProvider,
              let service = deployingService,
              let confirmation else { return }

        let url = URL(string: service.metadata["url"] ?? "")
            ?? URL(string: predictedPublicURL(
                serviceName: confirmation.spec.serviceName,
                provider: provider
            ))!

        let remote = RemoteInstance(
            displayName: confirmation.spec.serviceName,
            providerKind: provider.kind,
            providerServiceId: service.id,
            baseURL: url,
            imageTag: confirmation.spec.imageRef,
            createdAt: Date(),
            providerManagedDatabaseId: service.metadata["managed_postgres_id"]
        )
        let instance = Instance(id: UUID(), kind: .remote(remote))

        successContext = SuccessContext(
            instance: instance,
            adminEmail: adminEmail,
            adminPassword: confirmation.adminPassword,
            publicURL: url,
            estimatedMonthlyCost: confirmation.estimatedMonthlyCost,
            providerDisplayName: provider.displayName
        )
        phase = .success
    }

    /// Called from SuccessView's "Done" button. Persists the
    /// provider API token to Keychain, then hands the new instance
    /// to the caller. The caller (KeywordistaApp wiring in M3.13)
    /// is responsible for InstanceStore.add() and closing the window.
    func complete() {
        guard let context = successContext,
              let provider = selectedProvider else { return }
        // Stash the API token now that the instance has been
        // committed. Failure to write Keychain shouldn't block
        // completion — the user can re-supply the token later via
        // "Add existing deployment".
        if let account {
            try? KeychainStore.setProviderToken(
                token,
                kind: provider.kind,
                account: account.id
            )
        }
        onCompletion(context.instance)
    }

    /// User-initiated cancel. Tears down any in-flight deploy resources
    /// to avoid leaving orphan paid resources on the provider side.
    /// Safe to call from any phase.
    func cancel() async {
        deployStreamTask?.cancel()
        deployStreamTask = nil

        // If we got far enough to create a service, destroy it now.
        // Best-effort: ignore errors here — the user already wants out.
        if let provider = selectedProvider,
           let service = deployingService {
            try? await provider.destroy(service: service, token: token)
        }
    }

    /// User-initiated back navigation. Only valid from phases where
    /// it makes sense (Authenticate → PickProvider, Configure →
    /// Authenticate, Confirm → Configure). Deploying / Success /
    /// Failed don't support back.
    func goBack() {
        switch phase {
        case .pickProvider:
            return
        case .authenticate:
            phase = .pickProvider
        case .configure:
            phase = .authenticate
        case .confirm:
            phase = .configure
        case .deploying, .success, .failed:
            return
        }
    }

    // MARK: - Internals

    /// Returns a `DatabaseChoice` pre-populated with the cheapest
    /// concrete option inside the given DatabaseOption. SQLite picks
    /// the smallest disk; managed PG picks the cheapest plan; external
    /// PG defaults to empty string (user must paste a URL).
    private func defaultChoice(for option: DatabaseOption) -> DatabaseChoice {
        switch option {
        case .sqliteOnDisk(let sizes):
            return .sqliteOnDisk(size: sizes.first ?? DiskSize(sizeGB: 1, monthlyCostCents: 25))
        case .providerManagedPostgres(let plans):
            return .providerManagedPostgres(
                plan: plans.first ?? Plan(id: "basic_256mb", displayName: "Basic 256 MB",
                                          monthlyCostCents: 600, descriptionShort: "")
            )
        case .externalPostgres:
            return .externalPostgres(connectionURL: "")
        }
    }

    /// Predicts the public URL Render assigns to a service from its
    /// name. Pattern: `https://<name>.onrender.com`. Render returns
    /// 409 on naming collision before deploy, so this prediction is
    /// safe at proceed-to-confirm time.
    private func predictedPublicURL(serviceName: String, provider: any Provider) -> String {
        // For v1 we hardcode Render's URL shape; M4's FlyProvider
        // gets its own shape (.fly.dev with possible suffix). Future
        // refactor: move this into Provider as `publicURLPattern(name:)`.
        switch provider.kind {
        case .render: return "https://\(serviceName).onrender.com"
        case .fly: return "https://\(serviceName).fly.dev"
        default: return "https://\(serviceName).example.com"
        }
    }

    private func startConsumingDeployEvents(
        service: ProviderService,
        provider: any Provider
    ) {
        deployStreamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = provider.streamDeployEvents(service: service, token: self.token)
            for await event in stream {
                guard !Task.isCancelled else { return }
                self.deployEvents.append(event)
                switch event {
                case .statusChanged(let status):
                    self.currentDeployStatus = status
                case .healthCheckPassed:
                    self.transitionToSuccess()
                    return
                case .failed(let reason):
                    self.failure = FailureContext(reason: reason, retryable: true)
                    self.phase = .failed
                    return
                case .logLine:
                    // Already appended above; nothing else to do.
                    break
                }
            }
        }
    }

    private func userFacingMessage(_ error: ProviderError) -> String {
        switch error {
        case .authenticationFailed:
            return "That API key didn't work. Double-check it and try again."
        case .rateLimited:
            return "Render's API is throttling us. Try again in a minute."
        case .invalidRequest(let detail):
            return detail
        case .network(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .partial(let created, _):
            return "The deploy partly succeeded. Manual cleanup needed for: \(created.joined(separator: ", "))."
        case .unknown(let detail):
            return detail
        }
    }

    private func isRetryable(_ error: ProviderError) -> Bool {
        switch error {
        case .authenticationFailed, .invalidRequest:
            // Retrying with the same inputs would just fail the same
            // way; user has to back up and fix something.
            return false
        case .rateLimited, .network, .unknown:
            return true
        case .partial:
            return false  // covered above
        }
    }
}

// MARK: - Phase + context types

enum DeployFlowPhase {
    case pickProvider
    case authenticate
    case configure
    case confirm
    case deploying
    case success
    case failed
}

/// Snapshot at the Configure → Confirm transition. Bundling the spec
/// + cost + admin password means re-rendering the ConfirmView doesn't
/// recompute (and re-randomize) the admin password.
struct ConfirmationContext {
    let spec: DeploymentSpec
    let estimatedMonthlyCost: Money
    let adminPassword: String
}

struct SuccessContext {
    let instance: Instance
    let adminEmail: String
    let adminPassword: String
    let publicURL: URL
    /// Carried forward from ConfirmationContext so SuccessView can
    /// show "Render will bill $7.25/mo for this deployment" — closes
    /// the loop on what the user just committed to without making
    /// them mentally re-add the line items.
    let estimatedMonthlyCost: Money
    /// "Render", "Fly.io", etc. for the "<provider> will bill" line.
    let providerDisplayName: String
}

struct FailureContext {
    let reason: String
    let retryable: Bool
}

enum DeployFlowError: Error, CustomStringConvertible {
    case missingField(String)
    case invalidField(String)
    case localCryptoFailure(String)

    var description: String {
        switch self {
        case .missingField(let f): return "\(f) is required"
        case .invalidField(let f): return f
        case .localCryptoFailure(let f): return f
        }
    }
}
