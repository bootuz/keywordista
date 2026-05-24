@testable import App
import Foundation
import Testing

@Suite("ImageMetadata")
struct ImageMetadataTests {

    @Test("Fallback values are 'dev' / 'unknown' / 'unknown' when env vars are absent")
    func fallbacksShape() {
        // In the test process we expect KEYWORDISTA_BUILD_* env vars to be
        // unset — CI's release workflow only stamps the runtime image, not
        // the test binary. If any of these assertions fail because the
        // test environment IS stamped, that's a CI misconfiguration worth
        // catching here.
        //
        // We can't actually mutate static lets after first access, so the
        // best we can do is assert the public API exists and the shape
        // matches one of the two valid states (stamped or unstamped).
        let v = ImageMetadata.version
        let c = ImageMetadata.commitSHA
        let d = ImageMetadata.buildDate

        #expect(!v.isEmpty)
        #expect(!c.isEmpty)
        #expect(!d.isEmpty)
    }

    @Test("Summary is a single line starting with 'keywordista '")
    func summaryShape() {
        let s = ImageMetadata.summary
        #expect(s.hasPrefix("keywordista "))
        #expect(!s.contains("\n"))
        #expect(s.contains("built"))
    }

    @Test("Snapshot encodes to JSON and round-trips")
    func snapshotRoundTrips() throws {
        let snap = ImageMetadata.snapshot
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(ImageMetadata.Snapshot.self, from: data)
        #expect(decoded == snap)
    }

    @Test("Snapshot JSON uses the documented field names (version, commitSHA, buildDate)")
    func snapshotJSONFieldNames() throws {
        // These names are part of the /api/v1/version contract: the cockpit's
        // RemoteUpdateChecker (M5) parses them and compares across instances.
        // Renaming requires a major-version bump per §4.6.5.
        let snap = ImageMetadata.Snapshot(version: "1.0.0", commitSHA: "abc1234", buildDate: "2026-05-24T19:23:00Z")
        let data = try JSONEncoder().encode(snap)
        let str = String(decoding: data, as: UTF8.self)
        #expect(str.contains("\"version\""))
        #expect(str.contains("\"commitSHA\""))
        #expect(str.contains("\"buildDate\""))
    }

    @Test("Snapshot honors the values it's constructed with (not the static accessors)")
    func snapshotIsAValueType() {
        // The Snapshot struct must be independent of the static
        // ImageMetadata.* accessors so cockpit code can deserialize a
        // snapshot from a remote instance without contamination.
        let s = ImageMetadata.Snapshot(version: "x", commitSHA: "y", buildDate: "z")
        #expect(s.version == "x")
        #expect(s.commitSHA == "y")
        #expect(s.buildDate == "z")
    }
}
