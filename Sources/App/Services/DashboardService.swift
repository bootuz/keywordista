import Foundation

protocol DashboardServiceProtocol: Sendable {
    func dashboard(country: String?) async throws -> [DashboardRow]
    func history(keywordID: UUID, watchedAppID: UUID) async throws -> [HistoryPoint]
    func appKeywords(watchedAppID: UUID) async throws -> [AppKeywordRow]
}

struct DashboardService: DashboardServiceProtocol {
    let keywordRepository: any KeywordRepositoryProtocol
    let watchedAppRepository: any WatchedAppRepositoryProtocol
    let rankCheckRepository: any RankCheckRepositoryProtocol
    let topResultRepository: any TopResultSnapshotRepositoryProtocol

    func dashboard(country: String?) async throws -> [DashboardRow] {
        let keywords = try await keywordRepository.filtered(country: country)
        let allApps = try await watchedAppRepository.all()
        var rows: [DashboardRow] = []
        for keyword in keywords {
            let keywordID = try keyword.requireID()
            // Every watched app is checked in every country now — primaryCountry
            // no longer scopes the rows.
            let apps = allApps
            let topResults = try await topResultRepository
                .latestSnapshot(keywordID: keywordID)
                .map { TopResultDTO(position: $0.position, appStoreId: $0.appStoreId, name: $0.name, iconURL: $0.iconURL) }

            for app in apps {
                let appID = try app.requireID()
                // Fetch the two most recent checks in one query so we can
                // surface a previous-vs-current rank delta to the UI.
                let recent = try await rankCheckRepository.recent(
                    keywordID: keywordID,
                    watchedAppID: appID,
                    limit: 2
                )
                let latest = recent.first
                let previous = recent.dropFirst().first
                rows.append(DashboardRow(
                    keywordId: keywordID,
                    term: keyword.term,
                    countryCode: keyword.countryCode,
                    watchedAppId: appID,
                    watchedAppName: app.name,
                    rank: latest?.rank,
                    previousRank: previous?.rank,
                    hasPreviousCheck: previous != nil,
                    difficulty: latest?.difficulty ?? 0,
                    entryBarrier: latest?.entryBarrier ?? 0,
                    checkedAt: latest?.checkedAt,
                    topResults: topResults
                ))
            }
        }
        return rows
    }

    func history(keywordID: UUID, watchedAppID: UUID) async throws -> [HistoryPoint] {
        let checks = try await rankCheckRepository.history(keywordID: keywordID, watchedAppID: watchedAppID)
        return checks.map {
            HistoryPoint(
                checkedAt: $0.checkedAt,
                rank: $0.rank,
                difficulty: $0.difficulty,
                entryBarrier: $0.entryBarrier
            )
        }
    }

    // Per-app view: every tracked keyword + the latest rank check for this app.
    // Useful for "show me all keywords where Azri appears + how it's doing".
    func appKeywords(watchedAppID: UUID) async throws -> [AppKeywordRow] {
        let keywords = try await keywordRepository.all()
        var rows: [AppKeywordRow] = []
        for keyword in keywords {
            let keywordID = try keyword.requireID()
            let latest = try await rankCheckRepository.latest(
                keywordID: keywordID,
                watchedAppID: watchedAppID
            )
            rows.append(AppKeywordRow(
                keywordId: keywordID,
                term: keyword.term,
                countryCode: keyword.countryCode,
                rank: latest?.rank,
                difficulty: latest?.difficulty ?? 0,
                entryBarrier: latest?.entryBarrier ?? 0,
                checkedAt: latest?.checkedAt
            ))
        }
        return rows
    }
}
