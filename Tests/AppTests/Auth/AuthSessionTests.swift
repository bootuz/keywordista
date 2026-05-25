@testable import App
import Foundation
import Testing

@Suite("AuthSession model")
struct AuthSessionTests {

    // ── Token generation ─────────────────────────────────────────────

    @Suite("Token generation")
    struct TokenTests {

        @Test("generateToken produces a 43-char base64url string")
        func tokenShape() {
            // 32 bytes → ceil(32 * 4/3) = 43 chars without padding.
            // base64url alphabet: A-Z, a-z, 0-9, '-', '_'.
            let token = AuthSession.generateToken()
            #expect(token.count == 43)
            let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
            #expect(token.allSatisfy { allowed.contains($0) })
        }

        @Test("generateToken yields unique values across many calls")
        func tokenUniqueness() {
            // 256-bit space — collisions in 1000 calls would be a
            // catastrophic RNG failure, not statistical bad luck.
            let tokens = (0..<1000).map { _ in AuthSession.generateToken() }
            #expect(Set(tokens).count == 1000)
        }

        @Test("Token contains no padding characters")
        func tokenNoPadding() {
            // Strict base64url has no '=' padding (RFC 4648 §5).
            // Cookie-safety: '=' is reserved in cookie values per RFC 6265.
            for _ in 0..<50 {
                let token = AuthSession.generateToken()
                #expect(!token.contains("="))
                #expect(!token.contains("+"))
                #expect(!token.contains("/"))
            }
        }
    }

    // ── Expiry math ──────────────────────────────────────────────────

    @Suite("Expiry")
    struct ExpiryTests {

        @Test("expiry(fromNow:) adds the right number of days")
        func expiryAddsDays() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let in30 = AuthSession.expiry(fromNow: 30, now: now)
            #expect(in30.timeIntervalSince(now) == 30 * 86_400)
        }

        @Test("isExpired is false when expiresAt is in the future")
        func notExpired() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let s = AuthSession(userID: UUID(), token: "tok", expiresAt: now.addingTimeInterval(60))
            #expect(s.isExpired(at: now) == false)
        }

        @Test("isExpired is true when expiresAt is now or in the past")
        func expiredNow() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let pastSession = AuthSession(userID: UUID(), token: "p", expiresAt: now.addingTimeInterval(-1))
            let exactlyNowSession = AuthSession(userID: UUID(), token: "n", expiresAt: now)
            #expect(pastSession.isExpired(at: now) == true)
            // Equal-to-now is treated as expired (the inequality is <=)
            // so a session that "just" expired won't sneak one more
            // request through the auth middleware.
            #expect(exactlyNowSession.isExpired(at: now) == true)
        }

        @Test("extend slides expiresAt forward by ttlDays")
        func extendSlidesForward() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let s = AuthSession(userID: UUID(), token: "t", expiresAt: now.addingTimeInterval(60))
            // Pretend an hour has passed and the user is still active.
            let later = now.addingTimeInterval(3600)
            s.extend(ttlDays: 30, now: later)
            #expect(s.expiresAt.timeIntervalSince(later) == 30 * 86_400)
        }
    }

    // ── Convenience init ─────────────────────────────────────────────

    @Suite("Convenience init (login path)")
    struct ConvenienceInitTests {

        @Test("init(userID:ttlDays:userAgent:) fills token + expiresAt automatically")
        func loginPathInit() {
            let userID = UUID()
            let s = AuthSession(userID: userID, ttlDays: 7, userAgent: "TestAgent/1.0")
            #expect(s.$user.id == userID)
            #expect(s.token.count == 43)            // generated token shape
            #expect(s.userAgent == "TestAgent/1.0")
            // Expiry is ~7 days from now (give or take a few seconds
            // for test execution time).
            let delta = s.expiresAt.timeIntervalSinceNow
            #expect(delta > 7 * 86_400 - 5)
            #expect(delta < 7 * 86_400 + 5)
        }

        @Test("userAgent is optional and defaults to nil")
        func userAgentOptional() {
            let s = AuthSession(userID: UUID(), ttlDays: 30)
            #expect(s.userAgent == nil)
        }
    }

    // ── Fluent contract ──────────────────────────────────────────────

    @Suite("Fluent contract")
    struct FluentTests {

        @Test("schema name is auth_sessions (pinned for migration compat)")
        func schemaPinned() {
            // If you rename this, every existing DB needs a migration
            // to rename the table — be very deliberate.
            #expect(AuthSession.schema == "auth_sessions")
        }

        @Test("Fluent-required zero-arg init does not crash")
        func defaultInit() {
            _ = AuthSession()
        }

        @Test("Designated init preserves all fields including a custom id")
        func designatedInit() {
            let id = UUID()
            let userID = UUID()
            let created = Date(timeIntervalSince1970: 1_700_000_000)
            let expires = Date(timeIntervalSince1970: 1_700_086_400)
            let s = AuthSession(
                id: id,
                userID: userID,
                token: "fixed-token",
                createdAt: created,
                expiresAt: expires,
                userAgent: "ua"
            )
            #expect(s.id == id)
            #expect(s.$user.id == userID)
            #expect(s.token == "fixed-token")
            #expect(s.createdAt == created)
            #expect(s.expiresAt == expires)
            #expect(s.userAgent == "ua")
        }
    }
}
