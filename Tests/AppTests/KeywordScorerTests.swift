@testable import App
import Foundation
import Testing

@Suite("HeuristicScorer")
struct KeywordScorerTests {
    let scorer = HeuristicScorer()
    let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test func emptyReturnsZero() {
        let result = scorer.score(topFive: [], referenceDate: now)
        #expect(result == .zero)
    }

    @Test(
        "difficulty buckets by average rating count",
        arguments: [
            (200, 1),
            (5_000, 2),
            (50_000, 3),
            (250_000, 4),
            (1_000_000, 5),
        ]
    )
    func difficulty(ratings: Int, expected: Int) {
        let apps = (1...5).map { SearchResultApp.fixture(id: Int64($0), ratings: ratings) }
        let result = scorer.score(topFive: apps, referenceDate: now)
        #expect(result.difficulty == expected)
    }

    @Test func entryBarrier_dominantLeader() {
        let apps = [
            SearchResultApp.fixture(id: 1, ratings: 1_000_000),
            SearchResultApp.fixture(id: 2, ratings: 1_000),
            SearchResultApp.fixture(id: 3, ratings: 1_000),
            SearchResultApp.fixture(id: 4, ratings: 1_000),
            SearchResultApp.fixture(id: 5, ratings: 1_000),
        ]
        let result = scorer.score(topFive: apps, referenceDate: now)
        // dominance ≥15 (1000x) → 3, age 0 → 0, total 3
        #expect(result.entryBarrier == 3)
    }

    @Test func entryBarrier_oldCohort() {
        let tenYearsAgo = now.addingTimeInterval(-10 * 365.25 * 24 * 3600)
        let apps = (1...5).map { SearchResultApp.fixture(id: Int64($0), ratings: 50_000, release: tenYearsAgo) }
        let result = scorer.score(topFive: apps, referenceDate: now)
        // dominance ≈1 → 0, age ≥5 → 2, total 2
        #expect(result.entryBarrier == 2)
    }

    @Test func entryBarrier_capsAtFive() {
        let tenYearsAgo = now.addingTimeInterval(-10 * 365.25 * 24 * 3600)
        let apps = [
            SearchResultApp.fixture(id: 1, ratings: 5_000_000, release: tenYearsAgo),
            SearchResultApp.fixture(id: 2, ratings: 1_000, release: tenYearsAgo),
            SearchResultApp.fixture(id: 3, ratings: 1_000, release: tenYearsAgo),
            SearchResultApp.fixture(id: 4, ratings: 1_000, release: tenYearsAgo),
            SearchResultApp.fixture(id: 5, ratings: 1_000, release: tenYearsAgo),
        ]
        let result = scorer.score(topFive: apps, referenceDate: now)
        #expect(result.entryBarrier == 5)
    }
}
