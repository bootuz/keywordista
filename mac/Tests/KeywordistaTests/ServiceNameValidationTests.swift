import XCTest

@testable import Keywordista

/// Pins the Render service-name regex semantics. The bug this exists
/// to prevent: a user typing `studio_prod` in the cockpit (underscore)
/// causes Render to deploy at `studio-prod.onrender.com` (hyphen,
/// auto-normalized) — but the cockpit's URL prediction uses the raw
/// name verbatim and bakes `studio_prod.onrender.com` into
/// KEYWORDISTA_PUBLIC_BASE_URL. Invite links then resolve to a
/// non-existent host. Caught the hard way during the first real
/// Render deploy.
final class ServiceNameValidationTests: XCTestCase {

    private let provider = RenderProvider()

    // ── Valid names ──────────────────────────────────────────────────

    func testAcceptsValidHyphenatedName() {
        XCTAssertEqual(provider.validateServiceName("studio-prod"), .ok)
    }

    func testAcceptsAlphanumericOnly() {
        XCTAssertEqual(provider.validateServiceName("keywordista"), .ok)
        XCTAssertEqual(provider.validateServiceName("kw123"), .ok)
        XCTAssertEqual(provider.validateServiceName("123app"), .ok)
    }

    func testAcceptsAtMaxLength() {
        let thirty = String(repeating: "a", count: 30)
        XCTAssertEqual(provider.validateServiceName(thirty), .ok)
    }

    // ── Bad names — the bugs we're guarding against ─────────────────

    func testRejectsUnderscoreWithSpecificMessage() {
        // THE founding-bug case. Specific message matters because the
        // failure mode (silent invite-link breakage) is subtle and the
        // user needs to know exactly why.
        let result = provider.validateServiceName("studio_prod")
        guard case .invalid(let msg) = result else {
            XCTFail("expected .invalid, got \(result)"); return
        }
        XCTAssertTrue(msg.contains("underscore"))
        XCTAssertTrue(msg.contains("hyphen"))
    }

    func testRejectsUppercase() {
        let result = provider.validateServiceName("Studio-Prod")
        guard case .invalid(let msg) = result else {
            XCTFail("expected .invalid"); return
        }
        XCTAssertTrue(msg.contains("lowercase"))
    }

    func testRejectsLeadingHyphen() {
        let result = provider.validateServiceName("-studio")
        guard case .invalid(let msg) = result else {
            XCTFail("expected .invalid"); return
        }
        XCTAssertTrue(msg.contains("letter or digit"))
    }

    func testRejectsEmpty() {
        let result = provider.validateServiceName("")
        guard case .invalid(let msg) = result else {
            XCTFail("expected .invalid"); return
        }
        XCTAssertTrue(msg.contains("empty"))
    }

    func testRejectsOver30Chars() {
        let thirtyOne = String(repeating: "a", count: 31)
        let result = provider.validateServiceName(thirtyOne)
        guard case .invalid(let msg) = result else {
            XCTFail("expected .invalid"); return
        }
        XCTAssertTrue(msg.contains("30"))
    }

    func testRejectsSpaces() {
        let result = provider.validateServiceName("studio prod")
        XCTAssertFalse(result.isValid)
    }

    func testRejectsSpecialCharacters() {
        for special in [".", "/", "@", "+", "=", ":", "%"] {
            let result = provider.validateServiceName("studio\(special)prod")
            XCTAssertFalse(result.isValid,
                          "expected '\(special)' to be rejected")
        }
    }

    // ── Convenience helpers ──────────────────────────────────────────

    func testIsValidConvenienceMatchesCase() {
        XCTAssertTrue(ServiceNameValidation.ok.isValid)
        XCTAssertFalse(ServiceNameValidation.invalid("nope").isValid)
    }

    func testErrorMessageConvenienceReturnsCorrectShape() {
        XCTAssertNil(ServiceNameValidation.ok.errorMessage)
        XCTAssertEqual(
            ServiceNameValidation.invalid("specific reason").errorMessage,
            "specific reason"
        )
    }
}
