import Foundation
import OpenGrokHTTP
import Testing
@testable import OpenGrokWebMediaTools

@Suite("OpenGrokWebMediaTools")
struct OpenGrokWebMediaToolsTests {
    @Test("clipboard MIME detection matches Rust magic-byte contract")
    func clipboardMIME() {
        #expect(mimeType(for: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == "image/png")
        #expect(mimeType(for: Data([0xFF, 0xD8, 0xFF])) == "image/jpeg")
        #expect(mimeType(for: Data("GIF89a".utf8)) == "image/gif")
        #expect(mimeType(for: Data("RIFF1234WEBP".utf8)) == "image/webp")
        #expect(mimeType(for: Data("BM".utf8)) == "image/bmp")
        #expect(mimeType(for: Data([0x00, 0x01])) == "application/octet-stream")
        #expect(extensionForMime("image/jpeg") == "jpg")
        #expect(extensionForMime("application/octet-stream") == "bin")
    }

    @Test("clipboard providers expose typed validation and platform errors")
    func clipboardErrors() async {
        do {
            _ = try ClipboardImage(data: Data(), mimeType: "image/png")
            Issue.record("Expected empty image data to fail")
        } catch ClipboardError.invalidContent { }
        catch {
            Issue.record("Unexpected error: \(error)")
        }
        do {
            _ = try ClipboardImage(data: Data([0x01]), mimeType: "text/plain")
            Issue.record("Expected non-image MIME to fail")
        } catch ClipboardError.invalidContent { }
        catch {
            Issue.record("Unexpected error: \(error)")
        }

        let provider = SystemClipboardProvider(platform: .windows, environment: [:])
        do {
            _ = try await provider.read()
            Issue.record("Expected unsupported platform error")
        } catch ClipboardError.capabilityUnavailable(let capability, let platform, _) {
            #expect(capability == .clipboardText)
            #expect(platform == .windows)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Linux clipboard uses Wayland commands and preserves attachment precedence")
    func linuxClipboardCommands() async throws {
        let runner = RecordingClipboardRunner(responses: [
            .init(executable: "wl-paste", arguments: ["--no-newline", "-t", "text"], result: .init(status: 0, standardOutput: Data("hello".utf8))),
            .init(executable: "wl-copy", arguments: [], result: .init(status: 0)),
            .init(executable: "wl-paste", arguments: ["-t", "text/uri-list"], result: .init(status: 0, standardOutput: Data("file:///tmp/a.txt\n".utf8)))
        ])
        let provider = SystemClipboardProvider(
            platform: .linux,
            environment: ["WAYLAND_DISPLAY": "wayland-0"],
            commandRunner: runner
        )

        #expect(try await provider.read() == .text("hello"))
        try await provider.write(.text("copied"))
        let attachments = try await provider.readAttachments()
        #expect(attachments.fileURLs == [URL(fileURLWithPath: "/tmp/a.txt")])
        #expect(attachments.image == nil)
        #expect(runner.calls.count == 3)
        #expect(runner.calls[1].input == Data("copied".utf8))
        #expect(provider.capabilityStatus()[.clipboardText] == true)
    }

    @Test("OSC52 accepts text and rejects binary clipboard content")
    func osc52Clipboard() async {
        let provider = OSC52ClipboardProvider(environment: ["SSH_TTY": "/dev/pts/1"])
        do {
            try await provider.write(.image(Data([0x01])))
            Issue.record("Expected OSC52 image write to fail")
        } catch ClipboardError.capabilityUnavailable(let capability, _, _) {
            #expect(capability == .osc52Clipboard)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(provider.environment["SSH_TTY"] == "/dev/pts/1")
    }

    @Test("web fetch normalizes HTTP, strips noisy HTML, and caches")
    func webFetchAndCache() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200, headers: ["Content-Type": "text/html"]), body: Data("<h1>Hello</h1><script>bad()</script><p>World</p>".utf8))
        ])
        let client = WebFetchClient(
            params: WebFetchParams(allowedDomains: ["example.com"]),
            transport: transport
        )
        let first = try await client.fetch(url: "http://example.com/page")
        let second = try await client.fetch(url: "https://example.com/page")
        #expect(first.content.contains("# Hello"))
        #expect(first.content.contains("World"))
        #expect(!first.content.contains("bad"))
        #expect(first == second)
        #expect(transport.recordedRequests.count == 1)
        #expect(transport.recordedRequests.first?.url.scheme == "https")
    }

    @Test("web fetch follows same-host redirects and rejects cross-host redirects")
    func webFetchRedirects() async throws {
        let sameHostTransport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 302, headers: ["Location": "/next"])),
            .init(metadata: HTTPResponseMetadata(statusCode: 200, headers: ["Content-Type": "text/plain"]), body: Data("done".utf8))
        ])
        let client = WebFetchClient(
            params: WebFetchParams(allowedDomains: ["example.com"]),
            transport: sameHostTransport
        )
        let output = try await client.fetch(url: "https://example.com/start")
        #expect(output.content == "done")
        #expect(sameHostTransport.recordedRequests.map(\.url.path) == ["/start", "/next"])

        let crossHostTransport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 302, headers: ["Location": "https://other.example/next"]))
        ])
        let crossHostClient = WebFetchClient(
            params: WebFetchParams(allowedDomains: ["example.com", "other.example"]),
            transport: crossHostTransport
        )
        do {
            _ = try await crossHostClient.fetch(url: "https://example.com/start")
            Issue.record("Expected cross-host redirect to fail")
        } catch WebMediaToolError.crossHostRedirect(let host, let redirectURL) {
            #expect(host == "example.com")
            #expect(redirectURL == "https://other.example/next")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("web fetch saves validated binary artifacts below the configured Open Grok home")
    func webFetchMediaArtifact() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("open-grok-web-media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200, headers: ["Content-Type": "image/png"]), body: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00]))
        ])
        let client = WebFetchClient(
            params: WebFetchParams(allowedDomains: ["example.com"]),
            transport: transport,
            artifactDirectory: directory
        )
        let output = try await client.fetch(url: "https://example.com/image.png")
        #expect(output.artifact?.mimeType == "image/png")
        #expect(output.artifact.map { FileManager.default.fileExists(atPath: $0.localURL) } == true)
        #expect(output.artifact?.localURL.hasPrefix(directory.path) == true)
    }

    @Test("web search sends Responses API tool shape and parses citations")
    func webSearch() async throws {
        let body = Data(#"{"output_text":"Answer","output":[{"type":"message","content":[{"type":"output_text","text":"Answer"},{"type":"url_citation","title":"Docs","url":"https://docs.example/a"}]}]}"#.utf8)
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: body)
        ])
        let client = try WebSearchClient(
            configuration: .enabled(apiKey: "secret", baseURL: "https://api.example/v1", model: "grok-search"),
            transport: transport
        )
        let result = try await client.search(query: " Swift ", allowedDomains: ["docs.example"])
        #expect(result.content == "Answer")
        #expect(result.citations == [WebSearchCitation(title: "Docs", url: "https://docs.example/a")])
        let request = try #require(transport.recordedRequests.first)
        #expect(request.headers["Authorization"] == "Bearer secret")
        let requestBody = try #require(request.body)
        let payload = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(payload["model"] as? String == "grok-search")
        #expect((payload["input"] as? String) == "Swift")
        #expect((payload["tools"] as? [[String: Any]])?.first?["type"] as? String == "web_search_preview")
    }

    @Test("web and media clients classify authentication, rate, and malformed responses")
    func typedRemoteErrors() async throws {
        let unauthorized = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 401), body: Data("no".utf8))
        ])
        let search = try WebSearchClient(
            configuration: .enabled(apiKey: "secret", baseURL: "https://api.example", model: "model"),
            transport: unauthorized
        )
        do {
            _ = try await search.search(query: "query")
            Issue.record("Expected unauthorized error")
        } catch WebMediaToolError.unauthorized(let tool) {
            #expect(tool == "web_search")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let malformed = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data("{}".utf8))
        ])
        let media = try MediaGenerationClient(
            configuration: MediaGenerationConfiguration(apiKey: "secret", baseURL: "https://api.example"),
            transport: malformed
        )
        do {
            _ = try await media.generateImage(ImageGenerationRequest(prompt: "a test"))
            Issue.record("Expected malformed media response")
        } catch WebMediaToolError.malformedResponse(let tool, _) {
            #expect(tool == "image_gen")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("image edit resolves local references in stable order")
    func imageEditReferenceResolution() async throws {
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent("open-grok-reference-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: imageURL) }
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: imageURL)
        let encoded = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00]).base64EncodedString()
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data(#"{"data":[{"b64_json":"AQID"}]}"#.utf8))
        ])
        let media = try MediaGenerationClient(
            configuration: MediaGenerationConfiguration(apiKey: "secret", baseURL: "https://api.example"),
            transport: transport
        )
        let result = try await media.editImage(ImageEditRequest(
            prompt: "combine",
            references: [imageURL.path, "data:image/png;base64,\(encoded)"]
        ))
        #expect(result.data == Data([0x01, 0x02, 0x03]))
        let requestBody = try #require(transport.recordedRequests.first?.body)
        let payload = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        let images = try #require(payload["images"] as? [[String: Any]])
        #expect(images.count == 2)
        #expect(images.allSatisfy { ($0["url"] as? String)?.hasPrefix("data:image/") == true })
        #expect(payload["image"] == nil)
    }

    @Test("single-image edit uses the Rust object payload shape")
    func singleImageEditPayload() async throws {
        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let reference = "data:image/png;base64,\(imageData.base64EncodedString())"
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data(#"{"data":[{"b64_json":"AQID"}]}"#.utf8))
        ])
        let media = try MediaGenerationClient(
            configuration: MediaGenerationConfiguration(apiKey: "secret", baseURL: "https://api.example"),
            transport: transport
        )

        _ = try await media.editImage(ImageEditRequest(prompt: "animate", references: [reference]))
        let requestBody = try #require(transport.recordedRequests.first?.body)
        let payload = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        let image = try #require(payload["image"] as? [String: Any])
        #expect((image["url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
        #expect(payload["images"] == nil)
        #expect(payload["n"] as? Int == 1)
        #expect(payload["resolution"] as? String == "1k")
    }

    @Test("video generation polls, downloads, and honors cancellation-safe defaults")
    func videoGeneration() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data(#"{"request_id":"req-1"}"#.utf8)),
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data(#"{"status":"done","video":{"url":"https://cdn.example/video.mp4"}}"#.utf8)),
            .init(metadata: HTTPResponseMetadata(statusCode: 200, headers: ["Content-Type": "video/mp4"]), body: Data("video-bytes".utf8))
        ])
        let media = try MediaGenerationClient(
            configuration: MediaGenerationConfiguration(
                apiKey: "secret",
                baseURL: "https://api.example",
                videoPollIntervalSeconds: 0,
                videoTimeoutSeconds: 2
            ),
            transport: transport
        )
        let result = try await media.generateVideo(VideoGenerationRequest(prompt: "motion"))
        #expect(result.mimeType == "video/mp4")
        #expect(result.data == Data("video-bytes".utf8))
        #expect(transport.recordedRequests.map(\.method) == [.post, .get, .get])
        #expect(transport.recordedRequests[1].url.path == "/videos/req-1")
        #expect(transport.recordedRequests[2].url.path == "/video.mp4")
    }

    @Test("tool catalog preserves Open Grok tool names and typed schemas")
    func catalog() {
        let names = WebMediaToolCatalog.descriptions.map(\.name)
        #expect(names.contains("web_search"))
        #expect(names.contains("web_fetch"))
        #expect(names.contains("x_search"))
        #expect(names.contains("image_gen"))
        #expect(names.contains("image_edit"))
        #expect(names.contains("video_gen"))
    }
}

private final class RecordingClipboardRunner: ClipboardCommandRunner, @unchecked Sendable {
    struct Key: Hashable {
        var executable: String
        var arguments: [String]
    }

    struct Entry {
        var key: Key
        var result: ClipboardCommandResult
    }

    private(set) var calls: [(executable: String, arguments: [String], input: Data?)] = []
    private var responses: [Entry]

    init(responses: [Entry]) {
        self.responses = responses
    }

    func run(executable: String, arguments: [String], input: Data?, timeout: TimeInterval) throws -> ClipboardCommandResult {
        calls.append((executable, arguments, input))
        guard let index = responses.firstIndex(where: { $0.key == Key(executable: executable, arguments: arguments) }) else {
            throw ClipboardError.unsupported(executable)
        }
        return responses.remove(at: index).result
    }
}

extension RecordingClipboardRunner.Entry {
    init(executable: String, arguments: [String], result: ClipboardCommandResult) {
        self.key = RecordingClipboardRunner.Key(executable: executable, arguments: arguments)
        self.result = result
    }
}
