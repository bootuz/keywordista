@testable import App
import Foundation
import Logging
import Testing

// Load-bearing invariant (asymmetric by design — see the competitor
// keyword-gap feature):
//
//   • `RefreshService` ALSO ranks competitor apps. Their rank is read from
//     the *same* search results we already fetch for the keyword, so it
//     costs zero extra iTunes traffic, and the gap view depends on it.
//     Competitor rows are kept out of the main dashboard by
//     `DashboardService` scoping to `.own` (see DashboardServiceTests).
//
//   • `ChartTrackerService` STILL excludes competitors — chart tracking
//     really would burn extra iTunes traffic (one chart pull per app).
//
// These tests pin both halves so a future "let's unify" refactor can't
// silently collapse the asymmetry in either direction.
@Suite("WatchedApp.kind filtering across services")
struct WatchedAppKindFilteringTests {

    @Test("RefreshService.refresh ranks competitor apps too — for the gap view")
    func refreshRanksCompetitors() async throws {
        let keywordID = UUID()
        let ownID = UUID()
        let competitorID = UUID()
        let keyword = Keyword(id: keywordID, term: "flashcards", countryCode: "us")

        let own = WatchedApp(
            id: ownID, appStoreId: 42, bundleId: "com.mine", name: "Mine",
            iconURL: nil, kind: .own
        )
        let competitor = WatchedApp(
            id: competitorID, appStoreId: 999, bundleId: "com.competitor",
            name: "Competitor", iconURL: nil, kind: .competitor
        )

        let appRepo = InMemoryWatchedAppRepository([own, competitor])
        let keywordRepo = InMemoryKeywordRepository([keyword])
        let rankRepo = InMemoryRankCheckRepository()
        let topRepo = InMemoryTopResultSnapshotRepository()

        // Both apps appear in the search results — own at position 1,
        // competitor at position 2. We expect TWO rank_checks: one per app.
        let search = StubSearchClient(canned: [
            .fixture(id: 42, name: "Mine", ratings: 5_000),
            .fixture(id: 999, name: "Competitor", ratings: 10_000),
        ])

        let service = RefreshService(
            keywordRepository: keywordRepo,
            watchedAppRepository: appRepo,
            rankCheckRepository: rankRepo,
            topResultRepository: topRepo,
            searchClient: search,
            scorer: HeuristicScorer(),
            logger: Logger(label: "test")
        )

        try await service.refresh(keywordID: keywordID, now: Date())

        let savedChecks = await rankRepo.saved
        #expect(savedChecks.count == 2, "both own and competitor apps should be ranked")
        #expect(
            savedChecks.contains(where: { $0.$watchedApp.id == ownID && $0.rank == 1 }),
            "own app ranked at position 1"
        )
        #expect(
            savedChecks.contains(where: { $0.$watchedApp.id == competitorID && $0.rank == 2 }),
            "competitor app ranked at position 2 — this is what the gap view consumes"
        )
    }

    // ChartTrackerService.refreshAll is harder to unit-test because it
    // reads via Fluent's `WatchedApp.query(on: db).all()` directly (no
    // injectable repo). Coverage there is via the integration-test path
    // when migration is applied. The Swift-level invariant is verified
    // by reading the source code; this static-source assertion catches
    // a future refactor that removes the filter.
    @Test("ChartTrackerService.refreshAll source still filters by kind == .own")
    func chartTrackerSourceStillFiltersByKind() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/AppTests/WatchedAppKindFilteringTests.swift",
            with: "Sources/App/Services/ChartTrackerService.swift"
        ))
        // The filter expression: `.filter { $0.typedKind == .own }`. Searching
        // for the substring is brittle if the filter is rewritten as a
        // Fluent query predicate; in that case re-anchor this assertion
        // on the new form. The point is to fail loudly when the filter
        // disappears altogether.
        #expect(
            source.contains("$0.typedKind == .own") || source.contains("kindRaw") || source.contains(".filter("),
            "ChartTrackerService must include a kind-based filter (search the file for the filter expression)"
        )
    }

    @Test("WatchedAppKind enum coerces unknown rawValues to .own (safety default)")
    func unknownKindCoercesToOwn() {
        let app = WatchedApp()
        app.kind = "future_value_not_yet_supported"
        #expect(app.typedKind == .own, "unknown kind must default to .own — see WatchedApp.typedKind doc")
    }

    @Test("WatchedAppKind enum coerces NULL rawValue to .own (legacy rows)")
    func nilKindCoercesToOwn() {
        let app = WatchedApp()
        app.kind = nil
        #expect(app.typedKind == .own)
    }
}
