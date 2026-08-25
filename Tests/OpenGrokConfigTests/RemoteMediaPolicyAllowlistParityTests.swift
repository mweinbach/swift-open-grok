import OpenGrokConfigTypes
import Testing

@testable import OpenGrokConfig

@Suite("authenticated remote web and media policy allowlist parity")
struct RemoteMediaPolicyAllowlistParityTests {
    @Test("reviewed network and media fields survive projection")
    func reviewedFieldsProject() {
        var remote = RemoteSettings()
        remote.webFetchEnabled = false
        remote.webFetchProxy = "https://proxy.example.com"
        remote.webFetchAllowedDomains = ["docs.example.com"]
        remote.imageGenEnabled = false
        remote.videoGenEnabled = false
        remote.imagineToolsDisabled = ["image_edit", "image_to_video"]

        let projected = AllowlistedRemoteSettings(projecting: remote)

        #expect(projected.webFetchEnabled == false)
        #expect(projected.webFetchProxy == "https://proxy.example.com")
        #expect(projected.webFetchAllowedDomains == ["docs.example.com"])
        #expect(projected.imageGenEnabled == false)
        #expect(projected.videoGenEnabled == false)
        #expect(projected.imagineToolDisabled("image_edit"))
        #expect(projected.imagineToolDisabled("image_to_video"))
        #expect(!projected.imagineToolDisabled("IMAGE_EDIT"))
    }

    @Test("authenticated force-offs outrank local configuration and environment", arguments: [
        "web_fetch", "image_gen", "image_edit",
    ])
    func remoteDenialOutranksLocalOverrides(_ feature: String) throws {
        var remote = RemoteSettings()
        switch feature {
        case "web_fetch": remote.webFetchEnabled = false
        case "image_gen": remote.imageGenEnabled = false
        default: remote.imagineToolsDisabled = [feature]
        }
        let configuration = try parseTOML("[features]\n\(feature) = true\n")
        let resolved = EffectiveFeatures.resolve(FeatureResolutionInputs(
            effectiveConfig: configuration,
            remote: AllowlistedRemoteSettings(projecting: remote),
            environment: ["GROK_\(feature.uppercased())": "true"]
        ))

        let value: Resolved<Bool>
        switch feature {
        case "web_fetch": value = resolved.webFetch
        case "image_gen": value = resolved.imageGen
        default: value = resolved.imageEdit
        }
        #expect(value.value == false)
        #expect(value.source == .remote)
    }

    @Test("administrator requirement remains the highest media authority")
    func requirementOutranksRemoteDenylist() {
        var remote = RemoteSettings()
        remote.imageGenEnabled = false
        remote.imagineToolsDisabled = ["image_gen"]

        let resolved = EffectiveFeatures.resolve(FeatureResolutionInputs(
            requirements: ["image_gen": true],
            remote: AllowlistedRemoteSettings(projecting: remote)
        ))

        #expect(resolved.imageGen.value)
        #expect(resolved.imageGen.source == .requirement)
    }
}
