import AppleAdsClient
import Foundation
import OpenAPIRuntime
import Vapor

/// An Apple Ads ad account the configured API user can reach, as the
/// settings panel's picker shows it. IDs are strings on our side of the
/// wire so the SPA never meets an Int64 that JavaScript can't hold.
struct ASAAdAccount: Content, Equatable {
    let id: String
    let name: String
    let orgId: String
    let roles: [String]
}

/// Every failure the Apple Ads adapter surfaces. The descriptions are
/// user-facing copy: they end up in the settings panel and in 502 reasons,
/// so they say what to do, not what the transport saw.
enum AppleAdsError: Error, Equatable, CustomStringConvertible {
    case unauthorized
    case forbidden
    case rateLimited
    case adAccountSelectionRequired([ASAAdAccount])
    case unreadableResponse(String)
    case http(status: Int, message: String)
    /// The OAuth exchange itself failed, before any API call was made.
    case authFailed(String)
    /// No response at all: DNS, TLS, timeout, connection reset.
    case unreachable(String)
    /// The stored ad account ID isn't a number, so it can't be Apple's.
    case invalidAdAccountId(String)

    var description: String {
        switch self {
        case .unauthorized:
            return "Apple Ads rejected the credentials (401). Check the client ID and client secret; the secret may have expired."
        case .forbidden:
            return "Apple Ads returned 403: this API user can't read the selected ad account. Check its role in Apple Ads."
        case .rateLimited:
            return "Apple Ads is rate-limiting requests (429). Try again in a minute."
        case .adAccountSelectionRequired(let accounts):
            return "These credentials can reach \(accounts.count) ad accounts. Pick one in Settings → Apple Ads."
        case .unreadableResponse(let detail):
            return "Keywordista couldn't read Apple Ads' response (\(detail)). Apple may have changed the API."
        case .http(let status, let message):
            return message.isEmpty ? "Apple Ads returned HTTP \(status)." : "Apple Ads returned HTTP \(status): \(message.prefix(300))"
        case .authFailed(let message):
            return "Couldn't get an Apple Ads access token: \(message)"
        case .unreachable(let detail):
            return "Couldn't reach Apple Ads: \(detail)"
        case .invalidAdAccountId(let raw):
            return "The saved ad account ID \"\(raw)\" isn't valid. Pick the ad account again in Settings → Apple Ads."
        }
    }

    /// Maps a non-2xx status (and Apple's error body, when it decoded) to a case.
    static func status(_ code: Int, _ body: Components.Schemas._Error? = nil) -> AppleAdsError {
        switch code {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 429: return .rateLimited
        default: return .http(status: code, message: body?.message ?? body?.code ?? "")
        }
    }

    /// Some operations wrap the error object in `{"error": …}`.
    static func status(_ code: Int, _ body: Components.Schemas.ErrorResponse?) -> AppleAdsError {
        status(code, body?.error)
    }

    /// Translates whatever the generated client threw into a readable case.
    ///
    /// Why the response status wins over the decode failure: Apple's error
    /// bodies don't always match the spec (a bare `{}` on 401 is common), so
    /// the generated decoder throws on the very responses we most need to
    /// explain. The status is the reliable signal.
    static func from(_ error: any Error) -> AppleAdsError {
        if let mapped = error as? AppleAdsError { return mapped }
        if let auth = error as? AppleAdsAuthError { return .authFailed(auth.message) }
        guard let client = error as? ClientError else {
            if error is DecodingError { return .unreadableResponse(String(describing: error).prefix(200).description) }
            return .unreachable(String(describing: error))
        }
        if let auth = client.underlyingError as? AppleAdsAuthError { return .authFailed(auth.message) }
        if let response = client.response {
            let code = response.status.code
            if !(200..<300).contains(code) { return .status(code) }
            return .unreadableResponse("\(client.operationID): \(decodingSummary(client.underlyingError))")
        }
        return .unreachable(client.causeDescription)
    }

    /// One line naming the field that failed, instead of a DecodingError dump.
    private static func decodingSummary(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return String(describing: error).prefix(200).description }
        let context: DecodingError.Context
        switch decoding {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c), .dataCorrupted(let c): context = c
        @unknown default: return "unexpected shape"
        }
        let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        return path.isEmpty ? context.debugDescription : "unexpected value at \(path)"
    }
}

/// Any route that lets an `AppleAdsError` escape answers 502 with the copy.
/// Why 502 and never Apple's own status: the SPA treats every 401 as "your
/// Keywordista session expired" and sends the user to /login, and a 500
/// would hide the reason (the dashboard's opportunity call used to).
extension AppleAdsError: AbortError {
    var status: HTTPResponseStatus { .badGateway }
    var reason: String { description }
}
