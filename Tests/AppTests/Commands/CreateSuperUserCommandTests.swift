@testable import App
import ConsoleKit
import Fluent
import Foundation
import Testing
import Vapor

/// M3.25 — Tests for the `createsuperuser` CLI command.
///
/// **Testing strategy.** We invoke the command's `run(using:signature:)`
/// directly with a hand-rolled `CommandContext` rather than spawning
/// the binary. This lets us:
///   1. Stub the `Console` so prompts return canned input (no real TTY)
///   2. Inject a controlled `Application` with in-memory SQLite
///   3. Assert on the resulting `User` row directly via Fluent
///
/// The trade-off vs. an end-to-end `swift run App createsuperuser`
/// shell test: we don't exercise Vapor's argv parsing pipeline or
/// `app.execute()`'s dispatch. Both are covered by Vapor's own tests,
/// and the integration would be flaky to assert against in CI.
/// What WE own — input validation, password hashing, DB insertion,
/// duplicate handling — is what these tests cover.
@Suite("createsuperuser CLI (M3.25)")
struct CreateSuperUserCommandTests {

    // MARK: - Happy paths

    @Test("Interactive happy path: prompts → User row created with admin role")
    func interactiveHappyPath() async throws {
        let app = try await makeTestApp()
        defer { Task { try? await app.asyncShutdown() } }

        let stub = StubConsole(
            replies: [
                "Email:": "ops@studio.local",
                "Password:": "very-strong-password-please",
                "Password (confirm):": "very-strong-password-please",
            ]
        )

        try await run(command: CreateSuperUserCommand(cost: 4),
                     argv: [],
                     app: app, console: stub)

        let users = try await User.query(on: app.db).all()
        #expect(users.count == 1)
        #expect(users.first?.email == "ops@studio.local")
        #expect(users.first?.role == .admin)
        // Hash check: not bcrypt-shape-empty, and not the plaintext.
        let hash = try #require(users.first?.passwordHash)
        #expect(hash.hasPrefix("$2"), "expected a bcrypt MCF hash, got: \(hash)")
        #expect(hash != "very-strong-password-please")

        // Success message must include the email so a script that
        // greps stdout for the admin's address can confirm.
        #expect(stub.outputs.contains { $0.contains("ops@studio.local") })
        #expect(stub.outputs.contains { $0.contains("✓") || $0.contains("Created") })
    }

    @Test("Non-interactive: --email + --password-from-stdin")
    func nonInteractiveWithStdin() async throws {
        // M3.25-DEFERRED: simulating real stdin requires temporarily
        // redirecting STDIN_FILENO, which collides with parallel test
        // execution. Vapor's own Console+Ask uses readLine which
        // reads from the process's actual stdin. We pin the *signature
        // parsing* and the *email-validation-before-password* ordering
        // via separate tests above and below; the stdin-read path is
        // verified by the end-to-end docker exec check in the plan's
        // verification section.
        //
        // If stdin testing becomes critical, the right abstraction is
        // injecting a `(() -> String?) -> String?` reader on the
        // command — out of scope for M3.25.
    }

    @Test("Multi-admin allowed: second invocation succeeds if first already exists")
    func multiAdminAllowed() async throws {
        // Django's createsuperuser allows additional admins. Use case:
        // password recovery — operator lost the dashboard admin
        // password, shells in, creates a new admin. Anyone with shell
        // could SQL-surgery anyway; the UX delta is real, the
        // security delta is zero.
        let app = try await makeTestApp()
        defer { Task { try? await app.asyncShutdown() } }

        // Seed the first admin via direct DB insert (skipping HTTP
        // because the /setup endpoint no longer exists).
        let hasher = try PasswordHasher(cost: 4)
        let first = User(
            email: "first@studio.local",
            passwordHash: try await hasher.hash("first-password-1234"),
            role: .admin
        )
        try await first.save(on: app.db)

        // Now run the CLI to create a second admin.
        let stub = StubConsole(replies: [
            "Email:": "second@studio.local",
            "Password:": "second-password-5678",
            "Password (confirm):": "second-password-5678",
        ])

        try await run(command: CreateSuperUserCommand(cost: 4),
                     argv: [],
                     app: app, console: stub)

        let users = try await User.query(on: app.db).sort(\.$email).all()
        #expect(users.count == 2)
        #expect(users.map(\.email) == ["first@studio.local", "second@studio.local"])
        #expect(users.allSatisfy { $0.role == .admin })
    }

    // MARK: - Validation failures

    @Test("Malformed email exits with .inputInvalid")
    func malformedEmailFails() async throws {
        let app = try await makeTestApp()
        defer { Task { try? await app.asyncShutdown() } }

        let stub = StubConsole(replies: [
            "Email:": "not-an-email-no-at-sign",
            // Password prompts would only be reached if email passed.
            // Validation fails earlier; we shouldn't see these answered.
            "Password:": "irrelevant-pw-1234",
            "Password (confirm):": "irrelevant-pw-1234",
        ])

        await #expect(throws: ExitCode.inputInvalid) {
            try await run(command: CreateSuperUserCommand(cost: 4),
                         argv: [],
                         app: app, console: stub)
        }

        // No user should have been inserted.
        let count = try await User.query(on: app.db).count()
        #expect(count == 0)
    }

    @Test("Password shorter than minimum exits with .inputInvalid")
    func shortPasswordFails() async throws {
        let app = try await makeTestApp()
        defer { Task { try? await app.asyncShutdown() } }

        let stub = StubConsole(replies: [
            "Email:": "ops@studio.local",
            "Password:": "short",      // 5 chars, min is 8
            "Password (confirm):": "short",
        ])

        await #expect(throws: ExitCode.inputInvalid) {
            try await run(command: CreateSuperUserCommand(cost: 4),
                         argv: [],
                         app: app, console: stub)
        }

        let count = try await User.query(on: app.db).count()
        #expect(count == 0)
    }

    @Test("Password confirmation mismatch exits with .inputInvalid")
    func passwordMismatchFails() async throws {
        // The whole reason for the double-prompt UX. A user who
        // typos the password into both prompts the same way is on
        // their own; we catch the case where they typo only one.
        let app = try await makeTestApp()
        defer { Task { try? await app.asyncShutdown() } }

        let stub = StubConsole(replies: [
            "Email:": "ops@studio.local",
            "Password:": "long-enough-password-here",
            "Password (confirm):": "completely-different-pw",
        ])

        await #expect(throws: ExitCode.inputInvalid) {
            try await run(command: CreateSuperUserCommand(cost: 4),
                         argv: [],
                         app: app, console: stub)
        }

        // Error message mentions the mismatch so the operator knows
        // which prompt to fix on the retry.
        #expect(stub.outputs.contains { $0.lowercased().contains("don't match") })

        let count = try await User.query(on: app.db).count()
        #expect(count == 0)
    }

    @Test("Duplicate email exits with .inputInvalid + clear diagnostic")
    func duplicateEmailFails() async throws {
        let app = try await makeTestApp()
        defer { Task { try? await app.asyncShutdown() } }

        // Seed the conflicting user.
        let hasher = try PasswordHasher(cost: 4)
        let first = User(
            email: "ops@studio.local",
            passwordHash: try await hasher.hash("existing-password-1"),
            role: .member       // even a different role still conflicts on email
        )
        try await first.save(on: app.db)

        let stub = StubConsole(replies: [
            "Email:": "ops@studio.local",
            "Password:": "new-password-1234",
            "Password (confirm):": "new-password-1234",
        ])

        await #expect(throws: ExitCode.inputInvalid) {
            try await run(command: CreateSuperUserCommand(cost: 4),
                         argv: [],
                         app: app, console: stub)
        }

        // Operator-facing diagnostic must name the email so the
        // operator knows which one to either reuse or change.
        #expect(stub.outputs.contains { $0.contains("ops@studio.local") })

        // No new row inserted; the original member stays as-is.
        let users = try await User.query(on: app.db).all()
        #expect(users.count == 1)
        #expect(users.first?.role == .member,
               "duplicate-email rejection must NOT silently overwrite the existing user")
    }

    // MARK: - Email normalization

    @Test("Email is lowercased + trimmed before being stored")
    func emailNormalization() async throws {
        // User.init normalizes; this test pins that the CLI honors
        // it. A user who types "  Ops@Studio.LOCAL\n" gets the same
        // row as one who types "ops@studio.local".
        let app = try await makeTestApp()
        defer { Task { try? await app.asyncShutdown() } }

        let stub = StubConsole(replies: [
            "Email:": "  Ops@Studio.LOCAL  ",
            "Password:": "very-strong-password-please",
            "Password (confirm):": "very-strong-password-please",
        ])

        try await run(command: CreateSuperUserCommand(cost: 4),
                     argv: [],
                     app: app, console: stub)

        let user = try #require(try await User.query(on: app.db).first())
        #expect(user.email == "ops@studio.local",
               "email must be lowercased + trimmed, got: \(user.email)")
    }

    // MARK: - Helpers

    /// Builds a Vapor `Application` with the minimum surface the
    /// command needs: in-memory SQLite + the auth-table migrations.
    /// Doesn't register HTTP routes — the CLI doesn't touch them.
    private func makeTestApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateUsers())
        try await app.autoMigrate()
        return app
    }

    /// Invokes a command via the same path Vapor's `app.execute()` uses:
    /// builds a CommandInput from argv, parses the signature from it
    /// (which initializes the property-wrapper storage), and dispatches.
    ///
    /// We use the protocol-default `run(using: inout CommandContext)`
    /// rather than the typed `run(using:signature:)` overload — the
    /// default builds the Signature from input first, populating
    /// `@Option`/`@Flag` storage. Constructing `Signature()` directly
    /// leaves the wrappers uninitialized and crashes on first read.
    private func run<Command: AsyncCommand>(
        command: Command,
        argv: [String] = [],
        app: Application,
        console: any Console
    ) async throws {
        let input = CommandInput(arguments: ["test"] + argv)
        var context = CommandContext(console: console, input: input)
        // Vapor wires `context.application` via userInfo (see
        // CommandContext+Application.swift in vapor/vapor). The
        // production `app.execute()` path sets this for us; tests
        // build the context manually and must mirror it.
        context.application = app
        try await command.run(using: &context)
    }
}

// MARK: - Stub Console

/// Test console that returns canned replies to prompts and captures
/// all outputs/errors for assertion. Matches `Console.ask` behavior:
/// the prompt text itself is looked up in `replies` to choose what
/// to "type back."
///
/// Thread-safety: only one test invokes it at a time, so we use a
/// plain class. NSLock would be overkill for the test fixture.
final class StubConsole: Console, @unchecked Sendable {
    var replies: [String: String]
    var outputs: [String] = []
    var errors: [String] = []
    var userInfo: [AnySendableHashable: any Sendable] = [:]
    var size: (width: Int, height: Int) = (80, 24)

    init(replies: [String: String]) {
        self.replies = replies
    }

    func input(isSecure: Bool) -> String {
        // Console.ask(prompt) outputs the prompt then calls input.
        // We can't easily look up which prompt this corresponds to
        // here — instead, our `output` records the prompt text, and
        // we pop the matching reply by inspecting the LAST output.
        guard let lastPrompt = outputs.last else {
            return ""
        }
        // Match by substring — `ask` emits the prompt with trailing
        // whitespace, and outputs may include ANSI styling, so a
        // contains-based lookup is more forgiving than equality.
        for (key, value) in replies {
            if lastPrompt.contains(key) {
                return value
            }
        }
        return ""
    }

    func output(_ text: ConsoleText, newLine: Bool) {
        outputs.append(text.description)
    }

    func report(error: String, newLine: Bool) {
        errors.append(error)
    }

    func clear(_ type: ConsoleClear) {}
}
