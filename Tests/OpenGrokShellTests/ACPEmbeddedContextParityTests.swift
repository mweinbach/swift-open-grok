import Foundation
import OpenGrokACP
import OpenGrokShared
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

    @Test("image-capable conversion preserves text ordering while retaining validated image content")
    func imageCapableConversionRetainsOrderedTextAndImage() throws {
        let image = ImageContent(data: "aGVsbG8=", mimeType: "IMAGE/PNG")
        let blocks: [ContentBlock] = [
            .text("before "),
            .image(image),
            .resource(EmbeddedResource(resource: .text(TextResourceContents(
                uri: "file:///workspace/context.swift",
                text: "embedded"
            )))),
            .text(" after"),
        ]

        #expect(try ProviderBackedACPPromptDriver.promptText(
            for: blocks,
            allowingImages: true
        ) == "before embedded after")
        let images = try ProviderBackedACPPromptDriver.promptImages(for: blocks)
        #expect(images.count == 1)
        #expect(images.first?.mimeType == "image/png")
        #expect(images.first?.data == "aGVsbG8=")
        #expect(images.first?.uri == nil)
    }

    @Test("without an image-staging callback ACP images retain their explicit unsupported error")
    func imageWithoutStagingStillFailsClosed() {
        #expect(throws: OpenGrokShellError.self) {
            try ProviderBackedACPPromptDriver.promptText(for: [
                .image(ImageContent(data: "aGVsbG8=", mimeType: "image/png")),
            ])
        }
    }

    @Test("URI-backed, malformed, unsupported, oversized, and excessive ACP images fail closed")
    func malformedImagesNeverReachStaging() {
        let oversized = Data(repeating: 0x61, count: 1_500_001).base64EncodedString()
        let valid = ContentBlock.image(ImageContent(data: "aGVsbG8=", mimeType: "image/png"))
        let invalid: [[ContentBlock]] = [
            [.image(ImageContent(
                data: "aGVsbG8=",
                mimeType: "image/png",
                uri: "file:///private/secret.png"
            ))],
            [.image(ImageContent(data: "malformed!", mimeType: "image/png"))],
            [.image(ImageContent(data: "aGVsbG8=", mimeType: "image/svg+xml"))],
            [.image(ImageContent(data: oversized, mimeType: "image/png"))],
            Array(repeating: valid, count: maxPlaceholdersPerPrompt + 1),
        ]

        for blocks in invalid {
            #expect(throws: OpenGrokShellError.self) {
                try ProviderBackedACPPromptDriver.promptImages(for: blocks)
            }
        }
    }

    @Test("allowing images never admits audio or embedded binary resource content")
    func audioAndBinaryRemainForbidden() {
        let image = ContentBlock.image(ImageContent(data: "aGVsbG8=", mimeType: "image/png"))
        let audio = ContentBlock.audio(AudioContent(data: "aGVsbG8=", mimeType: "audio/wav"))
        #expect(throws: OpenGrokShellError.self) {
            try ProviderBackedACPPromptDriver.promptText(for: [image, audio], allowingImages: true)
        }
        #expect(throws: OpenGrokShellError.self) {
            try ProviderBackedACPPromptDriver.promptText(for: [
                image,
                .resource(EmbeddedResource(resource: .blob(BlobResourceContents(
                    uri: "file:///workspace/binary",
                    blob: "aW1hZ2U="
                )))),
            ], allowingImages: true)
        }
    }
}
