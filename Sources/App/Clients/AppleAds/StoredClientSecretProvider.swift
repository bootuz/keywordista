import AppleAdsClient

/// Hands Apple the client-secret JWT the user generated and pasted into
/// Settings. Why not `.key(...)` auth: existing installs only ever stored
/// that JWT — Keywordista never saw their private key — so v1 has to keep
/// accepting it. (Private-key setup arrives with the Apple Ads settings page.)
struct StoredClientSecretProvider: ClientSecretProvider {
    let secret: String

    nonisolated(nonsending) func clientSecret() async throws -> String { secret }
}
