import Foundation
import Logging

protocol RefreshServiceProtocol: Sendable {
    func refresh(keywordID: UUID, now: Date) async throws
}

struct RefreshService: RefreshServiceProtocol {
    let keywordRepository: any KeywordRepositoryProtocol
    let watchedAppRepository: any WatchedAppRepositoryProtocol
    let rankCheckRepository: any RankCheckRepositoryProtocol
    let topResultRepository: any TopResultSnapshotRepositoryProtocol
    let searchClient: any ITunesSearchClientProtocol
    let scorer: any KeywordScorerProtocol
    let logger: Logger
    static let searchLimit = 200

    func refresh(keywordID: UUID, now: Date) async throws {
        guard let keyword = try await keywordRepository.find(id: keywordID) else {
            logger.warning("RefreshService: keyword \(keywordID) not found")
            return
        }
        // All watched apps are candidates — we no longer scope by country.
        // The job ranks each app against the search results returned for the
        // keyword's storefront; apps not in the top 200 simply get rank=nil.
        let watchedApps = try await watchedAppRepository.all()
        let results = try await searchClient.search(
            term: keyword.term,
            country: keyword.countryCode,
            limit: Self.searchLimit
        )

        let topFive = Array(results.prefix(5))
        let scores = scorer.score(topFive: topFive, referenceDate: now)

        try await persistTopResults(topFive, keywordID: try keyword.requireID(), now: now)
        try await persistRankChecks(
            for: watchedApps,
            in: results,
            keywordID: try keyword.requireID(),
            scores: scores,
            now: now
        )

        logger.info("Refreshed keyword=\(keyword.term) country=\(keyword.countryCode) apps=\(watchedApps.count) topResults=\(topFive.count)")
    }

    private func persistTopResults(_ topFive: [SearchResultApp], keywordID: UUID, now: Date) async throws {
        for (index, app) in topFive.enumerated() {
            let snapshot = TopResultSnapshot(
                keywordID: keywordID,
                checkedAt: now,
                position: index + 1,
                appStoreId: app.trackId,
                name: app.trackName,
                iconURL: app.artworkUrl100,
                ratingCount: app.userRatingCount,
                averageRating: app.averageUserRating,
                releaseDate: app.releaseDate
            )
            try await topResultRepository.save(snapshot)
        }
    }

    private func persistRankChecks(
        for watchedApps: [WatchedApp],
        in results: [SearchResultApp],
        keywordID: UUID,
        scores: KeywordScores,
        now: Date
    ) async throws {
        for watched in watchedApps {
            let watchedID = try watched.requireID()
            let rank = results.firstIndex { $0.trackId == watched.appStoreId }.map { $0 + 1 }

            // Dedupe: if the latest RankCheck for this (keyword, app) pair
            // has identical (rank, difficulty, entryBarrier), just extend
            // its observation window by bumping checkedAt — no duplicate
            // row. Each RankCheck row now represents a contiguous run of
            // identical observations rather than a single point in time.
            //
            // The repository's `latest` query is indexed (keyword_id,
            // watched_app_id, checked_at DESC), so this lookup is cheap.
            let latest = try await rankCheckRepository.latest(
                keywordID: keywordID,
                watchedAppID: watchedID
            )
            if let latest,
               latest.rank == rank,
               latest.difficulty == scores.difficulty,
               latest.entryBarrier == scores.entryBarrier,
               let latestID = latest.id {
                try await rankCheckRepository.updateCheckedAt(id: latestID, checkedAt: now)
                continue
            }

            let check = RankCheck(
                keywordID: keywordID,
                watchedAppID: watchedID,
                rank: rank,
                difficulty: scores.difficulty,
                entryBarrier: scores.entryBarrier,
                checkedAt: now,
                firstSeenAt: now
            )
            try await rankCheckRepository.save(check)
        }
    }
}
