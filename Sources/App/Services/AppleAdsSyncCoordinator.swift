import Foundation
import Logging
import Vapor

/// What the Setup tab and the sync chip poll.
struct AppleAdsSyncStatus: Content, Equatable {
    let running: Bool
    let lastRun: AppleAdsSyncRun?
    let lastSuccessAt: Date?
}

/// Runs at most one Apple Ads sync at a time, outside the queue worker.
///
/// Why not a queue job: a 90-day backfill takes minutes, and on the single
/// worker (`workerCount = 1`) it would hold up keyword refreshes and inflate
/// the refresh chip's pending count, which reads `_jobs`.
actor AppleAdsSyncCoordinator {
    typealias Factory = @Sendable () -> any AppleAdsSyncServiceProtocol

    private let makeService: Factory
    private let logger: Logger
    private var current: (id: UUID, task: Task<Void, Never>)?

    init(logger: Logger, makeService: @escaping Factory) {
        self.logger = logger
        self.makeService = makeService
    }

    var isRunning: Bool { current != nil }

    /// Starts a sync in the background. Returns false when one is already running.
    @discardableResult
    func start(trigger: AppleAdsSyncTrigger) -> Bool {
        guard current == nil else { return false }
        let id = UUID()
        let service = makeService()
        let log = logger
        let task = Task {
            do {
                _ = try await service.sync(trigger: trigger)
            } catch is CancellationError {
                log.info("Apple Ads sync cancelled")
            } catch AppleAdsError.notConnected {
                // Nothing to sync; not an error worth logging.
            } catch {
                log.warning("Apple Ads sync failed: \(AppleAdsError.from(error))")
            }
            self.finished(id)
        }
        current = (id, task)
        return true
    }

    /// Runs a sync and waits for it (the daily schedule). Joins one already running.
    func runNow(trigger: AppleAdsSyncTrigger) async {
        if current == nil { start(trigger: trigger) }
        await current?.task.value
    }

    /// Cancels a running sync and waits until it has stopped writing, so a
    /// purge that follows can't be undone by a late write.
    func cancelAndWait() async {
        guard let running = current else { return }
        running.task.cancel()
        await running.task.value
    }

    private func finished(_ id: UUID) {
        if current?.id == id { current = nil }
    }
}
