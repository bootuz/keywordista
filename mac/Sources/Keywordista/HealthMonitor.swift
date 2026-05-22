import Foundation
import SwiftUI

// Polls /health on the local server every couple of seconds so the menu can
// show a green/red status dot without depending on the ServiceSupervisor's
// internal Process state (which only reflects "we launched it," not "it's
// actually accepting traffic").
//
// Two distinct timestamps so the UI can tell "we got a ping recently" apart
// from "the last ping failed." If the last successful ping was more than
// `staleThreshold` ago, the menu treats the service as not-running.
@MainActor
final class HealthMonitor: ObservableObject {
    @Published private(set) var lastPingOk: Date?
    @Published private(set) var lastPingFailed: Date?

    // Resolved fresh on every poll so when the supervisor falls back to a
    // different port we don't need to plumb an observer through — the next
    // 2s tick just reads the new value. AppCoordinator sets this once
    // during wiring; default keeps the class usable in isolation/tests.
    var portSource: @MainActor () -> UInt16 = { ServiceSupervisor.preferredPort }

    private var task: Task<Void, Never>?
    private let interval: UInt64 = 2_000_000_000 // 2s
    private let staleThreshold: TimeInterval = 5

    init() {
        start()
    }

    var isHealthy: Bool {
        guard let last = lastPingOk else { return false }
        return Date().timeIntervalSince(last) < staleThreshold
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.ping()
                try? await Task.sleep(nanoseconds: self?.interval ?? 2_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func ping() async {
        let port = portSource()
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                lastPingOk = Date()
            } else {
                lastPingFailed = Date()
            }
        } catch {
            lastPingFailed = Date()
        }
    }
}
