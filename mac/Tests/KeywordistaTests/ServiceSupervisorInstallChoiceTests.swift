import XCTest

@testable import Keywordista

/// Pins which server install the supervisor launches when both a
/// downloaded service update and the copy bundled in the .app exist.
///
/// The bug this guards: the supervisor used to prefer the downloaded
/// copy unconditionally, so installing a DMG whose bundled server was
/// NEWER than a previously downloaded `service-v*` update kept running
/// the stale download until the next service release.
///
/// Pure-function tests against `chooseServiceInstall` and
/// `parseVersionMarker` — the filesystem probing that builds the
/// candidates stays in the supervisor and isn't exercised here.
final class ServiceSupervisorInstallChoiceTests: XCTestCase {

    private func downloaded(_ version: String?) -> ServiceSupervisor.ServiceInstall {
        ServiceSupervisor.ServiceInstall(
            source: .downloaded,
            binary: URL(fileURLWithPath: "/data/service/keywordista-server"),
            publicDir: URL(fileURLWithPath: "/data/service/Public"),
            version: version
        )
    }

    private func bundled(_ version: String?) -> ServiceSupervisor.ServiceInstall {
        ServiceSupervisor.ServiceInstall(
            source: .bundled,
            binary: URL(fileURLWithPath: "/App.app/Contents/Resources/keywordista-server"),
            publicDir: URL(fileURLWithPath: "/App.app/Contents/Resources/Public"),
            version: version
        )
    }

    // ── Both installs present, both versions known ──────────────────

    func testNewerBundledBeatsStaleDownload() {
        // The founding case: new DMG ships 0.8.0, data dir still holds
        // the 0.7.0 update downloaded under the previous app.
        let choice = ServiceSupervisor.chooseServiceInstall(
            downloaded: downloaded("0.7.0"),
            bundled: bundled("0.8.0")
        )
        XCTAssertEqual(choice, bundled("0.8.0"))
    }

    func testNewerDownloadBeatsOlderBundle() {
        let choice = ServiceSupervisor.chooseServiceInstall(
            downloaded: downloaded("0.7.1"),
            bundled: bundled("0.7.0")
        )
        XCTAssertEqual(choice, downloaded("0.7.1"))
    }

    func testComparesNumericallyNotLexically() {
        // "0.10.0" < "0.9.0" as strings; the semver comparator must win.
        let choice = ServiceSupervisor.chooseServiceInstall(
            downloaded: downloaded("0.10.0"),
            bundled: bundled("0.9.0")
        )
        XCTAssertEqual(choice, downloaded("0.10.0"))
    }

    func testEqualVersionsPreferBundled() {
        // The bundle is stamped with the latest service tag reachable
        // from the commit the DMG was built from, so it carries at least
        // that tag's code (often more). On a tie it's the safer pick.
        let choice = ServiceSupervisor.chooseServiceInstall(
            downloaded: downloaded("0.7.0"),
            bundled: bundled("0.7.0")
        )
        XCTAssertEqual(choice, bundled("0.7.0"))
    }

    // ── Missing / unknown version markers ───────────────────────────

    func testUnmarkedDownloadLosesToMarkedBundle() {
        // Downloads applied by app builds that predate the marker have
        // no version on disk. They're treated as older than any known
        // version; if that guess is wrong the updater re-offers the
        // release and the re-applied copy gets a marker.
        let choice = ServiceSupervisor.chooseServiceInstall(
            downloaded: downloaded(nil),
            bundled: bundled("0.6.2")
        )
        XCTAssertEqual(choice, bundled("0.6.2"))
    }

    func testMarkedDownloadBeatsUnmarkedBundle() {
        let choice = ServiceSupervisor.chooseServiceInstall(
            downloaded: downloaded("0.7.0"),
            bundled: bundled(nil)
        )
        XCTAssertEqual(choice, downloaded("0.7.0"))
    }

    func testBothUnmarkedPreferBundled() {
        let choice = ServiceSupervisor.chooseServiceInstall(
            downloaded: downloaded(nil),
            bundled: bundled(nil)
        )
        XCTAssertEqual(choice, bundled(nil))
    }

    // ── Only one install present ────────────────────────────────────

    func testOnlyDownloadedPresent() {
        let choice = ServiceSupervisor.chooseServiceInstall(
            downloaded: downloaded(nil),
            bundled: nil
        )
        XCTAssertEqual(choice, downloaded(nil))
    }

    func testOnlyBundledPresent() {
        let choice = ServiceSupervisor.chooseServiceInstall(
            downloaded: nil,
            bundled: bundled("0.7.0")
        )
        XCTAssertEqual(choice, bundled("0.7.0"))
    }

    func testNeitherPresent() {
        XCTAssertNil(ServiceSupervisor.chooseServiceInstall(downloaded: nil, bundled: nil))
    }

    // ── Marker parsing ──────────────────────────────────────────────

    func testParsesMarkerTrimmingWhitespace() {
        XCTAssertEqual(ServiceSupervisor.parseVersionMarker("0.7.0\n"), "0.7.0")
        XCTAssertEqual(ServiceSupervisor.parseVersionMarker("  1.2.3  "), "1.2.3")
    }

    func testMissingOrEmptyMarkerIsUnknown() {
        XCTAssertNil(ServiceSupervisor.parseVersionMarker(nil))
        XCTAssertNil(ServiceSupervisor.parseVersionMarker(""))
        XCTAssertNil(ServiceSupervisor.parseVersionMarker(" \n"))
    }

    func testNonNumericMarkerIsUnknown() {
        // compareSemver drops non-numeric parts, so "garbage" would
        // otherwise compare equal to "0.0.0" instead of being unknown.
        XCTAssertNil(ServiceSupervisor.parseVersionMarker("garbage"))
        XCTAssertNil(ServiceSupervisor.parseVersionMarker("0.7.0-beta1"))
        XCTAssertNil(ServiceSupervisor.parseVersionMarker("v0.7.0"))
        XCTAssertNil(ServiceSupervisor.parseVersionMarker("0..1"))
        XCTAssertNil(ServiceSupervisor.parseVersionMarker("+1.2.3"))
    }
}
