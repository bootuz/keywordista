import XCTest

@testable import Keywordista

/// Regression guard for the v0.3.5 bug where the macOS-spawned backend
/// crashed at boot with:
///
///     Fatal error: env var KEYWORDISTA_ENCRYPTION_KEY is required in
///     server mode but is not set.
///
/// Cause: the supervisor never set `KEYWORDISTA_MODE=local`, the manifest
/// at the time defaulted to `.server`, and the encryption-key var was
/// required in server mode. Both halves have since been fixed
/// (supervisor sets the var explicitly + manifest default flipped to
/// `.local`), and the contract is now pinned by these tests so neither
/// can quietly regress.
///
/// These are pure-function tests against `makeChildEnvironment` — no
/// `Process.run()`, no I/O, no actor hops. The full "launch the supervisor
/// against a real server binary" check is a release-pipeline concern.
final class ServiceSupervisorEnvTests: XCTestCase {

    private let publicDir = URL(fileURLWithPath: "/tmp/keywordista-test/Public")
    private let dbPath = "/tmp/keywordista-test/db.sqlite"

    // ── The core contract ────────────────────────────────────────────

    func testSetsModeToLocal() {
        let env = ServiceSupervisor.makeChildEnvironment(
            base: [:],
            publicDir: publicDir,
            dbPath: dbPath
        )

        XCTAssertEqual(
            env["KEYWORDISTA_MODE"], "local",
            "The supervisor MUST set KEYWORDISTA_MODE=local so the spawned " +
            "backend doesn't fall into server mode and demand an " +
            "encryption key it has no way of receiving."
        )
    }

    func testSetsPublicDirAndDatabasePath() {
        let env = ServiceSupervisor.makeChildEnvironment(
            base: [:],
            publicDir: publicDir,
            dbPath: dbPath
        )

        XCTAssertEqual(env["KEYWORDISTA_PUBLIC_DIR"], publicDir.path)
        XCTAssertEqual(env["DATABASE_PATH"], dbPath)
    }

    // ── Inheritance behavior ─────────────────────────────────────────

    func testOurOverridesWinOverInheritedValues() {
        // A contributor with KEYWORDISTA_MODE=server set in their shell
        // (or a stale value from a previous test run) must NOT poison
        // the spawned backend.
        let inherited: [String: String] = [
            "KEYWORDISTA_MODE": "server",
            "KEYWORDISTA_PUBLIC_DIR": "/wrong",
            "DATABASE_PATH": "/wrong/db.sqlite",
        ]

        let env = ServiceSupervisor.makeChildEnvironment(
            base: inherited,
            publicDir: publicDir,
            dbPath: dbPath
        )

        XCTAssertEqual(env["KEYWORDISTA_MODE"], "local")
        XCTAssertEqual(env["KEYWORDISTA_PUBLIC_DIR"], publicDir.path)
        XCTAssertEqual(env["DATABASE_PATH"], dbPath)
    }

    func testPreservesUnrelatedInheritedVariables() {
        // PATH, HOME, dynamic-linker vars, etc. must pass through —
        // Swift binaries need them at runtime.
        let inherited: [String: String] = [
            "PATH": "/usr/local/bin:/usr/bin",
            "HOME": "/Users/test",
            "SOMETHING_ELSE": "value",
        ]

        let env = ServiceSupervisor.makeChildEnvironment(
            base: inherited,
            publicDir: publicDir,
            dbPath: dbPath
        )

        XCTAssertEqual(env["PATH"], "/usr/local/bin:/usr/bin")
        XCTAssertEqual(env["HOME"], "/Users/test")
        XCTAssertEqual(env["SOMETHING_ELSE"], "value")
    }
}
