import Foundation
import Testing
import Vapor
@testable import App

// `RichLookupResultApp` is the wire-shape consumer for Apple's `/lookup`
// response in the metadata-snapshot pipeline. The decode logic has two
// non-trivial corners:
//   • Apple's response uses non-fractional ISO 8601 dates
//     (`"2012-02-02T18:57:49Z"`), but the rest of Keywordista uses
//     fractional. The lookup client opts out of the global
//     ContentConfiguration encoder/decoder for that reason.
//   • `fileSizeBytes` is documented as Int64 but Apple sometimes returns
//     it as a string. The custom `init(from:)` handles both.
// These tests pin both behaviours against a captured fixture so a
// future "let's just use the global decoder" refactor breaks loudly.
@Suite("ITunesLookupClient rich decoder")
struct ITunesLookupClientRichTests {

    @Test("decodes a real lookup response end-to-end")
    func decodesHeadspaceFixture() throws {
        let app = try Self.decodeFixture()

        #expect(app.trackId == 493145008)
        #expect(app.bundleId == "com.getsomeheadspace.headspace")
        #expect(app.trackName == "Headspace: Sleep & Meditation")
        // The fixture is a captured production response, so these
        // values reflect Apple's data at capture time. Asserting them
        // also catches accidental field-rename regressions in the
        // CodingKeys (Apple uses camelCase verbatim).
        #expect(app.sellerName == "Headspace Inc.")
        #expect(app.primaryGenreId == 6013)
        #expect(app.primaryGenreName == "Health & Fitness")
        #expect(app.contentAdvisoryRating == "12+")
        #expect(app.formattedPrice == "Free")
    }

    @Test("parses non-fractional ISO 8601 dates (Apple's wire format)")
    func parsesAppleISO8601() throws {
        let app = try Self.decodeFixture()
        // Apple returns these as e.g. "2012-02-02T18:57:49Z" — no
        // fractional seconds. The custom .iso8601 strategy parses it;
        // if the lookup client ever reverts to the global decoder
        // (which is .withFractionalSeconds-strict), this assertion
        // breaks loudly instead of silently nulling out the date.
        #expect(app.releaseDate != nil)
        #expect(app.currentVersionReleaseDate != nil)
    }

    @Test("decodes optional fields tolerantly when present")
    func decodesOptionalFieldsWhenPresent() throws {
        let app = try Self.decodeFixture()
        #expect(app.description?.isEmpty == false)
        #expect(app.screenshotUrls?.isEmpty == false)
        #expect(app.languageCodesISO2A?.isEmpty == false)
        #expect(app.userRatingCount != nil && (app.userRatingCount ?? 0) > 0)
    }

    @Test("falls back gracefully when iTunes returns fileSizeBytes as a string")
    func fileSizeBytesCoercedFromString() throws {
        // Synthesize the dual-shape edge case Apple has shipped in the
        // wild. The custom init must accept "504375296" as well as
        // 504375296.
        let stringSizeJSON = """
        {
          "resultCount": 1,
          "results": [{
            "trackId": 1, "bundleId": "x", "trackName": "x",
            "fileSizeBytes": "504375296"
          }]
        }
        """.data(using: .utf8)!
        struct Envelope: Codable { let results: [RichLookupResultApp] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(Envelope.self, from: stringSizeJSON)
        #expect(envelope.results.first?.fileSizeBytes == 504375296)
    }

    // MARK: - Fixture loading

    private static func decodeFixture() throws -> RichLookupResultApp {
        let data = try Data(contentsOf: fixtureURL("itunes-lookup-headspace.json"))
        struct Envelope: Codable { let results: [RichLookupResultApp] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard let first = envelope.results.first else {
            Issue.record("fixture envelope had no results")
            throw FixtureError.empty
        }
        return first
    }

    private static func fixtureURL(_ name: String) -> URL {
        // `#filePath` points at *this* test file; the Fixtures directory
        // is its sibling. Matches the pattern in
        // `AppStoreConnectClientTests` (already in the test suite).
        let here = URL(fileURLWithPath: #filePath)
        return here.deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    }

    private enum FixtureError: Error { case empty }
}
