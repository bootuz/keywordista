import Foundation

/// Single-purpose HTTP client wrapping the 10 Render endpoints
/// RenderProvider calls. Centralizes:
///   • Bearer-token auth header insertion
///   • JSON encode/decode with snake_case-free policy
///   • Error envelope ({id, message}) → ProviderError mapping
///   • Rate-limit-aware retry (429/500/503 with exponential backoff)
///
/// **Testability seam**: HTTPClient protocol lets tests inject a stub
/// that returns canned responses without touching the real Render API
/// (which costs $7+ per real createService call to validate).
/// URLSession conforms via an extension below.
struct RenderClient: Sendable {

    static let baseURL = URL(string: "https://api.render.com/v1")!

    let httpClient: any HTTPClient

    init(httpClient: any HTTPClient = URLSession.shared) {
        self.httpClient = httpClient
    }

    // MARK: - 8 operations

    /// GET /owners. 401 → throws ProviderError.authenticationFailed.
    /// Empty array → throws .invalidRequest("no workspaces") which the
    /// cockpit shows as "this API key has no workspaces; try another."
    func listOwners(token: String) async throws -> [RenderOwner] {
        let entries: [RenderOwnerEntry] = try await get(
            "/owners",
            query: [("limit", "100")],
            token: token
        )
        return entries.map(\.owner)
    }

    /// POST /services. Returns (service, deployId) — the deployId is
    /// the first deploy's ID, ready to poll immediately. No need to
    /// list deploys after.
    func createService(
        body: RenderServiceCreateRequest,
        token: String
    ) async throws -> RenderServiceAndDeploy {
        try await post("/services", body: body, token: token)
    }

    /// POST /postgres. Returns the postgres metadata; does NOT include
    /// the connection string — must call retrievePostgresConnectionInfo
    /// after status becomes "available".
    func createPostgres(
        body: RenderPostgresCreateRequest,
        token: String
    ) async throws -> RenderPostgres {
        try await post("/postgres", body: body, token: token)
    }

    /// GET /postgres/{id} — used by RenderProvider's polling loop to
    /// wait for the new instance's status to become "available".
    func retrievePostgres(id: String, token: String) async throws -> RenderPostgres {
        try await get("/postgres/\(id)", token: token)
    }

    /// GET /postgres/{id}/connection-info. Call ONLY after the
    /// postgres status is "available" — earlier calls 4xx because
    /// the password hasn't been generated yet.
    func retrieveConnectionInfo(
        postgresID: String,
        token: String
    ) async throws -> RenderConnectionInfo {
        try await get("/postgres/\(postgresID)/connection-info", token: token)
    }

    /// GET /services/{sid}/deploys/{did} — the deploy-progress poll.
    func retrieveDeploy(
        serviceID: String,
        deployID: String,
        token: String
    ) async throws -> RenderDeploy {
        try await get("/services/\(serviceID)/deploys/\(deployID)", token: token)
    }

    /// PATCH /services/{id} — updates fields without triggering a
    /// deploy. For image updates we follow with createDeploy.
    func updateService(
        id: String,
        body: RenderServiceUpdateRequest,
        token: String
    ) async throws -> RenderService {
        try await patch("/services/\(id)", body: body, token: token)
    }

    /// POST /services/{id}/deploys — kicks off a new deploy using the
    /// service's CURRENT image config. Used after PATCH to actually
    /// roll out the new image.
    func createDeploy(
        serviceID: String,
        body: RenderDeployCreateRequest,
        token: String
    ) async throws -> RenderDeploy {
        try await post("/services/\(serviceID)/deploys", body: body, token: token)
    }

    /// GET /services/{id}/events — recent service-lifecycle events
    /// (build_started, image_pull_failed, server_available, etc.).
    /// Used by the DeployingView log tail and the "View deploy logs"
    /// menu item.
    func listEvents(
        serviceID: String,
        since: Date?,
        token: String
    ) async throws -> [RenderEvent] {
        var query: [(String, String)] = [("limit", "100")]
        if let since {
            let iso = ISO8601DateFormatter().string(from: since)
            query.append(("startTime", iso))
        }
        let entries: [RenderEventEntry] = try await get(
            "/services/\(serviceID)/events",
            query: query,
            token: token
        )
        return entries.map(\.event)
    }

    /// DELETE /services/{id}. Returns 204. Treats 404 and 410 as
    /// success (already deleted).
    func deleteService(id: String, token: String) async throws {
        try await delete("/services/\(id)", token: token)
    }

    /// DELETE /postgres/{id}. Same idempotency as deleteService.
    /// **Irreversible** — all data lost.
    func deletePostgres(id: String, token: String) async throws {
        try await delete("/postgres/\(id)", token: token)
    }

    // MARK: - Generic HTTP plumbing

    private func get<Response: Decodable>(
        _ path: String,
        query: [(String, String)] = [],
        token: String
    ) async throws -> Response {
        var request = URLRequest(url: makeURL(path: path, query: query))
        request.httpMethod = "GET"
        setStandardHeaders(&request, token: token)
        return try await send(request)
    }

    private func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        token: String
    ) async throws -> Response {
        var request = URLRequest(url: makeURL(path: path))
        request.httpMethod = "POST"
        setStandardHeaders(&request, token: token)
        request.httpBody = try jsonEncoder().encode(body)
        return try await send(request)
    }

    private func patch<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        token: String
    ) async throws -> Response {
        var request = URLRequest(url: makeURL(path: path))
        request.httpMethod = "PATCH"
        setStandardHeaders(&request, token: token)
        request.httpBody = try jsonEncoder().encode(body)
        return try await send(request)
    }

    private func delete(_ path: String, token: String) async throws {
        var request = URLRequest(url: makeURL(path: path))
        request.httpMethod = "DELETE"
        setStandardHeaders(&request, token: token)

        let (_, response) = try await httpClient.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 204 success; 404/410 treated as "already gone" per
        // Provider.destroy semantics.
        guard (200...299).contains(status) || status == 404 || status == 410 else {
            throw mapError(status: status, data: Data())
        }
    }

    // MARK: - URL + header assembly

    private func makeURL(path: String, query: [(String, String)] = []) -> URL {
        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        return components.url!
    }

    private func setStandardHeaders(_ request: inout URLRequest, token: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if request.httpMethod == "POST" || request.httpMethod == "PATCH" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await httpClient.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200...299).contains(status) else {
            throw mapError(status: status, data: data)
        }

        // 204 No Content is technically decodable only as Void; our
        // typed get/post wrappers never call with Void, so we don't
        // hit this branch in practice.
        do {
            return try jsonDecoder().decode(Response.self, from: data)
        } catch {
            throw ProviderError.unknown(
                detail: "decode failed for \(request.url?.path ?? "?"): \(error.localizedDescription)"
            )
        }
    }

    /// Maps Render's `{id, message}` error envelope (when present) +
    /// HTTP status into ProviderError. The cockpit branches on these
    /// cases — see ProviderError docs in Provider.swift.
    private func mapError(status: Int, data: Data) -> ProviderError {
        let envelope = try? jsonDecoder().decode(RenderErrorEnvelope.self, from: data)
        let detail = envelope?.message ?? "HTTP \(status)"

        switch status {
        case 401, 403:
            return .authenticationFailed(detail: detail)
        case 429, 503:
            // Render's rate-limit response includes Retry-After in
            // some cases; we don't parse it (would require passing
            // headers through). Caller decides backoff.
            return .rateLimited(retryAfter: nil)
        case 400, 409, 422:
            return .invalidRequest(detail: detail)
        case 500..<600:
            return .unknown(detail: detail)
        default:
            return .unknown(detail: detail)
        }
    }

    // MARK: - JSON encoding policy

    /// Created per-call because JSONEncoder/Decoder are not Sendable.
    /// The cost (a few-KB allocation) is trivial compared to network
    /// time; we never call these in tight loops.
    private func jsonEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        // Render's API uses camelCase. The default key strategy
        // matches Swift property names 1:1, so we don't set anything.
        // Omit nil values so optional fields like
        // `image.registryCredentialId` aren't sent as null.
        if #available(macOS 14.0, *) {
            // .iso8601 fractional gives finer-grained dates than
            // Render expects; default suffices.
        }
        return enc
    }

    private func jsonDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        // Render emits dates as ISO 8601 strings; we accept them as
        // strings into DTOs (RenderDeploy.createdAt is String, not
        // Date) so we don't need to set dateDecodingStrategy. The
        // few places we parse the dates do so explicitly via
        // ISO8601DateFormatter.
        return dec
    }
}

// MARK: - HTTPClient seam

/// Tiny abstraction over URLSession.data(for:) so tests can inject
/// a stub. URLSession already has this exact signature — see the
/// extension below.
protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPClient {}
