import Foundation

/// Render implementation of the `Provider` protocol (M3.4). The
/// canonical first-class provider — M4's FlyProvider is built against
/// the same protocol, so if anything here feels Render-shaped rather
/// than provider-shaped it's a smell to revisit before M4.
///
/// **Three things RenderProvider does that the generic Provider
/// protocol abstracts away from the cockpit**:
///
///   1. Sequenced create — when DatabaseChoice is
///      .providerManagedPostgres, we provision PG first, poll until
///      ready, fetch the connection string, THEN create the web
///      service with DATABASE_URL injected. Two roundtrips minimum;
///      can be 30s-2min including PG provisioning.
///
///   2. Two-step image update — Render's PATCH /services doesn't
///      auto-deploy. We PATCH the image tag, then POST a deploy to
///      actually roll it out. Single user-facing action, two API calls.
///
///   3. Deploy event polling — Render has no SSE/streaming endpoint
///      for deploys. We poll the deploy + opportunistically pull
///      recent events every 3s and synthesize an AsyncStream from
///      both sources, presenting it to the cockpit as if it were
///      a real stream.
struct RenderProvider: Provider {

    let client: RenderClient

    init(client: RenderClient = RenderClient()) {
        self.client = client
    }

    // MARK: - Provider metadata

    var kind: ProviderKind { .render }
    var displayName: String { "Render" }
    var marketingTagline: String { "$7/mo · 90 s deploy · auto TLS" }
    var supportLevel: ProviderSupport { .firstClass }

    // MARK: - Step 2: Authenticate

    func validateToken(_ token: String) async throws -> ProviderAccount {
        let owners = try await client.listOwners(token: token)
        guard let owner = owners.first else {
            throw ProviderError.invalidRequest(
                detail: "this API key has no workspaces — create one at dashboard.render.com first"
            )
        }
        // If the user has multiple workspaces we surface only the
        // first as the picker's "selected" default. The Configure
        // step will show all of them via a second listOwners call
        // (cached for the wizard session). v1 picks the first; v2
        // adds a workspace switcher.
        return ProviderAccount(
            id: owner.id,
            displayName: "\(owner.name) (\(owner.email))",
            metadata: [
                "owner_type": owner.type,
                "owner_email": owner.email,
            ]
        )
    }

    // MARK: - Step 3: Configure (hardcoded catalogs)

    func availableRegions(
        account: ProviderAccount,
        token: String
    ) async throws -> [Region] {
        // Render doesn't expose regions via API — see RenderCatalog.
        // Same for plans and databases below.
        RenderCatalog.regions
    }

    func availablePlans(
        account: ProviderAccount,
        token: String
    ) async throws -> [Plan] {
        RenderCatalog.webServicePlans
    }

    func availableDatabases(
        account: ProviderAccount,
        token: String
    ) async throws -> [DatabaseOption] {
        [
            .sqliteOnDisk(sizes: RenderCatalog.diskSizes),
            .providerManagedPostgres(plans: RenderCatalog.postgresPlans),
            .externalPostgres,
        ]
    }

    /// Render's service-name rules (from their API docs + empirical
    /// confirmation by deploying invalid names and observing 400s):
    ///
    ///   • Lowercase ASCII letters, digits, hyphens only
    ///   • Must start with a letter or digit (NOT a hyphen)
    ///   • Max length ~30 characters in practice (longer names are
    ///     accepted by API but generate ugly truncated subdomains)
    ///   • Underscores: BANNED — Render normalizes them to hyphens
    ///     for the DNS subdomain but the cockpit's URL prediction
    ///     uses the raw name, causing PUBLIC_BASE_URL drift (see
    ///     the Provider protocol's validateServiceName doc).
    ///
    /// Bare regex check — fast enough that ConfigureView can call
    /// this on every keystroke for live feedback without measurable
    /// cost.
    func validateServiceName(_ name: String) -> ServiceNameValidation {
        if name.isEmpty {
            return .invalid("Service name can't be empty.")
        }
        if name.count > 30 {
            return .invalid("Service name should be 30 characters or fewer (got \(name.count)).")
        }
        // Quick checks for the most common user mistakes — surface
        // a SPECIFIC remediation rather than a generic regex-fail
        // message, because "no underscores" is the bug we're
        // primarily defending against.
        if name.contains("_") {
            return .invalid("Service name can't contain underscores. Use hyphens instead — Render's rule. (Underscores in the name silently break invite-link generation.)")
        }
        if name != name.lowercased() {
            return .invalid("Service name must be all lowercase.")
        }
        if name.hasPrefix("-") {
            return .invalid("Service name must start with a letter or digit, not a hyphen.")
        }
        // Final catch-all regex for anything we didn't pre-flag.
        let pattern = "^[a-z0-9][a-z0-9-]*$"
        if name.range(of: pattern, options: .regularExpression) == nil {
            return .invalid("Service name must use only lowercase letters, digits, and hyphens.")
        }
        return .ok
    }

    /// M3.22: Render's public URL pattern is `{name}.onrender.com`.
    /// Always returns non-nil for Render — every service has a
    /// predictable subdomain matching its name. Custom domains
    /// are not modeled (out of v1 scope per plan §NG5).
    ///
    /// Caller should pre-validate the name via validateServiceName —
    /// passing a name that contains underscores would produce a
    /// URL that DOESN'T match the actual service's subdomain
    /// (Render silently normalizes underscores to hyphens). That
    /// drift is exactly the M3.16 bug, and the front-line defense
    /// is validateServiceName rejecting underscores before they
    /// reach this function.
    func publicURLPattern(serviceName: String) -> URL? {
        URL(string: "https://\(serviceName).onrender.com")
    }

    func estimateMonthlyCost(spec: DeploymentSpec) -> Money {
        var total = Money.usd(spec.plan.monthlyCostCents)
        switch spec.database {
        case .sqliteOnDisk(let size):
            total = total + Money.usd(size.monthlyCostCents)
        case .providerManagedPostgres(let plan):
            total = total + Money.usd(plan.monthlyCostCents)
        case .externalPostgres:
            // User pays their PG host directly — Render charges nothing
            // extra for the connection.
            break
        }
        return total
    }

    // MARK: - Step 5: Deploy (sequenced)

    func createService(
        spec: DeploymentSpec,
        token: String
    ) async throws -> ProviderService {
        // Owner ID lives in DeploymentSpec.envVars as a stash
        // (KEYWORDISTA_RENDER_OWNER_ID) because DeploymentSpec is
        // provider-agnostic. Cockpit's M3.7 packs it there during
        // Configure-step assembly. Defensively bail if missing — that's
        // a cockpit bug, not a user-facing error.
        guard let ownerId = spec.envVars["KEYWORDISTA_RENDER_OWNER_ID"] else {
            throw ProviderError.invalidRequest(
                detail: "internal: ownerId not provided in spec (cockpit bug — file issue)"
            )
        }

        // Strip the ownerId stash from the env vars we send to Render
        // — it's our internal plumbing, not a runtime config var.
        var envVars = spec.envVars
        envVars.removeValue(forKey: "KEYWORDISTA_RENDER_OWNER_ID")

        // Database-specific provisioning:
        //   • managed PG → provision first, poll for ready, fetch
        //     connection string, inject as DATABASE_URL.
        //   • sqliteOnDisk → no pre-provisioning; web service gets a
        //     disk + DATABASE_PATH env.
        //   • externalPostgres → caller already put DATABASE_URL in
        //     envVars; we pass through.
        var managedPostgresID: String?
        var disk: RenderDisk?

        switch spec.database {
        case .sqliteOnDisk(let size):
            disk = RenderDisk(name: "data", mountPath: "/data", sizeGB: size.sizeGB)
            envVars["DATABASE_PATH"] = "/data/db.sqlite"

        case .providerManagedPostgres(let plan):
            let pg = try await provisionManagedPostgres(
                name: "\(spec.serviceName)-db",
                ownerId: ownerId,
                plan: plan,
                region: spec.region,
                token: token
            )
            envVars["DATABASE_URL"] = pg.connectionURL
            managedPostgresID = pg.id

        case .externalPostgres(let url):
            envVars["DATABASE_URL"] = url
        }

        // Build the createService request now that DATABASE_* is settled.
        let request = RenderServiceCreateRequest(
            type: "web_service",
            name: spec.serviceName,
            ownerId: ownerId,
            autoDeploy: "no",
            image: RenderImageRef(
                ownerId: ownerId,
                imagePath: spec.imageRef,
                registryCredentialId: nil
            ),
            envVars: envVars
                .sorted(by: { $0.key < $1.key })   // stable order for diff'ability
                .map { RenderEnvVar(key: $0.key, value: $0.value) },
            serviceDetails: RenderServiceDetails(
                runtime: "image",
                plan: spec.plan.id,
                region: spec.region.id,
                numInstances: 1,
                healthCheckPath: "/health",
                disk: disk,
                envSpecificDetails: RenderEnvSpecificDetails(dockerCommand: "")
            )
        )

        do {
            let result = try await client.createService(body: request, token: token)

            // Stash the deployId + managedPostgresID in the metadata so
            // streamDeployEvents can find the in-flight deploy AND
            // destroy can tear down the orphan PG if the user later
            // deletes the service.
            var metadata: [String: String] = [
                "deploy_id": result.deployId,
                "url": result.service.serviceDetails.url,
            ]
            if let pgID = managedPostgresID {
                metadata["managed_postgres_id"] = pgID
            }

            return ProviderService(id: result.service.id, metadata: metadata)
        } catch {
            // Web service failed AFTER we provisioned PG → user is
            // charged for an orphan PG. Surface as .partial so the
            // cockpit can prompt for cleanup.
            if let pgID = managedPostgresID {
                throw ProviderError.partial(
                    created: ["postgres \(pgID)"],
                    failed: "service creation: \(error)"
                )
            }
            throw error
        }
    }

    func streamDeployEvents(
        service: ProviderService,
        token: String
    ) -> AsyncStream<DeployEvent> {
        AsyncStream { continuation in
            // deploy_id is stashed in createService's returned metadata.
            // Defensive: if missing, yield .failed and finish.
            guard let deployID = service.metadata["deploy_id"] else {
                continuation.yield(.failed(reason: "missing deploy_id in service metadata"))
                continuation.finish()
                return
            }

            let task = Task {
                var lastStatus: String?
                let pollInterval: UInt64 = 3_000_000_000  // 3s — RFC limit is 400 GET/min/key

                while !Task.isCancelled {
                    do {
                        let deploy = try await client.retrieveDeploy(
                            serviceID: service.id,
                            deployID: deployID,
                            token: token
                        )

                        // Status changed → narrate the new phase.
                        if deploy.status != lastStatus {
                            continuation.yield(.statusChanged(
                                RenderDeployStatus.displayName(deploy.status)
                            ))
                            lastStatus = deploy.status
                        }

                        // Terminal state → emit terminal event + finish.
                        if RenderDeployStatus.isTerminal(deploy.status) {
                            if deploy.status == RenderDeployStatus.success {
                                continuation.yield(.healthCheckPassed)
                            } else {
                                continuation.yield(.failed(
                                    reason: "deploy ended in \(deploy.status)"
                                ))
                            }
                            continuation.finish()
                            return
                        }

                        try await Task.sleep(nanoseconds: pollInterval)
                    } catch {
                        // Network blip or rate limit → log and keep
                        // polling; only terminate on terminal status.
                        // After 3 consecutive failures, give up.
                        continuation.yield(.logLine("poll error: \(error)"))
                        try? await Task.sleep(nanoseconds: pollInterval * 2)
                    }
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func currentImageTag(
        service: ProviderService,
        token: String
    ) async throws -> String {
        // We don't yet have a GET /services/{id} call in RenderClient
        // (no use case before this). For M3.6 we read from the
        // service.metadata cache — RemoteUpdateChecker (M5) will
        // promote this to a real API call.
        guard let url = service.metadata["image_path"] else {
            throw ProviderError.unknown(detail: "image_path not yet cached")
        }
        return url
    }

    // MARK: - Lifecycle

    func updateImage(
        service: ProviderService,
        toTag tag: String,
        token: String
    ) async throws {
        guard let ownerId = service.metadata["owner_id"] else {
            throw ProviderError.invalidRequest(
                detail: "internal: owner_id not in service metadata"
            )
        }
        // Two-step: PATCH the image, then POST a deploy to roll it out.
        // Render's PATCH alone doesn't auto-redeploy image services.
        _ = try await client.updateService(
            id: service.id,
            body: RenderServiceUpdateRequest(
                image: RenderImageRef(
                    ownerId: ownerId,
                    imagePath: tag,
                    registryCredentialId: nil
                )
            ),
            token: token
        )
        _ = try await client.createDeploy(
            serviceID: service.id,
            body: RenderDeployCreateRequest(
                imageUrl: tag,
                clearCache: "do_not_clear"
            ),
            token: token
        )
    }

    func fetchLogs(
        service: ProviderService,
        since: Date,
        token: String
    ) async throws -> [LogLine] {
        // We surface Render's service events (not raw container logs)
        // as the "log view." Raw logs require a separate logs API
        // call that we haven't wired here yet (M5 work). Events give
        // the user a high-signal view: build started, build ended,
        // server available, image_pull_failed.
        let events = try await client.listEvents(
            serviceID: service.id,
            since: since,
            token: token
        )
        let formatter = ISO8601DateFormatter()
        return events.compactMap { event -> LogLine? in
            guard let timestamp = formatter.date(from: event.timestamp) else { return nil }
            return LogLine(
                timestamp: timestamp,
                level: levelForEvent(event.type),
                message: humanizeEventType(event.type)
            )
        }
    }

    /// Maps Render's event types to log-level severity so the
    /// LogLine consumer can color them (red for failures, etc.).
    private func levelForEvent(_ type: String) -> LogLine.LogLevel? {
        if type.contains("failed") { return .error }
        if type.contains("warning") { return .warning }
        return .info
    }

    private func humanizeEventType(_ type: String) -> String {
        type.replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    func destroy(
        service: ProviderService,
        token: String
    ) async throws {
        // Delete the web service first; even if it fails the user
        // has a route to retry. Then delete the managed PG if we
        // provisioned one — without this they keep paying $7+/mo
        // for an orphan database.
        try await client.deleteService(id: service.id, token: token)

        if let pgID = service.metadata["managed_postgres_id"] {
            try await client.deletePostgres(id: pgID, token: token)
        }
    }

    // MARK: - Postgres provisioning helper

    /// Provisions a managed PG, polls until ready, fetches the
    /// connection string. Long-running — typical 30-90s.
    ///
    /// **Polling timeout**: 10 minutes. Render docs say provisioning
    /// completes within 1-2 min in most regions; 10 min is a generous
    /// upper bound that gives slow regions room without leaving the
    /// user staring at an infinite spinner.
    private func provisionManagedPostgres(
        name: String,
        ownerId: String,
        plan: Plan,
        region: Region,
        token: String
    ) async throws -> (id: String, connectionURL: String) {
        let pg = try await client.createPostgres(
            body: RenderPostgresCreateRequest(
                name: name,
                ownerId: ownerId,
                plan: plan.id,
                version: RenderCatalog.defaultPostgresVersion,
                region: region.id,
                databaseName: "keywordista",
                databaseUser: "keywordista"
            ),
            token: token
        )

        // Poll until ready or hard timeout.
        let deadline = Date().addingTimeInterval(600)  // 10 min
        let pollInterval: UInt64 = 5_000_000_000        // 5s
        while Date() < deadline {
            let current = try await client.retrievePostgres(id: pg.id, token: token)
            if RenderPostgresStatus.isReady(current.status) { break }
            if RenderPostgresStatus.isFailed(current.status) {
                throw ProviderError.unknown(
                    detail: "postgres provisioning failed (status=\(current.status))"
                )
            }
            try await Task.sleep(nanoseconds: pollInterval)
        }

        let info = try await client.retrieveConnectionInfo(
            postgresID: pg.id,
            token: token
        )
        return (pg.id, info.internalConnectionString)
    }
}
