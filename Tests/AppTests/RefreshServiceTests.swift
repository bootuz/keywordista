@testable import App
import Foundation
import Logging
import Testing

@Suite("RefreshService")
struct RefreshServiceTests {
    private func makeLogger() -> Logger { Logger(label: "test") }

    @Test("persists rank for watched app found in search results")
    func persistsRankAndTopResults() async throws {
        let keywordID = UUID()
        let watchedID = UUID()
        let keyword = Keyword(id: keywordID, term: "flashcards", countryCode: "us")
        let watched = WatchedApp(id: watchedID, appStoreId: 42, bundleId: "com.azri", name: "Azri", iconURL: nil)

        let keywordRepo = InMemoryKeywordRepository([keyword])
        let appRepo = InMemoryWatchedAppRepository([watched])
        let rankRepo = InMemoryRankCheckRepository()
        let topRepo = InMemoryTopResultSnapshotRepository()

        let results: [SearchResultApp] = [
            .fixture(id: 1, ratings: 50_000),
            .fixture(id: 2, ratings: 40_000),
            .fixture(id: 3, ratings: 30_000),
            .fixture(id: 42, name: "Azri", ratings: 5_000),
            .fixture(id: 5, ratings: 10_000),
        ]
        let search = StubSearchClient(canned: results)

        let service = RefreshService(
            keywordRepository: keywordRepo,
            watchedAppRepository: appRepo,
            rankCheckRepository: rankRepo,
            topResultRepository: topRepo,
            searchClient: search,
            scorer: HeuristicScorer(),
            logger: makeLogger()
        )

        try await service.refresh(keywordID: keywordID, now: Date())

        let savedChecks = await rankRepo.saved
        try #require(savedChecks.count == 1)
        #expect(savedChecks[0].rank == 4)
        #expect(savedChecks[0].difficulty == 3)
        #expect(savedChecks[0].entryBarrier >= 0)

        let snaps = await topRepo.saved
        #expect(snaps.count == 5)
        #expect(snaps.map(\.position).sorted() == [1, 2, 3, 4, 5])
    }

    @Test("stores nil rank when watched app is outside results")
    func nilRankWhenAppMissing() async throws {
        let keywordID = UUID()
        let watchedID = UUID()
        let keyword = Keyword(id: keywordID, term: "study", countryCode: "us")
        let watched = WatchedApp(id: watchedID, appStoreId: 999, bundleId: "com.missing", name: "Missing", iconURL: nil)

        let rankRepo = InMemoryRankCheckRepository()
        let topRepo = InMemoryTopResultSnapshotRepository()
        let service = RefreshService(
            keywordRepository: InMemoryKeywordRepository([keyword]),
            watchedAppRepository: InMemoryWatchedAppRepository([watched]),
            rankCheckRepository: rankRepo,
            topResultRepository: topRepo,
            searchClient: StubSearchClient(canned: [.fixture(id: 1, ratings: 100)]),
            scorer: HeuristicScorer(),
            logger: makeLogger()
        )

        try await service.refresh(keywordID: keywordID, now: Date())

        let saved = await rankRepo.saved
        try #require(saved.count == 1)
        #expect(saved[0].rank == nil)
    }

    @Test("ranks every watched app for every keyword regardless of country")
    func ranksAllAppsAcrossCountries() async throws {
        let keywordID = UUID()
        let keyword = Keyword(id: keywordID, term: "flashcards", countryCode: "us")
        let appA = WatchedApp(id: UUID(), appStoreId: 1, bundleId: "a", name: "AppA", iconURL: nil)
        let appB = WatchedApp(id: UUID(), appStoreId: 2, bundleId: "b", name: "AppB", iconURL: nil)

        let rankRepo = InMemoryRankCheckRepository()
        let service = RefreshService(
            keywordRepository: InMemoryKeywordRepository([keyword]),
            watchedAppRepository: InMemoryWatchedAppRepository([appA, appB]),
            rankCheckRepository: rankRepo,
            topResultRepository: InMemoryTopResultSnapshotRepository(),
            searchClient: StubSearchClient(canned: [.fixture(id: 1, ratings: 100)]),
            scorer: HeuristicScorer(),
            logger: makeLogger()
        )

        try await service.refresh(keywordID: keywordID, now: Date())

        let saved = await rankRepo.saved
        #expect(saved.count == 2)
        let appIDs = Set(saved.map(\.$watchedApp.id))
        #expect(appIDs == [appA.id, appB.id])
        // appA is in results at position 1, appB is not in results → nil.
        let appA_check = saved.first { $0.$watchedApp.id == appA.id }
        let appB_check = saved.first { $0.$watchedApp.id == appB.id }
        #expect(appA_check?.rank == 1)
        #expect(appB_check?.rank == nil)
    }

    @Test("dedupes no-change refresh by bumping checkedAt instead of inserting")
    func dedupeNoChangeRefresh() async throws {
        let keywordID = UUID()
        let watchedID = UUID()
        let firstObservedAt = Date(timeIntervalSince1970: 1_000_000_000)
        let secondRefreshAt = Date(timeIntervalSince1970: 1_000_086_400) // ~1 day later

        let keyword = Keyword(id: keywordID, term: "flashcards", countryCode: "us")
        let watched = WatchedApp(id: watchedID, appStoreId: 42, bundleId: "com.azri", name: "Azri", iconURL: nil)

        // Identical search results on both refreshes — the second call
        // should produce identical (rank, difficulty, entryBarrier) values,
        // so the dedupe path should notice the match and bump rather than
        // insert. By running the first refresh through the same service
        // we avoid hard-coding the scorer's exact entryBarrier output,
        // which would fragilely couple the test to the heuristic.
        let results: [SearchResultApp] = [
            .fixture(id: 1, ratings: 50_000),
            .fixture(id: 2, ratings: 40_000),
            .fixture(id: 3, ratings: 30_000),
            .fixture(id: 42, name: "Azri", ratings: 5_000),
            .fixture(id: 5, ratings: 10_000),
        ]

        let rankRepo = InMemoryRankCheckRepository()
        let service = RefreshService(
            keywordRepository: InMemoryKeywordRepository([keyword]),
            watchedAppRepository: InMemoryWatchedAppRepository([watched]),
            rankCheckRepository: rankRepo,
            topResultRepository: InMemoryTopResultSnapshotRepository(),
            searchClient: StubSearchClient(canned: results),
            scorer: HeuristicScorer(),
            logger: makeLogger()
        )

        // First refresh: cold path, inserts a row with firstSeenAt = now.
        try await service.refresh(keywordID: keywordID, now: firstObservedAt)
        try #require(await rankRepo.saved.count == 1)
        try #require(await rankRepo.bumps.isEmpty)
        let originalID = await rankRepo.saved[0].id
        try #require(originalID != nil)

        // Second refresh on identical data: should bump, not insert.
        try await service.refresh(keywordID: keywordID, now: secondRefreshAt)

        let saved = await rankRepo.saved
        let bumps = await rankRepo.bumps
        #expect(saved.count == 1, "no duplicate row should be inserted")
        #expect(bumps.count == 1, "exactly one checkedAt bump")
        #expect(bumps.first?.id == originalID)
        #expect(bumps.first?.checkedAt == secondRefreshAt)
        // The existing row's checkedAt now reflects the latest observation,
        // while firstSeenAt remains the original observation time.
        #expect(saved[0].checkedAt == secondRefreshAt)
        #expect(saved[0].firstSeenAt == firstObservedAt)
    }

    @Test("inserts a new row when rank changes")
    func insertsOnRankChange() async throws {
        let keywordID = UUID()
        let watchedID = UUID()
        let firstObservedAt = Date(timeIntervalSince1970: 1_000_000_000)
        let now = Date(timeIntervalSince1970: 1_000_086_400)

        let keyword = Keyword(id: keywordID, term: "flashcards", countryCode: "us")
        let watched = WatchedApp(id: watchedID, appStoreId: 42, bundleId: "com.azri", name: "Azri", iconURL: nil)

        // Previously observed rank=4; the upcoming search puts it at rank=1.
        let existing = RankCheck(
            id: UUID(),
            keywordID: keywordID,
            watchedAppID: watchedID,
            rank: 4,
            difficulty: 3,
            entryBarrier: 2,
            checkedAt: firstObservedAt,
            firstSeenAt: firstObservedAt
        )

        let rankRepo = InMemoryRankCheckRepository()
        try await rankRepo.save(existing)

        let results: [SearchResultApp] = [
            .fixture(id: 42, name: "Azri", ratings: 5_000),
            .fixture(id: 1, ratings: 50_000),
        ]

        let service = RefreshService(
            keywordRepository: InMemoryKeywordRepository([keyword]),
            watchedAppRepository: InMemoryWatchedAppRepository([watched]),
            rankCheckRepository: rankRepo,
            topResultRepository: InMemoryTopResultSnapshotRepository(),
            searchClient: StubSearchClient(canned: results),
            scorer: HeuristicScorer(),
            logger: makeLogger()
        )

        try await service.refresh(keywordID: keywordID, now: now)

        let saved = await rankRepo.saved
        let bumps = await rankRepo.bumps
        // Two distinct rows now — old + new state.
        #expect(saved.count == 2)
        // No bump occurred; the dedupe path correctly fell through.
        #expect(bumps.isEmpty)
        // The new row carries firstSeenAt = now (start of this run).
        let newest = saved.max(by: { $0.checkedAt < $1.checkedAt })
        #expect(newest?.rank == 1)
        #expect(newest?.firstSeenAt == now)
    }

    @Test("no-op when keyword id is unknown")
    func unknownKeywordIsNoop() async throws {
        let rankRepo = InMemoryRankCheckRepository()
        let service = RefreshService(
            keywordRepository: InMemoryKeywordRepository(),
            watchedAppRepository: InMemoryWatchedAppRepository(),
            rankCheckRepository: rankRepo,
            topResultRepository: InMemoryTopResultSnapshotRepository(),
            searchClient: StubSearchClient(canned: []),
            scorer: HeuristicScorer(),
            logger: makeLogger()
        )

        try await service.refresh(keywordID: UUID(), now: Date())

        let saved = await rankRepo.saved
        #expect(saved.isEmpty)
    }
}
