import Foundation

/// Metrics with the ratios the Apple Ads screens show.
///
/// Why tap installs for CPI and CR: view-through installs are attribution
/// Apple infers from impressions, so counting them would make every keyword
/// look cheaper than the taps it bought. `totalInstalls` still shows them.
struct AppleAdsMetricsDTO: Codable, Sendable, Equatable {
    let impressions: Int
    let taps: Int
    let tapInstalls: Int
    let totalInstalls: Int
    let spend: Double
    /// Cost per tap.
    let cpt: Double?
    /// Cost per (tap) install.
    let cpi: Double?
    /// Tap-through rate: taps ÷ impressions.
    let ttr: Double?
    /// Conversion rate: tap installs ÷ taps.
    let cr: Double?
    /// Under 50 taps the ratios swing on a handful of events; the UI greys them.
    let lowData: Bool
}

enum AppleAdsMath {
    static let lowDataTaps = 50

    static func dto(_ m: AppleAdsMetrics) -> AppleAdsMetricsDTO {
        AppleAdsMetricsDTO(
            impressions: m.impressions,
            taps: m.taps,
            tapInstalls: m.tapInstalls,
            totalInstalls: m.totalInstalls,
            spend: m.spend,
            cpt: ratio(m.spend, m.taps),
            cpi: ratio(m.spend, m.tapInstalls),
            ttr: ratio(Double(m.taps), m.impressions),
            cr: ratio(Double(m.tapInstalls), m.taps),
            lowData: m.taps < lowDataTaps
        )
    }

    /// The `days`-long period ending at `endingAt`, and the one just before it.
    static func periods(endingAt end: String, days: Int) -> (current: ClosedRange<String>, previous: ClosedRange<String>) {
        let start = shift(end, days: -(days - 1))
        let previousEnd = shift(start, days: -1)
        return (start...end, shift(previousEnd, days: -(days - 1))...previousEnd)
    }

    /// Every `yyyy-MM-dd` day in the range, in order.
    static func days(in range: ClosedRange<String>) -> [String] {
        var out: [String] = []
        var day = range.lowerBound
        while day <= range.upperBound, out.count < 400 {
            out.append(day)
            day = shift(day, days: 1)
        }
        return out
    }

    /// Moves a `yyyy-MM-dd` day by whole days. Report days are calendar days
    /// in the org's timezone, so UTC arithmetic on the bare date is exact.
    static func shift(_ day: String, days: Int) -> String {
        guard let date = formatter.date(from: day),
              let moved = calendar.date(byAdding: .day, value: days, to: date) else { return day }
        return formatter.string(from: moved)
    }

    private static func ratio(_ numerator: Double, _ denominator: Int) -> Double? {
        denominator == 0 ? nil : numerator / Double(denominator)
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
