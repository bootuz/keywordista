@testable import App
import Foundation
import Testing

@Suite("MetadataOptimizerService")
struct MetadataOptimizerServiceTests {
    private func snapshot(appID: UUID, country: String, title: String, subtitle: String?) -> AppMetadataSnapshot {
        let s = AppMetadataSnapshot()
        s.$watchedApp.id = appID
        s.countryCode = country
        s.trackName = title
        s.subtitle = subtitle
        s.lastSeenAt = Date(timeIntervalSince1970: 1_000_000)
        return s
    }

    @Test("lints the latest snapshot against tracked terms scoped to the country")
    func lintsLatestSnapshotCountryScoped() async throws {
        let appID = UUID()
        let snapRepo = InMemoryAppMetadataSnapshotRepository()
        try await snapRepo.save(snapshot(appID: appID, country: "us", title: "Azri FSRS", subtitle: nil))

        let kwRepo = InMemoryKeywordRepository([
            Keyword(id: UUID(), term: "azri", countryCode: "us"),
            // Tracked only in DE — must NOT count as tracked for the US listing.
            Keyword(id: UUID(), term: "fsrs", countryCode: "de"),
        ])

        let service = MetadataOptimizerService(
            snapshotRepository: snapRepo,
            keywordRepository: kwRepo,
            linter: MetadataLinter(),
        )

        let findings = try await service.findings(watchedAppID: appID, country: "us")

        // "fsrs" isn't tracked in US → flagged as an untracked indexed word.
        #expect(findings.contains { $0.rule == .untrackedWord && $0.message.contains("fsrs") })
        // "azri" is tracked in US → not flagged.
        #expect(findings.allSatisfy { !($0.rule == .untrackedWord && $0.message.contains("azri")) })
        // Missing subtitle → wastedBudget warning.
        #expect(findings.contains { $0.rule == .wastedBudget && $0.field == "subtitle" && $0.severity == .warning })
    }

    @Test("returns no findings when no snapshot exists for the app/country")
    func noSnapshot() async throws {
        let service = MetadataOptimizerService(
            snapshotRepository: InMemoryAppMetadataSnapshotRepository(),
            keywordRepository: InMemoryKeywordRepository([]),
            linter: MetadataLinter(),
        )
        let findings = try await service.findings(watchedAppID: UUID(), country: "us")
        #expect(findings.isEmpty)
    }
}
