import Foundation

// Popularity signal for tracked keywords, sourced from REAL Apple Ads
// search-term impressions (per the #43 spike: Option A — no fabricated
// numbers). Returns impressions only for tracked keywords whose term appears
// in the synced search-term reports for that keyword's country; everything
// else simply has no popularity signal (the opportunity score degrades to
// difficulty-only). Reads the local mirror the daily sync keeps, never Apple.
protocol KeywordPopularityServiceProtocol: Sendable {
    /// keywordId → ASA impressions, only for tracked keywords with ASA data.
    func popularity() async throws -> [UUID: Int]
}

struct KeywordPopularityService: KeywordPopularityServiceProtocol {
    let settings: any SettingsServiceProtocol
    let keywordRepo: any KeywordRepositoryProtocol
    let mirror: any AppleAdsDataRepositoryProtocol
    let today: @Sendable () -> String

    static let reportWindowDays = 30

    func popularity() async throws -> [UUID: Int] {
        guard try await settings.getASACredentials() != nil else { return [:] }
        let tracked = try await keywordRepo.all()
        if tracked.isEmpty { return [:] }

        let reader = AppleAdsMirrorReader(repository: mirror, today: today)
        guard let account = try await reader.syncedAccount() else { return [:] }

        // Rows are already per storefront (the report groups by country), so
        // a term's impressions count only where they happened.
        // byCountryTerm[COUNTRY_UPPER][term_lower] = summed impressions.
        var byCountryTerm: [String: [String: Int]] = [:]
        for row in try await reader.recentSearchTerms(account: account, days: Self.reportWindowDays)
        where !AppleAdsMirrorReader.isLowVolume(row.term) {
            byCountryTerm[row.country.uppercased(), default: [:]][row.term.lowercased(), default: 0] += row.metrics.impressions
        }

        var out: [UUID: Int] = [:]
        for keyword in tracked {
            guard let id = keyword.id else { continue }
            let impressions = byCountryTerm[keyword.countryCode.uppercased()]?[keyword.term.lowercased()]
            if let impressions, impressions > 0 { out[id] = impressions }
        }
        return out
    }
}
