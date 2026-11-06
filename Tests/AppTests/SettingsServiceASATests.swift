@testable import App
import Crypto
import Foundation
import Testing
import Vapor
import XCTVapor

@Suite("Apple Ads ad account in settings")
struct SettingsServiceASATests {
    private func makeService() -> (SettingsService, InMemorySettingsRepository) {
        let repo = InMemorySettingsRepository()
        return (SettingsService(repository: repo, secretBox: SecretBox(key: SymmetricKey(size: .bits256))), repo)
    }

    @Test("ad account ID round-trips and is stored as plaintext")
    func adAccountIdRoundTrips() async throws {
        let (svc, repo) = makeService()
        try await svc.setASACredentials(ASACredentials(clientId: "c", clientSecret: "s", orgId: nil, adAccountId: "123"))
        #expect(try await svc.getASACredentials()?.adAccountId == "123")
        #expect(try await repo.get("asa.adAccountId") == "123")
    }

    @Test("status exposes the ad account ID")
    func statusExposesAdAccountId() async throws {
        let (svc, _) = makeService()
        try await svc.setASACredentials(ASACredentials(clientId: "c", clientSecret: "s", orgId: "9", adAccountId: "123"))
        #expect(try await svc.getASAStatus().adAccountId == "123")
    }

    @Test("clearing credentials removes the ad account ID")
    func clearingRemovesAdAccountId() async throws {
        let (svc, repo) = makeService()
        try await svc.setASACredentials(ASACredentials(clientId: "c", clientSecret: "s", orgId: nil, adAccountId: "123"))
        try await svc.clearASACredentials()
        #expect(try await repo.get("asa.adAccountId") == nil)
    }

    @Test("PUT without adAccountId keeps the stored one")
    func putWithoutAdAccountIdKeepsStoredOne() async throws {
        let app = try await SettingsTestApp.make()
        defer { Task { try? await app.asyncShutdown() } }
        try await app.test(.PUT, "api/v1/settings/asa", beforeRequest: { req in
            try req.content.encode(["clientId": "c", "clientSecret": "s", "adAccountId": "123"])
        }, afterResponse: { res async in #expect(res.status == .ok) })
        try await app.test(.PUT, "api/v1/settings/asa", beforeRequest: { req in
            try req.content.encode(["clientId": "c2"])
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            #expect(try res.content.decode(ASAStatus.self).adAccountId == "123")
        })
    }
}
