import Foundation
import Logging

// Popularity signal for tracked keywords, sourced from REAL Apple Search Ads
// search-terms impressions (per the #43 spike: Option A — no fabricated
// numbers). Returns impressions only for tracked keywords whose term appears
// in the user's ASA campaign reports for that keyword's country; everything
// else simply has no popularity signal (the opportunity score degrades to
// difficulty-only). Mirrors KeywordSuggestionService's ASA mining flow.
protocol KeywordPopularityServiceProtocol: Sendable {
    /// keywordId → ASA impressions, only for tracked keywords with ASA data.
    func popularity() async throws -> [UUID: Int]
}

struct KeywordPopularityService: KeywordPopularityServiceProtocol {
    let settings: any SettingsServiceProtocol
    let keywordRepo: any KeywordRepositoryProtocol
    let makeClient: @Sendable (ASACredentials) -> any AppleSearchAdsClientProtocol
    let now: @Sendable () -> Date
    let logger: Logger

    static let reportWindowDays = 30

    func popularity() async throws -> [UUID: Int] {
        guard let creds = try await settings.getASACredentials() else { return [:] }
        let tracked = try await keywordRepo.all()
        if tracked.isEmpty { return [:] }

        let client = makeClient(creds)
        let campaigns = try await client.listCampaigns()
        if campaigns.isEmpty { return [:] }

        let endDate = now()
        let startDate = endDate.addingTimeInterval(-TimeInterval(Self.reportWindowDays * 86_400))

        // Pull each campaign's search-terms once, then attribute impressions to
        // every storefront the campaign targets. A campaign serving multiple
        // countries doesn't split its report per country, so this pools — the
        // same approximation KeywordSuggestionService makes.
        // byCountryTerm[COUNTRY_UPPER][term_lower] = summed impressions.
        var byCountryTerm: [String: [String: Int]] = [:]
        var failures: [any Error] = []
        try await withThrowingTaskGroup(of: (campaign: ASACampaign, rows: [ASASearchTerm], error: (any Error)?).self) { group in
            for campaign in campaigns {
                let client = client
                let log = logger
                let cam = campaign
                group.addTask {
                    do {
                        return (cam, try await client.searchTermsReport(
                            campaignId: cam.id, startDate: startDate, endDate: endDate,
                        ), nil)
                    } catch {
                        log.warning("ASA searchterms failed: campaign=\(cam.id) error=\(error)")
                        return (cam, [], error)
                    }
                }
            }
            for try await (campaign, rows, error) in group {
                if let error { failures.append(error) }
                for row in rows where row.text.uppercased() != "LOW_VOLUME" {
                    let term = row.text.lowercased()
                    for country in campaign.countriesOrRegions {
                        byCountryTerm[country, default: [:]][term, default: 0] += row.impressions
                    }
                }
            }
        }

        // One bad campaign shouldn't blank the column, but if every report
        // failed the empty result would read as "no demand": say why instead.
        if !campaigns.isEmpty, failures.count == campaigns.count, let first = failures.first { throw first }

        // Join tracked keywords → impressions for their (term, country).
        var out: [UUID: Int] = [:]
        for keyword in tracked {
            guard let id = keyword.id else { continue }
            let impressions = byCountryTerm[keyword.countryCode.uppercased()]?[keyword.term.lowercased()]
            if let impressions, impressions > 0 { out[id] = impressions }
        }
        return out
    }
}
