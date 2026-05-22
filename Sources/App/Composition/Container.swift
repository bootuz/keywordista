import Fluent
import Foundation
import Queues
import Vapor

// Composition root for request-scoped and job-scoped service construction.
// Concrete dependencies are wired here so controllers and jobs only depend on
// protocols. To swap an implementation (e.g. for tests or to add an Apple
// Search Ads scorer later), change one factory.

extension Request {
    func appService() -> any AppServiceProtocol {
        AppService(
            repository: FluentWatchedAppRepository(db: db),
            lookupClient: ITunesLookupClient(client: client)
        )
    }

    func keywordService() -> any KeywordServiceProtocol {
        KeywordService(
            repository: FluentKeywordRepository(db: db),
            dispatcher: QueueRefreshDispatcher(queue: queue)
        )
    }

    func dashboardService() -> any DashboardServiceProtocol {
        DashboardService(
            keywordRepository: FluentKeywordRepository(db: db),
            watchedAppRepository: FluentWatchedAppRepository(db: db),
            rankCheckRepository: FluentRankCheckRepository(db: db),
            topResultRepository: FluentTopResultSnapshotRepository(db: db)
        )
    }

    func settingsService() -> any SettingsServiceProtocol {
        SettingsService(repository: FluentSettingsRepository(db: db))
    }

    func queueStatusService() -> any QueueStatusServiceProtocol {
        QueueStatusService(db: db)
    }

    func versionService() -> any VersionServiceProtocol {
        VersionService(
            client: client,
            logger: logger,
            repoOwner: VersionService.defaultRepoOwner,
            repoName: VersionService.defaultRepoName
        )
    }
}

extension Application {
    // Factories used by Queues jobs, where we only have a `QueueContext`.
    var refreshServiceFactory: @Sendable (QueueContext) -> any RefreshServiceProtocol {
        { context in
            let app = context.application
            let db = app.db
            return RefreshService(
                keywordRepository: FluentKeywordRepository(db: db),
                watchedAppRepository: FluentWatchedAppRepository(db: db),
                rankCheckRepository: FluentRankCheckRepository(db: db),
                topResultRepository: FluentTopResultSnapshotRepository(db: db),
                searchClient: ITunesSearchClient(client: app.client, logger: context.logger),
                scorer: HeuristicScorer(),
                logger: context.logger
            )
        }
    }

    var keywordServiceFactory: @Sendable (QueueContext) -> any KeywordServiceProtocol {
        { context in
            let app = context.application
            return KeywordService(
                repository: FluentKeywordRepository(db: app.db),
                dispatcher: QueueRefreshDispatcher(queue: context.queue)
            )
        }
    }
}
