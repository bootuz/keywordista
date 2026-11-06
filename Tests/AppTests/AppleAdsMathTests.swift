@testable import App
import Testing

@Suite("Apple Ads metrics math")
struct AppleAdsMathTests {
    @Test("ratios use tap installs; total installs include view-through")
    func dtoComputesRatiosFromTapInstalls() {
        let m = AppleAdsMetrics(impressions: 4000, taps: 200, tapInstalls: 10, viewInstalls: 5, totalInstalls: 15, spend: 50)
        let dto = AppleAdsMath.dto(m)
        #expect(dto.cpi == 5.0)
        #expect(dto.cr == 0.05)
        #expect(dto.cpt == 0.25)
        #expect(dto.ttr == 0.05)
        #expect(dto.totalInstalls == 15)
        #expect(!dto.lowData)
    }

    @Test("fewer than 50 taps is low data")
    func dtoMarksLowDataBelow50Taps() {
        #expect(AppleAdsMath.dto(AppleAdsFixtures.metrics(taps: 49)).lowData)
        #expect(!AppleAdsMath.dto(AppleAdsFixtures.metrics(taps: 50)).lowData)
    }

    @Test("a ratio with a zero denominator is nil")
    func zeroDenominatorsAreNil() {
        let dto = AppleAdsMath.dto(.zero)
        #expect(dto.cpi == nil)
        #expect(dto.cpt == nil)
        #expect(dto.ttr == nil)
        #expect(dto.cr == nil)
    }

    @Test("the previous period ends the day before the current one starts")
    func periodsAreContiguous() {
        let p = AppleAdsMath.periods(endingAt: "2026-11-06", days: 7)
        #expect(p.current == "2026-10-31"..."2026-11-06")
        #expect(p.previous == "2026-10-24"..."2026-10-30")
        let month = AppleAdsMath.periods(endingAt: "2026-03-01", days: 30)
        #expect(month.current == "2026-01-31"..."2026-03-01")
        #expect(month.previous == "2026-01-01"..."2026-01-30")
    }
}
