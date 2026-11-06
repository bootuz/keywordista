@testable import App
import AppleAdsClient
import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Token provider that never touches the network — lets tests build real
/// `AppleAdsClient`s (no OAuth HTTPClient is created in `.tokenProvider` mode).
struct StaticTokenProvider: TokenProvider {
    let value: String
    init(_ value: String = "test-token") { self.value = value }
    nonisolated(nonsending) func token() async throws -> String { value }
}

/// Scripted `ClientTransport`: pops one canned response per request and
/// records each request (method, path, headers, body) for assertions.
actor StubAppleAdsTransport: ClientTransport {
    struct Canned {
        let status: HTTPResponse.Status
        let json: String
        var headers: HTTPFields = [:]
    }
    struct Recorded {
        let method: HTTPRequest.Method
        let path: String
        let headers: HTTPFields
        let body: String?
        let operationID: String
    }

    private var queue: [Canned]
    private(set) var requests: [Recorded] = []

    init(_ responses: [Canned] = []) { self.queue = responses }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var text: String?
        if let body { text = try await String(collecting: body, upTo: 10 * 1024 * 1024) }
        requests.append(Recorded(
            method: request.method,
            path: request.path ?? "",
            headers: request.headerFields,
            body: text,
            operationID: operationID
        ))
        guard !queue.isEmpty else {
            throw StubError.outOfResponses(operationID)
        }
        let next = queue.removeFirst()
        var fields = next.headers
        fields[.contentType] = "application/json"
        return (HTTPResponse(status: next.status, headerFields: fields), HTTPBody(next.json))
    }

    enum StubError: Error { case outOfResponses(String) }
}

/// Builds a real `AppleAdsClient` wired to a stub transport and a static token.
func makeTestAppleAdsClient(
    transport: StubAppleAdsTransport = StubAppleAdsTransport(),
    middleware: [any ClientMiddleware] = []
) async throws -> AppleAdsClient {
    try await AppleAdsClient(
        configuration: .init(
            clientId: "SEARCHADS.test",
            authMode: .tokenProvider(StaticTokenProvider()),
            middleware: middleware
        ),
        transport: transport
    )
}
