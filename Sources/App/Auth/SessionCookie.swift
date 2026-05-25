import Foundation
import Vapor

/// Cookie construction for AuthSession tokens.
///
/// Centralized so the three flags that *must* be set together
/// (`HttpOnly`, `Secure`, `SameSite=Strict`) live in one place and
/// can't accidentally drift between login / setup / accept-invite
/// handlers. Also pinned the cookie name here so future tooling
/// (cockpit's auto-login-cookie inspector, browser DevTools docs)
/// has a canonical reference.
///
/// Why **`SameSite=Strict`**: deployments are single-origin (the
/// SPA + the API share `KEYWORDISTA_PUBLIC_BASE_URL`), so we don't
/// need Lax's "allow top-level navigation" loophole. Strict gives
/// the strongest CSRF resistance available without a separate
/// token. If a future feature adds OAuth callbacks or third-party
/// embeds, revisit and downgrade to Lax.
///
/// Why **`HttpOnly`**: blocks `document.cookie` reads from JS — an
/// XSS injection can't exfiltrate the session token (it can still
/// make authenticated requests as a side effect, but the token
/// itself never leaves the browser's cookie jar).
///
/// Why **`Secure`**: cookie is only sent over HTTPS. In production,
/// providers terminate TLS upstream and forward over HTTP inside
/// the network; the `KEYWORDISTA_TRUST_PROXY` flag tells Vapor to
/// honor `X-Forwarded-Proto` so the binary correctly identifies
/// the original scheme.
enum SessionCookie {

    /// The cookie name. Pinned because some tooling reads it
    /// directly (cockpit's session inspector, future browser
    /// extensions). Renaming requires updating those too.
    static let name = "keywordista_session"

    /// Construct the Set-Cookie value carrying the session token.
    /// `expires` matches AuthSession.expiresAt so the browser auto-
    /// discards the cookie at the same moment the server would
    /// reject the session anyway.
    static func value(token: String, expiresAt: Date) -> HTTPCookies.Value {
        HTTPCookies.Value(
            string: token,
            expires: expiresAt,
            isSecure: true,
            isHTTPOnly: true,
            sameSite: .strict
        )
    }

    /// Construct a Set-Cookie value that immediately expires the
    /// cookie. Used by `/auth/logout` to clear the browser-side
    /// state regardless of whether the server-side AuthSession
    /// lookup succeeded.
    static func cleared() -> HTTPCookies.Value {
        HTTPCookies.Value(
            string: "",
            expires: Date(timeIntervalSince1970: 0),
            isSecure: true,
            isHTTPOnly: true,
            sameSite: .strict
        )
    }
}
