import Foundation
import Vapor

// MARK: - Runtime mode
//
// The dual-mode switch from plan §4.1. Local mode is what the macOS menubar
// app spawns (127.0.0.1, no auth, single user, SQLite at ~/Library/...).
// Server mode is what the published Docker image runs (0.0.0.0, auth on,
// multi-user, encryption key required). The mode is itself selected by an
// env var (`KEYWORDISTA_MODE`); a tiny bootstrap path reads it before the
// rest of the manifest is validated.
//
// Adding a third mode (e.g. `.test`) is a SemVer-additive change: existing
// `requiredIn` declarations stay valid because `.onlyInModes` is set-based.

public enum RuntimeMode: String, CaseIterable, Sendable {
    case local
    case server
}

// MARK: - Requirement semantics

/// Where a var must be set explicitly (i.e. has no default that covers it).
/// Used by the boot-time validator and rendered into `--help` and
/// `/api/v1/version/env`.
public enum RequiredIn: Sendable, Equatable {
    case never
    case onlyInModes(Set<RuntimeMode>)

    public func isRequired(in mode: RuntimeMode) -> Bool {
        switch self {
        case .never: return false
        case .onlyInModes(let modes): return modes.contains(mode)
        }
    }

    var modeNames: [String] {
        switch self {
        case .never: return []
        case .onlyInModes(let modes): return modes.map(\.rawValue).sorted()
        }
    }
}

// MARK: - Spec protocol (type-erased face for enumeration)
//
// Concrete `EnvVar<Value>`s have a typed parser but the manifest also needs
// to enumerate every var to render `--help` and `/version/env`. Existential
// `any EnvVarSpec` is the type-erased face: enough to print the help row,
// not enough to read a typed value (that goes through `Manifest.require`/
// `.optional` with the concrete `EnvVar<Value>`).

public protocol EnvVarSpec: Sendable {
    var name: String { get }
    var description: String { get }
    var since: String { get }
    var requiredIn: RequiredIn { get }
    /// `true` if the value is a credential / key; manifest renders `***` for
    /// it in `/version/env` instead of the literal value. Defaults are
    /// always rendered (defaults are not secret).
    var valueIsSecret: Bool { get }
    func renderDefault(for mode: RuntimeMode) -> String?
    func helpRow(width: Int) -> String
}

// MARK: - EnvVar<Value>

public struct EnvVar<Value: Sendable>: EnvVarSpec, Sendable {
    public let name: String
    public let description: String
    public let since: String
    public let requiredIn: RequiredIn
    public let valueIsSecret: Bool

    /// Mode-conditional default. Return `nil` to mean "no default in this
    /// mode" — combined with `requiredIn` this controls whether the boot
    /// validator yells about a missing var.
    public let defaults: @Sendable (RuntimeMode) -> Value?

    /// Human-renderable form of the default for `--help` / `/version/env`.
    /// Decoupled from `defaults` because some defaults are computed (e.g.
    /// "derived from MachineID") and shouldn't expose the raw bytes.
    public let defaultDescription: @Sendable (RuntimeMode) -> String?

    /// Parses the raw env string into `Value`. Throws a parse error with a
    /// human reason; the boot validator wraps it with the var name so the
    /// log line is actionable.
    public let parse: @Sendable (String) throws -> Value

    public init(
        name: String,
        description: String,
        since: String = "1.0",
        requiredIn: RequiredIn = .never,
        valueIsSecret: Bool = false,
        defaults: @escaping @Sendable (RuntimeMode) -> Value? = { _ in nil },
        defaultDescription: @escaping @Sendable (RuntimeMode) -> String? = { _ in nil },
        parse: @escaping @Sendable (String) throws -> Value
    ) {
        self.name = name
        self.description = description
        self.since = since
        self.requiredIn = requiredIn
        self.valueIsSecret = valueIsSecret
        self.defaults = defaults
        self.defaultDescription = defaultDescription
        self.parse = parse
    }

    public func renderDefault(for mode: RuntimeMode) -> String? {
        defaultDescription(mode)
    }

    public func helpRow(width: Int) -> String {
        let req: String
        switch requiredIn {
        case .never: req = "optional"
        case .onlyInModes(let modes):
            req = "required in " + modes.map(\.rawValue).sorted().joined(separator: ",")
        }
        let def = (renderDefault(for: .server) ?? renderDefault(for: .local) ?? "—")
        let head = name.padding(toLength: width, withPad: " ", startingAt: 0)
        return "\(head)  \(req); default: \(def)\n    \(description)"
    }
}

// MARK: - Errors

public enum EnvVarError: Error, CustomStringConvertible {
    case missingRequired(name: String, mode: RuntimeMode)
    /// M3.24c: `valueIsSecret` lets the description redact the raw
    /// value when the var carries secret material (token, key, hash).
    /// Pre-M3.24c this case logged the first 40 chars of `raw` for
    /// every var, leaking secrets to ops logs (and downstream log
    /// drains) when the operator misconfigured them — e.g. pasting
    /// a 15-char SETUP_TOKEN would put the near-complete secret into
    /// the Render Logs tab. Now we substitute "<redacted, N chars>"
    /// for secrets while keeping the count + the reason intact so the
    /// remediation hint stays actionable.
    case parseFailed(name: String, raw: String, reason: String, valueIsSecret: Bool)
    /// `KEYWORDISTA_MODE` is unset. Distinct from `missingRequired` because
    /// the mode itself can't be "required in a mode" (the chicken-and-egg
    /// from `bootstrap`) — its own absence is a fatal, mode-independent
    /// boot error. The remediation goes in the message so anyone hitting
    /// it learns the fix in one read.
    case modeNotSet

    public var description: String {
        switch self {
        case .missingRequired(let name, let mode):
            return "env var \(name) is required in \(mode.rawValue) mode but is not set"
        case .parseFailed(let name, let raw, let reason, let valueIsSecret):
            let display = valueIsSecret
                ? "<redacted, \(raw.count) chars>"
                : String(raw.prefix(40))
            return "env var \(name)=\(display) failed to parse: \(reason)"
        case .modeNotSet:
            return """
                KEYWORDISTA_MODE must be set explicitly to 'local' or 'server'.
                  • local  — single-user, no auth, binds 127.0.0.1 (macOS app, dev loops).
                  • server — multi-user with auth, binds 0.0.0.0; also requires \
                KEYWORDISTA_ENCRYPTION_KEY + KEYWORDISTA_PUBLIC_BASE_URL.
                The published Docker image sets this for you via ENV. For \
                `swift run` dev: prefix with `KEYWORDISTA_MODE=local`.
                """
        }
    }
}

// MARK: - Parsers
//
// Kept private to the manifest so call-sites can't reach around and parse
// raw strings ad-hoc. Adding a new value type means adding a new parser
// here AND a new `EnvVar<T>` in `EnvVars` — exactly two edits, in one file.

enum Parsers {
    static let identity: @Sendable (String) throws -> String = { $0 }

    static let int: @Sendable (String) throws -> Int = { raw in
        guard let v = Int(raw) else {
            throw ParseError("expected integer, got '\(raw)'")
        }
        return v
    }

    static let positiveInt: @Sendable (String) throws -> Int = { raw in
        let v = try int(raw)
        guard v > 0 else { throw ParseError("expected positive integer, got \(v)") }
        return v
    }

    static let bool: @Sendable (String) throws -> Bool = { raw in
        switch raw.lowercased() {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: throw ParseError("expected boolean (true/false/1/0/yes/no), got '\(raw)'")
        }
    }

    static let url: @Sendable (String) throws -> URL = { raw in
        guard let u = URL(string: raw), let scheme = u.scheme,
              scheme == "http" || scheme == "https" else {
            throw ParseError("expected http(s) URL, got '\(raw)'")
        }
        return u
    }

    static let mode: @Sendable (String) throws -> RuntimeMode = { raw in
        guard let m = RuntimeMode(rawValue: raw.lowercased()) else {
            throw ParseError("expected one of: \(RuntimeMode.allCases.map(\.rawValue).joined(separator: ", ")); got '\(raw)'")
        }
        return m
    }

    static let logLevel: @Sendable (String) throws -> Logger.Level = { raw in
        guard let lvl = Logger.Level(rawValue: raw.lowercased()) else {
            throw ParseError("expected one of: trace, debug, info, notice, warning, error, critical; got '\(raw)'")
        }
        return lvl
    }

    static let logFormat: @Sendable (String) throws -> LogFormat = { raw in
        guard let f = LogFormat(rawValue: raw.lowercased()) else {
            throw ParseError("expected one of: json, text; got '\(raw)'")
        }
        return f
    }

    /// Hex-encoded byte string of exactly `expectedBytes` bytes (so 64 chars
    /// for 32 bytes). Used by `KEYWORDISTA_ENCRYPTION_KEY`.
    static func hexBytes(expectedBytes: Int) -> @Sendable (String) throws -> Data {
        { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count == expectedBytes * 2 else {
                throw ParseError("expected \(expectedBytes * 2) hex chars (\(expectedBytes) bytes), got \(trimmed.count)")
            }
            var data = Data()
            data.reserveCapacity(expectedBytes)
            var i = trimmed.startIndex
            while i < trimmed.endIndex {
                let next = trimmed.index(i, offsetBy: 2)
                guard let byte = UInt8(trimmed[i..<next], radix: 16) else {
                    throw ParseError("invalid hex char near position \(trimmed.distance(from: trimmed.startIndex, to: i))")
                }
                data.append(byte)
                i = next
            }
            return data
        }
    }

    /// Hour-of-day 0–23. Used by the daily scheduler tuning vars.
    static let hourOfDay: @Sendable (String) throws -> Int = { raw in
        let v = try int(raw)
        guard (0...23).contains(v) else {
            throw ParseError("expected hour 0–23, got \(v)")
        }
        return v
    }

    /// Pre-bcrypted password hash (Modular Crypt Format, "$2a$"/"$2b$"/"$2y$").
    /// We don't accept plaintext passwords through env vars; the cockpit
    /// hashes locally on the Mac and sends only the hash.
    static let bcryptHash: @Sendable (String) throws -> String = { raw in
        let valid = raw.hasPrefix("$2a$") || raw.hasPrefix("$2b$") || raw.hasPrefix("$2y$")
        guard valid, raw.count >= 59, raw.count <= 64 else {
            throw ParseError("expected bcrypt MCF string starting with $2a$/$2b$/$2y$, got prefix '\(raw.prefix(4))'")
        }
        return raw
    }

    /// Lowercased trimmed email. Validation is intentionally permissive —
    /// the goal is to catch typos, not to fully validate RFC 5321.
    static let email: @Sendable (String) throws -> String = { raw in
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@"), trimmed.contains("."),
              !trimmed.hasPrefix("@"), !trimmed.hasSuffix("@") else {
            throw ParseError("expected email address, got '\(raw)'")
        }
        return trimmed
    }
}

struct ParseError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

// MARK: - LogFormat
//
// Lives next to the manifest because it's the canonical value type for the
// `KEYWORDISTA_LOG_FORMAT` var. The actual log-format wiring (which writes
// JSON to stdout in server mode) is a separate concern, set up in
// configure.swift after the manifest resolves.

public enum LogFormat: String, Sendable {
    case json
    case text
}

// MARK: - The contract (v1.0)
//
// One static `EnvVar<T>` per row of plan §4.6.3. Order matches the docs
// table — `EnvVars.all` is rendered in this order by `--help`. Adding a new
// var: declare it below + append to `all`. Removing or renaming: forbidden
// in v1.x; see §4.6.5 for the SemVer backcompat commitments.

public enum EnvVars {

    // ── Runtime mode ────────────────────────────────────────────

    public static let mode = EnvVar<RuntimeMode>(
        name: "KEYWORDISTA_MODE",
        description: "Runtime mode. `local` skips auth, binds 127.0.0.1; `server` registers auth, binds 0.0.0.0, also requires KEYWORDISTA_ENCRYPTION_KEY + KEYWORDISTA_PUBLIC_BASE_URL. MUST be set explicitly — `Manifest.bootstrap` throws EnvVarError.modeNotSet when this is unset. Docker image sets it via ENV; macOS app sets it via ServiceSupervisor; `swift run` dev loops must prefix the command (`KEYWORDISTA_MODE=local swift run …`).",
        // `.never` here means "the standard validator doesn't require
        // it" — mode is special-cased earlier in bootstrap (chicken-
        // and-egg: validateAll needs a mode to evaluate against), and
        // bootstrap throws .modeNotSet on its own. Don't try to express
        // mode's requirement via RequiredIn; the lifecycle is different.
        requiredIn: .never,
        // Defaults intentionally nil. The `.local` default this had
        // briefly during the v0.3.5 fix would have implied the var
        // was optional — but bootstrap fail-fasts on unset, so the
        // honest signal is "no default; you must set it."
        defaults: { _ in nil },
        defaultDescription: { _ in "(required; set to `local` or `server`)" },
        parse: Parsers.mode
    )

    // ── Listening ───────────────────────────────────────────────

    public static let port = EnvVar<Int>(
        name: "PORT",
        description: "HTTP listen port. Most PaaS providers override this.",
        defaults: { _ in 8080 },
        defaultDescription: { _ in "8080" },
        parse: Parsers.positiveInt
    )

    public static let hostname = EnvVar<String>(
        name: "HOSTNAME",
        description: "Bind address. Rarely overridden; defaults to 0.0.0.0 in server mode, 127.0.0.1 in local.",
        defaults: { mode in mode == .local ? "127.0.0.1" : "0.0.0.0" },
        defaultDescription: { mode in mode == .local ? "127.0.0.1" : "0.0.0.0" },
        parse: Parsers.identity
    )

    // ── Storage ─────────────────────────────────────────────────

    public static let dataDir = EnvVar<String>(
        name: "KEYWORDISTA_DATA_DIR",
        description: "Root directory for derived paths (SQLite file, future uploaded files). Must be writable.",
        defaults: { _ in "/data" },
        defaultDescription: { _ in "/data" },
        parse: Parsers.identity
    )

    public static let databaseURL = EnvVar<String>(
        name: "DATABASE_URL",
        description: "If set and the scheme is postgres://, use Postgres. Takes precedence over DATABASE_PATH.",
        valueIsSecret: true,
        defaults: { _ in nil },
        defaultDescription: { _ in nil },
        parse: Parsers.identity
    )

    public static let databasePath = EnvVar<String>(
        name: "DATABASE_PATH",
        description: "SQLite file path. Ignored if DATABASE_URL is set. Defaults: `db.sqlite` (cwd-relative) in local mode for dev-friendly `swift run`; `/data/db.sqlite` in server mode to match the Docker image's VOLUME mount.",
        defaults: { mode in
            switch mode {
            case .local: return "db.sqlite"
            case .server: return "/data/db.sqlite"
            }
        },
        defaultDescription: { mode in
            switch mode {
            case .local: return "db.sqlite"
            case .server: return "/data/db.sqlite"
            }
        },
        parse: Parsers.identity
    )

    // ── Secrets / crypto ────────────────────────────────────────

    public static let encryptionKey = EnvVar<Data>(
        name: "KEYWORDISTA_ENCRYPTION_KEY",
        description: "64 hex chars (32 bytes). Encrypts ASC .p8, ASA secret, future Web Push private key. Boot fails fast if missing in server mode. In local mode, derived from MachineID via EncryptionKeyResolver when unset.",
        requiredIn: .onlyInModes([.server]),
        valueIsSecret: true,
        defaults: { _ in nil },
        defaultDescription: { mode in mode == .local ? "derived from MachineID" : nil },
        parse: Parsers.hexBytes(expectedBytes: 32)
    )

    // ── Public surface ──────────────────────────────────────────

    public static let publicBaseURL = EnvVar<URL>(
        name: "KEYWORDISTA_PUBLIC_BASE_URL",
        description: "Public URL of this instance, e.g. https://kw.studio.com. Used to render invite links. Boot fails fast if missing in server mode.",
        requiredIn: .onlyInModes([.server]),
        defaults: { _ in nil },
        defaultDescription: { _ in nil },
        parse: Parsers.url
    )

    public static let publicDir = EnvVar<String>(
        name: "KEYWORDISTA_PUBLIC_DIR",
        description: "Path to the built Svelte SPA assets. The macOS menubar app sets this to the bundled (or downloaded) assets dir. Unset in Docker (image bundles the SPA at a known path).",
        defaults: { _ in nil },
        defaultDescription: { _ in "Vapor's app.directory.publicDirectory" },
        parse: Parsers.identity
    )

    // ── Admin bootstrap ─────────────────────────────────────────

    public static let adminEmail = EnvVar<String>(
        name: "KEYWORDISTA_ADMIN_EMAIL",
        description: "If set with KEYWORDISTA_ADMIN_PASSWORD_HASH and the users table is empty at boot, seeds an admin user. The cockpit uses this for pre-baked-credentials deploys.",
        defaults: { _ in nil },
        defaultDescription: { _ in nil },
        parse: Parsers.email
    )

    public static let adminPasswordHash = EnvVar<String>(
        name: "KEYWORDISTA_ADMIN_PASSWORD_HASH",
        description: "bcrypt hash for the bootstrap admin password. Plaintext passwords are NEVER accepted as env vars — the cockpit hashes locally on the Mac.",
        valueIsSecret: true,
        defaults: { _ in nil },
        defaultDescription: { _ in nil },
        parse: Parsers.bcryptHash
    )

    public static let setupToken = EnvVar<String>(
        name: "KEYWORDISTA_SETUP_TOKEN",
        description: "Defense-in-depth for raw-docker-run users who can't pre-seed an admin via KEYWORDISTA_ADMIN_*. When set, POST /api/v1/auth/setup requires the matching value in the X-Keywordista-Setup-Token header — closes the takeover window between deploy and first-run for operators who don't use the cockpit's pre-baked-credentials path. Generate with `openssl rand -hex 32`. Inert once any user exists (setup returns 410 then anyway).",
        // M3.24c (F8): pin the var's actual debut version. The default
        // is "1.0" — leaving that here would misreport this M3.21
        // addition to /version/env as v1.0-vintage and undermine the
        // env-var-as-SemVer-contract guarantee (additive in minor,
        // breaking only in major). Updates that introduce SETUP_TOKEN
        // are 1.1+; pin accordingly.
        since: "1.1",
        valueIsSecret: true,
        defaults: { _ in nil },
        defaultDescription: { _ in nil },
        parse: { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Min 16 chars ≈ 96 bits of entropy from hex/base64. Below that
            // a network attacker could brute-force during the boot window.
            // No max — operators may paste a password-manager string.
            guard trimmed.count >= 16 else {
                throw ParseError("must be at least 16 characters (recommend `openssl rand -hex 32`)")
            }
            return trimmed
        }
    )

    // ── Sign-up & auth policy ───────────────────────────────────

    public static let openSignup = EnvVar<Bool>(
        name: "KEYWORDISTA_OPEN_SIGNUP",
        description: "If true, expose POST /api/v1/auth/signup for public registration. Off by default; invites are the canonical path.",
        defaults: { _ in false },
        defaultDescription: { _ in "false" },
        parse: Parsers.bool
    )

    public static let sessionTTLDays = EnvVar<Int>(
        name: "KEYWORDISTA_SESSION_TTL_DAYS",
        description: "Rolling session expiry in days.",
        defaults: { _ in 30 },
        defaultDescription: { _ in "30" },
        parse: Parsers.positiveInt
    )

    public static let inviteTTLDays = EnvVar<Int>(
        name: "KEYWORDISTA_INVITE_TTL_DAYS",
        description: "Default invite expiry in days.",
        defaults: { _ in 7 },
        defaultDescription: { _ in "7" },
        parse: Parsers.positiveInt
    )

    public static let bcryptCost = EnvVar<Int>(
        name: "KEYWORDISTA_BCRYPT_COST",
        description: "Cost factor for password hashing. Revisit annually.",
        defaults: { _ in 12 },
        defaultDescription: { _ in "12" },
        parse: Parsers.positiveInt
    )

    public static let trustProxy = EnvVar<Bool>(
        name: "KEYWORDISTA_TRUST_PROXY",
        description: "If true, honor X-Forwarded-* headers (providers terminate TLS upstream). Defaults true in server mode, false in local.",
        defaults: { mode in mode == .server },
        defaultDescription: { mode in mode == .server ? "true" : "false" },
        parse: Parsers.bool
    )

    public static let rateLimitAuthPer15Min = EnvVar<Int>(
        name: "KEYWORDISTA_RATE_LIMIT_AUTH_PER_15MIN",
        description: "Per-IP failed-login attempts before 429.",
        defaults: { _ in 5 },
        defaultDescription: { _ in "5" },
        parse: Parsers.positiveInt
    )

    // ── Logging ─────────────────────────────────────────────────

    public static let logLevel = EnvVar<Logger.Level>(
        name: "KEYWORDISTA_LOG_LEVEL",
        description: "trace, debug, info, notice, warning, error, critical. Replaces LOG_LEVEL (kept as alias for one major).",
        defaults: { _ in .info },
        defaultDescription: { _ in "info" },
        parse: Parsers.logLevel
    )

    public static let logFormat = EnvVar<LogFormat>(
        name: "KEYWORDISTA_LOG_FORMAT",
        description: "json for log aggregators, text for humans. Defaults json in server mode, text in local.",
        defaults: { mode in mode == .server ? .json : .text },
        defaultDescription: { mode in mode == .server ? "json" : "text" },
        parse: Parsers.logFormat
    )

    // ── Scheduler tuning ────────────────────────────────────────

    public static let refreshHour = EnvVar<Int>(
        name: "KEYWORDISTA_REFRESH_HOUR",
        description: "Hour (UTC, 0–23) for the daily keyword refresh scheduler. Tunable for low-traffic windows.",
        defaults: { _ in 3 },
        defaultDescription: { _ in "3" },
        parse: Parsers.hourOfDay
    )

    public static let chartsHour = EnvVar<Int>(
        name: "KEYWORDISTA_CHARTS_HOUR",
        description: "Hour (UTC, 0–23) for the chart-position scheduler.",
        defaults: { _ in 4 },
        defaultDescription: { _ in "4" },
        parse: Parsers.hourOfDay
    )

    public static let workerCount = EnvVar<Int>(
        name: "KEYWORDISTA_WORKER_COUNT",
        description: "In-process queue workers. Capped at 1 by design (iTunes API throttling). Future-proofed as a knob in case Apple lifts throttling.",
        defaults: { _ in 1 },
        defaultDescription: { _ in "1" },
        parse: Parsers.positiveInt
    )

    public static let healthcheckPath = EnvVar<String>(
        name: "KEYWORDISTA_HEALTHCHECK_PATH",
        description: "For providers that need a different path. Begins with /.",
        defaults: { _ in "/health" },
        defaultDescription: { _ in "/health" },
        parse: { raw in
            guard raw.hasPrefix("/") else { throw ParseError("must begin with /, got '\(raw)'") }
            return raw
        }
    )

    // ── The enumerated contract ─────────────────────────────────
    //
    // Canonical order. `--help` and `/version/env` render in this order.
    // DO NOT alphabetize. CI test `EnvVarManifestTests.testAllListIsComplete`
    // fails if a static declared above is missing from this list.

    public static let all: [any EnvVarSpec] = [
        mode,
        port, hostname,
        dataDir, databaseURL, databasePath,
        encryptionKey,
        publicBaseURL, publicDir,
        adminEmail, adminPasswordHash, setupToken,
        openSignup, sessionTTLDays, inviteTTLDays, bcryptCost,
        trustProxy, rateLimitAuthPer15Min,
        logLevel, logFormat,
        refreshHour, chartsHour, workerCount,
        healthcheckPath,
    ]
}

// MARK: - Manifest (the boot-time validated state)
//
// `Manifest.bootstrap()` is the single entry point called once at boot
// from configure.swift. It (1) reads KEYWORDISTA_MODE directly (the only
// pre-manifest env read), (2) constructs a Manifest with that mode, and
// (3) validates every `requiredIn` constraint against the resolved mode
// so missing-required-var failures surface BEFORE any other init runs.
//
// After bootstrap, call-sites read typed values via `manifest.require(_:)`
// or `manifest.optional(_:)`. They never call `Environment.get` directly —
// the M0.3 CI script enforces this rule.

public struct Manifest: Sendable {
    public let mode: RuntimeMode

    public init(mode: RuntimeMode) {
        self.mode = mode
    }

    /// One-shot boot validation. Returns a Manifest for the resolved mode,
    /// or throws on (a) bad KEYWORDISTA_MODE value, (b) a `requiredIn`
    /// constraint failing, (c) any parse error encountered while validating.
    public static func bootstrap(env: ManifestEnv = .processEnv) throws -> Manifest {
        // KEYWORDISTA_MODE MUST be explicit. The v0.3.5 regression came
        // from this line having a `?? "server"` fallback that silently
        // chose a mode nobody asked for. Defaulting to "local" would
        // have fixed *that* bug but introduced the symmetric one — a
        // Docker image misconfiguration could silently boot in local
        // mode (no auth, 127.0.0.1) inside a remote container nobody
        // can reach. Fail-fast eliminates the whole class: every
        // deployment path must declare its intent.
        //
        // The three paths that consume the image/binary already set it:
        //   • Docker image  → ENV KEYWORDISTA_MODE=server  (Dockerfile)
        //   • macOS spawn   → env["KEYWORDISTA_MODE"]="local"
        //                                    (ServiceSupervisor)
        //   • Test harness  → ManifestEnv.fixture(["KEYWORDISTA_MODE": ...])
        // For `swift run` dev: `KEYWORDISTA_MODE=local swift run App serve …`
        guard let modeRaw = env.get(EnvVars.mode.name) else {
            throw EnvVarError.modeNotSet
        }
        let resolvedMode: RuntimeMode
        do {
            resolvedMode = try EnvVars.mode.parse(modeRaw)
        } catch {
            throw EnvVarError.parseFailed(
                name: EnvVars.mode.name,
                raw: modeRaw,
                reason: "\(error)",
                valueIsSecret: EnvVars.mode.valueIsSecret    // false — mode is "local"/"server"
            )
        }

        let manifest = Manifest(mode: resolvedMode)
        try manifest.validateAll(env: env)
        return manifest
    }

    /// Required: returns `T`, throws if the var is unset AND has no default
    /// in this mode. Use for vars that have a documented default and/or are
    /// gated by a `requiredIn` constraint.
    public func require<T>(_ envVar: EnvVar<T>, env: ManifestEnv = .processEnv) throws -> T {
        if let raw = env.get(envVar.name) {
            do { return try envVar.parse(raw) }
            catch {
                throw EnvVarError.parseFailed(
                    name: envVar.name,
                    raw: raw,
                    reason: "\(error)",
                    valueIsSecret: envVar.valueIsSecret    // M3.24c: redact secrets in logs
                )
            }
        }
        if let v = envVar.defaults(mode) { return v }
        throw EnvVarError.missingRequired(name: envVar.name, mode: mode)
    }

    /// Optional: returns `nil` if unset AND no default in this mode.
    /// Throws only on parse failure of an explicitly-set value.
    public func optional<T>(_ envVar: EnvVar<T>, env: ManifestEnv = .processEnv) throws -> T? {
        if let raw = env.get(envVar.name) {
            do { return try envVar.parse(raw) }
            catch {
                throw EnvVarError.parseFailed(
                    name: envVar.name,
                    raw: raw,
                    reason: "\(error)",
                    valueIsSecret: envVar.valueIsSecret    // M3.24c: redact secrets in logs
                )
            }
        }
        return envVar.defaults(mode)
    }

    /// Walks every spec in `EnvVars.all` and surfaces the first
    /// `requiredIn`/parse failure for this mode. Called by `bootstrap`;
    /// also exposed for tests.
    public func validateAll(env: ManifestEnv = .processEnv) throws {
        for spec in EnvVars.all {
            if spec.requiredIn.isRequired(in: mode), env.get(spec.name) == nil {
                throw EnvVarError.missingRequired(name: spec.name, mode: mode)
            }
            // Validate parsability of explicitly-set values; we don't run
            // defaults through the parser because they're code-supplied
            // and already typed.
            if let raw = env.get(spec.name) {
                try spec.validateParse(raw: raw)
            }
        }
    }

    // MARK: --help

    /// Renders the env-var contract as plain text, ordered per `EnvVars.all`.
    /// Used by `keywordista --help` and committed verbatim into
    /// `docs/env-vars.md` by the M0.10 CI gate.
    public static func helpText() -> String {
        let width = (EnvVars.all.map(\.name.count).max() ?? 32) + 2
        var lines: [String] = [
            "Keywordista — env-var contract (v1.0)",
            "",
            "Defaults shown for `server` mode unless otherwise noted.",
            "Run with KEYWORDISTA_MODE=local for the macOS local-spawn defaults.",
            "",
        ]
        for spec in EnvVars.all {
            lines.append(spec.helpRow(width: width))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: /version/env

    public struct VersionEnvEntry: Sendable, Encodable {
        public let name: String
        public let description: String
        public let since: String
        public let requiredIn: [String]
        public let defaultValue: String?
        public let valueIsSecret: Bool
        public let presence: String   // "set" | "default" | "unset"
    }

    public func versionEnv(env: ManifestEnv = .processEnv) -> [VersionEnvEntry] {
        EnvVars.all.map { spec in
            let presence: String
            if env.get(spec.name) != nil { presence = "set" }
            else if spec.renderDefault(for: mode) != nil { presence = "default" }
            else { presence = "unset" }

            return VersionEnvEntry(
                name: spec.name,
                description: spec.description,
                since: spec.since,
                requiredIn: spec.requiredIn.modeNames,
                defaultValue: spec.renderDefault(for: mode),
                valueIsSecret: spec.valueIsSecret,
                presence: presence
            )
        }
    }
}

// MARK: - Env source (testability seam)
//
// `ManifestEnv` exists so tests can construct an isolated env map without
// touching the process environment. In production, `processEnv` reads
// through Vapor's `Environment.get`, which is itself a thin wrapper over
// `getenv(3)`. **This is the only place in the binary that's allowed to
// call `Environment.get` directly** — the M0.3 CI script grep-bans it
// everywhere else.

public struct ManifestEnv: Sendable {
    public let get: @Sendable (String) -> String?

    public init(get: @escaping @Sendable (String) -> String?) {
        self.get = get
    }

    /// Production: reads from the real process environment via Vapor.
    public static let processEnv = ManifestEnv { name in
        Environment.get(name)
    }

    /// Tests: an in-memory dictionary.
    public static func fixture(_ map: [String: String]) -> ManifestEnv {
        ManifestEnv { name in map[name] }
    }
}

// MARK: - Spec parse-validation helper

extension EnvVarSpec {
    /// Type-erased parse-check used during `validateAll`. Each concrete
    /// `EnvVar<T>` reaches its own typed `parse` closure.
    fileprivate func validateParse(raw: String) throws {
        if let typed = self as? any TypedEnvVarSpec {
            try typed.parseAndDiscard(raw: raw)
        }
    }
}

private protocol TypedEnvVarSpec {
    func parseAndDiscard(raw: String) throws
}

extension EnvVar: TypedEnvVarSpec {
    fileprivate func parseAndDiscard(raw: String) throws {
        do { _ = try parse(raw) }
        catch {
            throw EnvVarError.parseFailed(
                name: name,
                raw: raw,
                reason: "\(error)",
                valueIsSecret: valueIsSecret    // M3.24c
            )
        }
    }
}
