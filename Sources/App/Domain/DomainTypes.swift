import Foundation

struct SearchResultApp: Codable, Sendable, Equatable {
    let trackId: Int64
    let bundleId: String?
    let trackName: String
    let artworkUrl100: String?
    let userRatingCount: Int?
    let averageUserRating: Double?
    let releaseDate: Date?
}

struct LookupResultApp: Codable, Sendable, Equatable {
    let trackId: Int64
    let bundleId: String
    let trackName: String
    let artworkUrl100: String?
}

struct DashboardRow: Codable, Sendable, Equatable {
    let keywordId: UUID
    let term: String
    let countryCode: String
    let watchedAppId: UUID
    let watchedAppName: String
    let rank: Int?
    // The rank from the *prior* RankCheck for this (keyword, app) pair. Used
    // by the UI to render a delta indicator (▲ N / ▼ N / —).
    // Null can mean either "previous check had no rank (outside top 200)" or
    // "there is no previous check yet" — disambiguate via hasPreviousCheck.
    let previousRank: Int?
    let hasPreviousCheck: Bool
    let difficulty: Int
    let entryBarrier: Int
    let checkedAt: Date?
    let topResults: [TopResultDTO]
}

struct TopResultDTO: Codable, Sendable, Equatable {
    let position: Int
    let appStoreId: Int64
    let name: String
    let iconURL: String?
}

struct HistoryPoint: Codable, Sendable, Equatable {
    let checkedAt: Date
    let rank: Int?
    let difficulty: Int
    let entryBarrier: Int
}

struct AppKeywordRow: Codable, Sendable, Equatable {
    let keywordId: UUID
    let term: String
    let countryCode: String
    let rank: Int?
    let difficulty: Int
    let entryBarrier: Int
    let checkedAt: Date?
}
