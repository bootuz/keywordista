import Fluent
import Foundation
import Vapor

/// One Apple Ads sync attempt, as the Setup tab and status chip show it.
struct AppleAdsSyncRun: Content, Equatable {
    let id: UUID
    let adAccountId: Int64?
    let trigger: AppleAdsSyncTrigger
    let outcome: AppleAdsSyncOutcome
    let startedAt: Date
    let finishedAt: Date?
    let fromDate: String?
    let toDate: String?
    let error: String?
}

protocol AppleAdsDataRepositoryProtocol: Sendable {
    /// Writes one sync's results in a single transaction: replaces the
    /// account's campaigns, keywords and ideas, replaces its day rows with
    /// `from ≤ date ≤ to`, and upserts popularity by (term, country, genre,
    /// week). A failure leaves every table as it was.
    func replace(adAccountId: Int64, from: String, to: String, with snapshot: AppleAdsSnapshot) async throws
    /// Disconnect: every mirror row and every sync run.
    func purgeAll() async throws
    /// Account switch: every mirror row and run belonging to another account.
    func purge(exceptAdAccountId: Int64) async throws

    func campaigns(adAccountId: Int64) async throws -> [AppleAdsCampaignInfo]
    func keywords(adAccountId: Int64) async throws -> [AppleAdsKeywordInfo]
    func campaignDays(adAccountId: Int64, from: String, to: String) async throws -> [AppleAdsCampaignDay]
    func keywordDays(adAccountId: Int64, from: String, to: String) async throws -> [AppleAdsKeywordDay]
    func searchTermDays(adAccountId: Int64, from: String, to: String) async throws -> [AppleAdsSearchTermDay]
    /// Latest week per (term, country). `terms` lowercased, `countries` uppercased.
    func popularity(terms: Set<String>, countries: Set<String>) async throws -> [AppleAdsTermPopularity]
    func ideas(adAccountId: Int64, appStoreId: Int64) async throws -> [AppleAdsKeywordIdea]
    /// The newest date with campaign data, used as the end of reporting periods.
    func latestDate(adAccountId: Int64) async throws -> String?

    func startRun(trigger: AppleAdsSyncTrigger) async throws -> AppleAdsSyncRun
    func finishRun(id: UUID, adAccountId: Int64?, outcome: AppleAdsSyncOutcome, fromDate: String?, toDate: String?, error: String?) async throws
    func latestRun() async throws -> AppleAdsSyncRun?
    func lastSuccessfulRun(adAccountId: Int64) async throws -> AppleAdsSyncRun?
}

struct FluentAppleAdsDataRepository: AppleAdsDataRepositoryProtocol {
    let db: any Database

    func replace(adAccountId: Int64, from: String, to: String, with snapshot: AppleAdsSnapshot) async throws {
        try await db.transaction { tx in
            try await AppleAdsCampaignRow.query(on: tx).filter(\.$adAccountId == adAccountId).delete()
            try await AppleAdsKeywordRow.query(on: tx).filter(\.$adAccountId == adAccountId).delete()
            try await AppleAdsKeywordIdeaRow.query(on: tx).filter(\.$adAccountId == adAccountId).delete()
            try await AppleAdsCampaignDayRow.query(on: tx).filter(\.$adAccountId == adAccountId)
                .filter(\.$date >= from).filter(\.$date <= to).delete()
            try await AppleAdsKeywordDayRow.query(on: tx).filter(\.$adAccountId == adAccountId)
                .filter(\.$date >= from).filter(\.$date <= to).delete()
            try await AppleAdsSearchTermDayRow.query(on: tx).filter(\.$adAccountId == adAccountId)
                .filter(\.$date >= from).filter(\.$date <= to).delete()

            for c in snapshot.campaigns { try await Self.row(c, adAccountId).create(on: tx) }
            for k in snapshot.keywords { try await Self.row(k, adAccountId).create(on: tx) }
            for i in snapshot.ideas { try await Self.row(i, adAccountId).create(on: tx) }
            for d in snapshot.campaignDays { try await Self.row(d, adAccountId).create(on: tx) }
            for d in snapshot.keywordDays { try await Self.row(d, adAccountId).create(on: tx) }
            for d in snapshot.searchTermDays { try await Self.row(d, adAccountId).create(on: tx) }
            for p in snapshot.popularity {
                try await AppleAdsTermPopularityRow.query(on: tx)
                    .filter(\.$adAccountId == adAccountId).filter(\.$term == p.term)
                    .filter(\.$country == p.country).filter(\.$genre == p.genre).filter(\.$week == p.week)
                    .delete()
                try await Self.row(p, adAccountId).create(on: tx)
            }
        }
    }

    func purgeAll() async throws {
        try await db.transaction { tx in
            try await AppleAdsCampaignRow.query(on: tx).delete()
            try await AppleAdsKeywordRow.query(on: tx).delete()
            try await AppleAdsKeywordIdeaRow.query(on: tx).delete()
            try await AppleAdsCampaignDayRow.query(on: tx).delete()
            try await AppleAdsKeywordDayRow.query(on: tx).delete()
            try await AppleAdsSearchTermDayRow.query(on: tx).delete()
            try await AppleAdsTermPopularityRow.query(on: tx).delete()
            try await AppleAdsSyncRunRow.query(on: tx).delete()
        }
    }

    func purge(exceptAdAccountId keep: Int64) async throws {
        try await db.transaction { tx in
            try await AppleAdsCampaignRow.query(on: tx).filter(\.$adAccountId != keep).delete()
            try await AppleAdsKeywordRow.query(on: tx).filter(\.$adAccountId != keep).delete()
            try await AppleAdsKeywordIdeaRow.query(on: tx).filter(\.$adAccountId != keep).delete()
            try await AppleAdsCampaignDayRow.query(on: tx).filter(\.$adAccountId != keep).delete()
            try await AppleAdsKeywordDayRow.query(on: tx).filter(\.$adAccountId != keep).delete()
            try await AppleAdsSearchTermDayRow.query(on: tx).filter(\.$adAccountId != keep).delete()
            try await AppleAdsTermPopularityRow.query(on: tx).filter(\.$adAccountId != keep).delete()
            // Runs with no account (failed before resolving one) belong to nobody: keep them.
            try await AppleAdsSyncRunRow.query(on: tx).filter(\.$adAccountId != keep).filter(\.$adAccountId != nil).delete()
        }
    }

    func campaigns(adAccountId: Int64) async throws -> [AppleAdsCampaignInfo] {
        try await AppleAdsCampaignRow.query(on: db).filter(\.$adAccountId == adAccountId).all().map {
            AppleAdsCampaignInfo(
                id: $0.appleId, appStoreId: $0.appStoreId, name: $0.name, status: $0.status,
                countries: $0.countries.split(separator: ",").map(String.init),
                dailyBudget: $0.dailyBudget, currency: $0.currency
            )
        }
    }

    func keywords(adAccountId: Int64) async throws -> [AppleAdsKeywordInfo] {
        try await AppleAdsKeywordRow.query(on: db).filter(\.$adAccountId == adAccountId).all().map {
            AppleAdsKeywordInfo(
                id: $0.appleId, campaignId: $0.campaignId, adGroupId: $0.adGroupId, text: $0.text,
                matchType: $0.matchType, status: $0.status, bid: $0.bid, currency: $0.currency
            )
        }
    }

    func campaignDays(adAccountId: Int64, from: String, to: String) async throws -> [AppleAdsCampaignDay] {
        try await AppleAdsCampaignDayRow.query(on: db).filter(\.$adAccountId == adAccountId)
            .filter(\.$date >= from).filter(\.$date <= to).all().map {
                AppleAdsCampaignDay(campaignId: $0.campaignId, date: $0.date, metrics: Self.metrics($0), currency: $0.currency)
            }
    }

    func keywordDays(adAccountId: Int64, from: String, to: String) async throws -> [AppleAdsKeywordDay] {
        try await AppleAdsKeywordDayRow.query(on: db).filter(\.$adAccountId == adAccountId)
            .filter(\.$date >= from).filter(\.$date <= to).all().map {
                AppleAdsKeywordDay(
                    keywordId: $0.keywordId, campaignId: $0.campaignId, country: $0.country, date: $0.date,
                    metrics: Self.metrics($0), suggestedBid: $0.suggestedBid
                )
            }
    }

    func searchTermDays(adAccountId: Int64, from: String, to: String) async throws -> [AppleAdsSearchTermDay] {
        try await AppleAdsSearchTermDayRow.query(on: db).filter(\.$adAccountId == adAccountId)
            .filter(\.$date >= from).filter(\.$date <= to).all().map {
                AppleAdsSearchTermDay(
                    campaignId: $0.campaignId, adGroupId: $0.adGroupId, keywordId: $0.keywordId == 0 ? nil : $0.keywordId,
                    term: $0.term, source: $0.source, country: $0.country, date: $0.date, metrics: Self.metrics($0)
                )
            }
    }

    func popularity(terms: Set<String>, countries: Set<String>) async throws -> [AppleAdsTermPopularity] {
        guard !terms.isEmpty, !countries.isEmpty else { return [] }
        let rows = try await AppleAdsTermPopularityRow.query(on: db)
            .filter(\.$term ~~ Array(terms)).filter(\.$country ~~ Array(countries)).all()
        var latest: [String: AppleAdsTermPopularityRow] = [:]
        for row in rows {
            let key = "\(row.term)\u{0}\(row.country)"
            if let seen = latest[key], seen.week >= row.week { continue }
            latest[key] = row
        }
        return latest.values.map {
            AppleAdsTermPopularity(
                term: $0.term, country: $0.country, genre: $0.genre, week: $0.week,
                popularity100: $0.popularity100, popularity5: $0.popularity5, rankInGenre: $0.rankInGenre
            )
        }
    }

    func ideas(adAccountId: Int64, appStoreId: Int64) async throws -> [AppleAdsKeywordIdea] {
        try await AppleAdsKeywordIdeaRow.query(on: db).filter(\.$adAccountId == adAccountId)
            .filter(\.$appStoreId == appStoreId).all().map {
                AppleAdsKeywordIdea(appStoreId: $0.appStoreId, country: $0.country, text: $0.text, popularity: $0.popularity)
            }
    }

    func latestDate(adAccountId: Int64) async throws -> String? {
        try await AppleAdsCampaignDayRow.query(on: db).filter(\.$adAccountId == adAccountId)
            .sort(\.$date, .descending).first()?.date
    }

    func startRun(trigger: AppleAdsSyncTrigger) async throws -> AppleAdsSyncRun {
        let row = AppleAdsSyncRunRow()
        row.id = UUID()
        row.trigger = trigger.rawValue
        row.outcome = AppleAdsSyncOutcome.running.rawValue
        row.startedAt = Date()
        try await row.create(on: db)
        return Self.run(row)
    }

    func finishRun(id: UUID, adAccountId: Int64?, outcome: AppleAdsSyncOutcome, fromDate: String?, toDate: String?, error: String?) async throws {
        guard let row = try await AppleAdsSyncRunRow.find(id, on: db) else { return }
        row.adAccountId = adAccountId
        row.outcome = outcome.rawValue
        row.finishedAt = Date()
        row.fromDate = fromDate
        row.toDate = toDate
        row.error = error
        try await row.update(on: db)
    }

    func latestRun() async throws -> AppleAdsSyncRun? {
        try await AppleAdsSyncRunRow.query(on: db).sort(\.$startedAt, .descending).first().map(Self.run)
    }

    func lastSuccessfulRun(adAccountId: Int64) async throws -> AppleAdsSyncRun? {
        try await AppleAdsSyncRunRow.query(on: db)
            .filter(\.$adAccountId == adAccountId)
            .filter(\.$outcome == AppleAdsSyncOutcome.succeeded.rawValue)
            .sort(\.$finishedAt, .descending).first().map(Self.run)
    }

    // MARK: Mapping

    private static func run(_ row: AppleAdsSyncRunRow) -> AppleAdsSyncRun {
        AppleAdsSyncRun(
            id: row.id ?? UUID(), adAccountId: row.adAccountId,
            trigger: AppleAdsSyncTrigger(rawValue: row.trigger) ?? .manual,
            outcome: AppleAdsSyncOutcome(rawValue: row.outcome) ?? .failed,
            startedAt: row.startedAt, finishedAt: row.finishedAt,
            fromDate: row.fromDate, toDate: row.toDate, error: row.error
        )
    }

    private static func metrics(_ r: some MetricRowLike) -> AppleAdsMetrics {
        AppleAdsMetrics(
            impressions: r.impressions, taps: r.taps, tapInstalls: r.tapInstalls,
            viewInstalls: r.viewInstalls, totalInstalls: r.totalInstalls, spend: r.spend
        )
    }

    private static func fill(_ r: some MetricRowLike, _ m: AppleAdsMetrics) {
        r.impressions = m.impressions
        r.taps = m.taps
        r.tapInstalls = m.tapInstalls
        r.viewInstalls = m.viewInstalls
        r.totalInstalls = m.totalInstalls
        r.spend = m.spend
    }

    private static func row(_ c: AppleAdsCampaignInfo, _ account: Int64) -> AppleAdsCampaignRow {
        let r = AppleAdsCampaignRow()
        r.id = UUID(); r.adAccountId = account; r.appleId = c.id; r.appStoreId = c.appStoreId
        r.name = c.name; r.status = c.status
        r.countries = c.countries.map { $0.uppercased() }.joined(separator: ",")
        r.dailyBudget = c.dailyBudget; r.currency = c.currency
        return r
    }

    private static func row(_ k: AppleAdsKeywordInfo, _ account: Int64) -> AppleAdsKeywordRow {
        let r = AppleAdsKeywordRow()
        r.id = UUID(); r.adAccountId = account; r.appleId = k.id; r.campaignId = k.campaignId
        r.adGroupId = k.adGroupId; r.text = k.text; r.matchType = k.matchType; r.status = k.status
        r.bid = k.bid; r.currency = k.currency
        return r
    }

    private static func row(_ i: AppleAdsKeywordIdea, _ account: Int64) -> AppleAdsKeywordIdeaRow {
        let r = AppleAdsKeywordIdeaRow()
        r.id = UUID(); r.adAccountId = account; r.appStoreId = i.appStoreId
        r.country = i.country.uppercased(); r.text = i.text; r.popularity = i.popularity
        return r
    }

    private static func row(_ d: AppleAdsCampaignDay, _ account: Int64) -> AppleAdsCampaignDayRow {
        let r = AppleAdsCampaignDayRow()
        r.id = UUID(); r.adAccountId = account; r.campaignId = d.campaignId; r.date = d.date; r.currency = d.currency
        fill(r, d.metrics)
        return r
    }

    private static func row(_ d: AppleAdsKeywordDay, _ account: Int64) -> AppleAdsKeywordDayRow {
        let r = AppleAdsKeywordDayRow()
        r.id = UUID(); r.adAccountId = account; r.keywordId = d.keywordId; r.campaignId = d.campaignId
        r.country = d.country.uppercased(); r.date = d.date; r.suggestedBid = d.suggestedBid
        fill(r, d.metrics)
        return r
    }

    private static func row(_ d: AppleAdsSearchTermDay, _ account: Int64) -> AppleAdsSearchTermDayRow {
        let r = AppleAdsSearchTermDayRow()
        r.id = UUID(); r.adAccountId = account; r.campaignId = d.campaignId; r.adGroupId = d.adGroupId
        r.keywordId = d.keywordId ?? 0; r.term = d.term; r.source = d.source
        r.country = d.country.uppercased(); r.date = d.date
        fill(r, d.metrics)
        return r
    }

    private static func row(_ p: AppleAdsTermPopularity, _ account: Int64) -> AppleAdsTermPopularityRow {
        let r = AppleAdsTermPopularityRow()
        r.id = UUID(); r.adAccountId = account; r.term = p.term.lowercased(); r.country = p.country.uppercased()
        r.genre = p.genre; r.week = p.week
        r.popularity100 = p.popularity100; r.popularity5 = p.popularity5; r.rankInGenre = p.rankInGenre
        return r
    }
}

/// The metric columns the three day tables share.
protocol MetricRowLike: AnyObject {
    var impressions: Int { get set }
    var taps: Int { get set }
    var tapInstalls: Int { get set }
    var viewInstalls: Int { get set }
    var totalInstalls: Int { get set }
    var spend: Double { get set }
}

extension AppleAdsCampaignDayRow: MetricRowLike {}
extension AppleAdsKeywordDayRow: MetricRowLike {}
extension AppleAdsSearchTermDayRow: MetricRowLike {}
