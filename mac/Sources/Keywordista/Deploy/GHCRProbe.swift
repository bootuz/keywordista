import Foundation

/// Pre-deploy verification that the configured image actually exists
/// AND is pullable without auth. Without this, the cockpit happily
/// hands a non-existent image ref to Render and the user waits 60s
/// only to see "lookup error: the provided URL could not be fetched"
/// — which is what happened in the v0.5.0-RC deploy and triggered
/// this whole sub-task.
///
/// **How the GHCR auth dance works**: GitHub Container Registry
/// always 401s on first hit, even for public images. The 401 response
/// includes a `Www-Authenticate: Bearer realm="https://ghcr.io/token",
/// service="ghcr.io",scope="repository:owner/repo:pull"` header. We
/// follow that, request an anonymous token (no credentials), then
/// retry the manifest fetch with the token. Public images: token is
/// granted, manifest fetch succeeds. Private images: token request
/// itself 401s.
///
/// **What we don't do here**: validate that the image actually CONTAINS
/// a working Keywordista binary. Render's deploy is the integration
/// test; we just verify "pulling it would succeed."
enum GHCRProbe {

    /// Verifies the image at `imageRef` is publicly fetchable from GHCR.
    /// Returns `.success` if Render (or any other unauthenticated client)
    /// could pull it; throws `ProbeError` with diagnostic detail otherwise.
    ///
    /// - Parameter imageRef: full image ref like
    ///   `ghcr.io/owner/repo:tag` or `ghcr.io/owner/repo@sha256:digest`
    ///
    /// Non-GHCR refs (Docker Hub, private registries) are NOT probed —
    /// returns `.success` so the cockpit doesn't false-fail on them.
    /// We probe only what we can verify; "this is not GHCR" is silent.
    static func checkPublicImage(
        ref: String,
        session: URLSession = .shared
    ) async throws {
        guard let parsed = parseGHCRRef(ref) else {
            // Not a ghcr.io ref → can't probe, assume OK. Forks that
            // push to Docker Hub or elsewhere skip this check; their
            // first failed deploy will surface the issue (with the
            // improved error mapping below making it readable).
            return
        }

        // Step 1: anonymous token for read access to the repo.
        let tokenURL = URL(string:
            "https://ghcr.io/token?service=ghcr.io&scope=repository:\(parsed.repo):pull"
        )!
        var tokenRequest = URLRequest(url: tokenURL)
        tokenRequest.timeoutInterval = 10

        let (tokenData, tokenResponse): (Data, URLResponse)
        do {
            (tokenData, tokenResponse) = try await session.data(for: tokenRequest)
        } catch {
            throw ProbeError.unreachable(error.localizedDescription)
        }

        let tokenStatus = (tokenResponse as? HTTPURLResponse)?.statusCode ?? 0
        guard tokenStatus == 200 else {
            // 401/403 here means the image (or whole repo) is private —
            // GHCR refuses to issue even a pull-scoped anonymous token.
            // The user needs to flip visibility to Public via the
            // GitHub UI.
            throw ProbeError.notPublic(ref: ref)
        }

        guard let body = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
              let token = body["token"] as? String else {
            throw ProbeError.unreachable("GHCR token response malformed")
        }

        // Step 2: HEAD the manifest with the anonymous token. We use
        // HEAD instead of GET to avoid downloading the manifest body
        // (~50KB). The Accept header matches what Docker / Render would
        // send — without it some registries return 406.
        let manifestURL = URL(string:
            "https://ghcr.io/v2/\(parsed.repo)/manifests/\(parsed.reference)"
        )!
        var manifestRequest = URLRequest(url: manifestURL)
        manifestRequest.httpMethod = "HEAD"
        manifestRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        manifestRequest.setValue(
            "application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json",
            forHTTPHeaderField: "Accept"
        )
        manifestRequest.timeoutInterval = 10

        let (_, manifestResponse): (Data, URLResponse)
        do {
            (_, manifestResponse) = try await session.data(for: manifestRequest)
        } catch {
            throw ProbeError.unreachable(error.localizedDescription)
        }

        let manifestStatus = (manifestResponse as? HTTPURLResponse)?.statusCode ?? 0
        if manifestStatus == 200 { return }   // ✓ image exists + pullable

        if manifestStatus == 404 {
            // Token was granted (so the REPO exists + is public), but
            // this specific TAG isn't published. Distinct from "image
            // doesn't exist at all" — tells the user "wrong tag."
            throw ProbeError.tagNotPublished(ref: ref)
        }

        // Any other status — defensive bucket. Probably means GHCR is
        // having a moment; we report it but don't block the deploy
        // (we throw, but the cockpit currently treats this as a hard
        // block; future polish could add a "skip probe" escape hatch).
        throw ProbeError.unreachable("GHCR HEAD returned \(manifestStatus)")
    }

    // MARK: - Internals

    /// Parses `ghcr.io/owner/repo:tag` or `ghcr.io/owner/repo@sha256:...`
    /// into the components GHCR's API needs. Returns nil for non-GHCR
    /// refs — caller skips the probe in that case.
    static func parseGHCRRef(_ ref: String) -> (repo: String, reference: String)? {
        guard ref.lowercased().hasPrefix("ghcr.io/") else { return nil }
        let stripped = String(ref.dropFirst("ghcr.io/".count))

        // Split on @ first (digest takes precedence over tag), then :.
        if let atIdx = stripped.firstIndex(of: "@") {
            let repo = String(stripped[..<atIdx])
            let digest = String(stripped[stripped.index(after: atIdx)...])
            return (repo, digest)
        }
        if let colonIdx = stripped.firstIndex(of: ":") {
            let repo = String(stripped[..<colonIdx])
            let tag = String(stripped[stripped.index(after: colonIdx)...])
            return (repo, tag)
        }
        // No tag specified → :latest by convention.
        return (stripped, "latest")
    }
}

enum ProbeError: Error, CustomStringConvertible {
    case notPublic(ref: String)
    case tagNotPublished(ref: String)
    case unreachable(String)

    var description: String {
        switch self {
        case .notPublic(let ref):
            return """
                The image \(ref) isn't public on GHCR. Render (or any other host) can't pull it without credentials.

                Fix: open https://github.com/users/<owner>/packages/container/keywordista/settings, scroll to "Danger Zone," and click "Change visibility → Public."
                """
        case .tagNotPublished(let ref):
            return """
                The image repository exists on GHCR but the tag \(ref) hasn't been published yet.

                The release-image GitHub workflow publishes new tags on `image-v*` git tags. If you just pushed a tag, the workflow may still be building (~10 min).
                """
        case .unreachable(let detail):
            return "Couldn't reach GHCR to verify the image: \(detail)"
        }
    }
}
