@testable import App
import Foundation
import Testing

@Suite("DashboardService")
struct DashboardServiceTests {
    @Test("dashboard joins latest rank, scores, and top results per (keyword, app)")
    func dashboard_joins() async throws {
        let kwID = UUID()
        let appID = UUID()
        let keyword = Keyword(id: kwID, term: "flashcards", countryCode: "us")
        let watched = WatchedApp(id: appID, appStoreId: 42, bundleId: "com.azri", name: "Azri", iconURL: nil)

        let rankRepo = InMemoryRankCheckRepository()
        try await rankRepo.save(RankCheck(
            keywordID: kwID, watchedAppID: appID,
            rank: 17, difficulty: 4, entryBarrier: 5,
            checkedAt: Date(timeIntervalSince1970: 1_000_000)
        ))
        try await rankRepo.save(RankCheck(
            keywordID: kwID, watchedAppID: appID,
            rank: 14, difficulty: 4, entryBarrier: 5,
            checkedAt: Date(timeIntervalSince1970: 2_000_000)
        ))

        let topRepo = InMemoryTopResultSnapshotRepository()
        for position in 1...5 {
            try await topRepo.save(TopResultSnapshot(
                keywordID: kwID,
                checkedAt: Date(timeIntervalSince1970: 2_000_000),
                position: position,
                appStoreId: Int64(position),
                name: "App\(position)",
                iconURL: nil,
                ratingCount: nil,
                averageRating: nil,
                releaseDate: nil
            ))
        }

        let service = DashboardService(
            keywordRepository: InMemoryKeywordRepository([keyword]),
            watchedAppRepository: InMemoryWatchedAppRepository([watched]),
            rankCheckRepository: rankRepo,
            topResultRepository: topRepo
        )

        let rows = try await service.dashboard(country: nil)
        try #require(rows.count == 1)
        #expect(rows[0].rank == 14) // latest, not earliest
        #expect(rows[0].topResults.count == 5)
        #expect(rows[0].topResults.map(\.position) == [1, 2, 3, 4, 5])
    }

    @Test("dashboard excludes competitor apps — only own apps appear as rows")
    func dashboard_excludesCompetitors() async throws {
        let kwID = UUID()
        let ownID = UUID()
        let competitorID = UUID()
        let keyword = Keyword(id: kwID, term: "flashcards", countryCode: "us")
        let own = WatchedApp(
            id: ownID, appStoreId: 42, bundleId: "com.mine", name: "Mine",
            iconURL: nil, kind: .own
        )
        let competitor = WatchedApp(
            id: competitorID, appStoreId: 999, bundleId: "com.competitor",
            name: "Competitor", iconURL: nil, kind: .competitor
        )

        // Both apps now have rank checks for the keyword (competitors get
        // ranked once RefreshService stops filtering them). The dashboard
        // is the user's *own-app* ranking view, so the competitor row must
        // NOT leak in — that data belongs to the gap view instead.
        let rankRepo = InMemoryRankCheckRepository()
        try await rankRepo.save(RankCheck(
            keywordID: kwID, watchedAppID: ownID,
            rank: 5, difficulty: 3, entryBarrier: 2,
            checkedAt: Date(timeIntervalSince1970: 1_000_000)
        ))
        try await rankRepo.save(RankCheck(
            keywordID: kwID, watchedAppID: competitorID,
            rank: 2, difficulty: 3, entryBarrier: 2,
            checkedAt: Date(timeIntervalSince1970: 1_000_000)
        ))

        let service = DashboardService(
            keywordRepository: InMemoryKeywordRepository([keyword]),
            watchedAppRepository: InMemoryWatchedAppRepository([own, competitor]),
            rankCheckRepository: rankRepo,
            topResultRepository: InMemoryTopResultSnapshotRepository()
        )

        let rows = try await service.dashboard(country: nil)
        #expect(rows.count == 1, "only the own app yields a dashboard row")
        #expect(rows.first?.watchedAppId == ownID)
        #expect(!rows.contains(where: { $0.watchedAppId == competitorID }))
    }

    @Test("history returns chronological points")
    func history_isOrdered() async throws {
        let kwID = UUID()
        let appID = UUID()
        let rankRepo = InMemoryRankCheckRepository()
        let later = Date(timeIntervalSince1970: 2_000_000)
        let earlier = Date(timeIntervalSince1970: 1_000_000)
        try await rankRepo.save(RankCheck(keywordID: kwID, watchedAppID: appID, rank: 50, difficulty: 3, entryBarrier: 3, checkedAt: later))
        try await rankRepo.save(RankCheck(keywordID: kwID, watchedAppID: appID, rank: 60, difficulty: 3, entryBarrier: 3, checkedAt: earlier))

        let service = DashboardService(
            keywordRepository: InMemoryKeywordRepository(),
            watchedAppRepository: InMemoryWatchedAppRepository(),
            rankCheckRepository: rankRepo,
            topResultRepository: InMemoryTopResultSnapshotRepository()
        )

        let history = try await service.history(keywordID: kwID, watchedAppID: appID)
        #expect(history.map(\.checkedAt) == [earlier, later])
        #expect(history.map(\.rank) == [60, 50])
    }
}
