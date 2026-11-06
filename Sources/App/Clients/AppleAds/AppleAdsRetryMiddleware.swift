import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Retries Apple Ads 429s, but only for requests that are safe to send twice.
///
/// Why only GETs and `…/query` POSTs: every other Apple Ads POST/PUT/DELETE
/// changes a campaign, and a 429 doesn't promise the first attempt did
/// nothing. Phase 3's write operations must surface the 429 instead.
struct AppleAdsRetryMiddleware: ClientMiddleware {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    static let maxAttempts = 3
    static let initialDelaySeconds = 2
    static let maxDelaySeconds = 16
    /// Bodies are tiny JSON queries; this only guards against a runaway stream.
    static let maxBufferedBodyBytes = 1 * 1024 * 1024

    private let sleep: Sleep

    init(sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard Self.isRetryable(request) else {
            return try await next(request, body, baseURL)
        }
        // An HTTPBody may be single-pass, so buffer it once to resend it.
        let buffered: Data? = if let body {
            try await Data(collecting: body, upTo: Self.maxBufferedBodyBytes)
        } else {
            nil
        }
        var delay = Self.initialDelaySeconds
        var attempt = 1
        while true {
            let (response, responseBody) = try await next(request, buffered.map { HTTPBody($0) }, baseURL)
            guard response.status == .tooManyRequests, attempt < Self.maxAttempts else {
                return (response, responseBody)
            }
            let wait = response.headerFields[.retryAfter].flatMap(Int.init) ?? delay
            try await sleep(.seconds(min(max(wait, 0), Self.maxDelaySeconds)))
            delay = min(delay * 2, Self.maxDelaySeconds)
            attempt += 1
        }
    }

    static func isRetryable(_ request: HTTPRequest) -> Bool {
        if request.method == .get { return true }
        guard request.method == .post, let path = request.path else { return false }
        let bare = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return bare.hasSuffix("/query")
    }
}
