@testable import App
import Foundation
import Logging
import Testing

@Suite("DeveloperKeywordsService")
struct DeveloperKeywordsServiceTests {
    @Test("returns [:] when ASC credentials are not configured")
    func fetchAll_emptyWhenNoCreds() async throws {
        let service = DeveloperKeywordsService(
            settings: StubSettingsService(creds: nil),
            watchedApps: InMemoryWatchedAppRepository([
                WatchedApp(id: UUID(), appStoreId: 1, bundleId: "com.x", name: "X", iconURL: nil),
            ]),
            makeClient: { _ in
                FailingASCClient(message: "should not be called when creds are missing")
            },
            logger: Logger(label: "test")
        )
        let result = try await service.fetchAll()
        #expect(result.isEmpty)
    }

    @Test("fans out per-app and folds locales into storefront codes")
    func fetchAll_foldsLocalesAcrossApps() async throws {
        let appA = WatchedApp(id: UUID(), appStoreId: 1, bundleId: "com.a", name: "A", iconURL: nil)
        let appB = WatchedApp(id: UUID(), appStoreId: 2, bundleId: "com.b", name: "B", iconURL: nil)
        let stub = StubASCClient(byBundle: [
            "com.a": ["en-US": ["flashcards", "anki"], "ja": ["暗記カード"]],
            "com.b": ["en-GB": ["revise", "study"]],
        ])
        let service = DeveloperKeywordsService(
            settings: StubSettingsService(creds: .init(keyId: "k", issuerId: "i", privateKey: "p")),
            watchedApps: InMemoryWatchedAppRepository([appA, appB]),
            makeClient: { _ in stub },
            logger: Logger(label: "test")
        )

        let result = try await service.fetchAll()

        let aId = appA.id!.uuidString
        let bId = appB.id!.uuidString
        #expect(Set(result[aId]?["us"] ?? []) == ["flashcards", "anki"])
        #expect(Set(result[aId]?["jp"] ?? []) == ["暗記カード"])
        // en-GB fans out to both UK and Ireland storefronts per the mapping
        // table — both should get the same keyword set.
        #expect(Set(result[bId]?["gb"] ?? []) == ["revise", "study"])
        #expect(Set(result[bId]?["ie"] ?? []) == ["revise", "study"])
    }

    @Test("one failing app yields {} for that app, others still populate")
    func fetchAll_isolatesFailures() async throws {
        let appA = WatchedApp(id: UUID(), appStoreId: 1, bundleId: "com.a", name: "A", iconURL: nil)
        let appB = WatchedApp(id: UUID(), appStoreId: 2, bundleId: "com.b", name: "B", iconURL: nil)
        let stub = StubASCClient(byBundle: ["com.a": ["en-US": ["ok"]]])  // com.b missing → throws
        let service = DeveloperKeywordsService(
            settings: StubSettingsService(creds: .init(keyId: "k", issuerId: "i", privateKey: "p")),
            watchedApps: InMemoryWatchedAppRepository([appA, appB]),
            makeClient: { _ in stub },
            logger: Logger(label: "test")
        )

        let result = try await service.fetchAll()
        #expect(result[appA.id!.uuidString]?["us"] == ["ok"])
        #expect(result[appB.id!.uuidString] == [:])
    }

    @Test("foldLocalesToStorefronts drops unmapped locales silently")
    func fold_dropsUnknownLocales() {
        let out = foldLocalesToStorefronts([
            "en-US": ["a"],
            "xx-YY": ["should-not-appear"],
        ])
        #expect(out["us"] == ["a"])
        #expect(out["xx"] == nil)
        #expect(out["yy"] == nil)
    }

    @Test("foldLocalesToStorefronts merges multiple locales mapping to the same storefront")
    func fold_mergesIntoSameStorefront() {
        // de-DE maps to de+at+ch; en-GB and en-AU map to non-overlapping
        // markets here, but de-DE alone forces at to share a keyword set
        // across all three.
        let out = foldLocalesToStorefronts(["de-DE": ["lernen", "karteikarten"]])
        #expect(Set(out["de"] ?? []) == ["lernen", "karteikarten"])
        #expect(Set(out["at"] ?? []) == ["lernen", "karteikarten"])
        #expect(Set(out["ch"] ?? []) == ["lernen", "karteikarten"])
    }
}

// ── Stubs ────────────────────────────────────────────────────────────────

private actor StubSettingsService: SettingsServiceProtocol {
    let creds: ASCCredentials?
    init(creds: ASCCredentials?) { self.creds = creds }

    func getASCStatus() async throws -> ASCStatus {
        ASCStatus(keyId: creds?.keyId, issuerId: creds?.issuerId, hasPrivateKey: creds != nil)
    }
    func getASCCredentials() async throws -> ASCCredentials? { creds }
    func setASCCredentials(_ creds: ASCCredentials) async throws {}
    func clearASCCredentials() async throws {}
    func getASAStatus() async throws -> ASAStatus {
        ASAStatus(clientId: nil, orgId: nil, hasClientSecret: false)
    }
    func getASACredentials() async throws -> ASACredentials? { nil }
    func setASACredentials(_ creds: ASACredentials) async throws {}
    func clearASACredentials() async throws {}
}

private actor StubASCClient: AppStoreConnectClientProtocol {
    let byBundle: [String: [String: [String]]]
    init(byBundle: [String: [String: [String]]]) { self.byBundle = byBundle }

    func fetchKeywords(forBundleId bundleId: String) async throws -> [String: [String]] {
        guard let result = byBundle[bundleId] else {
            throw AppStoreConnectClient.Failure.appNotFound(bundleId: bundleId)
        }
        return result
    }
}

private struct FailingASCClient: AppStoreConnectClientProtocol {
    let message: String
    func fetchKeywords(forBundleId bundleId: String) async throws -> [String: [String]] {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
