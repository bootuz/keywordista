import Fluent
import Foundation
import Vapor

/// M3.25 — Django-style `createsuperuser` CLI subcommand.
///
/// **Why this exists.** Pre-M3.25, raw-`docker run` operators had two
/// admin-bootstrap paths: set `KEYWORDISTA_ADMIN_EMAIL` + `_PASSWORD_HASH`
/// (requires pre-bcrypting the password) or race to `POST /api/v1/auth/setup`
/// before any scanner did. M3.21 added `KEYWORDISTA_SETUP_TOKEN` to gate
/// the second path, but the whole HTTP-endpoint shape is the wrong
/// architectural answer — admin creation doesn't belong on the public
/// network surface at all.
///
/// This command moves admin creation out-of-band, matching Django's
/// `python manage.py createsuperuser`. The operator runs it via
/// `docker exec <container> keywordista createsuperuser` after the
/// container is up. No HTTP endpoint, no race window, no token.
///
/// **The cockpit (M3 menubar app) path is unchanged.** It continues
/// to set `KEYWORDISTA_ADMIN_*` env vars that M3.17 `AdminBootstrap`
/// consumes at first boot. This CLI is the *sibling* path for non-
/// cockpit operators — neither replaces the other.
///
/// ## Invocation
///
/// Interactive (the common case):
/// ```text
/// $ keywordista createsuperuser
/// Email: ops@studio.example.com
/// Password: ********
/// Password (confirm): ********
/// ✓ Created admin: ops@studio.example.com
/// ```
///
/// Scripted (CI, automated provisioning):
/// ```text
/// $ echo "hunter2-very-long" | keywordista createsuperuser \
///       --email=ops@studio.example.com --password-from-stdin
/// ```
///
/// We deliberately do NOT accept `--password=<plaintext>` — plaintext
/// passwords on the command line leak to `ps`, shell history, and
/// process-monitoring tools. `--password-from-stdin` is the only
/// non-interactive password channel, which keeps the secret out of
/// long-lived process state.
///
/// ## Multi-admin behavior
///
/// Creating additional admins is **allowed** even when admins already
/// exist. Django does the same. The use case is password recovery —
/// an operator who's lost the dashboard admin password can shell into
/// the container, run the command, and bootstrap a new admin without
/// resorting to SQL surgery. Anyone with shell access could SQL-
/// surgery anyway, so the security delta is zero and the UX delta is
/// meaningful.
///
/// ## Exit codes
///
/// - `0` — admin created successfully
/// - `64` — input invalid (bad email, weak password, mismatched
///         confirm) — `EX_USAGE` from `sysexits.h`
/// - `69` — DB unavailable / not yet migrated — `EX_UNAVAILABLE`
/// - `73` — cannot prompt (no TTY + missing `--email` or
///         `--password-from-stdin`) — `EX_CANTCREAT`
///
/// Mapped to standard `sysexits.h` codes so shell wrappers, systemd
/// units, and CI orchestrators can branch on them without parsing
/// stderr.
struct CreateSuperUserCommand: AsyncCommand {

    struct Signature: CommandSignature {
        @Option(
            name: "email", short: "e",
            help: "Admin email. If omitted, the command prompts interactively."
        )
        var email: String?

        @Flag(
            name: "password-from-stdin",
            help: "Read password from stdin instead of prompting. Use for scripting."
        )
        var passwordFromStdin: Bool

        init() {}
    }

    var help: String {
        "Create an admin user (Django-style). Prompts for email + password by default; supports --email and --password-from-stdin for scripting."
    }

    /// Bcrypt cost. Injected at command-registration time so the
    /// command doesn't need to re-bootstrap the manifest inside its
    /// run() body — that would re-read every env var on every
    /// invocation AND would crash in tests that don't set
    /// `KEYWORDISTA_MODE`. Production wires this via `configure.swift`
    /// from `try manifest.require(EnvVars.bcryptCost)`.
    let cost: Int

    init(cost: Int) {
        self.cost = cost
    }

    // MARK: - Run

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let console = context.console

        // ── Step 1: Email (validate before asking for password) ───
        // Fail-fast on bad email so the operator doesn't type their
        // password twice and then learn the email was wrong.
        let email: String
        do {
            let raw = signature.email ?? console.ask("Email:")
            email = try AuthInputs.validateEmail(raw)
        } catch let abort as Abort {
            // Reuse AuthInputs's Abort errors so CLI + HTTP paths
            // emit identical validation messages — operators who hit
            // both surfaces see consistent diagnostics.
            console.error("Invalid email: \(abort.reason)")
            throw ExitCode.inputInvalid
        }

        // ── Step 2: Password (interactive double-prompt OR stdin) ──
        let password: String
        if signature.passwordFromStdin {
            // Non-interactive: read everything from stdin up to EOF,
            // strip the trailing newline if present. Confirm step is
            // skipped — the script's own logic owns confirmation.
            guard let line = readLine(strippingNewline: true), !line.isEmpty else {
                console.error("--password-from-stdin: no input on stdin")
                throw ExitCode.inputInvalid
            }
            password = line
        } else {
            let first = console.ask("Password:", isSecure: true)
            let confirm = console.ask("Password (confirm):", isSecure: true)
            guard first == confirm else {
                console.error("Passwords don't match.")
                throw ExitCode.inputInvalid
            }
            password = first
        }

        do {
            try AuthInputs.validatePassword(password)
        } catch let abort as Abort {
            console.error("Invalid password: \(abort.reason)")
            throw ExitCode.inputInvalid
        }

        // ── Step 3: Hash + insert ─────────────────────────────────
        // Reuse the production hasher with the same cost as the rest
        // of the auth layer — injected via init from configure.swift
        // so CLI-produced hashes are indistinguishable from those
        // produced by AdminBootstrap or future signup paths.
        let hasher: PasswordHasher
        do {
            hasher = try PasswordHasher(cost: cost)
        } catch {
            console.error("PasswordHasher init failed (cost=\(cost)): \(error)")
            throw ExitCode.inputInvalid
        }

        let hash: String
        do {
            hash = try await hasher.hash(password)
        } catch {
            console.error("bcrypt hashing failed: \(error)")
            throw ExitCode.inputInvalid
        }

        // Idempotency note: we DON'T pre-check for an existing user
        // with this email. The unique-email DB constraint catches
        // it at insert time, which is both atomic (no TOCTOU race
        // between two concurrent CLI runs) and authoritative (no
        // chance of the check disagreeing with the constraint).
        let user = User(email: email, passwordHash: hash, role: .admin)
        do {
            try await user.save(on: app.db)
        } catch let error as DatabaseError where error.isConstraintFailure {
            console.error("A user with email '\(email)' already exists.")
            throw ExitCode.inputInvalid
        } catch {
            console.error("Database error: \(error)")
            throw ExitCode.dbUnavailable
        }

        console.output("✓ Created admin: \(email)".consoleText(.success))
    }
}

// MARK: - Exit codes

/// `sysexits.h`-aligned exit codes thrown by the command. Vapor's
/// `app.execute()` catches these and propagates the rawValue as the
/// process exit code, so shell wrappers can branch reliably.
enum ExitCode: Int32, Error {
    case inputInvalid = 64       // EX_USAGE
    case dbUnavailable = 69      // EX_UNAVAILABLE
    case cannotPrompt = 73       // EX_CANTCREAT
}
