import XCTest

@testable import Keywordista

/// Covers the wizard's transition logic against a stub Provider that
/// returns canned data instantly. No network, no real provider, no
/// SwiftUI — just "given this input + this provider response, does the
/// state machine end up in the right phase with the right fields?"
final class DeployFlowCoordinatorTests: XCTestCase {

    // MARK: - Stub Provider

    /// Minimal Provider conformance that records calls and returns
    /// configurable responses. Lets tests exercise the coordinator
    /// without touching RenderProvider (already tested in M3.6).
    struct StubProvider: Provider {
        var kind: ProviderKind = .render
        var displayName: String = "Stub"
        var marketingTagline: String = "test"
        var supportLevel: ProviderSupport = .firstClass

        // Configurable behaviors per-test:
        var validateResult: Result<ProviderAccount, ProviderError> = .success(
            ProviderAccount(id: "tea-test", displayName: "Test", metadata: [:])
        )
        var fetchedRegions: [Region] = [
            Region(id: "oregon", displayName: "Oregon"),
        ]
        var fetchedPlans: [Plan] = [
            Plan(id: "starter", displayName: "Starter",
                 monthlyCostCents: 700, descriptionShort: ""),
        ]
        var fetchedDatabases: [DatabaseOption] = [
            .sqliteOnDisk(sizes: [DiskSize(sizeGB: 1, monthlyCostCents: 25)]),
        ]
        var createResult: Result<ProviderService, ProviderError> = .success(
            ProviderService(id: "srv-test", metadata: [
                "deploy_id": "dep-test",
                "url": "https://test.onrender.com",
            ])
        )

        func validateToken(_ token: String) async throws -> ProviderAccount {
            try validateResult.get()
        }
        func availableRegions(account: ProviderAccount, token: String) async throws -> [Region] {
            fetchedRegions
        }
        func availablePlans(account: ProviderAccount, token: String) async throws -> [Plan] {
            fetchedPlans
        }
        func availableDatabases(account: ProviderAccount, token: String) async throws -> [DatabaseOption] {
            fetchedDatabases
        }
        func estimateMonthlyCost(spec: DeploymentSpec) -> Money {
            .usd(spec.plan.monthlyCostCents)
        }
        // Stub always accepts the name unless overridden. Tests of
        // the validation path use a separate stub that rejects.
        var nameValidation: ServiceNameValidation = .ok
        func validateServiceName(_ name: String) -> ServiceNameValidation { nameValidation }
        // M3.22: every Provider now declares its URL shape. Stub uses
        // a deterministic .stub.test suffix so tests can assert on
        // baseURL without coupling to a real provider's pattern.
        func publicURLPattern(serviceName: String) -> URL? {
            URL(string: "https://\(serviceName).stub.test")
        }
        func createService(spec: DeploymentSpec, token: String) async throws -> ProviderService {
            try createResult.get()
        }
        func streamDeployEvents(service: ProviderService, token: String) -> AsyncStream<DeployEvent> {
            // Minimal — tests of the deploy phase use a separate
            // hand-driven stream (see testDeploySuccessTransitionsToSuccessPhase).
            AsyncStream { continuation in
                continuation.finish()
            }
        }
        func currentImageTag(service: ProviderService, token: String) async throws -> String {
            // Stub doesn't track image — tests don't exercise update flow.
            ""
        }
        func updateImage(service: ProviderService, toTag tag: String, token: String) async throws {}
        func fetchLogs(service: ProviderService, since: Date, token: String) async throws -> [LogLine] {
            []
        }
        func destroy(service: ProviderService, token: String) async throws {}
    }

    // ── Initial state ────────────────────────────────────────────────

    @MainActor
    func testInitialPhaseIsPickProvider() {
        let coord = DeployFlowCoordinator(providers: [StubProvider()], onCompletion: { _ in })
        XCTAssertEqual(coord.phase, .pickProvider)
        XCTAssertNil(coord.selectedProvider)
    }

    // ── Step 1 → 2 ──────────────────────────────────────────────────

    @MainActor
    func testSelectProviderAdvancesToAuthenticate() {
        let coord = DeployFlowCoordinator(providers: [StubProvider()], onCompletion: { _ in })
        coord.selectProvider(StubProvider())
        XCTAssertEqual(coord.phase, .authenticate)
        XCTAssertNotNil(coord.selectedProvider)
    }

    @MainActor
    func testSelectProviderClearsStaleAuthState() {
        let coord = DeployFlowCoordinator(providers: [StubProvider()], onCompletion: { _ in })
        coord.token = "old-token"
        coord.authError = "old error"
        coord.account = ProviderAccount(id: "old", displayName: "old", metadata: [:])

        coord.selectProvider(StubProvider())
        XCTAssertEqual(coord.token, "")
        XCTAssertNil(coord.authError)
        XCTAssertNil(coord.account)
    }

    // ── Step 2 (authenticate) ──────────────────────────────────────

    @MainActor
    func testAuthenticateSuccessAdvancesToConfigure() async {
        let coord = DeployFlowCoordinator(providers: [], onCompletion: { _ in })
        coord.selectProvider(StubProvider())
        coord.token = "rnd_valid"

        await coord.authenticate()

        XCTAssertEqual(coord.phase, .configure)
        XCTAssertNotNil(coord.account)
        XCTAssertFalse(coord.regions.isEmpty)
        XCTAssertFalse(coord.plans.isEmpty)
        XCTAssertFalse(coord.databases.isEmpty)
    }

    @MainActor
    func testAuthenticatePopulatesDefaultSelections() async {
        // After successful authenticate, the user can hit Continue
        // without making any picks — the first region / first plan /
        // cheapest database option is pre-selected.
        let coord = DeployFlowCoordinator(providers: [], onCompletion: { _ in })
        coord.selectProvider(StubProvider())
        coord.token = "rnd_valid"

        await coord.authenticate()

        XCTAssertEqual(coord.selectedRegion?.id, "oregon")
        XCTAssertEqual(coord.selectedPlan?.id, "starter")
        guard case .sqliteOnDisk(let size) = coord.selectedDatabase else {
            XCTFail("expected sqliteOnDisk default, got \(String(describing: coord.selectedDatabase))")
            return
        }
        XCTAssertEqual(size.sizeGB, 1)
    }

    @MainActor
    func testAuthenticateFailureStaysOnAuthenticatePhaseWithError() async {
        var stub = StubProvider()
        stub.validateResult = .failure(.authenticationFailed(detail: "bad key"))
        let coord = DeployFlowCoordinator(providers: [], onCompletion: { _ in })
        coord.selectProvider(stub)
        coord.token = "bad"

        await coord.authenticate()

        XCTAssertEqual(coord.phase, .authenticate)
        XCTAssertNotNil(coord.authError)
        XCTAssertTrue(coord.authError!.lowercased().contains("api key"))
        XCTAssertFalse(coord.authenticating)
    }

    @MainActor
    func testAuthenticateNoopsOnEmptyToken() async {
        let coord = DeployFlowCoordinator(providers: [], onCompletion: { _ in })
        coord.selectProvider(StubProvider())
        coord.token = ""  // empty

        await coord.authenticate()

        XCTAssertEqual(coord.phase, .authenticate, "empty token must not advance")
        XCTAssertFalse(coord.authenticating)
    }

    // ── Step 3 → 4 (proceedToConfirm) ──────────────────────────────

    @MainActor
    func testProceedToConfirmAssemblesSpecAndAdvances() async throws {
        let coord = DeployFlowCoordinator(providers: [], onCompletion: { _ in })
        coord.selectProvider(StubProvider())
        coord.token = "t"
        await coord.authenticate()

        coord.serviceName = "studio-prod"
        coord.adminEmail = "you@studio.local"

        try coord.proceedToConfirm()

        XCTAssertEqual(coord.phase, .confirm)
        let confirmation = try XCTUnwrap(coord.confirmation)
        XCTAssertEqual(confirmation.spec.serviceName, "studio-prod")
        XCTAssertEqual(confirmation.spec.region.id, "oregon")
        XCTAssertEqual(confirmation.spec.envVars["KEYWORDISTA_ADMIN_EMAIL"], "you@studio.local")
        XCTAssertEqual(confirmation.spec.envVars["KEYWORDISTA_MODE"], "server")
        XCTAssertNotNil(confirmation.spec.envVars["KEYWORDISTA_ENCRYPTION_KEY"])
        XCTAssertNotNil(confirmation.spec.envVars["KEYWORDISTA_ADMIN_PASSWORD_HASH"])
        XCTAssertEqual(confirmation.adminPassword.count, 24)
    }

    @MainActor
    func testProceedToConfirmThrowsWhenProviderRejectsServiceName() async {
        // The M3.16 integration: cockpit asks provider.validateServiceName
        // before assembling the spec. Stub returns .invalid → coordinator
        // should throw .invalidField rather than continue.
        var stub = StubProvider()
        stub.nameValidation = .invalid("Render says no underscores.")
        let coord = DeployFlowCoordinator(providers: [], onCompletion: { _ in })
        coord.selectProvider(stub)
        coord.token = "t"
        await coord.authenticate()
        coord.serviceName = "studio_prod"   // user typed an invalid name
        coord.adminEmail = "you@studio.local"

        XCTAssertThrowsError(try coord.proceedToConfirm()) { err in
            guard case DeployFlowError.invalidField(let msg) = err else {
                XCTFail("expected .invalidField, got \(err)"); return
            }
            XCTAssertTrue(msg.contains("underscore"))
        }
        XCTAssertEqual(coord.phase, .configure, "validation failure must keep us on configure")
    }

    @MainActor
    func testProceedToConfirmThrowsOnMissingServiceName() async {
        let coord = DeployFlowCoordinator(providers: [], onCompletion: { _ in })
        coord.selectProvider(StubProvider())
        coord.token = "t"
        await coord.authenticate()

        coord.serviceName = ""  // missing
        coord.adminEmail = "you@studio.local"

        XCTAssertThrowsError(try coord.proceedToConfirm()) { err in
            guard case DeployFlowError.missingField(let f) = err else {
                XCTFail("expected .missingField, got \(err)"); return
            }
            XCTAssertTrue(f.contains("service name"))
        }
        XCTAssertEqual(coord.phase, .configure, "validation failure must not advance")
    }

    @MainActor
    func testProceedToConfirmThrowsOnInvalidExternalPostgresURL() async {
        let coord = DeployFlowCoordinator(providers: [], onCompletion: { _ in })
        coord.selectProvider(StubProvider())
        coord.token = "t"
        await coord.authenticate()
        coord.serviceName = "studio"
        coord.adminEmail = "a@b"
        coord.selectedDatabase = .externalPostgres(connectionURL: "")
        coord.externalPostgresURL = "not-a-postgres-url"

        XCTAssertThrowsError(try coord.proceedToConfirm()) { err in
            guard case DeployFlowError.invalidField(let f) = err else {
                XCTFail("expected .invalidField, got \(err)"); return
            }
            XCTAssertTrue(f.contains("postgres://"))
        }
    }

    @MainActor
    func testProceedToConfirmStripsOwnerStashFromOutgoingEnvVars() async throws {
        // Internal plumbing: cockpit stashes KEYWORDISTA_RENDER_OWNER_ID
        // in envVars for the provider to use. It MUST stay in the spec
        // (RenderProvider strips it itself). But the cockpit's spec
        // assembly does include it. Pin that contract here.
        let coord = DeployFlowCoordinator(providers: [], onCompletion: { _ in })
        coord.selectProvider(StubProvider())
        coord.token = "t"
        await coord.authenticate()
        coord.serviceName = "x"
        coord.adminEmail = "a@b"

        try coord.proceedToConfirm()
        let envVars = try XCTUnwrap(coord.confirmation?.spec.envVars)
        XCTAssertEqual(envVars["KEYWORDISTA_RENDER_OWNER_ID"], "tea-test",
                      "ownerId stash must be present in the spec the provider receives")
    }

    // ── Back / cancel ───────────────────────────────────────────────

    @MainActor
    func testGoBackFromConfigureReturnsToAuthenticate() async {
        let coord = DeployFlowCoordinator(providers: [], onCompletion: { _ in })
        coord.selectProvider(StubProvider())
        coord.token = "t"
        await coord.authenticate()
        XCTAssertEqual(coord.phase, .configure)

        coord.goBack()
        XCTAssertEqual(coord.phase, .authenticate)
    }

    @MainActor
    func testGoBackFromDeployingIsNoOp() {
        let coord = DeployFlowCoordinator(providers: [], onCompletion: { _ in })
        coord.phase = .deploying
        coord.goBack()
        XCTAssertEqual(coord.phase, .deploying, "back must not work mid-deploy")
    }

    // ── Cost rendering (sanity check) ────────────────────────────────

    @MainActor
    func testConfirmationContextCarriesEstimatedCost() async throws {
        let coord = DeployFlowCoordinator(providers: [], onCompletion: { _ in })
        coord.selectProvider(StubProvider())
        coord.token = "t"
        await coord.authenticate()
        coord.serviceName = "x"
        coord.adminEmail = "a@b"

        try coord.proceedToConfirm()
        let cost = try XCTUnwrap(coord.confirmation?.estimatedMonthlyCost)
        // StubProvider's estimateMonthlyCost returns plan-only.
        XCTAssertEqual(cost.cents, 700)
    }

    // ── M3.11: cost rendering for the 3 database choices ────────────

    func testRenderCatalogCostMath() {
        // Pin the line-item math the cockpit's CostBreakdown view
        // renders. These are the numbers the user sees in Confirm
        // and Success, so a wrong addition shows up as the wrong
        // billing expectation.
        let provider = RenderProvider()
        let starter = RenderCatalog.webServicePlans.first!

        // Plan + 1 GB disk = $7.00 + $0.25 = $7.25
        let sqliteSpec = makeRenderSpec(
            plan: starter,
            database: .sqliteOnDisk(size: RenderCatalog.diskSizes.first!)
        )
        XCTAssertEqual(provider.estimateMonthlyCost(spec: sqliteSpec).cents, 725)

        // Plan + cheapest managed PG = $7.00 + $6.00 = $13.00
        let pgSpec = makeRenderSpec(
            plan: starter,
            database: .providerManagedPostgres(plan: RenderCatalog.postgresPlans.first!)
        )
        XCTAssertEqual(provider.estimateMonthlyCost(spec: pgSpec).cents, 1300)

        // Plan + external PG = $7.00 + $0 = $7.00 (user pays their PG host)
        let extSpec = makeRenderSpec(
            plan: starter,
            database: .externalPostgres(connectionURL: "postgres://x")
        )
        XCTAssertEqual(provider.estimateMonthlyCost(spec: extSpec).cents, 700)
    }

    // Helper for the cost-math test — minimal spec matching
    // RenderProvider's expected shape.
    private func makeRenderSpec(plan: Plan, database: DatabaseChoice) -> DeploymentSpec {
        DeploymentSpec(
            imageRef: "ghcr.io/x/k:1.0",
            serviceName: "test",
            region: RenderCatalog.regions.first!,
            plan: plan,
            database: database,
            envVars: ["KEYWORDISTA_RENDER_OWNER_ID": "tea-x"]
        )
    }
}
