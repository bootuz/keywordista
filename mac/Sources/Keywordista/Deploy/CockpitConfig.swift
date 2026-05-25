import Foundation

/// Centralized cockpit configuration knobs. Currently just the image
/// reference the cockpit deploys, but the right home for any future
/// "stuff a power user might want to override without rebuilding."
///
/// **Why an env var (not a UserDefaults / file)**: forks of Keywordista
/// publish their own image to their own GHCR. The most common case is
/// "I want to deploy ghcr.io/myorg/keywordista" — those users tend to
/// be CLI-comfortable and can wrap the .app launch with the env var:
///
///     KEYWORDISTA_COCKPIT_IMAGE_REF=ghcr.io/myorg/keywordista:latest \
///       open /Applications/Keywordista.app
///
/// Adding a UI for this would be UX clutter for the 99% case (deploy
/// our official image) and forking is itself a "you know what you're
/// doing" signal.
enum CockpitConfig {

    /// Docker image ref the cockpit asks providers to deploy.
    /// Defaults to the canonical GHCR-published image; overridable
    /// for forks via KEYWORDISTA_COCKPIT_IMAGE_REF.
    ///
    /// **Why `:latest` instead of a pinned digest**: simple for v1.
    /// The Plan §4.6 commits to digest-pinning eventually (fetches
    /// the manifest digest at cockpit-build time), but it requires
    /// either a build-script step or runtime resolution. Filed as
    /// follow-up for after v0.5.0 ships.
    static let imageRef: String = {
        ProcessInfo.processInfo.environment["KEYWORDISTA_COCKPIT_IMAGE_REF"]
            ?? "ghcr.io/bootuz/keywordista:latest"
    }()
}
