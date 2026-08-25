import Foundation
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokSamplingTypes
import OpenGrokWebMediaTools
import Testing

@testable import OpenGrokCLI

private struct RemoteMediaPolicyFixture {
    let root: URL
    let environment: [String: String]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-remote-media-policy-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        environment = [
            "HOME": root.path,
            "OPENGROK_HOME": root.path,
            "GROK_WEB_FETCH": "true",
            "GROK_VIDEO_GEN": "true",
            "XAI_API_KEY": "remote-media-policy-test-key",
        ]
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func web(
        remote: RemoteSettings,
        effectiveConfig: TOMLValue = .table(TOMLTable()),
        requirements: [TOMLValue] = [],
        environment override: [String: String]? = nil
    ) -> WebFetchConfig {
        LiveWebToolComposition.resolveFetchConfig(
            workingDirectory: root,
            openGrokHome: root,
            environment: override ?? environment,
            effectiveConfig: effectiveConfig,
            requirements: requirements,
            remoteSettings: remote
        )
    }

    func video(
        remote: RemoteSettings,
        requirements: [TOMLValue] = []
    ) -> LiveVideoToolAvailability {
        LiveVideoToolComposition.resolveAvailability(
            workingDirectory: root,
            openGrokHome: root,
            environment: environment,
            effectiveConfig: .table(TOMLTable()),
            samplingProvider: .xai,
            samplingAPIKey: "remote-media-policy-test-key",
            samplingBaseURL: "https://api.x.ai/v1",
            requirements: requirements,
            remoteSettings: remote
        )
    }
}

@Suite("live authenticated remote web and media policy parity")
struct LiveRemoteMediaPolicyParityTests {
    @Test("trusted web-search domain policy survives live tool resolution")
    func trustedWebSearchDomainPolicyReachesLiveToolAvailability() throws {
        let fixture = try RemoteMediaPolicyFixture()
        defer { fixture.cleanUp() }
        let config = try parseTOML("""
            [toolset.web_search]
            allowed_domains = ["docs.example.com"]
            """)
        let availability = LiveWebToolComposition.resolveAvailability(
            workingDirectory: fixture.root,
            openGrokHome: fixture.root,
            environment: fixture.environment,
            samplingProvider: .xai,
            samplingAPIKey: "remote-media-policy-test-key",
            samplingBaseURL: "https://api.x.ai/v1",
            disableWebSearch: false,
            effectiveConfig: config
        )

        #expect(availability.searchFilter.allowedDomains == ["docs.example.com"])
        #expect(availability.searchFilter.resolveFilters(
            modelAllowed: ["untrusted.example"]
        ).allowedDomains == ["docs.example.com"])
    }

    @Test("remote fetch force-off cannot be reenabled by environment")
    func remoteFetchForceOff() throws {
        let fixture = try RemoteMediaPolicyFixture()
        defer { fixture.cleanUp() }
        var remote = RemoteSettings()
        remote.webFetchEnabled = false

        #expect(fixture.web(remote: remote) == .disabled)
    }

    @Test("administrator pin outranks remote fetch force-off")
    func managedFetchPinOutranksRemote() throws {
        let fixture = try RemoteMediaPolicyFixture()
        defer { fixture.cleanUp() }
        var remote = RemoteSettings()
        remote.webFetchEnabled = false
        let permit = try parseTOML("[features]\nweb_fetch = true\n")

        #expect(fixture.web(remote: remote, requirements: [permit]).isEnabled)
    }

    @Test("remote domain authority intersects local allowlists")
    func remoteDomainAuthorityOnlyNarrows() throws {
        let fixture = try RemoteMediaPolicyFixture()
        defer { fixture.cleanUp() }
        var remote = RemoteSettings()
        remote.webFetchEnabled = true
        remote.webFetchAllowedDomains = ["docs.example.com/reference", "other.example.com"]
        let local = try parseTOML("""
            [toolset.web_fetch]
            allowed_domains = ["example.com", "unrelated.invalid"]
            """)

        guard case .enabled(let parameters) = fixture.web(remote: remote, effectiveConfig: local) else {
            Issue.record("intersecting remote and local authorities unexpectedly disabled fetch")
            return
        }
        #expect(parameters.allowedDomains == ["docs.example.com/reference", "other.example.com"])

        remote.webFetchAllowedDomains = ["outside.invalid"]
        #expect(fixture.web(remote: remote, effectiveConfig: local) == .disabled)
    }

    @Test("malformed remote domains fail closed", arguments: [
        "", "*.example.com", "https://example.com", "example.com/../private",
        "alice@example.com", "example.com:443", "example..com",
    ])
    func malformedRemoteDomainsFailClosed(_ entry: String) throws {
        let fixture = try RemoteMediaPolicyFixture()
        defer { fixture.cleanUp() }
        var remote = RemoteSettings()
        remote.webFetchEnabled = true
        remote.webFetchAllowedDomains = [entry]

        #expect(fixture.web(remote: remote) == .disabled)
    }

    @Test("remote proxy remains authoritative and malformed endpoints disable fetch")
    func remoteProxyCannotBeBypassed() throws {
        let fixture = try RemoteMediaPolicyFixture()
        defer { fixture.cleanUp() }
        var environment = fixture.environment
        environment["GROK_WEB_FETCH_PROXY"] = "https://untrusted-proxy.example.com"
        var remote = RemoteSettings()
        remote.webFetchEnabled = true
        remote.webFetchProxy = "https://authoritative-proxy.example.com"

        guard case .enabled(let parameters) = fixture.web(remote: remote, environment: environment) else {
            Issue.record("authenticated remote proxy unexpectedly disabled fetch")
            return
        }
        #expect(parameters.proxyEndpoint == "https://authoritative-proxy.example.com")

        remote.webFetchProxy = "ftp://attacker.example.com"
        #expect(fixture.web(remote: remote, environment: environment) == .disabled)
    }

    @Test("each remotely denylisted video tool closes both live tools", arguments: [
        "image_to_video", "reference_to_video", "video_gen",
    ])
    func remoteVideoDenylistClosesPair(_ name: String) throws {
        let fixture = try RemoteMediaPolicyFixture()
        defer { fixture.cleanUp() }
        var remote = RemoteSettings()
        remote.imagineToolsDisabled = [name]

        let availability = fixture.video(remote: remote)
        #expect(!availability.imageToVideoEnabled)
        #expect(!availability.referenceToVideoEnabled)
    }

    @Test("remote video feature force-off cannot be reenabled locally")
    func remoteVideoForceOff() throws {
        let fixture = try RemoteMediaPolicyFixture()
        defer { fixture.cleanUp() }
        var remote = RemoteSettings()
        remote.videoGenEnabled = false

        #expect(!fixture.video(remote: remote).advertisesAnything)
    }

    @Test("administrator video pin outranks remote denylist")
    func managedVideoPinOutranksRemote() throws {
        let fixture = try RemoteMediaPolicyFixture()
        defer { fixture.cleanUp() }
        var remote = RemoteSettings()
        remote.videoGenEnabled = false
        remote.imagineToolsDisabled = ["image_to_video"]
        let permit = try parseTOML("[features]\nvideo_gen = true\n")

        let availability = fixture.video(remote: remote, requirements: [permit])
        #expect(availability.imageToVideoEnabled)
        #expect(availability.referenceToVideoEnabled)
    }
}
