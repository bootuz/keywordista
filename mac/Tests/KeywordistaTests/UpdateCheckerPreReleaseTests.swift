import XCTest

@testable import Keywordista

/// Pins the M3.18 pre-release filter. The bug this guards against:
/// without it, tagging `service-v0.5.0-beta1` would trigger
/// UpdateChecker on every stable user (currently on v0.4.x) to
/// silently see "Update available: 0.5.0-beta1" and prompt them to
/// upgrade to the beta. Filed only after manually catching it during
/// the audit before tagging the first beta release.
final class UpdateCheckerPreReleaseTests: XCTestCase {

    // MARK: - Fixtures

    private func release(
        tag: String,
        prerelease: Bool,
        zipName: String = "service.zip"
    ) -> UpdateChecker.GitHubRelease {
        UpdateChecker.GitHubRelease(
            tagName: tag,
            prerelease: prerelease,
            assets: [.init(
                name: zipName,
                browserDownloadURL: "https://example.test/\(tag)/\(zipName)"
            )]
        )
    }

    // MARK: - The headline guarantee

    func testIgnoresPreReleaseEvenWhenItHasTheHighestVersion() {
        // Production scenario at the moment of M3.18 landing:
        // GitHub Releases has stable v0.4.0 + the about-to-tag
        // beta v0.5.0-beta1. UpdateChecker MUST pick v0.4.0.
        let releases = [
            release(tag: "service-v0.4.0", prerelease: false),
            release(tag: "service-v0.5.0-beta1", prerelease: true),
        ]
        let picked = UpdateChecker.pickLatestStableRelease(from: releases)
        XCTAssertEqual(picked?.version, "0.4.0",
                       "stable users must not be auto-prompted to install pre-releases")
    }

    func testPicksHighestStableWhenMultipleExist() {
        let releases = [
            release(tag: "service-v0.3.0", prerelease: false),
            release(tag: "service-v0.4.2", prerelease: false),
            release(tag: "service-v0.4.0", prerelease: false),
            release(tag: "service-v0.5.0-beta1", prerelease: true),
        ]
        let picked = UpdateChecker.pickLatestStableRelease(from: releases)
        XCTAssertEqual(picked?.version, "0.4.2")
    }

    // MARK: - The escape hatches

    func testReturnsPreReleaseWhenItsTheOnlyOption() {
        // Edge case: the project has ONLY pre-releases so far (early
        // days). Filter still applies — UpdateChecker returns nil
        // rather than fall back to pre-releases. The user sees
        // "no update available" and stays put. Correct because beta
        // users should opt in explicitly, not auto-bump silently.
        let releases = [
            release(tag: "service-v0.5.0-beta1", prerelease: true),
            release(tag: "service-v0.5.0-beta2", prerelease: true),
        ]
        let picked = UpdateChecker.pickLatestStableRelease(from: releases)
        XCTAssertNil(picked)
    }

    func testReturnsNilForEmptyList() {
        XCTAssertNil(UpdateChecker.pickLatestStableRelease(from: []))
    }

    // MARK: - Tag-prefix filter (existing M0 behavior, pinned here too)

    func testIgnoresReleasesFromOtherStreams() {
        // The release-app and release-image workflows also publish
        // releases on this same GitHub repo. UpdateChecker must
        // only pick service-v* — picking app-v* or image-v* would
        // download a DMG and try to extract it as a service binary,
        // which would visibly fail. Filter exists since M0 but
        // pinning here too because M3.18 reorganized the function.
        let releases = [
            release(tag: "app-v0.5.0-beta1", prerelease: true),
            release(tag: "app-v0.4.0", prerelease: false),
            release(tag: "image-v0.1.1", prerelease: false),
            release(tag: "service-v0.4.0", prerelease: false),
        ]
        let picked = UpdateChecker.pickLatestStableRelease(from: releases)
        XCTAssertEqual(picked?.version, "0.4.0",
                       "only service-v* should match")
    }

    func testIgnoresReleasesWithoutZipAsset() {
        // Incomplete/in-progress release uploads have no asset yet.
        // Skip them rather than trying to download from nothing.
        let releases = [
            UpdateChecker.GitHubRelease(
                tagName: "service-v0.5.0",
                prerelease: false,
                assets: []   // no .zip yet
            ),
            release(tag: "service-v0.4.0", prerelease: false),
        ]
        let picked = UpdateChecker.pickLatestStableRelease(from: releases)
        XCTAssertEqual(picked?.version, "0.4.0",
                       "should fall back to the previous stable when newest has no asset")
    }

    func testIgnoresReleasesWhereAssetIsntZip() {
        // The .sha256 file is also an asset on the release; UpdateChecker
        // wants the .zip, not the checksum.
        let release = UpdateChecker.GitHubRelease(
            tagName: "service-v0.4.0",
            prerelease: false,
            assets: [
                .init(name: "service-0.4.0.sha256",
                      browserDownloadURL: "https://x.test/0.4.0.sha256"),
            ]
        )
        let picked = UpdateChecker.pickLatestStableRelease(from: [release])
        XCTAssertNil(picked, "non-.zip assets must not be picked as download URL")
    }
}
