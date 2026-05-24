import Foundation

/// Build-time identity of this Keywordista binary.
///
/// These values are **immutable per binary**: they identify which build is
/// running, not what it's been configured to do. The Docker image bakes
/// them in via `ENV KEYWORDISTA_BUILD_VERSION=…` directives in the
/// Dockerfile (M0.7); the macOS app's launcher script sets them from the
/// bundle's Info.plist; raw `swift run` for dev work falls back to the
/// `dev`/`unknown` placeholders below.
///
/// These are deliberately NOT part of `EnvVarManifest` (§4.6.3) — that
/// manifest is the **operator-controllable** contract. Image metadata is
/// the **build-time** contract: an operator running our image cannot lie
/// about which version of our code is in it (well, they can override the
/// env var, but they have to set it explicitly; nobody does that by
/// accident). Reading via `ProcessInfo.processInfo.environment` rather
/// than `Environment.get` also keeps the M0.3 CI grep-ban on operator-
/// facing vars from getting confused.
///
/// Surfaced at:
///   • `/health`                — JSON `{ ok, version, commitSHA, buildDate, mode }`
///   • `/api/v1/version`        — full `Snapshot` blob
///   • `--version` CLI flag     — one-line `summary` string
///   • Startup log line         — `summary` (operator sanity-check)
///
/// Cached at first access (`static let`) so a running binary always
/// reports the same identity for its lifetime; subsequent env-var changes
/// don't take effect until next boot.
public enum ImageMetadata {

    // ── Per-binary identity ──────────────────────────────────────────

    /// SemVer of the binary, e.g. `"1.2.3"`. Falls back to `"dev"` for
    /// builds that weren't stamped (dev `swift run`, ad-hoc CI builds).
    public static let version: String = {
        nonEmptyEnv("KEYWORDISTA_BUILD_VERSION") ?? "dev"
    }()

    /// Short git SHA, e.g. `"abc1234"`. Falls back to `"unknown"`.
    public static let commitSHA: String = {
        nonEmptyEnv("KEYWORDISTA_BUILD_COMMIT_SHA") ?? "unknown"
    }()

    /// ISO-8601 UTC timestamp of when the binary was built, e.g.
    /// `"2026-05-24T19:23:00Z"`. Falls back to `"unknown"`.
    ///
    /// We deliberately do NOT fall back to `Date()` at process start: a
    /// "build date" that's actually a boot date would be honest-looking
    /// but wrong — and `RemoteUpdateChecker` (M5) compares this field
    /// across instances to spot version drift.
    public static let buildDate: String = {
        nonEmptyEnv("KEYWORDISTA_BUILD_DATE") ?? "unknown"
    }()

    // ── Rendered views ───────────────────────────────────────────────

    /// One-liner for `--version` flag and the startup log:
    /// `"keywordista 1.2.3 (abc1234, built 2026-05-24T19:23:00Z)"`.
    public static var summary: String {
        "keywordista \(version) (\(commitSHA), built \(buildDate))"
    }

    /// Structured form for JSON responses. `Codable` so tests can
    /// round-trip it; the API only ever encodes.
    public struct Snapshot: Sendable, Codable, Equatable {
        public let version: String
        public let commitSHA: String
        public let buildDate: String

        public init(version: String, commitSHA: String, buildDate: String) {
            self.version = version
            self.commitSHA = commitSHA
            self.buildDate = buildDate
        }
    }

    public static var snapshot: Snapshot {
        Snapshot(version: version, commitSHA: commitSHA, buildDate: buildDate)
    }

    // ── Helpers ──────────────────────────────────────────────────────

    /// Reads a `ProcessInfo` env var, trimming whitespace and treating
    /// the empty string as absent — Docker `ENV FOO=` produces an empty
    /// string, not a missing key.
    private static func nonEmptyEnv(_ name: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
