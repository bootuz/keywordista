import Foundation
import Testing
@testable import App

// `AppStoreHTMLScraper.extractSubtitle` is the load-bearing piece of the
// subtitle-snapshot pipeline. Apple rotates the svelte hash on every CSS
// deploy (e.g. `class="subtitle svelte-kps97o"` → `svelte-q9xv5e3`), so
// the parser must match on the `subtitle` class word irrespective of the
// surrounding class-list. These tests pin both the captured-fixture case
// and a representative handful of synthetic shapes the regex needs to
// tolerate (or correctly reject).
@Suite("AppStoreHTMLScraper subtitle parsing")
struct AppStoreHTMLScraperTests {

    @Test("extracts subtitle from a real apps.apple.com page")
    func extractsRealSubtitle() throws {
        let html = try String(contentsOf: Self.fixtureURL("apple-page-headspace.html"))
        let subtitle = AppStoreHTMLScraper.extractSubtitle(from: html)
        // Captured production page — the actual subtitle on the US
        // Headspace listing. If Apple ever ships a page where this
        // string changes for the captured app, the fixture should be
        // re-captured.
        #expect(subtitle == "Relax, Stress & Anxiety Relief")
    }

    @Test("tolerates rotating svelte hash class names")
    func toleratesSvelteHashRotation() {
        for hash in ["svelte-kps97o", "svelte-q9xv5e3", "svelte-a1b2c3"] {
            let html = #"<p class="subtitle \#(hash)">Meditation App</p>"#
            #expect(
                AppStoreHTMLScraper.extractSubtitle(from: html) == "Meditation App",
                "should parse subtitle with class hash '\(hash)'"
            )
        }
    }

    @Test("matches subtitle when other classes appear first")
    func handlesClassOrdering() {
        let cases = [
            #"<p class="header subtitle">Headspace</p>"#,
            #"<p class="subtitle">Headspace</p>"#,
            #"<p class="subtitle large bold">Headspace</p>"#,
        ]
        for html in cases {
            #expect(
                AppStoreHTMLScraper.extractSubtitle(from: html) == "Headspace",
                "should match regardless of class-list ordering"
            )
        }
    }

    @Test("returns nil when no subtitle element is present (legitimate empty)")
    func absentSubtitleIsNil() {
        let html = "<html><body><h1>App</h1><p>Some description</p></body></html>"
        #expect(AppStoreHTMLScraper.extractSubtitle(from: html) == nil)
    }

    @Test("does NOT match a class that merely *contains* the letters 'subtitle'")
    func wholeWordMatching() {
        // The `\b` anchors in the regex should prevent matching e.g.
        // `class="appsubtitle"` (no separator) — that's a different
        // semantic element and pulling its content would corrupt the
        // snapshot. Note: HTML attribute class names are whitespace-
        // separated, so `\bsubtitle\b` is the correct anchor here.
        let html = #"<p class="appsubtitle">Wrong element</p>"#
        #expect(AppStoreHTMLScraper.extractSubtitle(from: html) == nil)
    }

    @Test("HTML-unescapes common entities")
    func unescapesEntities() {
        let html = #"<p class="subtitle">Relax &amp; Sleep — &quot;mindful&quot;</p>"#
        #expect(
            AppStoreHTMLScraper.extractSubtitle(from: html)
                == #"Relax & Sleep — "mindful""#
        )
    }

    @Test("returns nil for an empty subtitle element")
    func emptyElementIsNil() {
        let html = #"<p class="subtitle"></p>"#
        #expect(AppStoreHTMLScraper.extractSubtitle(from: html) == nil)
    }

    @Test("matches the first subtitle if multiple are present")
    func firstMatchWins() {
        // The product page has only one subtitle, but other shelves on
        // the page (e.g. event lockups) also use `<p class="subtitle">`.
        // We want the FIRST one — the topLockup subtitle — which is
        // why the regex uses `firstMatch` rather than enumerating all.
        let html = """
        <p class="subtitle svelte-x">Top Subtitle</p>
        <div>...</div>
        <p class="subtitle other-class">Other Shelf Subtitle</p>
        """
        #expect(AppStoreHTMLScraper.extractSubtitle(from: html) == "Top Subtitle")
    }

    // MARK: - Fixture loading

    private static func fixtureURL(_ name: String) -> URL {
        let here = URL(fileURLWithPath: #filePath)
        return here.deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    }
}
