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
    // Apple's "Primary Category" id (e.g. 6017 = Education). Used by the
    // chart-tracking watchdog to pick the right RSS feed per app. Optional
    // because not every iTunes lookup variant returns it consistently.
    let primaryGenreId: Int?
}

/// Wide projection of Apple's `/lookup` response used by the metadata
/// snapshot pipeline. Distinct from `LookupResultApp` so the chart-watchdog
/// backfill path keeps decoding only the 5 fields it actually needs — the
/// hot path is called frequently and shouldn't pay for 25-field JSON work.
///
/// Most fields are `Optional` because Apple's responses are inconsistent:
/// some apps omit `price` entirely (most free apps), some omit
/// `releaseNotes` (apps never updated since launch), `userRatingCount` is
/// 0 when no ratings exist. Decoding everything via `decodeIfPresent`
/// keeps the snapshot pipeline tolerant of these gaps.
///
/// Subtitle, promotional text, and IAP listings are NOT in this struct
/// because Apple's `/lookup` endpoint does not return them — they live
/// behind the HTML scrape (subtitle) or the rotating-bearer AMP API
/// (promo / IAPs, deferred to phase 2). See `AppStoreHTMLScraper` for the
/// subtitle side and the plan's "Out of scope" section for the AMP gap.
struct RichLookupResultApp: Codable, Sendable, Equatable {
    let trackId: Int64
    let bundleId: String
    let trackName: String

    // versioning
    let version: String?
    let currentVersionReleaseDate: Date?
    let releaseNotes: String?
    let releaseDate: Date?  // first-ever release (vs. currentVersionReleaseDate)

    // ASO copy
    let description: String?
    let sellerName: String?
    let primaryGenreName: String?
    let primaryGenreId: Int?
    let genres: [String]?

    // assets
    let artworkUrl100: String?
    let artworkUrl512: String?
    let screenshotUrls: [String]?
    let ipadScreenshotUrls: [String]?

    // commercial
    let price: Double?
    let currency: String?
    let formattedPrice: String?

    // quality signals
    let averageUserRating: Double?
    let userRatingCount: Int?
    let averageUserRatingForCurrentVersion: Double?
    let userRatingCountForCurrentVersion: Int?
    let contentAdvisoryRating: String?
    let languageCodesISO2A: [String]?
    let fileSizeBytes: Int64?
    let minimumOsVersion: String?
}

extension RichLookupResultApp {
    /// Apple sometimes returns `fileSizeBytes` as a String (yes, really).
    /// This custom decoder coerces both shapes. Other Int64 / Double
    /// fields haven't been observed with this issue, but if discovered
    /// the same pattern applies.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.trackId = try c.decode(Int64.self, forKey: .trackId)
        self.bundleId = try c.decode(String.self, forKey: .bundleId)
        self.trackName = try c.decode(String.self, forKey: .trackName)
        self.version = try c.decodeIfPresent(String.self, forKey: .version)
        self.currentVersionReleaseDate = try c.decodeIfPresent(Date.self, forKey: .currentVersionReleaseDate)
        self.releaseNotes = try c.decodeIfPresent(String.self, forKey: .releaseNotes)
        self.releaseDate = try c.decodeIfPresent(Date.self, forKey: .releaseDate)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.sellerName = try c.decodeIfPresent(String.self, forKey: .sellerName)
        self.primaryGenreName = try c.decodeIfPresent(String.self, forKey: .primaryGenreName)
        self.primaryGenreId = try c.decodeIfPresent(Int.self, forKey: .primaryGenreId)
        self.genres = try c.decodeIfPresent([String].self, forKey: .genres)
        self.artworkUrl100 = try c.decodeIfPresent(String.self, forKey: .artworkUrl100)
        self.artworkUrl512 = try c.decodeIfPresent(String.self, forKey: .artworkUrl512)
        self.screenshotUrls = try c.decodeIfPresent([String].self, forKey: .screenshotUrls)
        self.ipadScreenshotUrls = try c.decodeIfPresent([String].self, forKey: .ipadScreenshotUrls)
        self.price = try c.decodeIfPresent(Double.self, forKey: .price)
        self.currency = try c.decodeIfPresent(String.self, forKey: .currency)
        self.formattedPrice = try c.decodeIfPresent(String.self, forKey: .formattedPrice)
        self.averageUserRating = try c.decodeIfPresent(Double.self, forKey: .averageUserRating)
        self.userRatingCount = try c.decodeIfPresent(Int.self, forKey: .userRatingCount)
        self.averageUserRatingForCurrentVersion = try c.decodeIfPresent(Double.self, forKey: .averageUserRatingForCurrentVersion)
        self.userRatingCountForCurrentVersion = try c.decodeIfPresent(Int.self, forKey: .userRatingCountForCurrentVersion)
        self.contentAdvisoryRating = try c.decodeIfPresent(String.self, forKey: .contentAdvisoryRating)
        self.languageCodesISO2A = try c.decodeIfPresent([String].self, forKey: .languageCodesISO2A)
        self.minimumOsVersion = try c.decodeIfPresent(String.self, forKey: .minimumOsVersion)
        // fileSizeBytes: Int64 normally, occasionally String. Try both.
        if let n = try? c.decodeIfPresent(Int64.self, forKey: .fileSizeBytes) {
            self.fileSizeBytes = n
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .fileSizeBytes), let n = Int64(s) {
            self.fileSizeBytes = n
        } else {
            self.fileSizeBytes = nil
        }
    }
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

// One cell of the competitor gap matrix: how my app stands against a single
// competitor on a single tracked keyword. The SPA renders the full
// (keyword × competitor) grid and lets the user sort/filter it.
struct CompetitorGapRow: Codable, Sendable, Equatable {
    let keywordId: UUID
    let term: String
    let countryCode: String
    let competitorAppId: UUID
    let competitorName: String
    let myRank: Int?          // my app's latest rank (nil = outside top 200)
    let competitorRank: Int?  // competitor's latest rank (nil = outside top 200)
    let verdict: GapVerdict
}

// How my app stands vs a competitor on a keyword. `score` drives the
// "most urgent first" sort in the gap view — higher = act on it sooner.
// The semantics live in `CompetitorGapClassifier`.
struct GapVerdict: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case behind      // both ranked, competitor is ahead of me
        case ahead       // I'm ahead (better finite rank, or competitor absent)
        case pureGap     // competitor ranks, I'm absent — the most actionable
        case neither     // both absent
        case tied        // identical rank
    }
    let kind: Kind
    let score: Int
}
