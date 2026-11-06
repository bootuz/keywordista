import Foundation
import SwiftUI

// State machine for the in-app service-update flow.
//
// .idle and .checking are background states the menu doesn't need to
// surface. .available, .applying, and .error are the ones the menu reacts
// to (badged icon, "Apply Update" item, error row).
//
// Equatable so SwiftUI can diff the value cheaply without re-renders.
enum UpdateStatus: Equatable {
    case idle
    case checking
    case available(version: String, downloadURL: URL)
    case applying(version: String, stage: String)   // stage = "downloading" / "verifying" / "swapping" / "restarting"
    case error(reason: String)
}

// Polls the project's GitHub Releases for newer `server-v*` tags, compares
// against the locally-running server's reported version, and on user
// request downloads + verifies + applies the new service binary.
//
// Two design choices baked in here:
//
//   1. **Two-click flow.** The poller only goes as far as detecting an
//      update; nothing is downloaded until the user clicks "Apply Update"
//      in the menu. Avoids burning bandwidth on releases the user might
//      skip and keeps the user in control of when the server restarts.
//
//   2. **Codesign verification before swap.** We refuse to apply a binary
//      unless `codesign --verify` passes against a requirement pinned to
//      our Developer ID team (see `releaseCodeRequirement`). Even if
//      GitHub Releases were compromised, the bar is "obtain our cert,"
//      not "swap a URL."
//
// All state mutations happen on the main actor so SwiftUI observation is
// free of concurrency hazards.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var status: UpdateStatus = .idle

    // Weakly held to avoid an AppCoordinator <-> UpdateChecker retain
    // cycle. The supervisor outlives this checker for the entire app
    // lifetime so the weak ref will never be nil in practice.
    private weak var supervisor: ServiceSupervisor?

    // 30-minute cadence + an initial check 5s after launch. At 2 req/hour
    // we're still safely under GitHub's 60-req/hour unauthenticated rate
    // limit; the tighter cadence means a freshly-shipped service release
    // reaches installed cockpits within half an hour instead of up to six.
    // Users who can't wait can use the "Check for updates" menu item.
    private let pollInterval: TimeInterval = 30 * 60
    private let initialDelay: UInt64 = 5_000_000_000
    private var pollTask: Task<Void, Never>?

    private let repoOwner: String
    private let repoName: String

    init(repoOwner: String = "bootuz", repoName: String = "keywordista") {
        self.repoOwner = repoOwner
        self.repoName = repoName
    }

    func bind(to supervisor: ServiceSupervisor) {
        self.supervisor = supervisor
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let initialDelay = self?.initialDelay else { return }
            try? await Task.sleep(nanoseconds: initialDelay)
            while !Task.isCancelled {
                guard let self else { return }
                await self.checkForUpdate(silent: true)
                let intervalNs = UInt64(self.pollInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Check
    //
    // User-triggered "Check for service updates" menu item. Distinguished
    // from the background poll by setting silent=false so the spinner
    // shows in the menu even when no update is found.

    func checkNow() async {
        await checkForUpdate(silent: false)
    }

    private func checkForUpdate(silent: Bool) async {
        // Don't clobber a more interesting state. If we're in the middle
        // of applying or there's a pending error the user hasn't seen
        // yet, leave it alone.
        if case .applying = status { return }

        if !silent { status = .checking }

        let currentVersion = await readCurrentServiceVersion()
        guard let latest = await fetchLatestServiceRelease() else {
            if !silent { status = .error(reason: "Couldn't reach GitHub Releases") }
            else if case .checking = status { status = .idle }
            return
        }

        if Self.compareSemver(latest.version, currentVersion) == .orderedDescending {
            status = .available(version: latest.version, downloadURL: latest.downloadURL)
        } else {
            // No newer version. Reset .checking → .idle, but don't
            // clobber a previously-surfaced .available state (the user
            // may have closed the menu before clicking Apply).
            if case .checking = status { status = .idle }
        }
    }

    // MARK: - Apply

    /// Triggered by the user clicking "Apply Update" in the menu.
    func applyUpdate() async {
        guard case .available(let version, let url) = status else { return }

        do {
            // 1. Download the .zip to a private scratch space.
            status = .applying(version: version, stage: "downloading")
            let zipURL = try await downloadZip(from: url)
            defer { try? FileManager.default.removeItem(at: zipURL) }

            // 2. Extract to an adjacent scratch dir. The zip's top-level
            //    entry is `service/` (see release-service.yml), so after
            //    extraction we have stageDir/service/keywordista-server.
            status = .applying(version: version, stage: "verifying")
            let stageDir = try await extract(zipURL: zipURL)
            defer { try? FileManager.default.removeItem(at: stageDir) }

            let extractedService = stageDir.appendingPathComponent("service", isDirectory: true)
            let extractedBinary = extractedService.appendingPathComponent("keywordista-server")

            guard FileManager.default.isExecutableFile(atPath: extractedBinary.path) else {
                throw UpdateError.malformedArchive
            }

            // 3. Verify codesign BEFORE touching the running service. If
            //    verification fails the running install stays put and
            //    the user just sees an error row.
            try Self.verifyCodesign(of: extractedBinary)

            // Record the version next to the binary so the supervisor can
            // compare this install against the one bundled in the .app
            // without launching either. Written by us rather than shipped
            // in the zip so service releases cut before markers existed
            // get one too; the tag version is what release-service.yml
            // stamped into the binary, so the two can't disagree.
            try Data((version + "\n").utf8).write(
                to: extractedService.appendingPathComponent(ServiceSupervisor.versionMarkerName),
                options: [.atomic]
            )

            // 4. Stop the current service, atomically replace the
            //    service/ directory, restart. The supervisor runs the
            //    newer of this and the bundled copy; this release is
            //    newer than what was running (that's why it was
            //    offered), so .start() picks it up.
            status = .applying(version: version, stage: "swapping")
            guard let supervisor else { throw UpdateError.noSupervisor }
            await supervisor.stop()

            try swapServiceDirectory(from: extractedService)

            status = .applying(version: version, stage: "restarting")
            await supervisor.start()

            status = .idle
        } catch {
            // Best effort to keep the user's service alive even if the
            // update flow tripped over its own feet. The old binary is
            // still in place (swap-atomicity).
            await supervisor?.start()
            status = .error(reason: error.localizedDescription)
        }
    }

    // MARK: - Implementation details

    /// Resolved release that the menubar's "Apply Update" can act on.
    /// Made `internal` so tests can assert on the picked candidate;
    /// production usage stays inside UpdateChecker.
    struct Release: Equatable {
        let version: String
        let downloadURL: URL
    }

    private func fetchLatestServiceRelease() async -> Release? {
        guard let apiURL = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases?per_page=20") else {
            return nil
        }

        do {
            var req = URLRequest(url: apiURL)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            // The User-Agent header is required by GitHub's API. Identifying
            // ourselves also makes it easier to investigate spikes against
            // their abuse heuristics later if needed.
            req.setValue("Keywordista-Menubar/\(bundleVersion())", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 10

            let (data, _) = try await URLSession.shared.data(for: req)
            let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
            return Self.pickLatestStableRelease(from: releases)
        } catch {
            return nil
        }
    }

    /// Pure-function half of fetchLatestServiceRelease — the part the
    /// unit tests can exercise without HTTP. Filters out:
    ///   • Pre-releases (the M3.18 fix — beta/rc/alpha tags must NOT
    ///     auto-prompt stable users)
    ///   • Releases without the `server-v` prefix (app-v* / image-v* /
    ///     the frozen legacy service-v*
    ///     belong to the other release streams; ignore them)
    ///   • Releases without a .zip asset (incomplete uploads etc.)
    /// Returns the highest-version remaining candidate, or nil if
    /// nothing qualifies.
    ///
    /// `nonisolated` because pure functions don't need MainActor; the
    /// class-level @MainActor would otherwise make this only callable
    /// from MainActor contexts (including tests).
    nonisolated static func pickLatestStableRelease(from releases: [GitHubRelease]) -> Release? {
        let candidates: [Release] = releases.compactMap { release in
            // M3.18: prerelease filter. Trust GitHub's explicit flag
            // (set by release-{service,app}.yml workflows when the
            // tag contains '-'). Without this, stable users on v0.4.x
            // would be prompted to "upgrade" to v0.5.0-beta1 the
            // moment we tagged it.
            guard !release.prerelease else { return nil }
            guard release.tagName.hasPrefix(serverTagPrefix) else { return nil }
            let version = String(release.tagName.dropFirst(serverTagPrefix.count))
            guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
                  let assetURL = URL(string: asset.browserDownloadURL) else {
                return nil
            }
            return Release(version: version, downloadURL: assetURL)
        }
        return candidates.max { Self.compareSemver($0.version, $1.version) == .orderedAscending }
    }

    /// Decoded shape of one entry in GitHub's /repos/.../releases response.
    /// Made `internal` (not private) so unit tests can construct fixtures
    /// + exercise the prerelease-filter logic without standing up a real
    /// HTTP server. The fields are exactly what `pickLatestStableRelease`
    /// reads — adding more would risk decode failures on schema changes
    /// we don't care about.
    struct GitHubRelease: Codable, Equatable {
        let tagName: String
        /// GitHub's per-release "this is a pre-release" flag, set by
        /// `gh release create --prerelease` (or the workflow file's
        /// equivalent conditional). M3.18's filter trusts THIS over
        /// any version-string heuristic — explicit flag beats
        /// guessing from a "-beta" suffix.
        let prerelease: Bool
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case prerelease
            case assets
        }
        struct Asset: Codable, Equatable {
            let name: String
            let browserDownloadURL: String
            enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url" }
        }
    }

    private func readCurrentServiceVersion() async -> String {
        // Default of "0.0.0" means "older than anything ever released",
        // so if /api/v1/version is unreachable we'll always offer an
        // update — but only the offer; nothing happens without user
        // intent. Safer than refusing to check.
        guard let supervisor else { return "0.0.0" }
        let port = supervisor.port
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/v1/version") else { return "0.0.0" }

        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 3
            let (data, _) = try await URLSession.shared.data(for: req)
            struct Response: Decodable { let current: String }
            return try JSONDecoder().decode(Response.self, from: data).current
        } catch {
            return "0.0.0"
        }
    }

    private func downloadZip(from url: URL) async throws -> URL {
        let (tmpURL, _) = try await URLSession.shared.download(from: url)
        // URLSession deletes the downloaded file when the completion
        // handler returns. Move it into our own scratch space so we
        // own the lifetime.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("keywordista-update-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: tmpURL, to: dest)
        return dest
    }

    private func extract(zipURL: URL) async throws -> URL {
        let stageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keywordista-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)

        // `ditto -x -k` is the inverse of the `ditto -c -k` the CI used.
        // /usr/bin/unzip also works but ditto preserves extended attributes
        // — particularly important because the binary's codesign blob
        // lives in an extended attribute (com.apple.cs.CodeSignature on
        // some systems).
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", zipURL.path, stageDir.path]
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw UpdateError.extractFailed(exitCode: task.terminationStatus)
        }
        return stageDir
    }

    /// Server releases for macOS 15+ builds. Why not the old `service-v`:
    /// menubar builds already in the field (macOS 13+) poll `service-v*` and
    /// would install a macOS-15-only server that can't launch, after deleting
    /// the working one. That channel is frozen; never tag it again.
    nonisolated static let serverTagPrefix = "server-v"

    /// Apple Developer team that signs `server-v*` release binaries
    /// (release-service.yml, "Developer ID Application" identity).
    /// Hardcoded like `repoOwner`: this updater only trusts releases
    /// from this project.
    nonisolated static let releaseTeamID = "KHNA6PF8QV"

    /// Why a `-R` requirement: bare `codesign --verify` only proves *some*
    /// valid signature exists, and the linker ad-hoc-signs every arm64
    /// binary for free, so it would accept anything. This is Apple's
    /// canonical Developer ID requirement (Developer ID CA intermediate +
    /// Developer ID Application leaf) pinned to our team.
    nonisolated static var releaseCodeRequirement: String {
        "anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(releaseTeamID)\""
    }

    nonisolated static func verifyCodesign(of binary: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = [
            "--verify", "--strict", "--verbose=1",
            "-R=\(releaseCodeRequirement)",
            binary.path,
        ]
        let stderr = Pipe()
        task.standardError = stderr
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let reason = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                ?? "codesign exit \(task.terminationStatus)"
            throw UpdateError.signatureInvalid(reason: reason)
        }
    }

    /// Atomically replace `~/Library/Application Support/Keywordista/service/`
    /// with the freshly-extracted version. Uses a side-by-side move so we
    /// can roll back if the move fails halfway through.
    private func swapServiceDirectory(from extractedService: URL) throws {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let target = appSupport.appendingPathComponent("Keywordista/service", isDirectory: true)
        let backup = target.appendingPathExtension("backup-\(UUID().uuidString)")

        try fm.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Move the existing service/ aside if present. If anything below
        // fails we restore it.
        let hadExisting = fm.fileExists(atPath: target.path)
        if hadExisting {
            try fm.moveItem(at: target, to: backup)
        }

        do {
            try fm.moveItem(at: extractedService, to: target)
        } catch {
            // Restore the previous service/ on failure.
            if hadExisting {
                try? fm.removeItem(at: target)  // partial move debris
                try? fm.moveItem(at: backup, to: target)
            }
            throw error
        }

        // Success — clean up the backup.
        if hadExisting {
            try? fm.removeItem(at: backup)
        }
    }

    private func bundleVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    enum UpdateError: LocalizedError {
        case noSupervisor
        case malformedArchive
        case extractFailed(exitCode: Int32)
        case signatureInvalid(reason: String)

        var errorDescription: String? {
            switch self {
            case .noSupervisor: return "Supervisor not bound"
            case .malformedArchive: return "Downloaded archive is missing service/keywordista-server"
            case .extractFailed(let code): return "ditto failed with exit code \(code)"
            case .signatureInvalid(let reason): return "Signature check failed: \(reason)"
            }
        }
    }

    // MARK: - Semver

    /// Lightweight MAJOR.MINOR.PATCH comparator. Doesn't handle prerelease
    /// or build-metadata tags — we filter those out at the pickLatestStableRelease
    /// step (M3.18), so by the time we get here the inputs are clean SemVer.
    /// `nonisolated static` for the same reason pickLatestStableRelease is —
    /// pure function, doesn't need MainActor.
    nonisolated static func compareSemver(_ a: String, _ b: String) -> ComparisonResult {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(aParts.count, bParts.count) {
            let ai = i < aParts.count ? aParts[i] : 0
            let bi = i < bParts.count ? bParts[i] : 0
            if ai != bi { return ai > bi ? .orderedDescending : .orderedAscending }
        }
        return .orderedSame
    }
}
