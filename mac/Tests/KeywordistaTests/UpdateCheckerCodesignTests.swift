import XCTest

@testable import Keywordista

/// Pins the update flow's signature gate to our Developer ID. The bug
/// this guards against: a bare `codesign --verify --strict` only proves
/// *some* valid signature exists, and every arm64 binary gets an ad-hoc
/// signature from the linker for free. Without the team pin, anyone who
/// could alter a GitHub release (or the API response pointing at it)
/// could get an arbitrary binary swapped in and launched.
final class UpdateCheckerCodesignTests: XCTestCase {

    func testRejectsAdHocSignedBinary() throws {
        // The test bundle's own executable is linker-ad-hoc-signed —
        // exactly what an attacker's freshly compiled binary looks like.
        let adHoc = try XCTUnwrap(Bundle(for: Self.self).executableURL)
        XCTAssertThrowsError(try UpdateChecker.verifyCodesign(of: adHoc),
                             "an ad-hoc signature must not pass the update gate")
    }

    func testRejectsBinarySignedByAppleButNotUs() {
        // Validly signed, just not by our team. Proves the check pins
        // the signer rather than accepting any trusted chain.
        XCTAssertThrowsError(try UpdateChecker.verifyCodesign(of: URL(fileURLWithPath: "/bin/ls")),
                             "a binary signed by another identity must not pass the update gate")
    }

    func testAcceptsInstalledReleaseBinary() throws {
        // Positive case needs a real Developer ID-signed release binary,
        // which only exists on a machine that has applied a service
        // update. Skipped in CI.
        let appSupport = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let installed = appSupport.appendingPathComponent("Keywordista/service/keywordista-server")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: installed.path),
                          "no installed release binary on this machine")
        XCTAssertNoThrow(try UpdateChecker.verifyCodesign(of: installed))
    }
}
