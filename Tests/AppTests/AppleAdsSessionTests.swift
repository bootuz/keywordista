@testable import App
import AppleAdsClient
import Logging
import Testing

/// Counts factory invocations so tests can tell reuse from re-creation.
private actor FactoryCounter {
    private(set) var calls = 0
    func bump() { calls += 1 }
}

@Suite("AppleAdsSession")
struct AppleAdsSessionTests {
    private static let credsA = ASACredentials(clientId: "SEARCHADS.a", clientSecret: "jwt-a", orgId: nil)
    private static let credsB = ASACredentials(clientId: "SEARCHADS.a", clientSecret: "jwt-b", orgId: nil)

    private func makeSession(_ counter: FactoryCounter) -> AppleAdsSession {
        AppleAdsSession(logger: Logger(label: "test")) { _ in
            await counter.bump()
            return try await makeTestAppleAdsClient()
        }
    }

    @Test("same credentials reuse one client")
    func reusesClientForSameCredentials() async throws {
        let counter = FactoryCounter()
        let session = makeSession(counter)
        _ = try await session.client(for: Self.credsA)
        _ = try await session.client(for: Self.credsA)
        #expect(await counter.calls == 1)
        await session.shutdown()
    }

    @Test("concurrent first calls share one construction")
    func concurrentFirstCallsShareConstruction() async throws {
        let counter = FactoryCounter()
        let session = makeSession(counter)
        async let one = session.client(for: Self.credsA)
        async let two = session.client(for: Self.credsA)
        _ = try await (one, two)
        #expect(await counter.calls == 1)
        await session.shutdown()
    }

    @Test("changed credentials build a new client and shut the old one down")
    func changedCredentialsReplaceAndShutDownClient() async throws {
        let counter = FactoryCounter()
        let session = makeSession(counter)
        _ = try await session.client(for: Self.credsA)
        _ = try await session.client(for: Self.credsB)
        #expect(await counter.calls == 2)
        #expect(await session.completedShutdowns == 1)
        await session.shutdown()
        #expect(await session.completedShutdowns == 2)
    }

    @Test("shutdown is idempotent")
    func shutdownIsIdempotent() async throws {
        let session = makeSession(FactoryCounter())
        _ = try await session.client(for: Self.credsA)
        await session.shutdown()
        await session.shutdown()
        #expect(await session.completedShutdowns == 1)
    }
}
