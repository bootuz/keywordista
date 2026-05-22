import Foundation
import Logging
import Vapor

// Reported by `GET /api/v1/version`. The menubar app polls this on the
// local server (rather than hitting GitHub directly) so the update-check
// logic lives in one place — the server already has retry/cache machinery
// and a logger, so the SwiftUI side stays small.
struct VersionInfo: Codable, Sendable {
    let current: String
    let latest: String?
    let updateAvailable: Bool
    let downloadUrl: String?
    let assetSha256: String?
}

extension VersionInfo: Content {}

protocol VersionServiceProtocol: Sendable {
    func status() async throws -> VersionInfo
}

// Actor singleton for the in-memory cache. GitHub's unauthenticated rate
// limit is 60 req/hr per IP, and we don't want to burn that on every menu
// re-render. One hour TTL is plenty.
actor VersionCache {
    static let shared = VersionCache()
    private var entry: (info: VersionInfo, fetchedAt: Date)?
    private static let ttl: TimeInterval = 3_600

    func get(now: Date = Date()) -> VersionInfo? {
        guard let entry, now.timeIntervalSince(entry.fetchedAt) < Self.ttl else { return nil }
        return entry.info
    }

    func set(_ info: VersionInfo, now: Date = Date()) {
        entry = (info, now)
    }
}

struct VersionService: VersionServiceProtocol {
    let client: any Client
    let logger: Logger
    let repoOwner: String
    let repoName: String

    static let defaultRepoOwner = "bootuz"
    static let defaultRepoName = "keywordista"

    func status() async throws -> VersionInfo {
        if let cached = await VersionCache.shared.get() {
            return cached
        }

        // GitHub failures shouldn't break /api/v1/version — we still want
        // to report the current version even when the API is down. Treat
        // any error as "no latest known" rather than throwing.
        let latest = try? await fetchLatestServiceTag()

        let info = VersionInfo(
            current: Version.current,
            latest: latest?.tag,
            updateAvailable: latest.map { isNewer($0.tag, than: Version.current) } ?? false,
            downloadUrl: latest?.downloadUrl,
            assetSha256: latest?.sha256
        )
        await VersionCache.shared.set(info)
        return info
    }

    // MARK: - GitHub Releases

    private struct GitHubRelease: Codable {
        let tagName: String
        let assets: [Asset]
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", assets }

        struct Asset: Codable {
            let name: String
            let browserDownloadURL: String
            // GitHub started returning a `digest` field of the form
            // "sha256:<hex>" on signed releases. Optional so older releases
            // without it still decode cleanly.
            let digest: String?
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
                case digest
            }
        }
    }

    private struct LatestServiceTag {
        let tag: String           // e.g. "0.3.0" (the "service-v" prefix stripped)
        let downloadUrl: String?
        let sha256: String?
    }

    private func fetchLatestServiceTag() async throws -> LatestServiceTag? {
        var url = URI(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases")
        url.query = "per_page=20"

        var headers = HTTPHeaders()
        headers.add(name: "Accept", value: "application/vnd.github+json")
        headers.add(name: "User-Agent", value: "keywordista-server")

        let response = try await client.get(url, headers: headers)
        guard response.status == .ok else {
            logger.warning("GitHub releases API returned \(response.status)")
            return nil
        }
        guard let buffer = response.body else { return nil }

        let decoder = JSONDecoder()
        let releases = try decoder.decode([GitHubRelease].self, from: Data(buffer: buffer))

        // Filter for `service-v*` tags only; ignore `app-v*` (the menubar app
        // ships on its own release stream) and any draft/test tags. Pick the
        // highest semver.
        let serviceReleases = releases.filter { $0.tagName.hasPrefix("service-v") }
        let newest = serviceReleases.max(by: { compareTags($0.tagName, $1.tagName) == .orderedAscending })
        guard let newest else { return nil }

        let tag = String(newest.tagName.dropFirst("service-v".count))
        // Prefer a universal tarball if there's one; fall back to whatever
        // asset is present so dev/test releases without arch-split builds
        // still resolve.
        let asset = newest.assets.first { $0.name.hasSuffix(".tar.gz") } ?? newest.assets.first
        let sha256 = asset?.digest.flatMap { digest in
            digest.split(separator: ":").last.map(String.init)
        }
        return LatestServiceTag(tag: tag, downloadUrl: asset?.browserDownloadURL, sha256: sha256)
    }

    // MARK: - Semver comparison

    private func isNewer(_ a: String, than b: String) -> Bool {
        compareSemver(a, b) == .orderedDescending
    }

    private func compareTags(_ a: String, _ b: String) -> ComparisonResult {
        let aClean = a.hasPrefix("service-v") ? String(a.dropFirst("service-v".count)) : a
        let bClean = b.hasPrefix("service-v") ? String(b.dropFirst("service-v".count)) : b
        return compareSemver(aClean, bClean)
    }

    /// Lightweight semver comparison — handles `MAJOR.MINOR.PATCH`. We don't
    /// publish prerelease or build-metadata tags, so the full SemVer spec
    /// (with `1.0.0-rc.1+meta`) would be overkill.
    private func compareSemver(_ a: String, _ b: String) -> ComparisonResult {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let pairs = max(aParts.count, bParts.count)
        for i in 0..<pairs {
            let ai = i < aParts.count ? aParts[i] : 0
            let bi = i < bParts.count ? bParts[i] : 0
            if ai != bi { return ai > bi ? .orderedDescending : .orderedAscending }
        }
        return .orderedSame
    }
}
