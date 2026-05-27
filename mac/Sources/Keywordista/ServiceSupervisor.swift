import Darwin
import Foundation
import SwiftUI

enum ServiceStatus: Equatable {
    case stopped
    case starting
    case running
    case crashed(reason: String)
}

// Owns the lifecycle of the Vapor server child process.
//
// Binary resolution order:
//   1. ~/Library/Application Support/Keywordista/service/keywordista-server
//      (a service update downloaded by the menubar app — 5d will populate
//       this; the supervisor already prefers it so the update flow only has
//       to drop the file and restart us)
//   2. <Bundle>/Contents/Resources/keywordista-server (the version that
//      shipped with the .app, used until an update is downloaded)
//
// The same fallback applies for the Public/ directory (the SPA assets).
//
// Port resolution: prefer 8080, fall back to 8081..8090 if it's busy. The
// chosen port is published so HealthMonitor and the menu URL both follow.
@MainActor
final class ServiceSupervisor: ObservableObject {
    @Published private(set) var status: ServiceStatus = .stopped
    @Published private(set) var port: UInt16 = preferredPort

    static let preferredPort: UInt16 = 8080
    static let maxFallbackOffset: UInt16 = 10  // → 8080…8090 inclusive

    private var process: Process?
    private let dataDir: URL
    private let logsDir: URL

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.dataDir = appSupport.appendingPathComponent("Keywordista", isDirectory: true)
        let libraryDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
        self.logsDir = libraryDir.appendingPathComponent("Logs/Keywordista", isDirectory: true)
        try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)

        // Kick off the server immediately so the dashboard is reachable by
        // the time the user clicks the menu. Start is async to keep the
        // initializer non-blocking.
        Task { await start() }
    }

    func start() async {
        guard status != .running, status != .starting else { return }
        status = .starting

        guard let binaryURL = resolveBinary() else {
            status = .crashed(reason: "service binary not found in bundle or data dir")
            return
        }
        guard let publicDir = resolvePublicDir() else {
            status = .crashed(reason: "Public/ not found in bundle or data dir")
            return
        }
        guard let chosenPort = resolveFreePort() else {
            let last = Self.preferredPort + Self.maxFallbackOffset
            status = .crashed(reason: "no free port in \(Self.preferredPort)–\(last); free one and re-launch")
            return
        }
        self.port = chosenPort

        let dbPath = dataDir.appendingPathComponent("db.sqlite").path

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = [
            "serve",
            "--hostname", "127.0.0.1",
            "--port", "\(chosenPort)",
        ]
        process.environment = Self.makeChildEnvironment(
            base: ProcessInfo.processInfo.environment,
            publicDir: publicDir,
            dbPath: dbPath
        )

        // Pipe stdout/stderr to log files so the user (or we) can grep them
        // when something goes sideways. Console.app opens them happily.
        process.standardOutput = openAppending(logsDir.appendingPathComponent("service.stdout.log"))
        process.standardError = openAppending(logsDir.appendingPathComponent("service.stderr.log"))

        process.terminationHandler = { [weak self] proc in
            // The inner Task is a Sendable closure crossing actor boundaries;
            // recapture self weakly here so the compiler can see the capture
            // is safe (just an Optional<ServiceSupervisor>, not a live
            // reference). Without this, older Swift toolchains (Xcode 15.4
            // on macos-14) reject the implicit recapture from the outer
            // [weak self] closure as "reference to captured var 'self' in
            // concurrently-executing code".
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Distinguish a clean stop (we called terminate()) from a crash.
                if self.process === proc {
                    self.process = nil
                    if case .stopped = self.status {
                        // already cleared by stop()
                    } else {
                        self.status = .crashed(reason: "exited with code \(proc.terminationStatus)")
                    }
                }
            }
        }

        do {
            try process.run()
            self.process = process
            status = .running
            // Publish the chosen base URL to a sidecar file. The Keywordista
            // MCP server (mcp/) reads this to find us — without it, an MCP
            // client would have to guess our port, since we pick from the
            // 8080–8090 range at boot. Best-effort: a write failure here is
            // a degraded-discovery state, not a startup failure.
            writeRuntimeSidecar(port: chosenPort, pid: process.processIdentifier)
        } catch {
            status = .crashed(reason: "failed to launch: \(error.localizedDescription)")
        }
    }

    func stop() async {
        guard let process, process.isRunning else {
            status = .stopped
            return
        }
        // SIGTERM, then escalate to SIGKILL if it hasn't exited in 5s. The
        // termination handler clears self.process; we just signal here.
        process.terminate()
        for _ in 0..<50 {
            if !process.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        self.process = nil
        status = .stopped
        removeRuntimeSidecar()
    }

    // MARK: - Runtime sidecar (MCP discovery)
    //
    // The sidecar file at <dataDir>/runtime.json publishes our base URL so
    // the Keywordista MCP server can find us without probing every port.
    // Shape:
    //   { "baseURL": "http://127.0.0.1:8083", "pid": 12345, "writtenAt": "<iso>" }
    //
    // Lifecycle: written after a successful `process.run()` in start(),
    // removed in stop(). On a crash the file is stale until next boot —
    // acceptable because the MCP server will fall back to probing if the
    // file points at a dead port.

    private var runtimeSidecarURL: URL {
        dataDir.appendingPathComponent("runtime.json")
    }

    private func writeRuntimeSidecar(port: UInt16, pid: Int32) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload: [String: Any] = [
            "baseURL": "http://127.0.0.1:\(port)",
            "pid": Int(pid),
            "writtenAt": formatter.string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: runtimeSidecarURL, options: [.atomic])
    }

    private func removeRuntimeSidecar() {
        try? FileManager.default.removeItem(at: runtimeSidecarURL)
    }

    // MARK: - Child-process environment
    //
    // Built from a pure static function so the regression test can exercise
    // it without launching a real process. The contract the test pins:
    //
    //   • KEYWORDISTA_MODE is ALWAYS "local". Without this the spawned
    //     backend defaults to server mode (per the v1 image-as-product
    //     contract — the Docker image sets =server explicitly via ENV)
    //     and crashes on boot demanding KEYWORDISTA_ENCRYPTION_KEY. This
    //     was the v0.3.5 regression.
    //   • Our three overrides win over anything inherited from the parent
    //     env (Dictionary assignment overwrites). A contributor who has
    //     KEYWORDISTA_MODE=server in their shell rc still gets a working
    //     local backend.
    //   • All other inherited env passes through unchanged — needed for
    //     PATH, HOME, the dynamic-linker vars Swift needs at runtime, etc.

    // `nonisolated` because this is a pure function — touches no
    // instance state, takes everything via parameters. Lets the test
    // suite call it without a MainActor hop and without forcing every
    // test case to be @MainActor.
    nonisolated static func makeChildEnvironment(
        base: [String: String],
        publicDir: URL,
        dbPath: String
    ) -> [String: String] {
        var env = base
        env["KEYWORDISTA_MODE"] = "local"
        env["KEYWORDISTA_PUBLIC_DIR"] = publicDir.path
        env["DATABASE_PATH"] = dbPath
        return env
    }

    // MARK: - Binary / public-dir resolution

    private func resolveBinary() -> URL? {
        let downloaded = dataDir.appendingPathComponent("service/keywordista-server")
        if FileManager.default.isExecutableFile(atPath: downloaded.path) {
            return downloaded
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("keywordista-server"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        return nil
    }

    private func resolvePublicDir() -> URL? {
        let downloaded = dataDir.appendingPathComponent("service/Public", isDirectory: true)
        if FileManager.default.fileExists(atPath: downloaded.path) {
            return downloaded
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Public", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return nil
    }

    private func openAppending(_ url: URL) -> FileHandle? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        return try? FileHandle(forWritingTo: url)
    }

    // MARK: - Port resolution
    //
    // We prefer 8080 because that's what the dashboard URL convention has
    // baked in (bookmarks, copy-pasted curl commands, the README). When it's
    // occupied — by another keywordista instance, an unrelated dev server,
    // or whatever — we walk up to :8090 looking for a free one.
    //
    // There IS a TOCTOU race: between our bind/close test and the child
    // process binding, something else could claim the port. In practice
    // it's vanishingly rare for a personal dev tool, and if it happens the
    // child crashes on bind, the terminationHandler marks .crashed, and
    // the user can quit/relaunch to retry.

    private func resolveFreePort() -> UInt16? {
        for offset in 0...Self.maxFallbackOffset {
            let candidate = Self.preferredPort + offset
            if Self.isPortFree(candidate) { return candidate }
        }
        return nil
    }

    static func isPortFree(_ port: UInt16) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        // SO_REUSEADDR so we don't fail with EADDRINUSE when our own server
        // just shut down on this port — the OS holds the socket in TIME_WAIT
        // briefly even after a clean close. Without this flag, a Quit+Relaunch
        // would spuriously think 8080 is busy.
        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }
}
