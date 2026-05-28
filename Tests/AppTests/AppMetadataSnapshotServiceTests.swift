import Foundation
import Logging
import Testing
@testable import App

// The snapshot service's contract is small but load-bearing:
//   1. On first fetch → INSERT a row.
//   2. On a re-fetch with identical content → BUMP `lastSeenAt`, do NOT insert.
//   3. On a re-fetch with changed content → INSERT a new row, leave the
//      prior row's `lastSeenAt` frozen.
//   4. On HTML-scrape failure → carry the prior subtitle forward into the
//      new row's content hash, so a transient blip does NOT churn the
//      timeline with spurious "subtitle changed → and back" entries.
// These four behaviors are what makes the `recentChanges` derivation in
// /compare honest. If any one of them regresses, the timeline becomes
// noise.
@Suite("AppMetadataSnapshotService dedupe + carry-forward")
struct AppMetadataSnapshotServiceTests {

    // MARK: - Fixtures

    static let appID = UUID()
    static let watchedApp = WatchedApp(
        id: appID,
        appStoreId: 493145008,
        bundleId: "com.getsomeheadspace.headspace",
        name: "Headspace",
        iconURL: nil,
        primaryGenreId: 6013,
        kind: .competitor
    )

    static func richHeadspace(version: String = "8.16.0", description: String = "Mindfulness app") -> RichLookupResultApp {
        RichLookupResultApp(
            trackId: 493145008,
            bundleId: "com.getsomeheadspace.headspace",
            trackName: "Headspace: Sleep & Meditation",
            version: version,
            currentVersionReleaseDate: nil,
            releaseNotes: "Bug fixes.",
            releaseDate: nil,
            description: description,
            sellerName: "Headspace Inc.",
            primaryGenreName: "Health & Fitness",
            primaryGenreId: 6013,
            genres: ["Health & Fitness"],
            artworkUrl100: nil,
            artworkUrl512: "https://cdn/icon.png",
            screenshotUrls: ["https://cdn/s1.png"],
            ipadScreenshotUrls: nil,
            price: 0,
            currency: "USD",
            formattedPrice: "Free",
            averageUserRating: 4.8,
            userRatingCount: 1_000_000,
            averageUserRatingForCurrentVersion: 4.8,
            userRatingCountForCurrentVersion: 1_000_000,
            contentAdvisoryRating: "12+",
            languageCodesISO2A: ["EN"],
            fileSizeBytes: 500_000_000,
            minimumOsVersion: "15.0"
        )
    }

    /// Build a service wired to in-memory deps. Returns the service plus
    /// the snapshot repo and HTML scraper so tests can inspect call traces.
    static func makeService(
        rich: RichLookupResultApp = richHeadspace(),
        scrapeOutcomes: [ScrapeOutcome],
        now: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) async -> (
        service: AppMetadataSnapshotService,
        snapshots: InMemoryAppMetadataSnapshotRepository,
        scraper: StubHTMLScraper,
        clockBox: ClockBox
    ) {
        let snapshots = InMemoryAppMetadataSnapshotRepository()
        let scraper = StubHTMLScraper(outcomes: scrapeOutcomes)
        let watched = InMemoryWatchedAppRepository([watchedApp])
        let stubLookup = StubLookupClient(
            canned: LookupResultApp(
                trackId: rich.trackId, bundleId: rich.bundleId,
                trackName: rich.trackName, artworkUrl100: rich.artworkUrl100,
                primaryGenreId: rich.primaryGenreId
            ),
            cannedRich: rich
        )
        let clockBox = ClockBox(now: now)
        let service = AppMetadataSnapshotService(
            snapshots: snapshots,
            watchedApps: watched,
            lookupClient: stubLookup,
            scraper: scraper,
            logger: Logger(label: "test"),
            clock: { [clockBox] in clockBox.now }
        )
        return (service, snapshots, scraper, clockBox)
    }

    // Reference-typed clock so tests can advance time between calls
    // without re-instantiating the service.
    final class ClockBox: @unchecked Sendable {
        var now: Date
        init(now: Date) { self.now = now }
    }

    // MARK: - Tests

    @Test("first snapshot for (app, country) INSERTS a row")
    func firstSnapshotInserts() async throws {
        let (service, snapshots, _, _) = await Self.makeService(
            scrapeOutcomes: [.succeeded(subtitle: "Relax, Stress & Anxiety Relief")]
        )

        let row = try await service.snapshot(watchedAppID: Self.appID, country: "us")

        let saved = await snapshots.saved
        let bumps = await snapshots.bumps
        #expect(saved.count == 1)
        #expect(bumps.isEmpty)
        #expect(row.subtitle == "Relax, Stress & Anxiety Relief")
        #expect(row.trackName == "Headspace: Sleep & Meditation")
        #expect(row.contentHash.isEmpty == false)
        #expect(row.firstSeenAt == row.lastSeenAt)
    }

    @Test("re-snapshot with identical content BUMPS lastSeenAt, no insert")
    func identicalContentDedupes() async throws {
        let (service, snapshots, _, clock) = await Self.makeService(
            scrapeOutcomes: [
                .succeeded(subtitle: "Relax, Stress & Anxiety Relief"),
                .succeeded(subtitle: "Relax, Stress & Anxiety Relief"),
            ]
        )
        _ = try await service.snapshot(watchedAppID: Self.appID, country: "us")
        clock.now = clock.now.addingTimeInterval(86400)
        _ = try await service.snapshot(watchedAppID: Self.appID, country: "us")

        let saved = await snapshots.saved
        let bumps = await snapshots.bumps
        #expect(saved.count == 1, "no new row should have been inserted")
        #expect(bumps.count == 1, "lastSeenAt should have been bumped exactly once")
        // The bump's timestamp matches the advanced clock, proving the
        // dedupe path used `now` rather than a stale value.
        #expect(bumps.first?.lastSeenAt == clock.now)
    }

    @Test("changed content INSERTS a new row, leaving the prior frozen")
    func changedContentInserts() async throws {
        let (service, snapshots, _, clock) = await Self.makeService(
            scrapeOutcomes: [
                .succeeded(subtitle: "Old subtitle"),
                .succeeded(subtitle: "New subtitle"),
            ]
        )
        let firstRow = try await service.snapshot(watchedAppID: Self.appID, country: "us")
        let firstLastSeen = firstRow.lastSeenAt
        clock.now = clock.now.addingTimeInterval(86400)
        let secondRow = try await service.snapshot(watchedAppID: Self.appID, country: "us")

        let saved = await snapshots.saved
        let bumps = await snapshots.bumps
        #expect(saved.count == 2)
        #expect(bumps.isEmpty)
        #expect(secondRow.subtitle == "New subtitle")
        // Prior row's lastSeenAt must NOT have been touched — that's
        // how the timeline records "subtitle was 'Old' from day 1 to
        // day 2, then 'New' from day 2 onward".
        let prior = saved.first { $0.id == firstRow.id }
        #expect(prior?.lastSeenAt == firstLastSeen)
    }

    @Test("HTML scrape failure carries forward the prior subtitle into the new hash")
    func scrapeFailureCarriesForwardSubtitle() async throws {
        // Day 1: scrape succeeds with subtitle "A".
        // Day 2: scrape FAILS — should reuse "A" so the row dedupes.
        let (service, snapshots, _, clock) = await Self.makeService(
            scrapeOutcomes: [
                .succeeded(subtitle: "A"),
                .failed(reason: "test 502"),
            ]
        )
        _ = try await service.snapshot(watchedAppID: Self.appID, country: "us")
        clock.now = clock.now.addingTimeInterval(86400)
        _ = try await service.snapshot(watchedAppID: Self.appID, country: "us")

        let saved = await snapshots.saved
        let bumps = await snapshots.bumps
        // The key property: scrape failure DID NOT cause a spurious
        // insert. Dedupe kept the timeline clean.
        #expect(saved.count == 1, "carry-forward should dedupe; no insert on scrape failure")
        #expect(bumps.count == 1)
        // The bump path INTENTIONALLY does not touch `scrapeFailedAt` —
        // the prior row's provenance (it was a clean observation when
        // inserted) must stay accurate. The day-2 scrape failure is
        // logged but not recorded on the historical row.
        #expect(saved.first?.scrapeFailedAt == nil, "bump path must not clobber a clean prior row's scrapeFailedAt")
        // And the surviving row's subtitle still reads "A" (the original).
        #expect(saved.first?.subtitle == "A")
    }

    @Test("scrape success after failure does NOT introduce a spurious change")
    func scrapeRecoveryDoesNotChurn() async throws {
        // Day 1: success "A". Day 2: failure → carries "A". Day 3:
        // success "A" again (Apple's page came back). All three days
        // should collapse into one row — no spurious "subtitle changed
        // → and back" pair.
        let (service, snapshots, _, clock) = await Self.makeService(
            scrapeOutcomes: [
                .succeeded(subtitle: "A"),
                .failed(reason: "blip"),
                .succeeded(subtitle: "A"),
            ]
        )
        _ = try await service.snapshot(watchedAppID: Self.appID, country: "us")
        clock.now = clock.now.addingTimeInterval(86400)
        _ = try await service.snapshot(watchedAppID: Self.appID, country: "us")
        clock.now = clock.now.addingTimeInterval(86400)
        _ = try await service.snapshot(watchedAppID: Self.appID, country: "us")

        let saved = await snapshots.saved
        let bumps = await snapshots.bumps
        #expect(saved.count == 1, "scrape blip+recovery should not churn the timeline")
        #expect(bumps.count == 2)
        // The original row was a successful observation on day 1
        // (`scrapeFailedAt == nil`), and the bump path never touches
        // that flag — so it stays nil through day 2's blip and day 3's
        // recovery. (This is the fix for the carry-forward bump
        // clobber bug surfaced in code review.)
        #expect(saved.first?.scrapeFailedAt == nil)
    }

    @Test("bump never clobbers a clean prior row's scrapeFailedAt (provenance preservation)")
    func bumpDoesNotClobberPriorRowProvenance() async throws {
        // Day 1: scrape succeeded → row has scrapeFailedAt == nil
        //        (the row is a real, clean observation).
        // Day 2: scrape fails → carry-forward subtitle, content hash
        //        matches, dedupe-bump path fires.
        //
        // The historical day-1 row must remain provenance-clean
        // (scrapeFailedAt stays nil). If the bump clobbers it with the
        // day-2 failure timestamp, the change-derivation logic later
        // mistakes a previously-clean row for a carry-forward row and
        // drops real changes from /compare's timeline. This is the
        // exact bug the ultrareview agent caught — pinning it here.
        let (service, snapshots, _, clock) = await Self.makeService(
            scrapeOutcomes: [
                .succeeded(subtitle: "Mindfulness"),
                .failed(reason: "transient 502"),
            ]
        )
        _ = try await service.snapshot(watchedAppID: Self.appID, country: "us")
        clock.now = clock.now.addingTimeInterval(86400)
        _ = try await service.snapshot(watchedAppID: Self.appID, country: "us")

        let saved = await snapshots.saved
        #expect(saved.count == 1)
        #expect(
            saved.first?.scrapeFailedAt == nil,
            "bump must preserve the day-1 row's clean scrapeFailedAt — clobbering it would corrupt provenance and silently hide real changes from the timeline"
        )
    }

    @Test("real subtitle change after a failure is recorded as a real change")
    func realChangeAfterFailureStillInserts() async throws {
        // Day 1: success "A". Day 2: failure → carries "A". Day 3:
        // success "B" — this IS a real change and should produce a new
        // row, with the carry-forward row's lastSeenAt frozen at day 2.
        let (service, snapshots, _, clock) = await Self.makeService(
            scrapeOutcomes: [
                .succeeded(subtitle: "A"),
                .failed(reason: "blip"),
                .succeeded(subtitle: "B"),
            ]
        )
        _ = try await service.snapshot(watchedAppID: Self.appID, country: "us")
        clock.now = clock.now.addingTimeInterval(86400)
        let day2BumpTime = clock.now
        _ = try await service.snapshot(watchedAppID: Self.appID, country: "us")
        clock.now = clock.now.addingTimeInterval(86400)
        let row3 = try await service.snapshot(watchedAppID: Self.appID, country: "us")

        let saved = await snapshots.saved
        #expect(saved.count == 2)
        #expect(row3.subtitle == "B")
        // Day-1 row's lastSeenAt should be the day-2 bump time (we
        // re-confirmed it via carry-forward on day 2).
        let day1Row = saved.first { $0.subtitle == "A" }
        #expect(day1Row?.lastSeenAt == day2BumpTime)
    }

    @Test("changes in rich-lookup fields (description, version) trigger inserts")
    func richFieldChangesInsert() async throws {
        let (snapshots, scraper, watched) = (
            InMemoryAppMetadataSnapshotRepository(),
            StubHTMLScraper(outcomes: [
                .succeeded(subtitle: "Sub"),
                .succeeded(subtitle: "Sub"),
            ]),
            InMemoryWatchedAppRepository([Self.watchedApp])
        )
        // Two calls return different rich projections — the description
        // mutates between them. Wrap the stub so the second call sees
        // the changed payload.
        let stubLookup = MutableRichLookupStub(
            sequence: [
                Self.richHeadspace(description: "First description"),
                Self.richHeadspace(description: "Second description"),
            ]
        )
        let clockBox = ClockBox(now: Date(timeIntervalSince1970: 1_700_000_000))
        let service = AppMetadataSnapshotService(
            snapshots: snapshots, watchedApps: watched,
            lookupClient: stubLookup, scraper: scraper,
            logger: Logger(label: "test"),
            clock: { [clockBox] in clockBox.now }
        )

        _ = try await service.snapshot(watchedAppID: Self.appID, country: "us")
        clockBox.now = clockBox.now.addingTimeInterval(86400)
        _ = try await service.snapshot(watchedAppID: Self.appID, country: "us")

        let saved = await snapshots.saved
        #expect(saved.count == 2, "description change should create a new row")
    }
}

/// Stub that returns successive rich-lookup payloads from a queue, used
/// by tests that need to simulate Apple's data changing between calls.
private actor MutableRichLookupStub: ITunesLookupClientProtocol {
    private var sequence: [RichLookupResultApp]
    init(sequence: [RichLookupResultApp]) { self.sequence = sequence }

    func lookup(appStoreId: Int64, country: String) async throws -> LookupResultApp {
        // Not used in these tests.
        throw NSError(domain: "unused", code: 0)
    }

    func lookupRich(appStoreId: Int64, country: String) async throws -> RichLookupResultApp {
        if sequence.count > 1 { return sequence.removeFirst() }
        return sequence.first!
    }
}
