@testable import App
import Foundation
import Testing

// The MetadataController has two pieces of non-trivial logic worth pinning:
//   • `deriveChanges` — walks history, skips carry-forward rows, emits
//     per-field diffs. This is what makes /compare's timeline honest.
//   • lazy backfill — when no snapshot exists for (app, country), one
//     gets fetched inline. Tested indirectly via the service stack
//     (a unit test of the controller routing requires booting an app).
// HTTP-level tests for /compare itself would require XCTVapor +
// migration; that's deferred to a follow-up integration suite. The
// pure-function `deriveChanges` is where regressions hurt most.
@Suite("MetadataController.deriveChanges")
struct MetadataControllerTests {

    private static func makeSnapshot(
        id: UUID = UUID(),
        countryCode: String = "us",
        trackName: String = "App",
        subtitle: String? = nil,
        description: String? = nil,
        version: String? = nil,
        releaseNotes: String? = nil,
        formattedPrice: String? = nil,
        screenshotsJSON: String? = nil,
        scrapeFailedAt: Date? = nil,
        firstSeen: Date,
        lastSeen: Date? = nil
    ) -> AppMetadataSnapshot {
        let s = AppMetadataSnapshot()
        s.id = id
        s.$watchedApp.id = UUID()
        s.countryCode = countryCode
        s.trackName = trackName
        s.bundleId = "com.test"
        s.subtitle = subtitle
        s.appDescription = description
        s.version = version
        s.releaseNotes = releaseNotes
        s.formattedPrice = formattedPrice
        s.screenshotURLsJSON = screenshotsJSON
        s.scrapeFailedAt = scrapeFailedAt
        s.contentHash = "h"
        s.firstSeenAt = firstSeen
        s.lastSeenAt = lastSeen ?? firstSeen
        s.fetchedAt = firstSeen
        return s
    }

    @Test("empty history yields no changes")
    func emptyYieldsNothing() {
        #expect(MetadataController.deriveChanges(history: []).isEmpty)
    }

    @Test("single-row history yields no changes (nothing to diff against)")
    func singleRowYieldsNothing() {
        let row = Self.makeSnapshot(subtitle: "A", firstSeen: Date())
        #expect(MetadataController.deriveChanges(history: [row]).isEmpty)
    }

    @Test("subtitle change between two rows produces one change entry")
    func subtitleChange() {
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let day2 = day1.addingTimeInterval(86400)
        // History is newest-first (matches repository ordering).
        let newer = Self.makeSnapshot(subtitle: "New", firstSeen: day2)
        let older = Self.makeSnapshot(subtitle: "Old", firstSeen: day1)

        let changes = MetadataController.deriveChanges(history: [newer, older])
        #expect(changes.count == 1)
        let change = changes.first!
        #expect(change.field == "subtitle")
        #expect(change.from == "Old")
        #expect(change.to == "New")
        // `at` is the firstSeenAt of the NEWER row — i.e. when the new
        // state began. That's what the UI labels as "changed on …".
        #expect(change.at == day2)
    }

    @Test("multiple fields change in the same diff emit multiple entries")
    func multipleFieldChanges() {
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let day2 = day1.addingTimeInterval(86400)
        let newer = Self.makeSnapshot(
            subtitle: "New sub", version: "2.0",
            formattedPrice: "$1.99", firstSeen: day2
        )
        let older = Self.makeSnapshot(
            subtitle: "Old sub", version: "1.0",
            formattedPrice: "Free", firstSeen: day1
        )
        let changes = MetadataController.deriveChanges(history: [newer, older])
        let fields = Set(changes.map { $0.field })
        #expect(fields == ["subtitle", "version", "formatted_price"])
    }

    @Test("carry-forward rows (scrape_failed_at != nil) are excluded from the timeline")
    func excludesCarryForwardRows() {
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let day2 = day1.addingTimeInterval(86400)
        let day3 = day2.addingTimeInterval(86400)
        // Real observation on day 1, carry-forward (failure) on day 2,
        // real observation again on day 3 with a different subtitle.
        // The timeline should treat day1 vs day3 as the diff, not
        // day1↔day2 or day2↔day3 (which would generate noise).
        let day3Row = Self.makeSnapshot(subtitle: "Changed", firstSeen: day3)
        let day2Row = Self.makeSnapshot(
            subtitle: "Original",
            scrapeFailedAt: day2,   // marks this row as carry-forward
            firstSeen: day2
        )
        let day1Row = Self.makeSnapshot(subtitle: "Original", firstSeen: day1)

        let changes = MetadataController.deriveChanges(history: [day3Row, day2Row, day1Row])
        #expect(changes.count == 1, "carry-forward row should be skipped from diff derivation")
        #expect(changes.first?.field == "subtitle")
        #expect(changes.first?.from == "Original")
        #expect(changes.first?.to == "Changed")
    }

    @Test("identical rows produce no spurious change")
    func identicalRowsNoChange() {
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let day2 = day1.addingTimeInterval(86400)
        let newer = Self.makeSnapshot(subtitle: "Same", firstSeen: day2)
        let older = Self.makeSnapshot(subtitle: "Same", firstSeen: day1)
        // (In practice the dedupe path would have collapsed these into
        // one row — but if the dedupe ever regresses, the diff path
        // shouldn't manufacture phantom changes from the duplicate.)
        #expect(MetadataController.deriveChanges(history: [newer, older]).isEmpty)
    }

    @Test("nil-to-value and value-to-nil transitions both count as changes")
    func nilTransitionsAreChanges() {
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let day2 = day1.addingTimeInterval(86400)
        let day3 = day2.addingTimeInterval(86400)
        // Day 1: no subtitle. Day 2: subtitle added. Day 3: subtitle removed.
        let day3Row = Self.makeSnapshot(subtitle: nil, firstSeen: day3)
        let day2Row = Self.makeSnapshot(subtitle: "X", firstSeen: day2)
        let day1Row = Self.makeSnapshot(subtitle: nil, firstSeen: day1)
        let changes = MetadataController.deriveChanges(history: [day3Row, day2Row, day1Row])
        #expect(changes.count == 2)
        // Newer-first: first entry is day3 (removed); second is day2 (added).
        #expect(changes[0].from == "X" && changes[0].to == nil)
        #expect(changes[1].from == nil && changes[1].to == "X")
    }
}
