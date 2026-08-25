import OpenGrokACP
import Testing

@testable import OpenGrokShell

@Suite("ACP embedded context reaches provider prompts")
struct ACPEmbeddedContextParityTests {
    @Test("embedded text resources and links survive provider conversion")
    func embeddedTextAndLinksReachPrompt() throws {
        let prompt = try ProviderBackedACPPromptDriver.promptText(for: [
            .text("Review "),
            .resource(EmbeddedResource(resource: .text(TextResourceContents(
                uri: "file:///workspace/main.swift",
                text: "let value = 42"
            )))),
            .text(" from "),
            .resourceLink(ResourceLink(uri: "file:///workspace/main.swift")),
        ])

        #expect(prompt == "Review let value = 42 from file:///workspace/main.swift")
    }

    @Test("unsupported binary resources fail loudly")
    func binaryResourcesAreRejected() {
        #expect(throws: OpenGrokShellError.self) {
            try ProviderBackedACPPromptDriver.promptText(for: [
                .resource(EmbeddedResource(resource: .blob(BlobResourceContents(
                    uri: "file:///workspace/image.png",
                    blob: "aW1hZ2U="
                )))),
            ])
        }
    }
}
