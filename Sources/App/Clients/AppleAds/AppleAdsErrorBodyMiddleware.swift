import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Turns Apple Ads' error responses into an `AppleAdsError` carrying Apple's
/// own reason, e.g. "Filters contain unsupported fields campaignId".
///
/// Why a middleware rather than the per-operation `.badRequest(let r)` cases:
/// Apple wraps its error bodies (`{"error":{"message":…,"details":[…]}}`)
/// while the generated client documents a bare error object, so the decoder
/// throws before any of those cases run and the reason is lost. Reading the
/// raw body here works whatever shape Apple sends.
///
/// Why 401/403/429 pass through untouched: their copy doesn't depend on the
/// body, and `AppleAdsRetryMiddleware` has to see every 429 to retry it.
struct AppleAdsErrorBodyMiddleware: ClientMiddleware {
    static let passThroughStatuses: Set<Int> = [401, 403, 429]
    /// Error bodies are a few hundred bytes; this only guards against a runaway stream.
    static let maxBufferedBodyBytes = 64 * 1024

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        let code = response.status.code
        guard code >= 400, !Self.passThroughStatuses.contains(code) else {
            return (response, responseBody)
        }
        // An unreadable or oversized body still yields the bare status copy.
        let data: Data? = if let responseBody {
            try? await Data(collecting: responseBody, upTo: Self.maxBufferedBodyBytes)
        } else {
            nil
        }
        throw AppleAdsError.status(code, message: data.flatMap(Self.reason(from:)) ?? "")
    }

    /// The most specific reason in an Apple Ads error body: the first detail's
    /// message, else the error's message, else its code. Accepts both the
    /// wrapped `{"error": {…}}` shape and a bare error object.
    static func reason(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let error = object["error"] as? [String: Any] ?? object
        let firstDetail = (error["details"] as? [[String: Any]])?.first
        let candidates: [Any?] = [firstDetail?["message"], error["message"], error["code"]]
        return candidates.lazy
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
