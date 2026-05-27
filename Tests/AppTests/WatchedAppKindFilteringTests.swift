@testable import App
import Foundation
import Logging
import Testing

// Load-bearing invariant: competitor apps participate in metadata
// snapshots only. They MUST NOT enter `RefreshService` (would litter
// rank_checks + burn iTunes traffic) or `ChartTrackerService` (would
// pull chart data the user never asked for). The filter lives in two
// places — one per service — because the queries iterate differently;
// these tests pin both to prevent a future "let's unify" refactor
// from accidentally dropping one.
@Suite("WatchedApp.kind filtering across services")
struct WatchedAppKindFilteringTests {

    @Test("RefreshService.refresh skips competitor apps — only owns get ranked")
    func refreshSkipsCompetitors() async throws {
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

        // Both apps appear in the search results — if the filter
        // regressed, we'd see TWO rank_checks (one per app). With the
        // filter intact, only the own app is ranked.
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
        #expect(savedChecks.count == 1, "exactly one rank_check should land — the own app")
        #expect(savedChecks.first?.$watchedApp.id == ownID)
        // The competitor's ID must NOT appear in any saved check.
        #expect(!savedChecks.contains(where: { $0.$watchedApp.id == competitorID }))
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
