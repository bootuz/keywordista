import XCTest

@testable import Keywordista

/// Coverage for RenderProvider's orchestration logic against a stubbed
/// HTTPClient. The real Render API costs $7+ per `createService` call,
/// so production-grade E2E is the manual M3.13 step against a real
/// account. These tests pin the wire-level contract: what bytes go
/// out, what bytes come back, and how the provider sequences calls.
///
/// **What's covered**:
///   • validateToken happy path + 401 path + empty-workspaces case
///   • availableRegions/Plans/Databases return the catalog
///   • estimateMonthlyCost adds plan + disk OR plan + PG OR plan only
///   • createService with sqliteOnDisk: one POST /services
///   • createService with managed PG: POST /postgres → poll →
///     GET connection-info → POST /services with DATABASE_URL
///   • createService with externalPostgres: one POST /services, URL pass-through
///   • destroy with managed PG: two DELETEs
///
/// **What's NOT covered here**: streamDeployEvents (timing-sensitive,
/// would need a fake clock; M3.13 manual E2E confirms it works).
final class RenderProviderTests: XCTestCase {

    // ── Stub client ──────────────────────────────────────────────────

    /// HTTP stub that returns canned responses in order. Tests assert
    /// against the captured requests after the operation completes.
    final class StubHTTPClient: HTTPClient, @unchecked Sendable {
        // Each canned response is a closure that decides based on the
        // request. Letting tests script "if path matches X, return Y"
        // is more readable than parallel arrays for sequenced calls.
        var responder: @Sendable (URLRequest) -> (Int, Data) = { _ in
            (200, Data())
        }
        var calls: [URLRequest] = []

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            calls.append(request)
            let (status, body) = responder(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (body, response)
        }
    }

    private func providerWithStub(_ stub: StubHTTPClient) -> RenderProvider {
        RenderProvider(client: RenderClient(httpClient: stub))
    }

    private func json(_ s: String) -> Data { Data(s.utf8) }

    // ── validateToken ────────────────────────────────────────────────

    func testValidateTokenReturnsFirstOwner() async throws {
        let stub = StubHTTPClient()
        stub.responder = { [self] _ in
            (200, json("""
                [{"owner":{"id":"tea-abc","name":"Studio","email":"a@b.co","type":"team"}}]
            """))
        }
        let account = try await providerWithStub(stub).validateToken("rnd_token")
        XCTAssertEqual(account.id, "tea-abc")
        XCTAssertTrue(account.displayName.contains("Studio"))
        XCTAssertEqual(account.metadata["owner_email"], "a@b.co")
    }

    func testValidateTokenThrowsAuthFailedOn401() async {
        let stub = StubHTTPClient()
        stub.responder = { [self] _ in
            (401, json(#"{"id":"e","message":"invalid api key"}"#))
        }
        do {
            _ = try await providerWithStub(stub).validateToken("bad")
            XCTFail("expected throw")
        } catch let err as ProviderError {
            guard case .authenticationFailed = err else {
                XCTFail("expected .authenticationFailed, got \(err)")
                return
            }
        } catch {
            XCTFail("expected ProviderError, got \(error)")
        }
    }

    func testValidateTokenThrowsInvalidRequestOnEmptyWorkspaces() async {
        let stub = StubHTTPClient()
        stub.responder = { [self] _ in (200, json("[]")) }
        do {
            _ = try await providerWithStub(stub).validateToken("rnd_token")
            XCTFail("expected throw")
        } catch let err as ProviderError {
            guard case .invalidRequest = err else {
                XCTFail("expected .invalidRequest, got \(err)"); return
            }
        } catch {
            XCTFail("expected ProviderError, got \(error)")
        }
    }

    func testValidateTokenSendsBearerHeader() async throws {
        let stub = StubHTTPClient()
        stub.responder = { [self] _ in
            (200, json("""
                [{"owner":{"id":"tea-x","name":"X","email":"x@x","type":"team"}}]
            """))
        }
        _ = try await providerWithStub(stub).validateToken("rnd_xyz")
        XCTAssertEqual(
            stub.calls.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer rnd_xyz"
        )
    }

    // ── Catalogs ─────────────────────────────────────────────────────

    func testAvailableRegionsReturnsCatalog() async throws {
        let regions = try await providerWithStub(StubHTTPClient())
            .availableRegions(account: stubAccount(), token: "t")
        XCTAssertEqual(regions, RenderCatalog.regions)
    }

    func testAvailablePlansReturnsCatalog() async throws {
        let plans = try await providerWithStub(StubHTTPClient())
            .availablePlans(account: stubAccount(), token: "t")
        XCTAssertEqual(plans, RenderCatalog.webServicePlans)
    }

    func testAvailableDatabasesIncludesAllThreeChoices() async throws {
        let dbs = try await providerWithStub(StubHTTPClient())
            .availableDatabases(account: stubAccount(), token: "t")
        XCTAssertEqual(dbs.count, 3)
        XCTAssertEqual(dbs[0].id, "sqlite_on_disk")
        XCTAssertEqual(dbs[1].id, "provider_managed_postgres")
        XCTAssertEqual(dbs[2].id, "external_postgres")
    }

    // ── estimateMonthlyCost ──────────────────────────────────────────

    func testCostSqliteAddsPlanPlusDisk() {
        let spec = makeSpec(database: .sqliteOnDisk(
            size: DiskSize(sizeGB: 1, monthlyCostCents: 25)
        ))
        let total = providerWithStub(StubHTTPClient()).estimateMonthlyCost(spec: spec)
        // Starter is $7.00 + $0.25 disk = $7.25.
        XCTAssertEqual(total.cents, 725)
    }

    func testCostManagedPgAddsPlanPlusPgPlan() {
        let spec = makeSpec(database: .providerManagedPostgres(
            plan: Plan(id: "basic_256mb", displayName: "B256",
                       monthlyCostCents: 600, descriptionShort: "")
        ))
        let total = providerWithStub(StubHTTPClient()).estimateMonthlyCost(spec: spec)
        // Starter $7 + $6 PG = $13.
        XCTAssertEqual(total.cents, 1300)
    }

    func testCostExternalPgIsPlanOnly() {
        let spec = makeSpec(database: .externalPostgres(
            connectionURL: "postgres://example"
        ))
        let total = providerWithStub(StubHTTPClient()).estimateMonthlyCost(spec: spec)
        XCTAssertEqual(total.cents, 700)
    }

    // ── createService — sqliteOnDisk path ────────────────────────────

    func testCreateServiceSqliteSendsDiskAndDatabasePath() async throws {
        let stub = StubHTTPClient()
        stub.responder = { [self] _ in
            (201, json("""
                {
                    "service": {
                        "id": "srv-new",
                        "name": "test",
                        "ownerId": "tea-x",
                        "serviceDetails": {"url": "https://test.onrender.com"}
                    },
                    "deployId": "dep-first"
                }
            """))
        }
        let spec = makeSpec(database: .sqliteOnDisk(
            size: DiskSize(sizeGB: 5, monthlyCostCents: 125)
        ))
        let result = try await providerWithStub(stub).createService(
            spec: spec, token: "t"
        )

        XCTAssertEqual(result.id, "srv-new")
        XCTAssertEqual(result.metadata["deploy_id"], "dep-first")
        XCTAssertNil(result.metadata["managed_postgres_id"])

        // Exactly one call: POST /services.
        XCTAssertEqual(stub.calls.count, 1)
        let call = stub.calls[0]
        XCTAssertEqual(call.httpMethod, "POST")
        XCTAssertTrue(call.url!.path.hasSuffix("/services"))

        // Verify the disk + DATABASE_PATH made it into the body.
        let body = try XCTUnwrap(call.httpBody)
        let bodyDict = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let details = bodyDict["serviceDetails"] as! [String: Any]
        let disk = details["disk"] as? [String: Any]
        XCTAssertEqual(disk?["sizeGB"] as? Int, 5)
        XCTAssertEqual(disk?["mountPath"] as? String, "/data")

        let envVars = bodyDict["envVars"] as! [[String: String]]
        let dbPath = envVars.first(where: { $0["key"] == "DATABASE_PATH" })
        XCTAssertEqual(dbPath?["value"], "/data/db.sqlite")

        // Owner-stash should be stripped from outgoing env vars —
        // it's our internal plumbing, never sent to Render.
        XCTAssertNil(envVars.first(where: { $0["key"] == "KEYWORDISTA_RENDER_OWNER_ID" }))
    }

    // ── createService — managed PG path (the sequenced one) ──────────

    func testCreateServiceManagedPostgresSequencesCalls() async throws {
        let stub = StubHTTPClient()
        // Path-based dispatch — avoids mutable counter capture (which
        // Swift 6's Sendable checking rejects in test-closure context).
        // The order of CALLS is verified afterwards via stub.calls,
        // not in the responder itself.
        stub.responder = { [self] request in
            let path = request.url!.path
            let method = request.httpMethod ?? "GET"
            if method == "POST" && path.hasSuffix("/postgres") {
                return (201, json("""
                    {"id":"dpg-new","name":"test-db","status":"creating",
                     "region":"oregon","plan":"basic_256mb"}
                """))
            }
            if method == "GET" && path.hasSuffix("/connection-info") {
                return (200, json("""
                    {
                        "password": "secret",
                        "internalConnectionString": "postgres://u:p@dpg-new-a/d",
                        "externalConnectionString": "postgres://u:p@oregon.../d"
                    }
                """))
            }
            if method == "GET" && path.contains("/postgres/dpg-new") {
                // Always return "available" — the test doesn't exercise
                // the multi-poll path (would force a 5s sleep).
                return (200, json("""
                    {"id":"dpg-new","name":"test-db","status":"available",
                     "region":"oregon","plan":"basic_256mb"}
                """))
            }
            if method == "POST" && path.hasSuffix("/services") {
                return (201, json("""
                    {
                        "service": {
                            "id": "srv-new",
                            "name": "test",
                            "ownerId": "tea-x",
                            "serviceDetails": {"url": "https://test.onrender.com"}
                        },
                        "deployId": "dep-first"
                    }
                """))
            }
            return (500, Data())
        }

        let spec = makeSpec(database: .providerManagedPostgres(
            plan: Plan(id: "basic_256mb", displayName: "B",
                       monthlyCostCents: 600, descriptionShort: "")
        ))
        let result = try await providerWithStub(stub).createService(
            spec: spec, token: "t"
        )

        // Verify call sequence by inspecting stub.calls after the fact.
        // Expected order: POST /postgres → GET /postgres/{id} → GET
        // connection-info → POST /services. Exactly 4 calls.
        XCTAssertEqual(stub.calls.count, 4, "expected exactly 4 calls in the sequence")
        XCTAssertEqual(stub.calls[0].httpMethod, "POST")
        XCTAssertTrue(stub.calls[0].url!.path.hasSuffix("/postgres"))
        XCTAssertEqual(stub.calls[1].httpMethod, "GET")
        XCTAssertTrue(stub.calls[1].url!.path.contains("/postgres/dpg-new"))
        XCTAssertFalse(stub.calls[1].url!.path.hasSuffix("/connection-info"))
        XCTAssertEqual(stub.calls[2].httpMethod, "GET")
        XCTAssertTrue(stub.calls[2].url!.path.hasSuffix("/connection-info"))
        XCTAssertEqual(stub.calls[3].httpMethod, "POST")
        XCTAssertTrue(stub.calls[3].url!.path.hasSuffix("/services"))

        XCTAssertEqual(result.metadata["managed_postgres_id"], "dpg-new",
                      "service metadata must carry the PG id for later destroy()")

        // Verify the createService request used the internal connection
        // string from connection-info as DATABASE_URL.
        let serviceBody = try XCTUnwrap(stub.calls[3].httpBody)
        let bodyDict = try JSONSerialization.jsonObject(with: serviceBody) as! [String: Any]
        let envVars = bodyDict["envVars"] as! [[String: String]]
        let dbUrl = envVars.first(where: { $0["key"] == "DATABASE_URL" })
        XCTAssertEqual(dbUrl?["value"], "postgres://u:p@dpg-new-a/d",
                      "must use internalConnectionString, not external")
    }

    // ── createService — external PG path ─────────────────────────────

    func testCreateServiceExternalPostgresPassesThroughURL() async throws {
        let stub = StubHTTPClient()
        stub.responder = { [self] _ in
            (201, json("""
                {
                    "service": {
                        "id": "srv-x",
                        "name": "t",
                        "ownerId": "tea-x",
                        "serviceDetails": {"url": "https://t.onrender.com"}
                    },
                    "deployId": "dep-x"
                }
            """))
        }
        let spec = makeSpec(database: .externalPostgres(
            connectionURL: "postgres://user:pass@neon.tech/db"
        ))
        _ = try await providerWithStub(stub).createService(spec: spec, token: "t")

        XCTAssertEqual(stub.calls.count, 1, "external PG = no Render PG calls")
        let body = try XCTUnwrap(stub.calls[0].httpBody)
        let bodyDict = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let envVars = bodyDict["envVars"] as! [[String: String]]
        let dbUrl = envVars.first(where: { $0["key"] == "DATABASE_URL" })
        XCTAssertEqual(dbUrl?["value"], "postgres://user:pass@neon.tech/db")
    }

    // ── destroy ──────────────────────────────────────────────────────

    func testDestroyServiceOnlyWhenNoManagedPg() async throws {
        let stub = StubHTTPClient()
        stub.responder = { [self] _ in (204, Data()) }
        let service = ProviderService(id: "srv-x", metadata: ["deploy_id": "dep-x"])
        try await providerWithStub(stub).destroy(service: service, token: "t")
        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertEqual(stub.calls[0].httpMethod, "DELETE")
        XCTAssertTrue(stub.calls[0].url!.path.hasSuffix("/services/srv-x"))
    }

    func testDestroyAlsoDeletesManagedPostgres() async throws {
        let stub = StubHTTPClient()
        stub.responder = { [self] _ in (204, Data()) }
        let service = ProviderService(
            id: "srv-x",
            metadata: ["deploy_id": "d", "managed_postgres_id": "dpg-y"]
        )
        try await providerWithStub(stub).destroy(service: service, token: "t")

        XCTAssertEqual(stub.calls.count, 2, "service + PG = 2 deletes")
        XCTAssertTrue(stub.calls[0].url!.path.hasSuffix("/services/srv-x"))
        XCTAssertTrue(stub.calls[1].url!.path.hasSuffix("/postgres/dpg-y"))
    }

    func testDestroyTreats404AsSuccess() async throws {
        // Already-deleted service should not throw — matches the
        // Provider.destroy idempotency contract.
        let stub = StubHTTPClient()
        stub.responder = { [self] _ in
            (404, self.json(#"{"id":"e","message":"already gone"}"#))
        }
        let service = ProviderService(id: "srv-deleted", metadata: [:])
        try await providerWithStub(stub).destroy(service: service, token: "t")
        XCTAssertEqual(stub.calls.count, 1)
    }

    // ── Helpers ──────────────────────────────────────────────────────

    private func stubAccount() -> ProviderAccount {
        ProviderAccount(id: "tea-x", displayName: "Test", metadata: [:])
    }

    private func makeSpec(database: DatabaseChoice) -> DeploymentSpec {
        DeploymentSpec(
            imageRef: "ghcr.io/owner/keywordista:1.0.0",
            serviceName: "test",
            region: Region(id: "oregon", displayName: "Oregon"),
            plan: Plan(
                id: "starter",
                displayName: "Starter",
                monthlyCostCents: 700,
                descriptionShort: ""
            ),
            database: database,
            envVars: [
                "KEYWORDISTA_RENDER_OWNER_ID": "tea-x",
                "KEYWORDISTA_MODE": "server",
                "KEYWORDISTA_ENCRYPTION_KEY": String(repeating: "00", count: 32),
                "KEYWORDISTA_PUBLIC_BASE_URL": "https://test.onrender.com",
                "KEYWORDISTA_ADMIN_EMAIL": "you@studio.local",
                "KEYWORDISTA_ADMIN_PASSWORD_HASH": "$2y$12$test",
            ]
        )
    }
}
