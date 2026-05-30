import Foundation

// Produces metadata-optimizer findings for a watched app's listing in one
// storefront: pulls the latest snapshot's indexed fields + the user's
// tracked terms for that country, and runs the MetadataLinter over them.
protocol MetadataOptimizerServiceProtocol: Sendable {
    func findings(watchedAppID: UUID, country: String) async throws -> [LintFinding]
}

struct MetadataOptimizerService: MetadataOptimizerServiceProtocol {
    let snapshotRepository: any AppMetadataSnapshotRepositoryProtocol
    let keywordRepository: any KeywordRepositoryProtocol
    let linter: any MetadataLinterProtocol

    func findings(watchedAppID: UUID, country: String) async throws -> [LintFinding] {
        // No snapshot yet → nothing to lint. The metadata/compare flow
        // populates snapshots for tracked apps; the optimizer reads them.
        guard let snapshot = try await snapshotRepository.latest(
            watchedAppID: watchedAppID, country: country,
        ) else {
            return []
        }
        // Tracked terms are scoped to the same storefront as the listing —
        // a keyword tracked only in DE shouldn't count as "tracked" for the
        // US listing's words.
        let trackedTerms = try await keywordRepository.filtered(country: country).map(\.term)
        return linter.lint(
            title: snapshot.trackName,
            subtitle: snapshot.subtitle,
            trackedTerms: trackedTerms,
        )
    }
}
