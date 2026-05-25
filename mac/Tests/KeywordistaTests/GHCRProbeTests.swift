import XCTest

@testable import Keywordista

/// GHCRProbe.parseGHCRRef is the pure-function entry point worth
/// pinning — the rest of the probe is HTTP work tested end-to-end
/// against the real GHCR (touching it from a unit test would
/// introduce network flakiness + rate-limit concerns).
final class GHCRProbeTests: XCTestCase {

    // ── parseGHCRRef ─────────────────────────────────────────────────

    func testParsesGHCRRefWithTag() {
        let parsed = GHCRProbe.parseGHCRRef("ghcr.io/bootuz/keywordista:1.0.0")
        XCTAssertEqual(parsed?.repo, "bootuz/keywordista")
        XCTAssertEqual(parsed?.reference, "1.0.0")
    }

    func testParsesGHCRRefWithLatestImplicit() {
        // No tag in the ref → assume :latest. Matches Docker CLI
        // semantics and matches what the cockpit's pre-M3.14 hardcoded
        // ref looked like.
        let parsed = GHCRProbe.parseGHCRRef("ghcr.io/bootuz/keywordista")
        XCTAssertEqual(parsed?.repo, "bootuz/keywordista")
        XCTAssertEqual(parsed?.reference, "latest")
    }

    func testParsesGHCRRefWithDigest() {
        // Digest-pinned refs use @sha256: instead of :tag. Critical
        // because the Plan §4.6 commitment is to digest-pin for
        // repeatable deploys — the probe needs to support both shapes.
        let ref = "ghcr.io/bootuz/keywordista@sha256:abc123def456"
        let parsed = GHCRProbe.parseGHCRRef(ref)
        XCTAssertEqual(parsed?.repo, "bootuz/keywordista")
        XCTAssertEqual(parsed?.reference, "sha256:abc123def456")
    }

    func testReturnsNilForNonGHCRRef() {
        // Docker Hub refs, private registries, garbage all return nil
        // — the probe skips them. The cockpit's fallback is "let the
        // deploy attempt surface any issue."
        XCTAssertNil(GHCRProbe.parseGHCRRef("docker.io/library/postgres:16"))
        XCTAssertNil(GHCRProbe.parseGHCRRef("private.example.com/myimage:1"))
        XCTAssertNil(GHCRProbe.parseGHCRRef("just-a-string"))
    }

    func testCaseInsensitiveGHCRPrefix() {
        // Defensive — users might paste GHCR.IO/... or Ghcr.io/...
        // Don't reject them.
        let parsed = GHCRProbe.parseGHCRRef("GHCR.IO/bootuz/keywordista:latest")
        XCTAssertEqual(parsed?.repo, "bootuz/keywordista")
    }

    // ── ProbeError descriptions ──────────────────────────────────────

    func testNotPublicErrorMentionsPackageSettings() {
        let err = ProbeError.notPublic(ref: "ghcr.io/x/y:1")
        XCTAssertTrue(err.description.contains("ghcr.io/x/y:1"))
        XCTAssertTrue(err.description.contains("Public"),
                     "must mention 'Public' so user knows what to look for in GitHub UI")
    }

    func testTagNotPublishedErrorMentionsWorkflow() {
        let err = ProbeError.tagNotPublished(ref: "ghcr.io/x/y:1.2.3")
        XCTAssertTrue(err.description.contains("image-v*"),
                     "must hint at the GitHub workflow trigger tag pattern")
    }

    // ── CockpitConfig ────────────────────────────────────────────────

    func testImageRefDefaultsToCanonical() {
        // Default (no env override): the canonical bootuz image.
        // Pin so a typo here surfaces immediately rather than at
        // the next user's deploy.
        XCTAssertEqual(
            CockpitConfig.imageRef,
            ProcessInfo.processInfo.environment["KEYWORDISTA_COCKPIT_IMAGE_REF"]
                ?? "ghcr.io/bootuz/keywordista:latest"
        )
    }
}
