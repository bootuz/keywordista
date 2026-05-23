@testable import App
import Foundation
import Testing

// Verifies the RSS-feed JSON decoder. Apple's iTunes RSS endpoint returns a
// nested `feed.entry[]` shape with dotted keys ("im:id", "im:name") that
// Swift can't express directly; we rely on custom CodingKeys to map them.
@Suite("ITunesChartsClient.parseEntries")
struct ITunesChartsClientTests {
    @Test("decodes positions and app ids in order")
    func decodesEntriesInOrder() throws {
        let json = """
        {
          "feed": {
            "entry": [
              {
                "im:name": { "label": "Duolingo: Language Lessons" },
                "id": { "attributes": { "im:id": "570060128" } }
              },
              {
                "im:name": { "label": "Azri: AI Flashcards & FSRS" },
                "id": { "attributes": { "im:id": "1625870857" } }
              },
              {
                "im:name": { "label": "Toca Boca World" },
                "id": { "attributes": { "im:id": "863571574" } }
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let entries = try ITunesChartsClient.parseEntries(from: json)
        #expect(entries.count == 3)
        #expect(entries[0].position == 1)
        #expect(entries[0].appStoreId == 570060128)
        #expect(entries[0].name == "Duolingo: Language Lessons")
        #expect(entries[1].position == 2)
        #expect(entries[1].appStoreId == 1625870857)
        #expect(entries[2].position == 3)
    }

    @Test("handles an absent entry array (empty chart) without crashing")
    func decodesEmptyEntries() throws {
        let json = """
        { "feed": { } }
        """.data(using: .utf8)!
        let entries = try ITunesChartsClient.parseEntries(from: json)
        #expect(entries.isEmpty)
    }

    @Test("skips entries with malformed im:id rather than throwing")
    func skipsBadEntries() throws {
        let json = """
        {
          "feed": {
            "entry": [
              {
                "im:name": { "label": "Good" },
                "id": { "attributes": { "im:id": "42" } }
              },
              {
                "im:name": { "label": "Bad — non-numeric id" },
                "id": { "attributes": { "im:id": "not-a-number" } }
              }
            ]
          }
        }
        """.data(using: .utf8)!
        let entries = try ITunesChartsClient.parseEntries(from: json)
        #expect(entries.count == 1)
        #expect(entries[0].name == "Good")
        #expect(entries[0].appStoreId == 42)
    }
}
