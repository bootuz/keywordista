@testable import App
import Foundation

actor InMemoryWatchedAppRepository: WatchedAppRepositoryProtocol {
    private var storage: [UUID: WatchedApp] = [:]

    init(_ initial: [WatchedApp] = []) {
        for app in initial {
            if let id = app.id { storage[id] = app }
        }
    }

    func all() async throws -> [WatchedApp] { Array(storage.values) }

    func find(id: UUID) async throws -> WatchedApp? { storage[id] }

    func save(_ app: WatchedApp) async throws {
        let id = app.id ?? UUID()
        app.id = id
        storage[id] = app
    }

    func delete(id: UUID) async throws { storage.removeValue(forKey: id) }
}

actor InMemoryKeywordRepository: KeywordRepositoryProtocol {
    private var storage: [UUID: Keyword] = [:]

    init(_ initial: [Keyword] = []) {
        for kw in initial {
            if let id = kw.id { storage[id] = kw }
        }
    }

    func all() async throws -> [Keyword] { Array(storage.values) }

    func filtered(country: String?) async throws -> [Keyword] {
        guard let country else { return Array(storage.values) }
        return storage.values.filter { $0.countryCode == country.lowercased() }
    }

    func find(id: UUID) async throws -> Keyword? { storage[id] }

    func save(_ keyword: Keyword) async throws {
        let id = keyword.id ?? UUID()
        keyword.id = id
        storage[id] = keyword
    }

    func delete(id: UUID) async throws { storage.removeValue(forKey: id) }
}

actor InMemoryRankCheckRepository: RankCheckRepositoryProtocol {
    private(set) var saved: [RankCheck] = []
    // Tracks every checkedAt-bump triggered by no-change refreshes. Tests
    // can inspect this to verify the dedupe path was taken instead of an
    // insert (which would land in `saved`).
    private(set) var bumps: [(id: UUID, checkedAt: Date)] = []

    func save(_ check: RankCheck) async throws {
        if check.id == nil { check.id = UUID() }
        saved.append(check)
    }

    func updateCheckedAt(id: UUID, checkedAt: Date) async throws {
        bumps.append((id, checkedAt))
        if let idx = saved.firstIndex(where: { $0.id == id }) {
            saved[idx].checkedAt = checkedAt
        }
    }

    func latest(keywordID: UUID, watchedAppID: UUID) async throws -> RankCheck? {
        saved
            .filter { $0.$keyword.id == keywordID && $0.$watchedApp.id == watchedAppID }
            .max(by: { $0.checkedAt < $1.checkedAt })
    }

    func recent(keywordID: UUID, watchedAppID: UUID, limit: Int) async throws -> [RankCheck] {
        Array(
            saved
                .filter { $0.$keyword.id == keywordID && $0.$watchedApp.id == watchedAppID }
                .sorted(by: { $0.checkedAt > $1.checkedAt })
                .prefix(limit),
        )
    }

    func history(keywordID: UUID, watchedAppID: UUID) async throws -> [RankCheck] {
        saved
            .filter { $0.$keyword.id == keywordID && $0.$watchedApp.id == watchedAppID }
            .sorted(by: { $0.checkedAt < $1.checkedAt })
    }
}

actor InMemoryTopResultSnapshotRepository: TopResultSnapshotRepositoryProtocol {
    private(set) var saved: [TopResultSnapshot] = []

    func save(_ snapshot: TopResultSnapshot) async throws { saved.append(snapshot) }

    func latestSnapshot(keywordID: UUID) async throws -> [TopResultSnapshot] {
        let forKeyword = saved.filter { $0.$keyword.id == keywordID }
        guard let latest = forKeyword.map(\.checkedAt).max() else { return [] }
        return forKeyword
            .filter { $0.checkedAt == latest }
            .sorted(by: { $0.position < $1.position })
    }
}

/// In-memory Apple Ads mirror with the same replace/purge semantics as the
/// Fluent repository (window replace, account scoping, latest-week popularity).
actor InMemoryAppleAdsDataRepository: AppleAdsDataRepositoryProtocol {
    private var campaignsByAccount: [Int64: [AppleAdsCampaignInfo]] = [:]
    private var keywordsByAccount: [Int64: [AppleAdsKeywordInfo]] = [:]
    private var ideasByAccount: [Int64: [AppleAdsKeywordIdea]] = [:]
    private var campaignDayRows: [(Int64, AppleAdsCampaignDay)] = []
    private var keywordDayRows: [(Int64, AppleAdsKeywordDay)] = []
    private var searchTermDayRows: [(Int64, AppleAdsSearchTermDay)] = []
    private var popularityRows: [(Int64, AppleAdsTermPopularity)] = []
    private var runs: [AppleAdsSyncRun] = []
    /// Set to make the next `replace` throw, to exercise failure paths.
    var failNextReplace: (any Error)?

    init() {}

    func setFailNextReplace(_ error: (any Error)?) { failNextReplace = error }

    func replace(adAccountId: Int64, from: String, to: String, with s: AppleAdsSnapshot) async throws {
        if let error = failNextReplace { failNextReplace = nil; throw error }
        campaignsByAccount[adAccountId] = s.campaigns
        keywordsByAccount[adAccountId] = s.keywords
        ideasByAccount[adAccountId] = s.ideas
        let inWindow: (String) -> Bool = { $0 >= from && $0 <= to }
        campaignDayRows.removeAll { $0.0 == adAccountId && inWindow($0.1.date) }
        keywordDayRows.removeAll { $0.0 == adAccountId && inWindow($0.1.date) }
        searchTermDayRows.removeAll { $0.0 == adAccountId && inWindow($0.1.date) }
        campaignDayRows += s.campaignDays.map { (adAccountId, $0) }
        keywordDayRows += s.keywordDays.map { (adAccountId, $0) }
        searchTermDayRows += s.searchTermDays.map { (adAccountId, $0) }
        for p in s.popularity {
            popularityRows.removeAll { $0.0 == adAccountId && $0.1.term == p.term && $0.1.country == p.country && $0.1.genre == p.genre && $0.1.week == p.week }
            popularityRows.append((adAccountId, p))
        }
    }

    func purgeAll() async throws {
        campaignsByAccount = [:]; keywordsByAccount = [:]; ideasByAccount = [:]
        campaignDayRows = []; keywordDayRows = []; searchTermDayRows = []; popularityRows = []; runs = []
    }

    func purge(exceptAdAccountId keep: Int64) async throws {
        campaignsByAccount = campaignsByAccount.filter { $0.key == keep }
        keywordsByAccount = keywordsByAccount.filter { $0.key == keep }
        ideasByAccount = ideasByAccount.filter { $0.key == keep }
        campaignDayRows.removeAll { $0.0 != keep }
        keywordDayRows.removeAll { $0.0 != keep }
        searchTermDayRows.removeAll { $0.0 != keep }
        popularityRows.removeAll { $0.0 != keep }
        runs.removeAll { $0.adAccountId != nil && $0.adAccountId != keep }
    }

    func campaigns(adAccountId: Int64) async throws -> [AppleAdsCampaignInfo] { campaignsByAccount[adAccountId] ?? [] }
    func keywords(adAccountId: Int64) async throws -> [AppleAdsKeywordInfo] { keywordsByAccount[adAccountId] ?? [] }
    func campaignDays(adAccountId: Int64, from: String, to: String) async throws -> [AppleAdsCampaignDay] {
        campaignDayRows.filter { $0.0 == adAccountId && $0.1.date >= from && $0.1.date <= to }.map(\.1)
    }
    func keywordDays(adAccountId: Int64, from: String, to: String) async throws -> [AppleAdsKeywordDay] {
        keywordDayRows.filter { $0.0 == adAccountId && $0.1.date >= from && $0.1.date <= to }.map(\.1)
    }
    func searchTermDays(adAccountId: Int64, from: String, to: String) async throws -> [AppleAdsSearchTermDay] {
        searchTermDayRows.filter { $0.0 == adAccountId && $0.1.date >= from && $0.1.date <= to }.map(\.1)
    }
    func popularity(terms: Set<String>, countries: Set<String>) async throws -> [AppleAdsTermPopularity] {
        var latest: [String: AppleAdsTermPopularity] = [:]
        for (_, p) in popularityRows where terms.contains(p.term) && countries.contains(p.country) {
            let key = "\(p.term)\u{0}\(p.country)"
            if let seen = latest[key], seen.week >= p.week { continue }
            latest[key] = p
        }
        return Array(latest.values)
    }
    func ideas(adAccountId: Int64, appStoreId: Int64) async throws -> [AppleAdsKeywordIdea] {
        (ideasByAccount[adAccountId] ?? []).filter { $0.appStoreId == appStoreId }
    }
    func latestDate(adAccountId: Int64) async throws -> String? {
        campaignDayRows.filter { $0.0 == adAccountId }.map(\.1.date).max()
    }

    func startRun(trigger: AppleAdsSyncTrigger) async throws -> AppleAdsSyncRun {
        let run = AppleAdsSyncRun(id: UUID(), adAccountId: nil, trigger: trigger, outcome: .running, startedAt: Date(), finishedAt: nil, fromDate: nil, toDate: nil, error: nil)
        runs.append(run)
        return run
    }
    func finishRun(id: UUID, adAccountId: Int64?, outcome: AppleAdsSyncOutcome, fromDate: String?, toDate: String?, error: String?) async throws {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        let r = runs[i]
        runs[i] = AppleAdsSyncRun(id: r.id, adAccountId: adAccountId, trigger: r.trigger, outcome: outcome, startedAt: r.startedAt, finishedAt: Date(), fromDate: fromDate, toDate: toDate, error: error)
    }
    func latestRun() async throws -> AppleAdsSyncRun? { runs.last }
    func lastSuccessfulRun(adAccountId: Int64) async throws -> AppleAdsSyncRun? {
        runs.last { $0.adAccountId == adAccountId && $0.outcome == .succeeded }
    }
    /// Test hook: seed a finished run directly.
    func seedRun(_ run: AppleAdsSyncRun) { runs.append(run) }
    var allRuns: [AppleAdsSyncRun] { runs }
}
