@testable import App
import Crypto
import Foundation
import Testing

@Suite("AppStoreConnectClient")
struct AppStoreConnectClientTests {
    // ── JWT signing ──────────────────────────────────────────────────────

    @Test("signJWT produces a valid three-part token with expected header + payload claims")
    func signJWT_structureAndClaims() throws {
        let key = P256.Signing.PrivateKey()
        let creds = ASCCredentials(
            keyId: "ABCDE12345",
            issuerId: "11111111-2222-3333-4444-555555555555",
            privateKey: key.pemRepresentation
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let token = try AppStoreConnectClient.signJWT(credentials: creds, now: now)
        let parts = token.split(separator: ".")
        #expect(parts.count == 3, "JWT must be header.payload.signature")

        let header = try decodeBase64URLJSON(String(parts[0]))
        #expect(header["alg"] as? String == "ES256")
        #expect(header["typ"] as? String == "JWT")
        #expect(header["kid"] as? String == "ABCDE12345")

        let payload = try decodeBase64URLJSON(String(parts[1]))
        #expect(payload["iss"] as? String == "11111111-2222-3333-4444-555555555555")
        #expect(payload["aud"] as? String == "appstoreconnect-v1")
        #expect(payload["iat"] as? Int == 1_700_000_000)
        // 20-minute lifetime — Apple's hard ceiling.
        #expect(payload["exp"] as? Int == 1_700_000_000 + 1_200)
    }

    @Test("signJWT signature verifies under the matching public key")
    func signJWT_signatureVerifies() throws {
        let key = P256.Signing.PrivateKey()
        let creds = ASCCredentials(
            keyId: "k",
            issuerId: "i",
            privateKey: key.pemRepresentation
        )
        let token = try AppStoreConnectClient.signJWT(credentials: creds, now: Date())
        let parts = token.split(separator: ".")
        let signingInput = "\(parts[0]).\(parts[1])"
        let sigData = try base64URLDecode(String(parts[2]))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: sigData)
        #expect(key.publicKey.isValidSignature(signature, for: Data(signingInput.utf8)))
    }

    @Test("signJWT rejects garbage PEM with a descriptive Failure")
    func signJWT_rejectsInvalidPEM() throws {
        let creds = ASCCredentials(keyId: "k", issuerId: "i", privateKey: "not a pem")
        #expect(throws: AppStoreConnectClient.Failure.self) {
            _ = try AppStoreConnectClient.signJWT(credentials: creds, now: Date())
        }
    }

    // ── Keyword parsing ──────────────────────────────────────────────────

    @Test("parseKeywords splits on commas, trims, lowercases, drops empties")
    func parseKeywords_basics() {
        let parsed = AppStoreConnectClient.parseKeywords(" Anki , Flashcards,study,, SPACED REPETITION ")
        #expect(parsed == ["anki", "flashcards", "study", "spaced repetition"])
    }

    @Test("parseKeywords returns [] for nil / empty input")
    func parseKeywords_emptyCases() {
        #expect(AppStoreConnectClient.parseKeywords(nil) == [])
        #expect(AppStoreConnectClient.parseKeywords("") == [])
        #expect(AppStoreConnectClient.parseKeywords(",,,") == [])
    }

    @Test("parseKeywords preserves unicode and casing-folds Latin only")
    func parseKeywords_unicode() {
        let parsed = AppStoreConnectClient.parseKeywords("暗記カード,Karteikarten,FLASH")
        #expect(parsed == ["暗記カード", "karteikarten", "flash"])
    }

    // ── base64URL helpers ────────────────────────────────────────────────

    // ── Live-API quirk regressions ───────────────────────────────────────

    @Test("does not send `sort` on /v1/apps/{id}/appStoreVersions — ASC rejects it with 400")
    func versionsQuery_doesNotPassSort() throws {
        // ASC's nested versions endpoint refuses `sort` (only the top-level
        // /v1/appStoreVersions accepts it). We sort client-side instead;
        // make sure no future refactor reintroduces the parameter.
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/AppTests/AppStoreConnectClientTests.swift",
            with: "Sources/App/Clients/AppStoreConnectClient.swift"
        ))
        let versionsBlock = source.range(of: "/v1/apps/\\(appId)/appStoreVersions")
        #expect(versionsBlock != nil, "expected to find the appStoreVersions call site")
        if let r = versionsBlock {
            // Slice the next ~250 chars (covers the query string + decl line)
            // and assert `sort` doesn't appear inside it.
            let end = source.index(r.upperBound, offsetBy: 250, limitedBy: source.endIndex) ?? source.endIndex
            let snippet = source[r.upperBound..<end]
            #expect(!snippet.contains("sort="), "the nested versions endpoint rejects `sort` — see fetchLatestVersionId for the workaround")
        }
    }

    @Test("base64URL strips padding and uses URL-safe alphabet")
    func base64URL_encoding() {
        // The bytes 0xFB,0xFF produce '+' and '/' in standard b64; URL-safe
        // form must replace them with '-' and '_' and drop trailing '='.
        let data = Data([0xFB, 0xFF, 0xFF])
        let encoded = AppStoreConnectClient.base64URL(data)
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.hasSuffix("="))
    }
}

// ── Test helpers (file-private — Swift Testing allows free functions) ────

private func decodeBase64URLJSON(_ s: String) throws -> [String: Any] {
    let data = try base64URLDecode(s)
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "test", code: 1)
    }
    return obj
}

private func base64URLDecode(_ s: String) throws -> Data {
    var padded = s
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    // Re-add the '=' padding that base64URL stripped.
    while padded.count % 4 != 0 { padded.append("=") }
    guard let data = Data(base64Encoded: padded) else {
        throw NSError(domain: "test", code: 2)
    }
    return data
}
