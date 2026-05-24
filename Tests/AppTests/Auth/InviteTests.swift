@testable import App
import Foundation
import Testing

@Suite("Invite model")
struct InviteTests {

    // ── Convenience init (admin create path) ─────────────────────────

    @Suite("Convenience init")
    struct ConvenienceInitTests {

        @Test("Fills token + expiresAt + createdBy automatically")
        func happyPath() {
            let adminID = UUID()
            let invite = Invite(role: .member, createdByID: adminID, ttlDays: 7)
            #expect(invite.role == .member)
            #expect(invite.token.count == 43)
            #expect(invite.$createdBy.id == adminID)
            #expect(invite.email == nil)            // open invite by default
            #expect(invite.isConsumed == false)
            // expiresAt ~7 days from now (give or take seconds)
            let delta = invite.expiresAt.timeIntervalSinceNow
            #expect(delta > 7 * 86_400 - 5)
            #expect(delta < 7 * 86_400 + 5)
        }

        @Test("Email pre-pin is normalized (lowercased + trimmed)")
        func emailNormalized() {
            let invite = Invite(
                role: .admin,
                email: "  Newbie@Studio.COM\n",
                createdByID: UUID(),
                ttlDays: 7
            )
            #expect(invite.email == "newbie@studio.com")
        }

        @Test("Admin-role invite works (not just member)")
        func adminInviteOK() {
            let i = Invite(role: .admin, createdByID: UUID(), ttlDays: 7)
            #expect(i.role == .admin)
        }
    }

    // ── Expiry ───────────────────────────────────────────────────────

    @Suite("Expiry")
    struct ExpiryTests {

        @Test("Not expired when expiresAt is in the future")
        func futureNotExpired() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let i = makeInvite(expiresAt: now.addingTimeInterval(60))
            #expect(i.isExpired(at: now) == false)
        }

        @Test("Expired at or after expiresAt (boundary inclusive)")
        func boundaryExpired() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let just = makeInvite(expiresAt: now)
            let past = makeInvite(expiresAt: now.addingTimeInterval(-1))
            // Mirror of AuthSession.isExpired's `<=` semantics —
            // exactly-at-now is treated as expired so a fence-post
            // race can't authenticate a stale invite.
            #expect(just.isExpired(at: now) == true)
            #expect(past.isExpired(at: now) == true)
        }
    }

    // ── Consumption ──────────────────────────────────────────────────

    @Suite("Consumption")
    struct ConsumptionTests {

        @Test("Fresh invite is not consumed")
        func freshNotConsumed() {
            let i = makeInvite(expiresAt: Date().addingTimeInterval(60))
            #expect(i.isConsumed == false)
            #expect(i.consumedAt == nil)
            #expect(i.$consumedBy.id == nil)
        }

        @Test("consume(by:at:) sets both consumedAt and consumedBy")
        func consumeSetsBoth() {
            let i = makeInvite(expiresAt: Date().addingTimeInterval(60))
            let acceptorID = UUID()
            let when = Date(timeIntervalSince1970: 1_700_000_000)
            i.consume(by: acceptorID, at: when)
            #expect(i.isConsumed == true)
            #expect(i.consumedAt == when)
            #expect(i.$consumedBy.id == acceptorID)
        }

        @Test("Re-consuming an already-consumed invite updates the timestamps (caller is responsible for first-write-wins)")
        func reConsumeOverwrites() {
            // Documenting current behavior: the model itself doesn't
            // enforce first-write-wins; the AuthController will check
            // isConsumed before calling consume. Pinned here so anyone
            // changing the model to enforce that semantic must
            // explicitly update the test.
            let i = makeInvite(expiresAt: Date().addingTimeInterval(60))
            let firstID = UUID()
            let secondID = UUID()
            i.consume(by: firstID, at: Date(timeIntervalSince1970: 1_000_000_000))
            i.consume(by: secondID, at: Date(timeIntervalSince1970: 2_000_000_000))
            #expect(i.$consumedBy.id == secondID)
            #expect(i.consumedAt == Date(timeIntervalSince1970: 2_000_000_000))
        }
    }

    // ── Designated init (fixtures) ───────────────────────────────────

    @Suite("Designated init")
    struct DesignatedInitTests {

        @Test("Preserves all fields incl. custom id and email normalization")
        func designatedRoundTrip() {
            let id = UUID()
            let adminID = UUID()
            let consumerID = UUID()
            let created = Date(timeIntervalSince1970: 1_700_000_000)
            let expires = Date(timeIntervalSince1970: 1_700_604_800)
            let consumed = Date(timeIntervalSince1970: 1_700_086_400)

            let i = Invite(
                id: id,
                email: "  Pre@Pinned.com  ",
                role: .admin,
                token: "fixed-token",
                createdAt: created,
                expiresAt: expires,
                consumedAt: consumed,
                consumedByID: consumerID,
                createdByID: adminID
            )

            #expect(i.id == id)
            #expect(i.email == "pre@pinned.com")    // normalized
            #expect(i.role == .admin)
            #expect(i.token == "fixed-token")
            #expect(i.createdAt == created)
            #expect(i.expiresAt == expires)
            #expect(i.consumedAt == consumed)
            #expect(i.$consumedBy.id == consumerID)
            #expect(i.$createdBy.id == adminID)
        }
    }

    // ── Token shape ──────────────────────────────────────────────────

    @Suite("Token generation")
    struct TokenTests {

        @Test("generateToken matches AuthSession's shape (43-char base64url)")
        func sameShape() {
            // The two token generators are duplicated (see Invite.swift
            // header); pinning the shape match here means a refactor
            // that diverges them fails this test loudly.
            let inviteToken = Invite.generateToken()
            let sessionToken = AuthSession.generateToken()
            #expect(inviteToken.count == sessionToken.count)
            #expect(inviteToken.count == 43)

            let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
            #expect(inviteToken.allSatisfy { allowed.contains($0) })
        }

        @Test("1000 invite tokens are unique")
        func uniqueness() {
            let tokens = (0..<1000).map { _ in Invite.generateToken() }
            #expect(Set(tokens).count == 1000)
        }
    }

    // ── Schema pin ───────────────────────────────────────────────────

    @Test("schema name is auth_invites (pinned for migration compat)")
    func schemaPinned() {
        #expect(Invite.schema == "auth_invites")
    }
}

// MARK: - Test helpers

private func makeInvite(expiresAt: Date) -> Invite {
    Invite(
        role: .member,
        token: "fixed-token-for-tests",
        expiresAt: expiresAt,
        createdByID: UUID()
    )
}
