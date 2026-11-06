@testable import App
import Testing

@Suite("VersionService release channel")
struct VersionServiceTagTests {
    @Test("server-v tags yield their version")
    func serverChannelTagParses() {
        #expect(VersionService.serverReleaseVersion(fromTag: "server-v0.8.0") == "0.8.0")
    }

    @Test("legacy service-v tags are ignored (frozen macOS 13+ channel)")
    func legacyServiceChannelIgnored() {
        #expect(VersionService.serverReleaseVersion(fromTag: "service-v0.9.0") == nil)
    }

    @Test("other release streams are ignored")
    func otherStreamsIgnored() {
        #expect(VersionService.serverReleaseVersion(fromTag: "app-v0.8.0") == nil)
        #expect(VersionService.serverReleaseVersion(fromTag: "image-v0.8.0") == nil)
    }
}
