@testable import App
import Foundation
import Testing
import Vapor

@Suite("UsersController")
struct UsersControllerTests {

    // ── Invite URL construction ──────────────────────────────────────

    @Suite("inviteAcceptURL")
    struct InviteURLTests {

        private func controller(base: String) -> UsersController {
            UsersController(publicBaseURL: URL(string: base)!, inviteTTLDays: 7)
        }

        @Test("Builds /#/invite/<token> against a clean base URL")
        func cleanBase() {
            let url = controller(base: "https://kw.studio.com").inviteAcceptURL(token: "abc123")
            #expect(url.absoluteString == "https://kw.studio.com/#/invite/abc123")
        }

        @Test("Tolerates a trailing slash on the base URL")
        func trailingSlash() {
            let url = controller(base: "https://kw.studio.com/").inviteAcceptURL(token: "abc123")
            #expect(url.absoluteString == "https://kw.studio.com/#/invite/abc123")
        }

        @Test("Preserves the # character (does NOT URL-encode it)")
        func hashUnescaped() {
            // The # is the SPA hash-route marker — must reach the
            // browser literally. URL.appendingPathComponent would
            // escape it as %23, which would break the frontend
            // router. Pinning this so a future "let's use URL APIs
            // for elegance" refactor doesn't silently break invite
            // links.
            let url = controller(base: "https://kw.studio.com").inviteAcceptURL(token: "abc")
            #expect(url.absoluteString.contains("/#/invite/"))
            #expect(!url.absoluteString.contains("%23"))
        }

        @Test("Works with localhost URLs (raw-docker / dev path)")
        func localhost() {
            let url = controller(base: "http://localhost:8080").inviteAcceptURL(token: "tok")
            #expect(url.absoluteString == "http://localhost:8080/#/invite/tok")
        }

        @Test("Real-shape 43-char token round-trips through the URL builder")
        func realToken() {
            let token = Invite.generateToken()
            let url = controller(base: "https://kw.studio.com").inviteAcceptURL(token: token)
            #expect(url.absoluteString.hasSuffix("/#/invite/\(token)"))
        }
    }

    // ── DTO shapes ───────────────────────────────────────────────────

    @Suite("DTOs")
    struct DTOTests {

        @Test("UserListItem(user:) populates from a User")
        func userListItemFromUser() {
            // Use the designated init so we control every field.
            let user = User(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                email: "you@studio.com",
                passwordHash: "$2b$12$" + String(repeating: "a", count: 53),
                role: .admin,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastLoginAt: Date(timeIntervalSince1970: 1_700_100_000)
            )
            let item = UserListItem(user: user)
            #expect(item.id == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
            #expect(item.email == "you@studio.com")
            #expect(item.role == "admin")
            #expect(item.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
            #expect(item.lastLoginAt == Date(timeIntervalSince1970: 1_700_100_000))
        }

        @Test("UserListItem omits password_hash from JSON encoding")
        func noPasswordInJSON() throws {
            let item = UserListItem(
                id: UUID(),
                email: "x@y.com",
                role: "member",
                createdAt: nil,
                lastLoginAt: nil
            )
            let data = try JSONEncoder().encode(item)
            let json = String(decoding: data, as: UTF8.self).lowercased()
            // Belt-and-suspenders: even though UserListItem doesn't
            // HAVE a password field, this test fails loudly if
            // someone adds one in the future without thinking.
            #expect(!json.contains("password"))
            #expect(!json.contains("hash"))
        }

        @Test("InviteCreatedResponse round-trips through JSON")
        func inviteResponseEncodes() throws {
            let token = "fake-token-43-chars-xxxxxxxxxxxxxxxxxxxxxxx"
            let resp = InviteCreatedResponse(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                token: token,
                acceptUrl: URL(string: "https://kw.studio.com/#/invite/\(token)")!,
                role: "member",
                email: "newbie@studio.com",
                expiresAt: Date(timeIntervalSince1970: 1_700_604_800)
            )
            let data = try JSONEncoder().encode(resp)
            let decoded = try JSONDecoder().decode(InviteCreatedResponse.self, from: data)
            #expect(decoded.token == resp.token)
            #expect(decoded.acceptUrl == resp.acceptUrl)
            #expect(decoded.role == "member")
            #expect(decoded.email == "newbie@studio.com")
        }
    }
}
