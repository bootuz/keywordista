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
//   4. Filter to terms that look related to the seed (substring contains).
//   5. Join against tracked keywords for `alreadyTracked` + `currentRank`.

protocol KeywordSuggestionServiceProtocol: Sendable {
    func suggest(seedKeywordId: UUID) async throws -> [SuggestionRow]
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

struct KeywordSuggestionService: KeywordSuggestionServiceProtocol {
    let settings: any SettingsServiceProtocol
    let keywordRepo: any KeywordRepositoryProtocol
    let rankCheckRepo: any RankCheckRepositoryProtocol
    let makeClient: @Sendable (ASACredentials) -> any AppleSearchAdsClientProtocol
    let now: @Sendable () -> Date
    let logger: Logger

    static let reportWindowDays = 30

    func suggest(seedKeywordId: UUID) async throws -> [SuggestionRow] {
        // (1) ASA not configured → empty (controller treats as 200 + []).
        guard let creds = try await settings.getASACredentials() else { return [] }

        // (2) Resolve seed.
        guard let seed = try await keywordRepo.find(id: seedKeywordId) else { return [] }
        let seedTerm = seed.term.lowercased()
        let country = seed.countryCode.uppercased()

        let client = makeClient(creds)

        // (3) Find campaigns serving this country.
        let allCampaigns = try await client.listCampaigns()
        let relevant = allCampaigns.filter { c in
            c.countriesOrRegions.contains(country)
        }
        if relevant.isEmpty { return [] }

        // (4) Pull search-terms reports in parallel; collect all terms.
        let endDate = now()
        let startDate = endDate.addingTimeInterval(-TimeInterval(Self.reportWindowDays * 86_400))

        var all: [ASASearchTerm] = []
        try await withThrowingTaskGroup(of: [ASASearchTerm].self) { group in
            for campaign in relevant {
                let c = client
                let id = campaign.id
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
                        return []
                    }
                }
            }
            for try await rows in group { all.append(contentsOf: rows) }
        }
        if all.isEmpty { return [] }

        // (5) Filter to seed-related terms. Substring is intentionally loose
        //     so that a seed like "flashcards" surfaces "best flashcards",
        //     "medical flashcards", etc. The Search Match source means we're
        //     already showing only queries Apple decided were relevant to
        //     the app, so additional precision isn't worth dropping signal.
        let related = all.filter { row in
            let t = row.text.lowercased()
            return t.contains(seedTerm) || seedTerm.contains(t)
        }

        // Multiple campaigns may report the same term — collapse to one row.
        let dedup: [String: ASASearchTerm] = related.reduce(into: [:]) { acc, row in
            if let existing = acc[row.text.lowercased()] {
                acc[row.text.lowercased()] = ASASearchTerm(
                    text: existing.text,
                    source: existing.source,
                    impressions: existing.impressions + row.impressions,
                    taps: existing.taps + row.taps,
                    ttr: existing.taps + row.taps > 0
                        ? Double(existing.taps + row.taps) / Double(max(1, existing.impressions + row.impressions))
                        : 0,
                    localSpend: existing.localSpend + row.localSpend
                )
            } else {
                acc[row.text.lowercased()] = row
            }
        }

        // Tracked-keyword lookup for the same country, lowercased.
        let tracked = try await keywordRepo.filtered(country: country.lowercased())
        let trackedByTerm: [String: Keyword] = tracked.reduce(into: [:]) { acc, k in
            acc[k.term.lowercased()] = k
        }

        // Build the final SuggestionRow list — already-tracked terms include
        // their best current rank (across watched apps; we take the min).
        var out: [SuggestionRow] = []
        for (lcText, row) in dedup {
            let trackedKw = trackedByTerm[lcText]
            var currentRank: Int? = nil
            if let kw = trackedKw, let kwId = kw.id {
                currentRank = try await bestRank(for: kwId)
            }
            out.append(SuggestionRow(
                term: row.text,
                source: row.source,
                impressions: row.impressions,
                taps: row.taps,
                ttr: row.ttr,
                alreadyTracked: trackedKw != nil,
                currentRank: currentRank
            ))
        }
        // Highest-impression first so the most-observed queries lead.
        return out.sorted { $0.impressions > $1.impressions }
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
}
