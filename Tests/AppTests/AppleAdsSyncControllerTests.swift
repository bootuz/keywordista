@testable import App
import Fluent
import Foundation
import Testing
import Vapor
import XCTVapor

@Suite("Apple Ads sync endpoints and purge")
struct AppleAdsSyncControllerTests {

    private static func client() async -> ScriptedReportingClient {
        let client = ScriptedReportingClient()
        await client.configure { c in
            c.campaigns = [AppleAdsFixtures.campaign]
            c.campaignDayRows = [AppleAdsCampaignDay(campaignId: 1, date: "2026-11-05", metrics: AppleAdsFixtures.metrics(taps: 10, installs: 1, spend: 3), currency: "USD")]
        }
        return client
    }

    @Test("Sync now answers 202 and two quick presses start one sync")
    func syncNowReturns202AndRunsOnce() async throws {
        let client = await Self.client()
        await client.holdAtCampaigns()
        let app = try await AppleAdsTestApp.make(client: client)
        defer { Task { try? await app.asyncShutdown() } }
        try await AppleAdsTestApp.connect(app)

        try await app.test(.POST, "api/v1/apple-ads/sync", afterResponse: { res async throws in
            #expect(res.status == .accepted)
            #expect(try res.content.decode(AppleAdsSyncStatus.self).running)
        })
        try await app.test(.POST, "api/v1/apple-ads/sync", afterResponse: { res async in #expect(res.status == .accepted) })
        await client.release()
        try await AppleAdsTestApp.waitForIdle(app)
        #expect(try await AppleAdsSyncRunRow.query(on: app.db).count() == 1)
    }

    @Test("sync-status reports running, then the finished run")
    func syncStatusReportsRunningThenFinished() async throws {
        let client = await Self.client()
        await client.holdAtCampaigns()
        let app = try await AppleAdsTestApp.make(client: client)
        defer { Task { try? await app.asyncShutdown() } }
        try await AppleAdsTestApp.connect(app)

        try await app.test(.POST, "api/v1/apple-ads/sync", afterResponse: { _ async in })
        try await app.test(.GET, "api/v1/apple-ads/sync-status", afterResponse: { res async throws in
            #expect(try res.content.decode(AppleAdsSyncStatus.self).running)
        })
        await client.release()
        try await AppleAdsTestApp.waitForIdle(app)
        try await app.test(.GET, "api/v1/apple-ads/sync-status", afterResponse: { res async throws in
            let status = try res.content.decode(AppleAdsSyncStatus.self)
            #expect(!status.running)
            #expect(status.lastRun?.outcome == .succeeded)
            #expect(status.lastSuccessAt != nil)
        })
    }

    @Test("Sync now without Apple Ads connected is a 409")
    func syncWithoutCredentialsIs409() async throws {
        let app = try await AppleAdsTestApp.make(client: await Self.client())
        defer { Task { try? await app.asyncShutdown() } }
        try await app.test(.POST, "api/v1/apple-ads/sync", afterResponse: { res async in
            #expect(res.status == .conflict)
            #expect(res.body.string.contains("Connect Apple Ads first"))
        })
    }

    @Test("disconnecting mid-sync leaves no synced data behind")
    func disconnectDuringSyncLeavesNoData() async throws {
        let client = await Self.client()
        let app = try await AppleAdsTestApp.make(client: client)
        defer { Task { try? await app.asyncShutdown() } }
        try await AppleAdsTestApp.connect(app)
        // A finished sync first, so there is data to delete.
        try await app.test(.POST, "api/v1/apple-ads/sync", afterResponse: { _ async in })
        try await AppleAdsTestApp.waitForIdle(app)
        #expect(try await AppleAdsTestApp.mirrorRowCount(app) > 0)

        await client.holdAtCampaigns()
        try await app.test(.POST, "api/v1/apple-ads/sync", afterResponse: { _ async in })
        while await !client.isHeld { try await Task.sleep(for: .milliseconds(2)) }
        try await app.test(.DELETE, "api/v1/settings/asa", afterResponse: { res async in #expect(res.status == .noContent) })
        try await AppleAdsTestApp.waitForIdle(app)
        #expect(try await AppleAdsTestApp.mirrorRowCount(app) == 0)
    }

    @Test("saving a different client ID deletes the synced data")
    func changingClientIdPurgesMirror() async throws {
        let app = try await AppleAdsTestApp.make(client: await Self.client())
        defer { Task { try? await app.asyncShutdown() } }
        try await AppleAdsTestApp.connect(app)
        try await app.test(.POST, "api/v1/apple-ads/sync", afterResponse: { _ async in })
        try await AppleAdsTestApp.waitForIdle(app)
        #expect(try await AppleAdsTestApp.mirrorRowCount(app) > 0)

        try await AppleAdsTestApp.connect(app, clientId: "someone-else")
        #expect(try await AppleAdsTestApp.mirrorRowCount(app) == 0)
    }

    @Test("in server mode a signed-in member can press Sync now")
    func serverModeMemberCanSync() async throws {
        let base = try await AuthTestApp.make()
        let app = try await AppleAdsTestApp.make(client: await Self.client(), configureRoutes: { app in
            let authenticated = app.routes.grouped("api", "v1").grouped(AuthMiddleware(sessionTTLDays: AuthTestApp.sessionTTLDays))
            try authenticated.register(collection: AppleAdsController())
            try authenticated.grouped(RoleMiddleware.requireAdmin()).register(collection: SettingsController())
        }, base: base)
        defer { Task { try? await app.asyncShutdown() } }
        let adminCookie = try await AuthTestApp.setupAdmin(on: app)
        try await app.test(.PUT, "api/v1/settings/asa", headers: AuthTestApp.cookieHeaders(adminCookie), beforeRequest: { req in
            try req.content.encode(["clientId": "c", "clientSecret": "s", "adAccountId": "42"])
        }, afterResponse: { res async in #expect(res.status == .ok) })

        let hasher = try PasswordHasher(cost: AuthTestApp.bcryptCost)
        let member = User(email: "member@studio.local", passwordHash: try await hasher.hash("member-pw-12"), role: .member)
        try await member.save(on: app.db)
        let session = AuthSession(userID: try member.requireID(), ttlDays: 30)
        try await session.save(on: app.db)

        try await app.test(.POST, "api/v1/apple-ads/sync", headers: AuthTestApp.cookieHeaders(session.token), afterResponse: { res async in
            #expect(res.status == .accepted)
        })
        try await AppleAdsTestApp.waitForIdle(app)
    }
}
