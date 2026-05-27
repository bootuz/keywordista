import Vapor

/// Fetches the public `https://apps.apple.com/<country>/app/-/id<N>` page
/// and extracts the app's subtitle from the embedded `<p class="subtitle …">`
/// element. This is the only field we currently scrape — every other field
/// in the metadata pipeline comes from iTunes Lookup (cheaper, no HTML
/// parsing). Subtitle is uniquely valuable to ASO and uniquely absent from
/// the lookup API, so the round-trip cost is justified.
///
/// Why this is its own service (not folded into `ITunesLookupClient`):
///   • Different host, different rate-limit posture (apps.apple.com is a
///     consumer-facing CDN; itunes.apple.com is an API endpoint).
///   • Failure semantics differ — scrape misses are common (apps without a
///     subtitle) and shouldn't fail the snapshot. Lookup misses are rare
///     and signal a real problem (delisted app, wrong storefront).
///   • Lets the test fake for the snapshot service be minimal — one stub
///     per concern.
protocol AppStoreHTMLScraperProtocol: Sendable {
    /// Returns the subtitle string if the page renders one, `nil` if the
    /// app has no subtitle (legitimate empty state) or if the scrape
    /// failed. The caller distinguishes the two via `ScrapeOutcome`.
    func scrapeSubtitle(appStoreId: Int64, country: String) async throws -> ScrapeOutcome
}

/// Two-state result so the snapshot service can decide whether to carry
/// forward the prior row's subtitle (on `.failed`) vs. accept an absent
/// subtitle (on `.succeeded(nil)`) without re-checking error semantics.
enum ScrapeOutcome: Sendable, Equatable {
    case succeeded(subtitle: String?)
    case failed(reason: String)
}

struct AppStoreHTMLScraper: AppStoreHTMLScraperProtocol {
    let client: any Client
    let logger: Logger
    // Same shape as ITunesSearchClient's wall-clock cap. apps.apple.com is
    // a CDN-fronted page that almost always returns in <500ms when it
    // returns at all, but a hung TCP socket would otherwise pin a queue
    // worker and wedge the daily-snapshot pipeline.
    static let requestTimeoutSeconds: UInt64 = 30

    func scrapeSubtitle(appStoreId: Int64, country: String) async throws -> ScrapeOutcome {
        // The `/-/` slug placeholder makes the URL self-describing without
        // knowing the app's slug — Apple 301-redirects to the canonical
        // URL, but the response body of the redirect itself contains the
        // page when we follow it. Vapor's `Client` follows redirects by
        // default.
        let urlString = "https://apps.apple.com/\(country.lowercased())/app/-/id\(appStoreId)"
        let url = URI(string: urlString)

        let response: ClientResponse
        do {
            response = try await withThrowingTaskGroup(of: ClientResponse.self) { group in
                let theClient = client
                let theURL = url
                let timeoutSeconds = Self.requestTimeoutSeconds
                group.addTask {
                    // Apple sometimes serves a stripped-down page (or 403s)
                    // to clients without a browser-shaped User-Agent. Set
                    // a generic one to get the canonical rendering.
                    var headers = HTTPHeaders()
                    headers.add(name: .userAgent, value: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15")
                    return try await theClient.get(theURL, headers: headers)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                    throw Abort(.gatewayTimeout, reason: "apps.apple.com scrape timed out after \(timeoutSeconds)s")
                }
                guard let first = try await group.next() else {
                    throw Abort(.internalServerError, reason: "apps.apple.com scrape produced no result")
                }
                group.cancelAll()
                return first
            }
        } catch {
            logger.warning("apps.apple.com HTTP failed for id=\(appStoreId) country=\(country): \(String(describing: error))")
            return .failed(reason: "http: \(error)")
        }

        guard response.status == .ok else {
            logger.warning("apps.apple.com returned \(response.status) for id=\(appStoreId) country=\(country)")
            return .failed(reason: "http \(response.status)")
        }
        guard let buffer = response.body else {
            return .failed(reason: "empty body")
        }
        let html = String(buffer: buffer)
        return .succeeded(subtitle: Self.extractSubtitle(from: html))
    }

    /// Pulls the first `<p class="…subtitle…">…</p>` block's inner text out
    /// of Apple's HTML. Tolerant of the rotating svelte hash that's
    /// appended to the class list (`class="subtitle svelte-kps97o"`).
    /// Returns `nil` if no subtitle element is present (legitimate — many
    /// apps don't ship one) or if the element is empty.
    static func extractSubtitle(from html: String) -> String? {
        // Match `<p` then `class="…subtitle…"` (any class-list containing
        // `subtitle` as a whole word) then `>` then the inner text up to
        // the closing `</p>`. Greedy on the text capture is fine because
        // `<p>` rarely nests.
        // Using NSRegularExpression for predictable cross-Swift-version
        // behavior; Swift's own Regex DSL is fine but the literal syntax
        // is concise enough here.
        let pattern = #"<p[^>]*\bclass\s*=\s*"[^"]*\bsubtitle\b[^"]*"[^>]*>([^<]*)</p>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: nsRange),
              match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: html)
        else { return nil }

        // Apple's pages occasionally HTML-encode quotes and ampersands in
        // the subtitle ("Relax, Stress &amp; Anxiety Relief"). Unescape
        // the handful of common entities; we don't need a full HTML
        // unescaper for a 30-char copy field.
        let raw = String(html[captureRange])
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return trimmed
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
