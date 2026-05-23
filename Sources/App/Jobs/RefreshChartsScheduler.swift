import Foundation
import Queues
import Vapor

// Daily chart-watchdog pass. Mirrors DailyRefreshScheduler's shape: the
// scheduler runs the work inline rather than enqueueing per-app jobs because
// (a) ChartTrackerService already does its own bounded concurrency across
// countries and (b) we only have a handful of watched apps in practice.
//
// Cadence is configured in configure.swift to 04:00 UTC — a few hours after
// Apple's PT-midnight chart refresh window so the RSS feeds have settled.
struct RefreshChartsScheduler: AsyncScheduledJob {
    func run(context: QueueContext) async throws {
        let service = context.application.chartTrackerServiceFactory(context)
        let summary = try await service.refreshAll(now: Date())
        context.logger.info(
            """
            RefreshChartsScheduler done: \
            apps=\(summary.appsProcessed) charts=\(summary.chartsFetched) events=\(summary.eventsEmitted)
            """
        )
    }
}
