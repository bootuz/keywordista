import Vapor

// Serves the SPA's index.html on 404 for non-API GET requests so client-side
// routing survives a browser refresh. Skips:
//   • non-GET methods (POST /api/foo should error, not return HTML)
//   • /api/* and /health (real API surface — let real 404s through)
//   • any path containing a "." in its last component (looked like an asset)
struct SPAFallbackMiddleware: AsyncMiddleware {
    let indexPath: String

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch let abort as AbortError where abort.status == .notFound {
            guard shouldServeSPA(for: request) else { throw abort }
            return try await serveIndex(req: request)
        }
    }

    private func shouldServeSPA(for request: Request) -> Bool {
        guard request.method == .GET else { return false }
        let path = request.url.path
        if path.hasPrefix("/api") || path == "/health" { return false }
        if let last = path.split(separator: "/").last, last.contains(".") { return false }
        return true
    }

    private func serveIndex(req: Request) async throws -> Response {
        let fileIO = req.fileio
        let response = try await fileIO.asyncStreamFile(at: indexPath)
        response.headers.replaceOrAdd(name: .contentType, value: "text/html; charset=utf-8")
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        return response
    }
}
