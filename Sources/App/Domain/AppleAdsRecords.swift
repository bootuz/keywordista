import Foundation

// Plain values the Apple Ads client returns, the sync stores, and the read
// services aggregate. No Vapor or Fluent here: the same shapes travel
// through all three layers. Dates are `yyyy-MM-dd` in the org's reporting
// timezone (ORTZ), money is a Double plus its currency code.

struct AppleAdsMetrics: Sendable, Equatable {
    var impressions: Int
    var taps: Int
    var tapInstalls: Int
    var viewInstalls: Int
    var totalInstalls: Int
    var spend: Double

    static let zero = AppleAdsMetrics(impressions: 0, taps: 0, tapInstalls: 0, viewInstalls: 0, totalInstalls: 0, spend: 0)

    static func + (lhs: AppleAdsMetrics, rhs: AppleAdsMetrics) -> AppleAdsMetrics {
        AppleAdsMetrics(
            impressions: lhs.impressions + rhs.impressions,
            taps: lhs.taps + rhs.taps,
            tapInstalls: lhs.tapInstalls + rhs.tapInstalls,
            viewInstalls: lhs.viewInstalls + rhs.viewInstalls,
            totalInstalls: lhs.totalInstalls + rhs.totalInstalls,
            spend: lhs.spend + rhs.spend
        )
    }
}

struct AppleAdsCampaignInfo: Sendable, Equatable {
    let id: Int64
    let appStoreId: Int64
    let name: String
    let status: String
    let countries: [String]
    let dailyBudget: Double?
    let currency: String?
}

struct AppleAdsKeywordInfo: Sendable, Equatable {
    let id: Int64
    let campaignId: Int64
    let adGroupId: Int64
    let text: String
    let matchType: String
    let status: String
    let bid: Double?
    let currency: String?
}

struct AppleAdsCampaignDay: Sendable, Equatable {
    let campaignId: Int64
    let date: String
    let metrics: AppleAdsMetrics
    let currency: String?
}

struct AppleAdsKeywordDay: Sendable, Equatable {
    let keywordId: Int64
    let campaignId: Int64
    let country: String
    let date: String
    let metrics: AppleAdsMetrics
    let suggestedBid: Double?
}

struct AppleAdsSearchTermDay: Sendable, Equatable {
    let campaignId: Int64
    let adGroupId: Int64
    let keywordId: Int64?
    /// `LOW_VOLUME` when Apple withholds the text for privacy.
    let term: String
    let source: String
    let country: String
    let date: String
    let metrics: AppleAdsMetrics
}

struct AppleAdsTermPopularity: Sendable, Equatable {
    /// Lowercased.
    let term: String
    /// Uppercased ISO code.
    let country: String
    let genre: String
    /// First day of the week Apple reports, `yyyy-MM-dd`.
    let week: String
    let popularity100: Int?
    let popularity5: Int?
    let rankInGenre: Int?
}

struct AppleAdsKeywordIdea: Sendable, Equatable {
    let appStoreId: Int64
    let country: String
    let text: String
    let popularity: Int?
}

/// Everything one sync fetched, written to the mirror in a single transaction.
struct AppleAdsSnapshot: Sendable, Equatable {
    var campaigns: [AppleAdsCampaignInfo]
    var keywords: [AppleAdsKeywordInfo]
    var campaignDays: [AppleAdsCampaignDay]
    var keywordDays: [AppleAdsKeywordDay]
    var searchTermDays: [AppleAdsSearchTermDay]
    var popularity: [AppleAdsTermPopularity]
    var ideas: [AppleAdsKeywordIdea]
    /// (app, storefront) pairs whose suggestions Apple failed to return this
    /// time: their stored ideas stay, so a hiccup doesn't empty Bid ideas.
    var failedIdeaScopes: Set<AppleAdsIdeaScope> = []
}

struct AppleAdsIdeaScope: Hashable, Sendable {
    let appStoreId: Int64
    /// Uppercased ISO code.
    let country: String
}

enum AppleAdsSyncTrigger: String, Codable, Sendable {
    case scheduled, manual
}

enum AppleAdsSyncOutcome: String, Codable, Sendable {
    case running, succeeded, failed
}
