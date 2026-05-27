import Fluent
import Foundation
import Queues
import Vapor

// Daily metadata-snapshot pass. Refreshes the metadata for every tracked
// app across the storefronts the user cares about, deduping into the
// append-only `app_metadata_snapshots` timeline.
//
// Cadence is configured in configure.swift to 03:30 UTC — between
// DailyRefreshScheduler (03:00) and RefreshChartsScheduler (04:00) so
// the three daily jobs don't stack on the same minute. Apple's CDN has
// settled in PT timezones by then.
//
// Why this runs serially (no parallelism, no per-app enqueueing): same
// reason as the existing schedulers. `workerCount = 1` is load-bearing
// (see configure.swift comment), and the polite-~1-req/sec posture to
// iTunes is part of the project's contract with Apple. A handful of
// apps × ~10 storefronts × 2 HTTP calls each (iTunes + HTML scrape)
// completes well under the job's available window.
//
// Storefront strategy:
//   • Own apps → every storefront in AppStorefrontAvailability for that
//     app (the prober has narrowed this down from 175 to 1–10 typical).
//   • Competitor apps → the storefronts where any keyword exists, plus
//     a default storefront (we don't probe 175 per competitor because
//     they don't participate in chart-watching — paying for 175 lookups
//     per competitor per day for no user-visible win would balloon the
//     iTunes rate budget).
struct DailyMetadataSnapshotJob: AsyncScheduledJob {
    func run(context: QueueContext) async throws {
        let app = context.application
        let logger = context.logger
        let service = app.appMetadataSnapshotServiceFactory(context)
        let db = app.db

        let allApps = try await WatchedApp.query(on: db).all()
        var totalSnapshots = 0
        var totalFailures = 0

        for watched in allApps {
            guard let appID = watched.id else { continue }
            let countries = try await Self.countries(for: watched, on: db)
            if countries.isEmpty {
                logger.debug("DailyMetadataSnapshot: app=\(appID) has no storefronts to refresh; skipping")
                continue
            }
            for country in countries {
                do {
                    _ = try await service.snapshot(watchedAppID: appID, country: country)
                    totalSnapshots += 1
                } catch {
                    // Fail-soft per (app, country). One bad lookup
                    // shouldn't kill the rest of the cohort — the next
                    // run will retry.
                    totalFailures += 1
                    logger.warning("DailyMetadataSnapshot: app=\(appID) country=\(country) failed: \(error)")
                }
            }
        }

        logger.info(
            "DailyMetadataSnapshot done: apps=\(allApps.count) snapshots=\(totalSnapshots) failures=\(totalFailures)"
        )
    }

    /// Decide which storefronts to refresh for a given app. Own apps get
    /// the full availability set; competitors get the storefronts where
    /// the user has tracked keywords (so the compare page has data for
    /// the places the user actually looks).
    private static func countries(for app: WatchedApp, on db: any Database) async throws -> [String] {
        guard let appID = app.id else { return [] }
        switch app.typedKind {
        case .own:
            let avail = try await AppStorefrontAvailability.query(on: db)
                .filter(\.$watchedApp.$id == appID)
                .filter(\.$available == true)
                .all()
            // Fallback: if the prober hasn't run yet (newly-added app),
            // snapshot just the default storefront — the next pass will
            // see availability rows and expand.
            if avail.isEmpty { return ["us"] }
            return avail.map { $0.country }

        case .competitor:
            // Storefronts where any keyword exists. This naturally
            // tracks the user's coverage: they only see compare data
            // for places they care to rank in.
            let keywords = try await Keyword.query(on: db).all()
            let countrySet = Set(keywords.map { $0.countryCode })
            if countrySet.isEmpty { return ["us"] }
            return Array(countrySet).sorted()
        }
    }
}
