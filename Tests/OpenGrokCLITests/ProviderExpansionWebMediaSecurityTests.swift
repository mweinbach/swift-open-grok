import Foundation
import OpenGrokSamplingTypes
import OpenGrokWebMediaTools
import Testing
@testable import OpenGrokCLI

@Suite("Expanded-provider web and media credential isolation")
struct ProviderExpansionWebMediaSecurityTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-media-security-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test(
        "expanded providers default to separately authenticated xAI search",
        arguments: [ModelProvider.runinfra, .gemini, .openRouter]
    )
    func defaultsNeverBorrowProviderCredentials(_ provider: ModelProvider) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = ["HOME": directory.path]

        #expect(LiveWebToolComposition.effectiveSource(
            provider: provider,
            workingDirectory: directory,
            openGrokHome: directory,
            environment: environment,
            xaiAvailable: false,
            perplexityAvailable: true
        ) == .xai)
        #expect(LiveImageToolComposition.xaiMediaAPIKey(
            samplingProvider: provider,
            samplingAPIKey: "foreign-provider-bearer",
            environment: environment
        ) == nil)

        let availability = LiveWebToolComposition.resolveAvailability(
            workingDirectory: directory,
            openGrokHome: directory,
            environment: environment,
            samplingProvider: provider,
            samplingAPIKey: "foreign-provider-bearer",
            samplingBaseURL: "https://foreign-provider.example/v1",
            disableWebSearch: false
        )
        #expect(!availability.webSearchEnabled)
        #expect(!availability.xSearchEnabled)
    }

    @Test(
        "a foreign inference endpoint never receives an independently resolved xAI search bearer",
        arguments: [ModelProvider.runinfra, .gemini, .openRouter]
    )
    func xaiSearchNeverUsesForeignProviderEndpoint(_ provider: ModelProvider) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let config = LiveWebToolComposition.resolveXaiSearchConfig(
            workingDirectory: directory,
            openGrokHome: directory,
            environment: ["HOME": directory.path, "XAI_API_KEY": "isolated-xai-bearer"],
            samplingProvider: provider,
            samplingAPIKey: "foreign-provider-bearer",
            samplingBaseURL: "https://credential-harvester.example/v1"
        )

        guard case .enabled(let apiKey, let baseURL, _, _, _) = config else {
            Issue.record("expected independently authenticated xAI search")
            return
        }
        #expect(apiKey == "isolated-xai-bearer")
        #expect(baseURL == "https://api.x.ai/v1")
    }

    @Test(
        "a foreign inference endpoint never receives an xAI image bearer",
        arguments: [ModelProvider.runinfra, .gemini, .openRouter]
    )
    func xaiImagesNeverUseForeignProviderEndpoint(_ provider: ModelProvider) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let availability = LiveImageToolComposition.resolveAvailability(
            workingDirectory: directory,
            openGrokHome: directory,
            environment: [
                "HOME": directory.path,
                "XAI_API_KEY": "isolated-xai-image-bearer",
                "GROK_IMAGE_GEN": "1",
            ],
            samplingProvider: provider,
            samplingAPIKey: "foreign-provider-bearer",
            samplingBaseURL: "https://credential-harvester.example/v1"
        )

        guard case .enabled(let settings) = availability.config else {
            Issue.record("expected independently authenticated xAI image generation")
            return
        }
        #expect(settings.provider == .grok)
        #expect(settings.apiKey == "isolated-xai-image-bearer")
        #expect(settings.baseURL == "https://api.x.ai/v1")
    }

    @Test(
        "a foreign inference endpoint never receives an xAI video bearer",
        arguments: [ModelProvider.runinfra, .gemini, .openRouter]
    )
    func xaiVideoNeverUsesForeignProviderEndpoint(_ provider: ModelProvider) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let availability = LiveVideoToolComposition.resolveAvailability(
            workingDirectory: directory,
            openGrokHome: directory,
            environment: [
                "HOME": directory.path,
                "XAI_API_KEY": "isolated-xai-video-bearer",
                "GROK_VIDEO_GEN": "1",
            ],
            samplingProvider: provider,
            samplingAPIKey: "foreign-provider-bearer",
            samplingBaseURL: "https://credential-harvester.example/v1"
        )

        guard case .enabled(let settings) = availability.config else {
            Issue.record("expected independently authenticated xAI video generation")
            return
        }
        #expect(settings.apiKey == "isolated-xai-video-bearer")
        #expect(settings.baseURL == "https://api.x.ai/v1")
    }

    @Test(
        "xAI endpoint overrides are explicit, scoped, and config-preferred",
        arguments: [ModelProvider.runinfra, .gemini, .openRouter]
    )
    func xaiEndpointOverridesRemainScoped(_ provider: ModelProvider) {
        let samplingURL = "https://credential-harvester.example/v1"

        #expect(LiveImageToolComposition.xaiMediaBaseURL(
            samplingProvider: provider,
            samplingBaseURL: samplingURL,
            configuredXaiBaseURL: nil,
            environment: ["GROK_XAI_API_BASE_URL": "https://xai-proxy.example/v1"]
        ) == "https://xai-proxy.example/v1")
        #expect(LiveImageToolComposition.xaiMediaBaseURL(
            samplingProvider: provider,
            samplingBaseURL: samplingURL,
            configuredXaiBaseURL: "https://managed-xai.example/v1",
            environment: ["GROK_XAI_API_BASE_URL": "https://xai-proxy.example/v1"]
        ) == "https://managed-xai.example/v1")
        #expect(LiveImageToolComposition.xaiMediaBaseURL(
            samplingProvider: .xai,
            samplingBaseURL: "https://session-xai.example/v1",
            configuredXaiBaseURL: nil,
            environment: [:]
        ) == "https://session-xai.example/v1")
    }

    @Test(
        "expanded providers honor only their canonical web-search config key",
        arguments: [ModelProvider.runinfra, .gemini, .openRouter]
    )
    func canonicalPerProviderConfiguration(_ provider: ModelProvider) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "[toolset.web_search_source]\n\(provider.asString) = \"native\"\n"
            .write(to: directory.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let availability = LiveWebToolComposition.resolveAvailability(
            workingDirectory: directory,
            openGrokHome: directory,
            environment: ["HOME": directory.path, "XAI_API_KEY": "isolated-xai-bearer"],
            samplingProvider: provider,
            samplingAPIKey: "foreign-provider-bearer",
            samplingBaseURL: "https://credential-harvester.example/v1",
            disableWebSearch: false
        )
        #expect(!availability.webSearchEnabled)
        #expect(!availability.xSearchEnabled)
    }
}
