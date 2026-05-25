import XCTest

@testable import Keywordista

/// Pure-value-type behavior. The Provider protocol itself has no
/// behavior — that lives in M3.6's RenderProvider and onwards. These
/// tests pin the supporting types that DO have behavior (Money
/// arithmetic, DeploymentSpec equality, DatabaseChoice round-trip).
final class ProviderTypesTests: XCTestCase {

    // ── Money ────────────────────────────────────────────────────────

    func testMoneyAdditionCentsAreExact() {
        // Floats would give 7.249999...; cents-based math gives 725.
        let plan = Money.usd(700)
        let disk = Money.usd(25)
        let total = plan + disk
        XCTAssertEqual(total.cents, 725)
        XCTAssertEqual(total.currency, "USD")
    }

    func testMoneyFormattedReturnsCurrencyString() {
        let m = Money.usd(725)
        // Locale-dependent — en_US gives "$7.25", de_DE gives "7,25 US$".
        // Assert on the digits (which are locale-invariant) AND that the
        // output mentions USD in some form. Strips both "." and ","
        // separators to compare the numeric body.
        let normalized = m.formatted.replacingOccurrences(of: ",", with: "")
                                     .replacingOccurrences(of: ".", with: "")
        XCTAssertTrue(normalized.contains("725"),
                     "expected formatted to contain digits 725, got '\(m.formatted)'")
        XCTAssertTrue(m.formatted.contains("$") || m.formatted.contains("USD"),
                     "expected formatted to mention USD, got '\(m.formatted)'")
    }

    func testMoneyZeroFormatsCleanly() {
        // "0" appears in every locale's zero-currency string.
        XCTAssertTrue(Money.zero.formatted.contains("0"))
    }

    // ── DatabaseChoice ────────────────────────────────────────────────

    func testDatabaseChoiceEqualityRespectsAssociatedValues() {
        let a = DatabaseChoice.sqliteOnDisk(size: DiskSize(sizeGB: 1, monthlyCostCents: 25))
        let b = DatabaseChoice.sqliteOnDisk(size: DiskSize(sizeGB: 1, monthlyCostCents: 25))
        let c = DatabaseChoice.sqliteOnDisk(size: DiskSize(sizeGB: 5, monthlyCostCents: 125))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testDatabaseOptionIDsAreStable() {
        // Stable IDs matter for SwiftUI Picker stability — if the id
        // changes between renders the picker collapses + re-expands.
        XCTAssertEqual(DatabaseOption.sqliteOnDisk(sizes: []).id, "sqlite_on_disk")
        XCTAssertEqual(DatabaseOption.providerManagedPostgres(plans: []).id, "provider_managed_postgres")
        XCTAssertEqual(DatabaseOption.externalPostgres.id, "external_postgres")
    }

    // ── ProviderError descriptions ────────────────────────────────────

    func testProviderErrorDescriptionIncludesDetail() {
        let err = ProviderError.authenticationFailed(detail: "token rejected")
        XCTAssertTrue(err.description.contains("authentication failed"))
        XCTAssertTrue(err.description.contains("token rejected"))
    }

    func testRateLimitedDescriptionIncludesRetryAfter() {
        let withRetry = ProviderError.rateLimited(retryAfter: 60)
        XCTAssertTrue(withRetry.description.contains("60"))
        let withoutRetry = ProviderError.rateLimited(retryAfter: nil)
        XCTAssertEqual(withoutRetry.description, "rate limited")
    }

    func testPartialErrorListsCreatedResources() {
        let err = ProviderError.partial(
            created: ["postgres srv-pg-123"],
            failed: "web service create"
        )
        XCTAssertTrue(err.description.contains("postgres srv-pg-123"))
        XCTAssertTrue(err.description.contains("web service create"))
    }

    // ── ProviderService round-trip (it's Codable for instances.json) ──

    func testProviderServiceCodableRoundTrip() throws {
        let original = ProviderService(
            id: "srv-abc123",
            metadata: ["pg_id": "srv-pg-456", "owner_slug": "studio"]
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProviderService.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }
}
