@testable import App
import Foundation
import Logging
import Testing
import Vapor

@Suite("EnvVarManifest")
struct EnvVarManifestTests {

    // ── Parsers ──────────────────────────────────────────────────────────

    @Suite("Parsers")
    struct ParserTests {

        @Test("bool accepts the documented forms in either case")
        func boolAccepts() throws {
            for raw in ["true", "TRUE", "1", "yes", "Yes", "on"] {
                #expect(try Parsers.bool(raw) == true, "expected true for '\(raw)'")
            }
            for raw in ["false", "FALSE", "0", "no", "No", "off"] {
                #expect(try Parsers.bool(raw) == false, "expected false for '\(raw)'")
            }
        }

        @Test("bool rejects garbage")
        func boolRejects() {
            for raw in ["", "maybe", "2", "truthy"] {
                #expect(throws: ParseError.self) { try Parsers.bool(raw) }
            }
        }

        @Test("positiveInt accepts > 0 and rejects 0 and negatives")
        func positiveInt() throws {
            #expect(try Parsers.positiveInt("1") == 1)
            #expect(try Parsers.positiveInt("8080") == 8080)
            #expect(throws: ParseError.self) { try Parsers.positiveInt("0") }
            #expect(throws: ParseError.self) { try Parsers.positiveInt("-5") }
            #expect(throws: ParseError.self) { try Parsers.positiveInt("abc") }
        }

        @Test("url accepts http and https; rejects other schemes and garbage")
        func url() throws {
            let a = try Parsers.url("https://example.com")
            #expect(a.scheme == "https")
            let b = try Parsers.url("http://localhost:8080")
            #expect(b.scheme == "http")
            #expect(throws: ParseError.self) { try Parsers.url("ftp://example.com") }
            #expect(throws: ParseError.self) { try Parsers.url("not a url") }
        }

        @Test("mode parses both cases (case-insensitive)")
        func mode() throws {
            #expect(try Parsers.mode("local") == .local)
            #expect(try Parsers.mode("SERVER") == .server)
            #expect(throws: ParseError.self) { try Parsers.mode("staging") }
        }

        @Test("hexBytes parses 64-char strings to 32 bytes")
        func hexBytes() throws {
            let raw = String(repeating: "ab", count: 32)
            let data = try Parsers.hexBytes(expectedBytes: 32)(raw)
            #expect(data.count == 32)
            #expect(data.allSatisfy { $0 == 0xab })
        }

        @Test("hexBytes rejects wrong length")
        func hexBytesWrongLength() {
            #expect(throws: ParseError.self) {
                try Parsers.hexBytes(expectedBytes: 32)("ab")
            }
            #expect(throws: ParseError.self) {
                try Parsers.hexBytes(expectedBytes: 32)(String(repeating: "a", count: 63))
            }
        }

        @Test("hexBytes rejects non-hex characters")
        func hexBytesNonHex() {
            // 64 chars but contains 'z'
            let raw = "z" + String(repeating: "a", count: 63)
            #expect(throws: ParseError.self) {
                try Parsers.hexBytes(expectedBytes: 32)(raw)
            }
        }

        @Test("hourOfDay accepts 0–23")
        func hourOfDay() throws {
            #expect(try Parsers.hourOfDay("0") == 0)
            #expect(try Parsers.hourOfDay("23") == 23)
            #expect(throws: ParseError.self) { try Parsers.hourOfDay("-1") }
            #expect(throws: ParseError.self) { try Parsers.hourOfDay("24") }
        }

        @Test("bcryptHash accepts $2a/$2b/$2y prefixed strings of the right length")
        func bcryptHash() throws {
            // 60-char canonical bcrypt MCF string
            let valid = "$2b$12$" + String(repeating: "a", count: 53)
            #expect(try Parsers.bcryptHash(valid) == valid)
            let alt = "$2a$12$" + String(repeating: "b", count: 53)
            #expect(try Parsers.bcryptHash(alt) == alt)
        }

        @Test("bcryptHash rejects plaintext and wrong-prefix strings")
        func bcryptHashRejects() {
            #expect(throws: ParseError.self) {
                try Parsers.bcryptHash("mypassword")
            }
            #expect(throws: ParseError.self) {
                try Parsers.bcryptHash("$1$wrongprefix$" + String(repeating: "a", count: 50))
            }
            // Right prefix, wrong length
            #expect(throws: ParseError.self) {
                try Parsers.bcryptHash("$2b$12$short")
            }
        }

        @Test("email lowercases, trims, and rejects obvious garbage")
        func email() throws {
            #expect(try Parsers.email("  You@Studio.Com  ") == "you@studio.com")
            #expect(throws: ParseError.self) { try Parsers.email("not-an-email") }
            #expect(throws: ParseError.self) { try Parsers.email("@no-local.com") }
            #expect(throws: ParseError.self) { try Parsers.email("no-domain@") }
        }

        @Test("logLevel accepts all Logger.Level cases")
        func logLevel() throws {
            for raw in ["trace", "debug", "info", "notice", "warning", "error", "critical"] {
                _ = try Parsers.logLevel(raw)
            }
            #expect(throws: ParseError.self) { try Parsers.logLevel("verbose") }
        }

        @Test("logFormat accepts json or text")
        func logFormat() throws {
            #expect(try Parsers.logFormat("json") == .json)
            #expect(try Parsers.logFormat("TEXT") == .text)
            #expect(throws: ParseError.self) { try Parsers.logFormat("xml") }
        }
    }

    // ── EnvVars contract integrity ───────────────────────────────────────

    @Suite("Contract integrity")
    struct ContractTests {

        @Test("EnvVars.all contains 23 unique entries (the v1.0 contract size)")
        func allHasExpectedShape() {
            #expect(EnvVars.all.count == 23, "if you added or removed an EnvVar, update this assertion AND docs/env-vars.md")
            let names = EnvVars.all.map(\.name)
            let unique = Set(names)
            #expect(names.count == unique.count, "EnvVars.all contains a duplicate name")
        }

        @Test("Every name is KEYWORDISTA_-prefixed except the four PaaS conventions")
        func namingConventionEnforced() {
            let allowedUnprefixed: Set<String> = ["PORT", "HOSTNAME", "DATABASE_URL", "DATABASE_PATH"]
            for spec in EnvVars.all {
                let ok = spec.name.hasPrefix("KEYWORDISTA_") || allowedUnprefixed.contains(spec.name)
                #expect(ok, "\(spec.name) violates the §4.6.3 reserved-namespace rule")
            }
        }

        @Test("Only secret-flagged vars are the ones documented as secret")
        func secretSetIsCorrect() {
            let secretNames = Set(EnvVars.all.filter(\.valueIsSecret).map(\.name))
            #expect(secretNames == [
                "DATABASE_URL",                         // contains password
                "KEYWORDISTA_ENCRYPTION_KEY",
                "KEYWORDISTA_ADMIN_PASSWORD_HASH",
            ], "If you added a credential-type var, mark valueIsSecret AND update this assertion.")
        }
    }

    // ── Bootstrap ────────────────────────────────────────────────────────

    @Suite("bootstrap()")
    struct BootstrapTests {

        @Test("Empty env throws .modeNotSet (v0.3.5 regression guard)")
        func emptyEnvThrowsModeNotSet() {
            // The v0.3.5 bug came from `bootstrap` having a silent
            // `?? "server"` fallback for KEYWORDISTA_MODE. Defaulting
            // the other direction (?? "local") would have fixed that
            // case but hidden the symmetric one (a Docker image
            // misconfiguration silently booting in local mode inside
            // a remote container). Fail-fast eliminates both: every
            // deployment path MUST declare its intent. The three real
            // paths already do — Dockerfile ENV, ServiceSupervisor,
            // and test fixtures. This test pins that contract shut.
            let env = ManifestEnv.fixture([:])
            do {
                _ = try Manifest.bootstrap(env: env)
                Issue.record("expected .modeNotSet to throw")
            } catch let err as EnvVarError {
                guard case .modeNotSet = err else {
                    Issue.record("expected .modeNotSet, got \(err)"); return
                }
                // Sanity-check that the message includes the remediation
                // hint — that hint IS the documentation for anyone
                // hitting this in the wild.
                #expect("\(err)".contains("KEYWORDISTA_MODE must be set"))
                #expect("\(err)".contains("local"))
                #expect("\(err)".contains("server"))
            } catch {
                Issue.record("expected EnvVarError, got \(error)")
            }
        }

        @Test("Local mode with empty env succeeds (no vars are required in local)")
        func localModeEmptyOK() throws {
            let env = ManifestEnv.fixture(["KEYWORDISTA_MODE": "local"])
            let m = try Manifest.bootstrap(env: env)
            #expect(m.mode == .local)
        }

        @Test("Server mode with valid required vars succeeds")
        func serverModeFullySpecified() throws {
            let env = ManifestEnv.fixture([
                "KEYWORDISTA_MODE": "server",
                "KEYWORDISTA_ENCRYPTION_KEY": String(repeating: "00", count: 32),
                "KEYWORDISTA_PUBLIC_BASE_URL": "https://kw.example.com",
            ])
            let m = try Manifest.bootstrap(env: env)
            #expect(m.mode == .server)
        }

        @Test("Server mode missing ENCRYPTION_KEY throws missingRequired naming the var")
        func serverMissingKey() {
            let env = ManifestEnv.fixture([
                "KEYWORDISTA_MODE": "server",
                "KEYWORDISTA_PUBLIC_BASE_URL": "https://kw.example.com",
            ])
            do {
                _ = try Manifest.bootstrap(env: env)
                Issue.record("expected throw")
            } catch let err as EnvVarError {
                guard case .missingRequired(let name, .server) = err else {
                    Issue.record("expected .missingRequired(.server), got \(err)"); return
                }
                #expect(name == "KEYWORDISTA_ENCRYPTION_KEY")
            } catch {
                Issue.record("expected EnvVarError, got \(error)")
            }
        }

        @Test("Garbage KEYWORDISTA_MODE throws parseFailed")
        func badMode() {
            let env = ManifestEnv.fixture(["KEYWORDISTA_MODE": "staging"])
            #expect(throws: EnvVarError.self) {
                _ = try Manifest.bootstrap(env: env)
            }
        }

        @Test("Bad encryption-key hex throws parseFailed in server mode")
        func badEncryptionKey() {
            let env = ManifestEnv.fixture([
                "KEYWORDISTA_MODE": "server",
                "KEYWORDISTA_ENCRYPTION_KEY": "not-hex-at-all",
                "KEYWORDISTA_PUBLIC_BASE_URL": "https://kw.example.com",
            ])
            do {
                _ = try Manifest.bootstrap(env: env)
                Issue.record("expected throw")
            } catch let err as EnvVarError {
                guard case .parseFailed(let name, _, _) = err else {
                    Issue.record("expected .parseFailed, got \(err)"); return
                }
                #expect(name == "KEYWORDISTA_ENCRYPTION_KEY")
            } catch {
                Issue.record("expected EnvVarError, got \(error)")
            }
        }
    }

    // ── require / optional ───────────────────────────────────────────────

    @Suite("require/optional")
    struct ReaderTests {

        @Test("require returns the explicit value when set")
        func requireExplicit() throws {
            let env = ManifestEnv.fixture(["PORT": "9000"])
            let m = Manifest(mode: .server)
            #expect(try m.require(EnvVars.port, env: env) == 9000)
        }

        @Test("require returns the documented default when unset")
        func requireDefault() throws {
            let env = ManifestEnv.fixture([:])
            let m = Manifest(mode: .server)
            #expect(try m.require(EnvVars.port, env: env) == 8080)
            #expect(try m.require(EnvVars.hostname, env: env) == "0.0.0.0")
            let local = Manifest(mode: .local)
            #expect(try local.require(EnvVars.hostname, env: env) == "127.0.0.1")
        }

        @Test("require throws missingRequired when unset and no default")
        func requireMissing() {
            let env = ManifestEnv.fixture([:])
            let m = Manifest(mode: .server)
            #expect(throws: EnvVarError.self) {
                _ = try m.require(EnvVars.publicBaseURL, env: env)
            }
        }

        @Test("optional returns nil when unset and no default")
        func optionalMissing() throws {
            let env = ManifestEnv.fixture([:])
            let m = Manifest(mode: .server)
            let v = try m.optional(EnvVars.adminEmail, env: env)
            #expect(v == nil)
        }

        @Test("optional surfaces parse failures of explicitly-set values")
        func optionalParseFailure() {
            let env = ManifestEnv.fixture(["KEYWORDISTA_REFRESH_HOUR": "99"])
            let m = Manifest(mode: .server)
            #expect(throws: EnvVarError.self) {
                _ = try m.optional(EnvVars.refreshHour, env: env)
            }
        }

        @Test("Mode-conditional defaults switch correctly between local and server")
        func modeConditionalDefaults() throws {
            let env = ManifestEnv.fixture([:])
            let local = Manifest(mode: .local)
            let server = Manifest(mode: .server)
            #expect(try local.require(EnvVars.trustProxy, env: env) == false)
            #expect(try server.require(EnvVars.trustProxy, env: env) == true)
            #expect(try local.require(EnvVars.logFormat, env: env) == .text)
            #expect(try server.require(EnvVars.logFormat, env: env) == .json)
        }
    }

    // ── Help & version/env rendering ─────────────────────────────────────

    @Suite("Rendering")
    struct RenderingTests {

        @Test("helpText mentions every env var name")
        func helpMentionsEveryVar() {
            let txt = Manifest.helpText()
            for spec in EnvVars.all {
                #expect(txt.contains(spec.name), "\(spec.name) missing from --help output")
            }
            #expect(txt.contains("Keywordista — env-var contract"))
        }

        @Test("versionEnv presence is 'set' for fixture vars, 'default' for ones with defaults, 'unset' otherwise")
        func versionEnvPresence() {
            let env = ManifestEnv.fixture(["PORT": "9000"])
            let m = Manifest(mode: .server)
            let entries = m.versionEnv(env: env)

            let port = entries.first { $0.name == "PORT" }
            let hostname = entries.first { $0.name == "HOSTNAME" }
            let adminEmail = entries.first { $0.name == "KEYWORDISTA_ADMIN_EMAIL" }

            #expect(port?.presence == "set")
            #expect(hostname?.presence == "default")
            #expect(adminEmail?.presence == "unset")
        }

        @Test("versionEnv marks the three credential vars as secret")
        func versionEnvSecretFlagPropagates() {
            let m = Manifest(mode: .server)
            let entries = m.versionEnv(env: .fixture([:]))
            let secret = Set(entries.filter(\.valueIsSecret).map(\.name))
            #expect(secret == [
                "DATABASE_URL",
                "KEYWORDISTA_ENCRYPTION_KEY",
                "KEYWORDISTA_ADMIN_PASSWORD_HASH",
            ])
        }
    }
}
