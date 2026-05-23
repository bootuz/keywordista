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

    func developerKeywordsService() -> any DeveloperKeywordsServiceProtocol {
        let theClient = client
        let theLogger = logger
        return DeveloperKeywordsService(
            settings: settingsService(),
            watchedApps: FluentWatchedAppRepository(db: db),
            makeClient: { creds in
                AppStoreConnectClient(credentials: creds, client: theClient, logger: theLogger)
            },
            logger: logger
        )
    }

    func keywordSuggestionService() -> any KeywordSuggestionServiceProtocol {
        let theHTTP: any ASAHTTPClient = VaporASAHTTPClient(client: client)
        let theLogger = logger
        let cache = application.asaTokenCache
        return KeywordSuggestionService(
            settings: settingsService(),
            keywordRepo: FluentKeywordRepository(db: db),
            rankCheckRepo: FluentRankCheckRepository(db: db),
            makeClient: { creds in
                AppleSearchAdsClient(
                    credentials: creds,
                    tokenCache: cache,
                    http: theHTTP,
                    logger: theLogger
                )
            },
            now: { Date() },
            logger: logger
        )
    }

    func queueStatusService() -> any QueueStatusServiceProtocol {
        QueueStatusService(db: db)
    }

    func chartTrackerService() -> any ChartTrackerServiceProtocol {
        ChartTrackerService(
            db: db,
            chartsClient: ITunesChartsClient(client: client, logger: logger),
            lookupClient: ITunesLookupClient(client: client),
            logger: logger
        )
    }

    func availabilityProber() -> any AvailabilityProberProtocol {
        AvailabilityProber(
            db: db,
            lookupClient: ITunesLookupClient(client: client),
            logger: logger
        )
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
    /// Process-wide cache for ASA OAuth access tokens. Lazily created on
    /// first use and held in `Application.storage` so all request-scoped
    /// ASA clients share the same cache and don't burn one OAuth exchange
    /// per request.
    var asaTokenCache: ASATokenCache {
        if let existing = storage[ASATokenCacheKey.self] { return existing }
        let new = ASATokenCache()
        storage[ASATokenCacheKey.self] = new
        return new
    }

    private struct ASATokenCacheKey: StorageKey {
        typealias Value = ASATokenCache
    }

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

    var chartTrackerServiceFactory: @Sendable (QueueContext) -> any ChartTrackerServiceProtocol {
        { context in
            let app = context.application
            return ChartTrackerService(
                db: app.db,
                chartsClient: ITunesChartsClient(client: app.client, logger: context.logger),
                lookupClient: ITunesLookupClient(client: app.client),
                logger: context.logger
            )
        }
    }
}
