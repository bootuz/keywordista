import Foundation

protocol CompetitorGapServiceProtocol: Sendable {
    // The full (keyword × competitor) matrix for one of the user's own apps.
    func gaps(ownAppID: UUID, country: String?) async throws -> [CompetitorGapRow]
}

struct CompetitorGapService: CompetitorGapServiceProtocol {
    let keywordRepository: any KeywordRepositoryProtocol
    let watchedAppRepository: any WatchedAppRepositoryProtocol
    let rankCheckRepository: any RankCheckRepositoryProtocol
    let classifier: any CompetitorGapClassifierProtocol

    func gaps(ownAppID: UUID, country: String?) async throws -> [CompetitorGapRow] {
        let keywords = try await keywordRepository.filtered(country: country)
        let competitors = try await watchedAppRepository.all()
            .filter { $0.typedKind == .competitor }

        var rows: [CompetitorGapRow] = []
        for keyword in keywords {
            let keywordID = try keyword.requireID()
            // My rank is fetched once per keyword and reused across every
            // competitor column — that's the whole point of the matrix.
            let myRank = try await rankCheckRepository
                .latest(keywordID: keywordID, watchedAppID: ownAppID)?.rank

            for competitor in competitors {
                let competitorID = try competitor.requireID()
                let competitorRank = try await rankCheckRepository
                    .latest(keywordID: keywordID, watchedAppID: competitorID)?.rank

                rows.append(CompetitorGapRow(
                    keywordId: keywordID,
                    term: keyword.term,
                    countryCode: keyword.countryCode,
                    competitorAppId: competitorID,
                    competitorName: competitor.name,
                    myRank: myRank,
                    competitorRank: competitorRank,
                    verdict: classifier.classify(myRank: myRank, competitorRank: competitorRank)
                ))
            }
        }
        return rows
    }
}
