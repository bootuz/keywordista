@testable import App
import Foundation
import Logging
import Testing
import Vapor
import XCTVapor

@Suite("GET /settings/asa/accounts")
struct SettingsControllerASAAccountsTests {

    private static func session(_ transport: StubAppleAdsTransport) -> AppleAdsSession {
        AppleAdsSession(logger: Logger(label: "t")) { _ in
            try await makeTestAppleAdsClient(transport: transport)
        }
    }

    @Test("lists every ad account the API user can reach")
    func accountsEndpointListsAccounts() async throws {
        let transport = StubAppleAdsTransport([
            .init(status: .ok, json: #"{"result":{"acls":[{"adAccount":{"id":5,"name":"Main","orgId":1},"roles":["Admin"]},{"adAccount":{"id":6,"name":"Side","orgId":1},"roles":["Read Only"]}]}}"#),
        ])
        let session = Self.session(transport)
        let app = try await SettingsTestApp.make(session: session)
        defer { Task { await session.shutdown(); try? await app.asyncShutdown() } }

        try await app.test(.PUT, "api/v1/settings/asa", beforeRequest: { req in
            try req.content.encode(["clientId": "c", "clientSecret": "s"])
        }, afterResponse: { res async in #expect(res.status == .ok) })
        try await app.test(.GET, "api/v1/settings/asa/accounts", afterResponse: { res async throws in
            #expect(res.status == .ok)
            let accounts = try res.content.decode([ASAAdAccount].self)
            #expect(accounts == [
                ASAAdAccount(id: "5", name: "Main", orgId: "1", roles: ["Admin"]),
                ASAAdAccount(id: "6", name: "Side", orgId: "1", roles: ["Read Only"]),
            ])
        })
    }

    @Test("without stored credentials the endpoint asks to connect first")
    func accountsEndpointWithoutCredentialsIs409() async throws {
        let transport = StubAppleAdsTransport()
        let app = try await SettingsTestApp.make(session: Self.session(transport))
        defer { Task { try? await app.asyncShutdown() } }

        try await app.test(.GET, "api/v1/settings/asa/accounts", afterResponse: { res async throws in
            #expect(res.status == .conflict)
            #expect(res.body.string.contains("Connect Apple Ads first"))
        })
        #expect(await transport.requests.isEmpty)
    }

    @Test("disconnecting Apple Ads shuts the live client down")
    func disconnectShutsDownClient() async throws {
        let transport = StubAppleAdsTransport([
            .init(status: .ok, json: #"{"result":{"acls":[{"adAccount":{"id":5,"name":"Main","orgId":1},"roles":["Admin"]}]}}"#),
        ])
        let session = Self.session(transport)
        let app = try await SettingsTestApp.make(session: session)
        defer { Task { await session.shutdown(); try? await app.asyncShutdown() } }

        try await app.test(.PUT, "api/v1/settings/asa", beforeRequest: { req in
            try req.content.encode(["clientId": "c", "clientSecret": "s"])
        }, afterResponse: { res async in #expect(res.status == .ok) })
        try await app.test(.GET, "api/v1/settings/asa/accounts", afterResponse: { res async in #expect(res.status == .ok) })
        try await app.test(.DELETE, "api/v1/settings/asa", afterResponse: { res async in #expect(res.status == .noContent) })
        #expect(await session.completedShutdowns == 1)
    }

    @Test("Apple's 401 comes back as a 502 carrying the readable reason")
    func accountsEndpointSurfacesAppleAdsError() async throws {
        let transport = StubAppleAdsTransport([.init(status: .unauthorized, json: "{}")])
        let session = Self.session(transport)
        let app = try await SettingsTestApp.make(session: session)
        defer { Task { await session.shutdown(); try? await app.asyncShutdown() } }

        try await app.test(.PUT, "api/v1/settings/asa", beforeRequest: { req in
            try req.content.encode(["clientId": "c", "clientSecret": "s"])
        }, afterResponse: { res async in #expect(res.status == .ok) })
        try await app.test(.GET, "api/v1/settings/asa/accounts", afterResponse: { res async throws in
            #expect(res.status == .badGateway)
            #expect(res.body.string.contains("rejected the credentials"))
        })
    }
}
