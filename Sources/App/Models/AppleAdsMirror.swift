import Fluent
import Foundation

// Local mirror of the user's Apple Ads data, read by the Apple Ads area.
//
// Why a mirror and not an append-only log like `RankCheck`: Apple revises
// recent days (late installs, spend corrections), so each sync *replaces*
// its date window for the ad account. Keeping old values would double-count.
//
// Every row carries `ad_account_id` so switching accounts or disconnecting
// can delete exactly the right rows, and a stale account's numbers can never
// leak into another's.

final class AppleAdsCampaignRow: Model, @unchecked Sendable {
    static let schema = "apple_ads_campaigns"
    @ID(key: .id) var id: UUID?
    @Field(key: "ad_account_id") var adAccountId: Int64
    @Field(key: "apple_id") var appleId: Int64
    @Field(key: "app_store_id") var appStoreId: Int64
    @Field(key: "name") var name: String
    @Field(key: "status") var status: String
    /// Comma-joined uppercase ISO codes.
    @Field(key: "countries") var countries: String
    @OptionalField(key: "daily_budget") var dailyBudget: Double?
    @OptionalField(key: "currency") var currency: String?
    init() {}
}

final class AppleAdsKeywordRow: Model, @unchecked Sendable {
    static let schema = "apple_ads_keywords"
    @ID(key: .id) var id: UUID?
    @Field(key: "ad_account_id") var adAccountId: Int64
    @Field(key: "apple_id") var appleId: Int64
    @Field(key: "campaign_id") var campaignId: Int64
    @Field(key: "ad_group_id") var adGroupId: Int64
    @Field(key: "text") var text: String
    @Field(key: "match_type") var matchType: String
    @Field(key: "status") var status: String
    @OptionalField(key: "bid") var bid: Double?
    @OptionalField(key: "currency") var currency: String?
    init() {}
}

final class AppleAdsKeywordIdeaRow: Model, @unchecked Sendable {
    static let schema = "apple_ads_keyword_ideas"
    @ID(key: .id) var id: UUID?
    @Field(key: "ad_account_id") var adAccountId: Int64
    @Field(key: "app_store_id") var appStoreId: Int64
    @Field(key: "country") var country: String
    @Field(key: "text") var text: String
    @OptionalField(key: "popularity") var popularity: Int?
    init() {}
}

final class AppleAdsCampaignDayRow: Model, @unchecked Sendable {
    static let schema = "apple_ads_campaign_days"
    @ID(key: .id) var id: UUID?
    @Field(key: "ad_account_id") var adAccountId: Int64
    @Field(key: "campaign_id") var campaignId: Int64
    @Field(key: "date") var date: String
    @OptionalField(key: "currency") var currency: String?
    @Field(key: "impressions") var impressions: Int
    @Field(key: "taps") var taps: Int
    @Field(key: "tap_installs") var tapInstalls: Int
    @Field(key: "view_installs") var viewInstalls: Int
    @Field(key: "total_installs") var totalInstalls: Int
    @Field(key: "spend") var spend: Double
    init() {}
}

final class AppleAdsKeywordDayRow: Model, @unchecked Sendable {
    static let schema = "apple_ads_keyword_days"
    @ID(key: .id) var id: UUID?
    @Field(key: "ad_account_id") var adAccountId: Int64
    @Field(key: "keyword_id") var keywordId: Int64
    @Field(key: "campaign_id") var campaignId: Int64
    @Field(key: "country") var country: String
    @Field(key: "date") var date: String
    @OptionalField(key: "suggested_bid") var suggestedBid: Double?
    @Field(key: "impressions") var impressions: Int
    @Field(key: "taps") var taps: Int
    @Field(key: "tap_installs") var tapInstalls: Int
    @Field(key: "view_installs") var viewInstalls: Int
    @Field(key: "total_installs") var totalInstalls: Int
    @Field(key: "spend") var spend: Double
    init() {}
}

final class AppleAdsSearchTermDayRow: Model, @unchecked Sendable {
    static let schema = "apple_ads_search_term_days"
    @ID(key: .id) var id: UUID?
    @Field(key: "ad_account_id") var adAccountId: Int64
    @Field(key: "campaign_id") var campaignId: Int64
    @Field(key: "ad_group_id") var adGroupId: Int64
    /// 0 when the row isn't attributed to a keyword (Search Match), so the
    /// natural key stays NOT NULL and unique.
    @Field(key: "keyword_id") var keywordId: Int64
    @Field(key: "term") var term: String
    @Field(key: "source") var source: String
    @Field(key: "country") var country: String
    @Field(key: "date") var date: String
    @Field(key: "impressions") var impressions: Int
    @Field(key: "taps") var taps: Int
    @Field(key: "tap_installs") var tapInstalls: Int
    @Field(key: "view_installs") var viewInstalls: Int
    @Field(key: "total_installs") var totalInstalls: Int
    @Field(key: "spend") var spend: Double
    init() {}
}

final class AppleAdsTermPopularityRow: Model, @unchecked Sendable {
    static let schema = "apple_ads_term_popularity"
    @ID(key: .id) var id: UUID?
    @Field(key: "ad_account_id") var adAccountId: Int64
    @Field(key: "term") var term: String
    @Field(key: "country") var country: String
    @Field(key: "genre") var genre: String
    @Field(key: "week") var week: String
    @OptionalField(key: "popularity_100") var popularity100: Int?
    @OptionalField(key: "popularity_5") var popularity5: Int?
    @OptionalField(key: "rank_in_genre") var rankInGenre: Int?
    init() {}
}

final class AppleAdsSyncRunRow: Model, @unchecked Sendable {
    static let schema = "apple_ads_sync_runs"
    @ID(key: .id) var id: UUID?
    @OptionalField(key: "ad_account_id") var adAccountId: Int64?
    @Field(key: "trigger") var trigger: String
    @Field(key: "outcome") var outcome: String
    @Field(key: "started_at") var startedAt: Date
    @OptionalField(key: "finished_at") var finishedAt: Date?
    @OptionalField(key: "from_date") var fromDate: String?
    @OptionalField(key: "to_date") var toDate: String?
    @OptionalField(key: "error") var error: String?
    init() {}
}

struct CreateAppleAdsMirror: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AppleAdsCampaignRow.schema)
            .id()
            .field("ad_account_id", .int64, .required)
            .field("apple_id", .int64, .required)
            .field("app_store_id", .int64, .required)
            .field("name", .string, .required)
            .field("status", .string, .required)
            .field("countries", .string, .required)
            .field("daily_budget", .double)
            .field("currency", .string)
            .unique(on: "ad_account_id", "apple_id")
            .create()

        try await database.schema(AppleAdsKeywordRow.schema)
            .id()
            .field("ad_account_id", .int64, .required)
            .field("apple_id", .int64, .required)
            .field("campaign_id", .int64, .required)
            .field("ad_group_id", .int64, .required)
            .field("text", .string, .required)
            .field("match_type", .string, .required)
            .field("status", .string, .required)
            .field("bid", .double)
            .field("currency", .string)
            .unique(on: "ad_account_id", "apple_id")
            .create()

        try await database.schema(AppleAdsKeywordIdeaRow.schema)
            .id()
            .field("ad_account_id", .int64, .required)
            .field("app_store_id", .int64, .required)
            .field("country", .string, .required)
            .field("text", .string, .required)
            .field("popularity", .int)
            .unique(on: "ad_account_id", "app_store_id", "country", "text")
            .create()

        try await database.schema(AppleAdsCampaignDayRow.schema)
            .id()
            .field("ad_account_id", .int64, .required)
            .field("campaign_id", .int64, .required)
            .field("date", .string, .required)
            .field("currency", .string)
            .metricFields()
            .unique(on: "ad_account_id", "campaign_id", "date")
            .create()

        try await database.schema(AppleAdsKeywordDayRow.schema)
            .id()
            .field("ad_account_id", .int64, .required)
            .field("keyword_id", .int64, .required)
            .field("campaign_id", .int64, .required)
            .field("country", .string, .required)
            .field("date", .string, .required)
            .field("suggested_bid", .double)
            .metricFields()
            .unique(on: "ad_account_id", "keyword_id", "country", "date")
            .create()

        try await database.schema(AppleAdsSearchTermDayRow.schema)
            .id()
            .field("ad_account_id", .int64, .required)
            .field("campaign_id", .int64, .required)
            .field("ad_group_id", .int64, .required)
            .field("keyword_id", .int64, .required)
            .field("term", .string, .required)
            .field("source", .string, .required)
            .field("country", .string, .required)
            .field("date", .string, .required)
            .metricFields()
            .unique(on: "ad_account_id", "campaign_id", "ad_group_id", "keyword_id", "term", "source", "country", "date")
            .create()

        try await database.schema(AppleAdsTermPopularityRow.schema)
            .id()
            .field("ad_account_id", .int64, .required)
            .field("term", .string, .required)
            .field("country", .string, .required)
            .field("genre", .string, .required)
            .field("week", .string, .required)
            .field("popularity_100", .int)
            .field("popularity_5", .int)
            .field("rank_in_genre", .int)
            .unique(on: "ad_account_id", "term", "country", "genre", "week")
            .create()

        try await database.schema(AppleAdsSyncRunRow.schema)
            .id()
            .field("ad_account_id", .int64)
            .field("trigger", .string, .required)
            .field("outcome", .string, .required)
            .field("started_at", .datetime, .required)
            .field("finished_at", .datetime)
            .field("from_date", .string)
            .field("to_date", .string)
            .field("error", .string)
            .create()
    }

    func revert(on database: any Database) async throws {
        for schema in [
            AppleAdsSyncRunRow.schema, AppleAdsTermPopularityRow.schema, AppleAdsSearchTermDayRow.schema,
            AppleAdsKeywordDayRow.schema, AppleAdsCampaignDayRow.schema, AppleAdsKeywordIdeaRow.schema,
            AppleAdsKeywordRow.schema, AppleAdsCampaignRow.schema,
        ] {
            try await database.schema(schema).delete()
        }
    }
}

private extension SchemaBuilder {
    func metricFields() -> Self {
        self.field("impressions", .int, .required)
            .field("taps", .int, .required)
            .field("tap_installs", .int, .required)
            .field("view_installs", .int, .required)
            .field("total_installs", .int, .required)
            .field("spend", .double, .required)
    }
}
