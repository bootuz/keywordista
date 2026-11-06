import Queues
import Vapor

/// Daily Apple Ads sync. Runs from the scheduler, not as a queued job, so a
/// long backfill never blocks keyword refreshes on the single queue worker.
struct AppleAdsSyncScheduler: AsyncScheduledJob {
    func run(context: QueueContext) async throws {
        await context.application.appleAdsSyncCoordinator.runNow(trigger: .scheduled)
    }
}
