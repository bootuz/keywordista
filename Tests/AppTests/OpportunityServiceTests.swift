@testable import App
import Foundation
import Testing

@Suite("OpportunityScore")
struct OpportunityScoreTests {
    @Test("opportunity = impressions / difficulty")
    func divides() {
        #expect(OpportunityScore.compute(impressions: 1000, difficulty: 2) == 500)
        #expect(OpportunityScore.compute(impressions: 300, difficulty: 5) == 60)
    }

    @Test("nil when difficulty is unknown (0)")
    func nilOnUnknown() {
        #expect(OpportunityScore.compute(impressions: 1000, difficulty: 0) == nil)
    }
}

@Suite("OpportunityService")
struct OpportunityServiceTests {
    private struct StubPopularity: KeywordPopularityServiceProtocol {
        let map: [UUID: Int]
        func popularity() async throws -> [UUID: Int] { map }
    }

    @Test("joins ASA impressions with difficulty into an opportunity score")
    func joins() async throws {
        let kw = UUID()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let topRepo = InMemoryTopResultSnapshotRepository()
        // 5 incumbents averaging 50k ratings → HeuristicScorer difficulty = 3.
        for pos in 1...5 {
            try await topRepo.save(TopResultSnapshot(
                keywordID: kw, checkedAt: now, position: pos,
                appStoreId: Int64(pos), name: "App\(pos)", iconURL: nil,
                ratingCount: 50_000, averageRating: 4.5, releaseDate: nil,
            ))
        }
        let service = OpportunityService(
            popularity: StubPopularity(map: [kw: 1000]),
            topResultRepository: topRepo,
            scorer: HeuristicScorer(),
            now: { now },
        )

        let opps = try await service.opportunities()
        #expect(opps.count == 1)
        #expect(opps.first?.keywordId == kw)
        #expect(opps.first?.impressions == 1000)
        #expect(opps.first?.difficulty == 3)     // avg 50k ratings → bucket 3
        #expect(opps.first?.opportunity == 333)  // 1000 / 3
    }

    @Test("skips keywords whose difficulty can't be assessed (no top-results snapshot)")
    func skipsUnknownDifficulty() async throws {
        let kw = UUID()
        let service = OpportunityService(
            popularity: StubPopularity(map: [kw: 1000]),
            topResultRepository: InMemoryTopResultSnapshotRepository(),  // no snapshots
            scorer: HeuristicScorer(),
            now: { Date() },
        )
        #expect(try await service.opportunities().isEmpty)
    }
}
