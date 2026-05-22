import Vapor

protocol ITunesSearchClientProtocol: Sendable {
    func search(term: String, country: String, limit: Int) async throws -> [SearchResultApp]
}

struct ITunesSearchClient: ITunesSearchClientProtocol {
    let client: any Client
    let logger: Logger
    // Wall-clock cap on a single iTunes call. Without this a hung TCP
    // connection (or a half-open socket Apple's edge sometimes leaves
    // behind) can pin a queue worker on a single job indefinitely,
    // wedging the entire pipeline. 30s is generous — successful calls
    // typically return in 200–500ms.
    static let requestTimeoutSeconds: UInt64 = 30

    func search(term: String, country: String, limit: Int) async throws -> [SearchResultApp] {
        let encodedTerm = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        var url = URI(string: "https://itunes.apple.com/search")
        url.query = "term=\(encodedTerm)&country=\(country.lowercased())&entity=software&limit=\(limit)&media=software"

        // Race the HTTP call against a timeout task. Whichever finishes
        // first wins; the other is cancelled. Standard Swift Concurrency
        // pattern for adding deadlines to async APIs that don't expose
        // their own timeout knob.
        let response: ClientResponse = try await withThrowingTaskGroup(of: ClientResponse.self) { group in
            let theClient = client
            let theURL = url
            let timeoutSeconds = Self.requestTimeoutSeconds
            group.addTask { try await theClient.get(theURL) }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw Abort(.gatewayTimeout, reason: "iTunes search timed out after \(timeoutSeconds)s")
            }
            guard let first = try await group.next() else {
                throw Abort(.internalServerError, reason: "iTunes search produced no result")
            }
            group.cancelAll()
            return first
        }

        guard response.status == HTTPResponseStatus.ok else {
            logger.error("iTunes search returned \(response.status) for term=\(term) country=\(country)")
            throw Abort(.badGateway, reason: "iTunes search failed with \(response.status)")
        }

        struct Envelope: Codable { let resultCount: Int; let results: [SearchResultApp] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let buffer = response.body else { return [] }
        return try decoder.decode(Envelope.self, from: Data(buffer: buffer)).results
    }
}
