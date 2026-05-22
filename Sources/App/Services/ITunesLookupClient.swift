import Vapor

protocol ITunesLookupClientProtocol: Sendable {
    func lookup(appStoreId: Int64, country: String) async throws -> LookupResultApp
}

struct ITunesLookupClient: ITunesLookupClientProtocol {
    let client: any Client

    func lookup(appStoreId: Int64, country: String) async throws -> LookupResultApp {
        var url = URI(string: "https://itunes.apple.com/lookup")
        url.query = "id=\(appStoreId)&country=\(country.lowercased())&entity=software"

        let response = try await client.get(url)
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "iTunes lookup failed with \(response.status)")
        }

        struct Envelope: Codable { let resultCount: Int; let results: [LookupResultApp] }
        guard let buffer = response.body else {
            throw Abort(.badGateway, reason: "iTunes lookup empty body")
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(buffer: buffer))
        guard let first = envelope.results.first else {
            throw Abort(.notFound, reason: "No app found for id=\(appStoreId) in country=\(country)")
        }
        return first
    }
}
