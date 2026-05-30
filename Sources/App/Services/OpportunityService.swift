import Foundation

// Produces opportunity scores for ASA-covered tracked keywords: joins the
// real ASA impressions (KeywordPopularityService) with each keyword's
// difficulty (recomputed from its latest top-results landscape) via the
// OpportunityScore heuristic. Keywords without ASA data, or whose difficulty
// can't be assessed, are simply absent — never fabricated.
protocol OpportunityServiceProtocol: Sendable {
    func opportunities() async throws -> [KeywordOpportunity]
}

struct OpportunityService: OpportunityServiceProtocol {
    let popularity: any KeywordPopularityServiceProtocol
    let topResultRepository: any TopResultSnapshotRepositoryProtocol
    let scorer: any KeywordScorerProtocol
    let now: @Sendable () -> Date

    func opportunities() async throws -> [KeywordOpportunity] {
        let impressionsByKeyword = try await popularity.popularity()
        let referenceDate = now()

        var out: [KeywordOpportunity] = []
        for (keywordId, impressions) in impressionsByKeyword {
            // Recompute difficulty from the keyword's latest top-results
            // landscape (same scorer RefreshService uses), mapping snapshot
            // rows back into the SearchResultApp shape the scorer expects.
            let topFive = try await topResultRepository.latestSnapshot(keywordID: keywordId).map { snap in
                SearchResultApp(
                    trackId: snap.appStoreId,
                    bundleId: nil,
                    trackName: snap.name,
                    artworkUrl100: snap.iconURL,
                    userRatingCount: snap.ratingCount,
                    averageUserRating: snap.averageRating,
                    releaseDate: snap.releaseDate,
                )
            }
            let difficulty = scorer.score(topFive: topFive, referenceDate: referenceDate).difficulty
            guard let opportunity = OpportunityScore.compute(impressions: impressions, difficulty: difficulty) else {
                continue
            }
            out.append(KeywordOpportunity(
                keywordId: keywordId,
                impressions: impressions,
                difficulty: difficulty,
                opportunity: opportunity,
            ))
        }
        // Best bets first.
        return out.sorted { $0.opportunity > $1.opportunity }
    }
}
