@testable import App
import Foundation

/// Settings stub holding only Apple Ads credentials.
actor ASASettingsStub: SettingsServiceProtocol {
    var asa: ASACredentials?
    init(_ asa: ASACredentials? = ASACredentials(clientId: "c", clientSecret: "s", orgId: nil, adAccountId: "42")) { self.asa = asa }
    func setASA(_ creds: ASACredentials?) { asa = creds }
    func getASCStatus() async throws -> ASCStatus { ASCStatus(keyId: nil, issuerId: nil, hasPrivateKey: false) }
    func getASCCredentials() async throws -> ASCCredentials? { nil }
    func setASCCredentials(_ creds: ASCCredentials) async throws {}
    func clearASCCredentials() async throws {}
    func getASAStatus() async throws -> ASAStatus { ASAStatus(clientId: asa?.clientId, orgId: asa?.orgId, hasClientSecret: asa != nil) }
    func getASACredentials() async throws -> ASACredentials? { asa }
    func setASACredentials(_ creds: ASACredentials) async throws { asa = creds }
    func clearASACredentials() async throws { asa = nil }
}

/// Scripted Apple Ads reads: fixed data per call, optional failures, and a
/// record of the date windows requested. `gate` lets a test hold the sync
/// mid-fetch (released with `release()`).
actor ScriptedReportingClient: AppleAdsReportingClientProtocol {
    var adAccountId: Int64 = 42
    var campaigns: [AppleAdsCampaignInfo] = []
    var keywordsByCampaign: [Int64: [AppleAdsKeywordInfo]] = [:]
    var campaignDayRows: [AppleAdsCampaignDay] = []
    var keywordDayRows: [AppleAdsKeywordDay] = []
    var searchTermDayRows: [AppleAdsSearchTermDay] = []
    var popularityRows: [AppleAdsTermPopularity] = []
    var ideaRows: [AppleAdsKeywordIdea] = []
    var resolveError: (any Error)?
    var searchTermError: (any Error)?
    var popularityError: (any Error)?
    private(set) var requestedWindows: [(from: String, to: String)] = []
    private(set) var popularityRequests: [(terms: [String], country: String, genre: String)] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var holdNextFetch = false
    private(set) var isHeld = false

    init() {}

    func configure(_ body: @Sendable (isolated ScriptedReportingClient) -> Void) { body(self) }
    func holdAtCampaigns() { holdNextFetch = true }
    /// Lets a held fetch go, or cancels a hold the sync hasn't reached yet.
    func release() { holdNextFetch = false; gate?.resume(); gate = nil; isHeld = false }

    func resolveAdAccountId() async throws -> Int64 {
        if let resolveError { throw resolveError }
        return adAccountId
    }
    func campaignInfos() async throws -> [AppleAdsCampaignInfo] {
        if holdNextFetch {
            holdNextFetch = false
            isHeld = true
            // Like a real request, a cancelled sync stops waiting.
            await withTaskCancellationHandler {
                await withCheckedContinuation { gate = $0 }
            } onCancel: {
                Task { await self.release() }
            }
        }
        return campaigns
    }
    func keywords(campaignId: Int64) async throws -> [AppleAdsKeywordInfo] { keywordsByCampaign[campaignId] ?? [] }
    func campaignDays(campaignIds: [Int64], from: String, to: String) async throws -> [AppleAdsCampaignDay] {
        requestedWindows.append((from, to))
        return campaignDayRows.filter { campaignIds.contains($0.campaignId) }
    }
    func keywordDays(campaignId: Int64, from: String, to: String) async throws -> [AppleAdsKeywordDay] {
        keywordDayRows.filter { $0.campaignId == campaignId }
    }
    func searchTermDays(campaignId: Int64, from: String, to: String) async throws -> [AppleAdsSearchTermDay] {
        if let searchTermError { throw searchTermError }
        return searchTermDayRows.filter { $0.campaignId == campaignId }
    }
    func termPopularity(terms: [String], country: String, genre: String) async throws -> [AppleAdsTermPopularity] {
        popularityRequests.append((terms, country, genre))
        if let popularityError { throw popularityError }
        return popularityRows.filter { terms.contains($0.term) && $0.country == country }
    }
    func keywordIdeas(appStoreId: Int64, country: String) async throws -> [AppleAdsKeywordIdea] {
        ideaRows.filter { $0.appStoreId == appStoreId && $0.country == country }
    }
}

enum AppleAdsFixtures {
    static func metrics(taps: Int, installs: Int = 0, spend: Double = 0, impressions: Int? = nil) -> AppleAdsMetrics {
        AppleAdsMetrics(impressions: impressions ?? taps * 10, taps: taps, tapInstalls: installs, viewInstalls: 0, totalInstalls: installs, spend: spend)
    }
    static let ownApp = WatchedApp(id: UUID(), appStoreId: 99, bundleId: "com.example.cards", name: "Cards", iconURL: nil, primaryGenreId: 6017, kind: .own)
    static let campaign = AppleAdsCampaignInfo(id: 1, appStoreId: 99, name: "US Search", status: "RUNNING", countries: ["US"], dailyBudget: 20, currency: "USD")
}
