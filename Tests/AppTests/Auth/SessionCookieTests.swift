@testable import App
import Foundation
import Testing
import Vapor

@Suite("SessionCookie")
struct SessionCookieTests {

    @Test("Name is stable and matches the documented contract")
    func nameIsPinned() {
        // Renaming this requires updating: cockpit session inspector
        // tooling, frontend cookie-clear code, docs/architecture/.
        // Pinning here to make the rename require an intentional
        // multi-file edit.
        #expect(SessionCookie.name == "keywordista_session")
    }

    // ── value(token:expiresAt:) ──────────────────────────────────────

    @Suite("value()")
    struct ValueTests {

        @Test("Stores the token verbatim as the cookie value")
        func tokenStored() {
            let token = "abc123-token"
            let v = SessionCookie.value(token: token, expiresAt: Date().addingTimeInterval(60))
            #expect(v.string == token)
        }

        @Test("Sets all three security flags: HttpOnly + Secure + SameSite=Strict")
        func securityFlags() {
            let v = SessionCookie.value(token: "x", expiresAt: Date().addingTimeInterval(60))
            #expect(v.isHTTPOnly == true)
            #expect(v.isSecure == true)
            #expect(v.sameSite == .strict)
        }

        @Test("Expires matches the supplied expiresAt")
        func expiryMatches() {
            let when = Date(timeIntervalSince1970: 1_700_000_000)
            let v = SessionCookie.value(token: "x", expiresAt: when)
            #expect(v.expires == when)
        }
    }

    // ── cleared() ────────────────────────────────────────────────────

    @Suite("cleared()")
    struct ClearedTests {

        @Test("Empty value")
        func emptyValue() {
            #expect(SessionCookie.cleared().string == "")
        }

        @Test("Already-expired (epoch zero) so the browser drops it immediately")
        func epochExpiry() {
            #expect(SessionCookie.cleared().expires == Date(timeIntervalSince1970: 0))
        }

        @Test("Same security flags as value() so the browser matches + replaces correctly")
        func sameFlags() {
            // Browsers match Set-Cookie replacements by name+domain+path+
            // sameSite tuple. If `cleared()` had different security flags
            // from `value()`, the browser would *add* a second cookie
            // instead of replacing the first — leaving the active session
            // cookie alive.
            let active = SessionCookie.value(token: "x", expiresAt: Date())
            let clear = SessionCookie.cleared()
            #expect(active.isHTTPOnly == clear.isHTTPOnly)
            #expect(active.isSecure == clear.isSecure)
            #expect(active.sameSite == clear.sameSite)
        }
    }
}
