@testable import App
import Foundation
import Testing

@Suite("User model")
struct UserTests {

    // ── Email normalization ──────────────────────────────────────────

    @Suite("Email normalization")
    struct EmailNormalizationTests {

        @Test("init lowercases the email")
        func lowercase() {
            let u = User(email: "You@Studio.COM", passwordHash: stubHash, role: .member)
            #expect(u.email == "you@studio.com")
        }

        @Test("init trims leading and trailing whitespace")
        func trim() {
            let u = User(email: "  you@studio.com\n", passwordHash: stubHash, role: .member)
            #expect(u.email == "you@studio.com")
        }

        @Test("Mixed-case + padded email normalizes to the canonical form")
        func combinedNormalization() {
            let u = User(email: "\t  Boss@Studio.Co.UK  \n", passwordHash: stubHash, role: .admin)
            #expect(u.email == "boss@studio.co.uk")
        }
    }

    // ── Role enum ────────────────────────────────────────────────────

    @Suite("Role")
    struct RoleTests {

        @Test("isAdmin returns true only for .admin")
        func isAdminClassification() {
            #expect(User.Role.admin.isAdmin == true)
            #expect(User.Role.member.isAdmin == false)
        }

        @Test("allCases is exactly [.admin, .member]")
        func allCasesPinned() {
            // If you added a new role and this test fails: update the test
            // AND audit every isAdmin check, AND check whether any existing
            // 'role == .admin' comparisons should change to '.isAdmin'.
            #expect(User.Role.allCases.count == 2)
            #expect(User.Role.allCases.contains(.admin))
            #expect(User.Role.allCases.contains(.member))
        }

        @Test("Role round-trips through JSON encoding as a string")
        func jsonRoundTrip() throws {
            // Fluent's @Field uses the Codable surface to store this
            // column. JSON round-trip == DB round-trip for our purposes.
            for role in User.Role.allCases {
                let data = try JSONEncoder().encode(role)
                let str = String(decoding: data, as: UTF8.self)
                #expect(str == "\"\(role.rawValue)\"")
                let decoded = try JSONDecoder().decode(User.Role.self, from: data)
                #expect(decoded == role)
            }
        }

        @Test("Role rejects an unknown string in JSON decode")
        func jsonRejectsUnknown() {
            let bad = Data("\"superadmin\"".utf8)
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(User.Role.self, from: bad)
            }
        }
    }

    // ── Constructor ──────────────────────────────────────────────────

    @Suite("Construction")
    struct ConstructionTests {

        @Test("Designated init preserves passed-in fields")
        func designatedInit() {
            let id = UUID()
            let created = Date(timeIntervalSince1970: 1_700_000_000)
            let lastLogin = Date(timeIntervalSince1970: 1_700_100_000)
            let u = User(
                id: id,
                email: "you@studio.com",
                passwordHash: stubHash,
                role: .admin,
                createdAt: created,
                lastLoginAt: lastLogin
            )
            #expect(u.id == id)
            #expect(u.email == "you@studio.com")
            #expect(u.passwordHash == stubHash)
            #expect(u.role == .admin)
            #expect(u.createdAt == created)
            #expect(u.lastLoginAt == lastLogin)
        }

        @Test("Fluent-required default init does not crash")
        func defaultInit() {
            // Fluent requires a zero-arg init to materialize rows from
            // query results. We never call it directly; this test just
            // pins the requirement so a future refactor doesn't break
            // Fluent's contract silently.
            _ = User()
        }
    }
}

// MARK: - Test helpers

/// A canonical bcrypt MCF string used everywhere we need a non-empty
/// `passwordHash` but don't actually want to test bcrypt itself
/// (M1.2's PasswordHasherTests cover that). 60 chars total, valid `$2b$`
/// prefix, deterministic so test failures are easy to spot.
private let stubHash = "$2b$12$" + String(repeating: "a", count: 53)
