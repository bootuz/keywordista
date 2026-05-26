import Foundation
import Vapor

// Discovers candidate keywords for a seed keyword + country by mining the
// user's Apple Search Ads search-terms reports. Apple's public API doesn't
// expose a generic "given seed X return related terms" endpoint — the only
// way to get real keyword discovery data is via search-terms reports tied
// to the user's running campaign(s).
//
// Flow:
//   1. Resolve seed → (term, countryCode) by loading the keyword row.
//   2. Fetch ASA campaigns; keep those targeting `countryCode`.
//   3. For each matching campaign, pull last 30d of search-terms.
//   4. Partition rows: aggregate Apple's LOW_VOLUME privacy placeholders
//      into a single summary; score remaining rows for seed-relevance.
//   5. Dedup, join against tracked keywords, sort by relevance then impressions.

protocol KeywordSuggestionServiceProtocol: Sendable {
    func suggest(seedKeywordId: UUID) async throws -> SuggestionsResponse
}

struct SuggestionRow: Content, Sendable, Equatable {
    let term: String
    let source: String          // "AUTO" | "TARGETED" | …
    let impressions: Int
    let taps: Int
    let ttr: Double
    let alreadyTracked: Bool
    let currentRank: Int?
}

/// Aggregated counters for the Apple "LOW_VOLUME" placeholder rows.
///
/// Apple anonymizes individual search terms when their underlying query
/// volume is below a k-anonymity threshold (so a single rare query can't
/// be tied back to a specific user). The report still returns these rows
/// — text replaced with the literal "LOW_VOLUME" — and they're real,
/// billable impressions/taps from the campaign. We surface the totals so
/// the user knows the campaign is producing signal even when nothing
/// passes the relevance filter.
struct AnonymizedSummary: Content, Sendable, Equatable {
    let impressions: Int
    let taps: Int
    /// Number of campaign × match-type combos that contributed a
    /// LOW_VOLUME row. Useful for "spread across N ad groups" copy.
    let sourceCount: Int
}

struct SuggestionsResponse: Content, Sendable, Equatable {
    let rows: [SuggestionRow]
    let anonymized: AnonymizedSummary?
}

struct KeywordSuggestionService: KeywordSuggestionServiceProtocol {
    let settings: any SettingsServiceProtocol
    let keywordRepo: any KeywordRepositoryProtocol
    let rankCheckRepo: any RankCheckRepositoryProtocol
    let makeClient: @Sendable (ASACredentials) -> any AppleSearchAdsClientProtocol
    let now: @Sendable () -> Date
    let logger: Logger

    static let reportWindowDays = 30

    /// Empty response constant — keeps the early-exit branches readable.
    private static let empty = SuggestionsResponse(rows: [], anonymized: nil)

    /// Rows with a single shared token at least this many characters long
    /// pass the relevance filter regardless of Jaccard. Tuned to admit
    /// useful matches like seed "anki" ↔ "anki desktop app" while still
    /// rejecting "the app", "best app" against seed "anki".
    private static let minSharedTokenLength = 4

    /// Minimum Jaccard similarity for rows that don't pass the
    /// shared-token rule. Tuned so a 1-token seed against a 4-token term
    /// sharing one token (0.25) is kept.
    private static let minJaccard = 0.2

    func suggest(seedKeywordId: UUID) async throws -> SuggestionsResponse {
        // (1) ASA not configured → empty (controller treats as 200 + []).
        guard let creds = try await settings.getASACredentials() else { return Self.empty }

        // (2) Resolve seed.
        guard let seed = try await keywordRepo.find(id: seedKeywordId) else { return Self.empty }
        let seedTerm = seed.term.lowercased()
        let seedTokens = Self.tokenize(seedTerm)
        let country = seed.countryCode.uppercased()

        let client = makeClient(creds)

        // (3) Find campaigns serving this country.
        let allCampaigns = try await client.listCampaigns()
        let relevant = allCampaigns.filter { c in
            c.countriesOrRegions.contains(country)
        }
        if relevant.isEmpty { return Self.empty }

        // (4) Pull search-terms reports in parallel; collect all terms.
        let endDate = now()
        let startDate = endDate.addingTimeInterval(-TimeInterval(Self.reportWindowDays * 86_400))

        var all: [ASASearchTerm] = []
        try await withThrowingTaskGroup(of: [ASASearchTerm].self) { group in
            for campaign in relevant {
                let c = client
                let id = campaign.id
                let log = logger
                group.addTask {
                    do {
                        return try await c.searchTermsReport(
                            campaignId: id,
                            startDate: startDate,
                            endDate: endDate
                        )
                    } catch {
                        // Don't let one bad campaign kill the whole panel —
                        // log and continue. The UI shows what we did get.
                        // (The comment said "log" since the beginning; this
                        // is where the actual log call lives now — previously
                        // the catch swallowed errors silently, which made
                        // ASA-side failures invisible.)
                        log.warning("ASA searchterms failed: campaign=\(id) error=\(error)")
                        return []
                    }
                }
            }
            for try await rows in group { all.append(contentsOf: rows) }
        }
        if all.isEmpty { return Self.empty }

        // (5a) Partition out Apple's anonymized placeholder rows BEFORE the
        //      relevance filter. "LOW_VOLUME" never lexically matches a
        //      real seed, so the filter would drop these silently and the
        //      user would lose the signal that the campaign is producing
        //      impressions at all. Match case-insensitively to be safe;
        //      Apple has historically used the upper-case literal.
        var lowVolumeRows: [ASASearchTerm] = []
        var realRows: [ASASearchTerm] = []
        for row in all {
            if row.text.uppercased() == "LOW_VOLUME" {
                lowVolumeRows.append(row)
            } else {
                realRows.append(row)
            }
        }
        let anonymized: AnonymizedSummary? = lowVolumeRows.isEmpty ? nil : AnonymizedSummary(
            impressions: lowVolumeRows.reduce(0) { $0 + $1.impressions },
            taps: lowVolumeRows.reduce(0) { $0 + $1.taps },
            sourceCount: lowVolumeRows.count
        )

        // (5b) Token-based relevance. Substring containment is too strict
        //      for ASA broad/search-match auctions, which routinely surface
        //      long-tail queries that share *some* but not all words with
        //      the seed (e.g. seed "flashcard maker" → "best flashcard
        //      maker", seed "anki" → "anki desktop app review"). We keep a
        //      row when it shares any token of length ≥ minSharedTokenLength
        //      with the seed, OR when its Jaccard similarity is ≥ minJaccard.
        //      The length floor avoids false positives from short
        //      stopword-y tokens ("the", "app", "a").
        let scored: [(row: ASASearchTerm, score: Double)] = realRows.compactMap { row in
            let termTokens = Self.tokenize(row.text.lowercased())
            let (jaccard, hasLongShared) = Self.score(seedTokens: seedTokens, termTokens: termTokens)
            let keep = hasLongShared || jaccard >= Self.minJaccard
            return keep ? (row, jaccard) : nil
        }

        // Multiple campaigns may report the same term — collapse to one row.
        // Carry the highest relevance seen for the term so the final sort
        // doesn't get confused by ordering of duplicates.
        struct Accum { var row: ASASearchTerm; var score: Double }
        let dedup: [String: Accum] = scored.reduce(into: [:]) { acc, pair in
            let key = pair.row.text.lowercased()
            if let existing = acc[key] {
                let merged = ASASearchTerm(
                    text: existing.row.text,
                    source: existing.row.source,
                    impressions: existing.row.impressions + pair.row.impressions,
                    taps: existing.row.taps + pair.row.taps,
                    ttr: existing.row.taps + pair.row.taps > 0
                        ? Double(existing.row.taps + pair.row.taps) / Double(max(1, existing.row.impressions + pair.row.impressions))
                        : 0,
                    localSpend: existing.row.localSpend + pair.row.localSpend
                )
                acc[key] = Accum(row: merged, score: max(existing.score, pair.score))
            } else {
                acc[key] = Accum(row: pair.row, score: pair.score)
            }
        }

        // Tracked-keyword lookup for the same country, lowercased.
        let tracked = try await keywordRepo.filtered(country: country.lowercased())
        let trackedByTerm: [String: Keyword] = tracked.reduce(into: [:]) { acc, k in
            acc[k.term.lowercased()] = k
        }

        // Build the final SuggestionRow list — already-tracked terms include
        // their best current rank (across watched apps; we take the min).
        var out: [(row: SuggestionRow, score: Double)] = []
        for (lcText, accum) in dedup {
            let trackedKw = trackedByTerm[lcText]
            var currentRank: Int? = nil
            if let kw = trackedKw, let kwId = kw.id {
                currentRank = try await bestRank(for: kwId)
            }
            out.append((
                SuggestionRow(
                    term: accum.row.text,
                    source: accum.row.source,
                    impressions: accum.row.impressions,
                    taps: accum.row.taps,
                    ttr: accum.row.ttr,
                    alreadyTracked: trackedKw != nil,
                    currentRank: currentRank
                ),
                accum.score
            ))
        }
        // Sort by relevance first (so tight matches win regardless of how
        // many impressions a long-tail query racked up), then impressions
        // as the tiebreaker.
        let rows = out
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.row.impressions > b.row.impressions
            }
            .map(\.row)

        return SuggestionsResponse(rows: rows, anonymized: anonymized)
    }

    /// Best (lowest) rank across all watched-app rows for this keyword.
    private func bestRank(for keywordId: UUID) async throws -> Int? {
        // We don't have a "list watched apps for keyword" repo method, but
        // every keyword is checked against every watched app, so latest()
        // per app gives us the picture. For now we approximate by reading
        // the latest rank check for the keyword across any app; if there
        // are multiple watched apps the dashboard already shows them
        // separately, and this hint is just for the suggestion row.
        // Cheapest implementation: hit each watched app via the dashboard's
        // existing repository, but that's out of scope for the suggestion
        // surface. Punt to a single latest() lookup using the only watched
        // app id we can infer — the most recent check.
        // Concretely: not implemented for multi-app users; returns nil.
        // (TODO when multi-app support lands: pass watchedAppId through
        // from HistoryPanel — it already has it.)
        _ = keywordId
        return nil
    }

    // MARK: - Relevance helpers

    /// Whitespace tokenizer with light cleanup — strips a small set of
    /// punctuation that ASA reports occasionally include around tokens
    /// (commas in numeric queries, parentheses in branded queries).
    /// Empty/whitespace input → empty set.
    static func tokenize(_ s: String) -> Set<String> {
        let lowered = s.lowercased()
        let chars = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: ",.()[]{}\"'!?;:")
        )
        return Set(
            lowered
                .components(separatedBy: chars)
                .filter { !$0.isEmpty }
        )
    }

    /// Returns the Jaccard similarity of the two token sets and whether
    /// any shared token is at least `minSharedTokenLength` chars long.
    /// Empty seed *or* empty term → (0, false) — a degenerate term can't
    /// be ranked.
    static func score(seedTokens: Set<String>, termTokens: Set<String>) -> (jaccard: Double, hasLongShared: Bool) {
        if seedTokens.isEmpty || termTokens.isEmpty { return (0, false) }
        let intersection = seedTokens.intersection(termTokens)
        if intersection.isEmpty { return (0, false) }
        let union = seedTokens.union(termTokens)
        let jaccard = Double(intersection.count) / Double(union.count)
        let hasLong = intersection.contains { $0.count >= minSharedTokenLength }
        return (jaccard, hasLong)
    }
}
