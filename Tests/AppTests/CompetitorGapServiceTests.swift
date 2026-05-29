@testable import App
import Foundation
import Testing

// The plumbing test: pins the matrix SHAPE and that ranks are joined
// correctly. It injects a stub classifier so it stays independent of the
// gap *semantics* (those are pinned separately in the classifier's own
// tests, once the heuristic is implemented).
@Suite("CompetitorGapService")
struct CompetitorGapServiceTests {

    private struct StubClassifier: CompetitorGapClassifierProtocol {
        func classify(myRank: Int?, competitorRank: Int?) -> GapVerdict {
            GapVerdict(kind: .tied, score: 0)
        }
    }

    @Test("produces a full matrix: one row per (keyword × competitor) with both ranks joined")
    func fullMatrix() async throws {
        let kw1 = UUID()
        let kw2 = UUID()
        let ownID = UUID()
        let compA = UUID()
        let compB = UUID()

        let keywords = [
            Keyword(id: kw1, term: "flashcards", countryCode: "us"),
            Keyword(id: kw2, term: "study", countryCode: "us"),
        ]
        let own = WatchedApp(id: ownID, appStoreId: 1, bundleId: "com.mine", name: "Mine", iconURL: nil, kind: .own)
        let rivalA = WatchedApp(id: compA, appStoreId: 2, bundleId: "com.a", name: "Rival A", iconURL: nil, kind: .competitor)
        let rivalB = WatchedApp(id: compB, appStoreId: 3, bundleId: "com.b", name: "Rival B", iconURL: nil, kind: .competitor)

        let rankRepo = InMemoryRankCheckRepository()
        let now = Date(timeIntervalSince1970: 1_000_000)
        // kw1: me #5, Rival A #2, Rival B absent
        try await rankRepo.save(RankCheck(keywordID: kw1, watchedAppID: ownID, rank: 5, difficulty: 0, entryBarrier: 0, checkedAt: now))
        try await rankRepo.save(RankCheck(keywordID: kw1, watchedAppID: compA, rank: 2, difficulty: 0, entryBarrier: 0, checkedAt: now))
        // kw2: me absent, Rival A #3
        try await rankRepo.save(RankCheck(keywordID: kw2, watchedAppID: compA, rank: 3, difficulty: 0, entryBarrier: 0, checkedAt: now))

        let service = CompetitorGapService(
            keywordRepository: InMemoryKeywordRepository(keywords),
            watchedAppRepository: InMemoryWatchedAppRepository([own, rivalA, rivalB]),
            rankCheckRepository: rankRepo,
            classifier: StubClassifier()
        )

        let rows = try await service.gaps(ownAppID: ownID, country: nil)

        // 2 keywords × 2 competitors = 4 rows (own app is never a row)
        #expect(rows.count == 4)
        #expect(!rows.contains { $0.competitorAppId == ownID })

        let kw1A = rows.first { $0.keywordId == kw1 && $0.competitorAppId == compA }
        #expect(kw1A?.myRank == 5)
        #expect(kw1A?.competitorRank == 2)

        // Rival B is absent on kw1 → competitorRank nil, my rank still joined
        let kw1B = rows.first { $0.keywordId == kw1 && $0.competitorAppId == compB }
        #expect(kw1B?.myRank == 5)
        #expect(kw1B?.competitorRank == nil)

        // I'm absent on kw2 → myRank nil, competitor present
        let kw2A = rows.first { $0.keywordId == kw2 && $0.competitorAppId == compA }
        #expect(kw2A?.myRank == nil)
        #expect(kw2A?.competitorRank == 3)
    }
}
