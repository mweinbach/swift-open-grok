import Foundation
@testable import OpenGrokPager
import OpenGrokPagerMinimal
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing

@Suite("Pasted images survive the interactive prompt delivery seam")
struct PagerImageAttachmentDeliveryParityTests {
    @Test("a pasted image reaches the typed runtime with its exact bytes and MIME")
    func pastedImageReachesTypedRuntime() async throws {
        let image = imageAttachmentPNG(width: 32, height: 32)
        let runtime = ImageAttachmentRecordingRuntime()
        let renderer = ImageAttachmentRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: imageAttachmentInput([
                .paste("Describe "),
                .paste(encodeWrapImagePayload(data: image, mimeType: "image/png")),
                .key(KeyEvent(key: .enter)),
            ]),
            runtime: runtime,
            renderer: renderer,
            output: ImageAttachmentSilentOutput()
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))
        let delivered = try #require(await runtime.deliveries.first)

        #expect(result.completedTurnCount == 1)
        #expect(delivered.request.prompt == "Describe [Image #1]")
        #expect(delivered.images.count == 1)
        #expect(delivered.images[0].mimeType == "image/png")
        #expect(delivered.images[0].encodedBytes == image)
        #expect(!delivered.request.metadata.values.contains(image.base64EncodedString()))
        #expect(await controller.state().prompt.pastedImages.isEmpty)
    }

    @Test("a legacy text-only runtime retains the draft and never starts a text-only turn")
    func legacyRuntimeRetainsImageDraft() async throws {
        let image = imageAttachmentPNG(width: 32, height: 32)
        let runtime = ImageAttachmentLegacyRuntime()
        let renderer = ImageAttachmentRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: imageAttachmentInput([
                .paste("Keep "),
                .paste(encodeWrapImagePayload(data: image, mimeType: "image/png")),
                .key(KeyEvent(key: .enter)),
            ]),
            runtime: runtime,
            renderer: renderer,
            output: ImageAttachmentSilentOutput()
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))
        let state = await controller.state()

        #expect(result.submittedPrompts.isEmpty)
        #expect(await runtime.requests.isEmpty)
        #expect(state.prompt.text == "Keep [Image #1]")
        #expect(state.prompt.pastedImages.first?.encodedBytes == image)
        #expect(await renderer.notices.contains(
            OpenGrokPagerImageAttachmentError.unsupportedRuntime.description
        ))
    }

    @Test("an unsupported attachment MIME keeps the original bytes in the composer")
    func invalidImageRetainsDraft() async throws {
        let image = imageAttachmentPNG(width: 32, height: 32)
        let runtime = ImageAttachmentRecordingRuntime()
        let renderer = ImageAttachmentRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: imageAttachmentInput([
                .paste(encodeWrapImagePayload(data: image, mimeType: "image/svg+xml")),
                .key(KeyEvent(key: .enter)),
            ]),
            runtime: runtime,
            renderer: renderer,
            output: ImageAttachmentSilentOutput()
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))
        let state = await controller.state()

        #expect(result.submittedPrompts.isEmpty)
        #expect(await runtime.deliveries.isEmpty)
        #expect(state.prompt.pastedImages.first?.encodedBytes == image)
        #expect(await renderer.notices.contains(
            OpenGrokPagerImageAttachmentError.unsupportedMIMEType("image/svg+xml").description
        ))
    }

    @Test("combine stops before an image-bearing follower and preserves each prompt")
    func queuedImagesRemainPairedWithPrompts() async throws {
        let firstImage = imageAttachmentPNG(width: 32, height: 32)
        let secondImage = imageAttachmentPNG(width: 48, height: 32)
        let runtime = ImageAttachmentRecordingRuntime(holdFirstSession: true)
        let renderer = ImageAttachmentRecordingRenderer()
        let stream = AsyncStream<InputEvent>.makeStream()
        let controller = OpenGrokPagerInteractiveController(
            input: stream.stream,
            runtime: runtime,
            renderer: renderer,
            output: ImageAttachmentSilentOutput()
        )
        await controller.setInputModes(.init(combineQueuedPrompts: true))
        let run = Task { try await controller.run(.init(prompt: "", mode: .inline)) }

        stream.continuation.yield(.paste("running"))
        stream.continuation.yield(.key(KeyEvent(key: .enter)))
        #expect(await imageAttachmentWaitUntil { await runtime.deliveries.count == 1 })

        stream.continuation.yield(.paste("first "))
        stream.continuation.yield(.paste(
            encodeWrapImagePayload(data: firstImage, mimeType: "image/png")
        ))
        stream.continuation.yield(.key(KeyEvent(key: .enter)))
        stream.continuation.yield(.paste("second "))
        stream.continuation.yield(.paste(
            encodeWrapImagePayload(data: secondImage, mimeType: "image/png")
        ))
        stream.continuation.yield(.key(KeyEvent(key: .enter)))

        #expect(await imageAttachmentWaitUntil { await renderer.queueCounts.contains(2) })
        await runtime.finishFirstSession()
        #expect(await imageAttachmentWaitUntil { await runtime.deliveries.count == 3 })
        stream.continuation.finish()
        let result = try await run.value
        let deliveries = await runtime.deliveries

        #expect(result.completedTurnCount == 3)
        #expect(deliveries.map(\.request.prompt) == [
            "running",
            "first [Image #1]",
            "second [Image #1]",
        ])
        #expect(deliveries[0].images.isEmpty)
        #expect(deliveries[1].images.map(\.encodedBytes) == [firstImage])
        #expect(deliveries[2].images.map(\.encodedBytes) == [secondImage])
    }

    @Test("attachment validation enforces upstream byte and pixel bounds")
    func validatorEnforcesUpstreamLimits() {
        let valid = PastedImage(
            displayNumber: 1,
            mimeType: "image/png",
            dimensions: (width: 32, height: 32),
            byteLen: 1,
            encodedBytes: Data([0x89])
        )
        #expect(throws: Never.self) {
            try OpenGrokPagerImageAttachmentValidator.validate([valid])
        }

        var tooSmall = valid
        tooSmall.dimensions = (width: 16, height: 16)
        #expect(throws: OpenGrokPagerImageAttachmentError.imageDimensionsTooSmall) {
            try OpenGrokPagerImageAttachmentValidator.validate([tooSmall])
        }

        var tooLarge = valid
        tooLarge.dimensions = (width: 20_000, height: 20_000)
        #expect(throws: OpenGrokPagerImageAttachmentError.imageDimensionsTooLarge) {
            try OpenGrokPagerImageAttachmentValidator.validate([tooLarge])
        }

        var missing = valid
        missing.encodedBytes = nil
        missing.sourcePath = "/private/must-never-be-opened.png"
        #expect(throws: OpenGrokPagerImageAttachmentError.missingImageData) {
            try OpenGrokPagerImageAttachmentValidator.validate([missing])
        }
    }
}

private func imageAttachmentPNG(width: UInt32, height: UInt32) -> Data {
    Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        UInt8((width >> 24) & 0xFF), UInt8((width >> 16) & 0xFF),
        UInt8((width >> 8) & 0xFF), UInt8(width & 0xFF),
        UInt8((height >> 24) & 0xFF), UInt8((height >> 16) & 0xFF),
        UInt8((height >> 8) & 0xFF), UInt8(height & 0xFF),
        0x08, 0x02, 0x00, 0x00, 0x00,
    ])
}

private func imageAttachmentInput(_ events: [InputEvent]) -> AsyncStream<InputEvent> {
    AsyncStream { continuation in
        for event in events {
            continuation.yield(event)
        }
        continuation.finish()
    }
}

private func imageAttachmentWaitUntil(
    timeout: TimeInterval = 5,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

private struct ImageAttachmentDelivery: Sendable {
    let request: OpenGrokPagerRequest
    let images: [PastedImage]
}

private actor ImageAttachmentRecordingRuntime: OpenGrokPagerImageAttachmentRuntimeAdapter {
    private let holdFirstSession: Bool
    private var firstSession: ImageAttachmentSession?
    private(set) var deliveries: [ImageAttachmentDelivery] = []

    init(holdFirstSession: Bool = false) {
        self.holdFirstSession = holdFirstSession
    }

    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        try await makeSession(for: request, attachments: [])
    }

    func makeSession(
        for request: OpenGrokPagerRequest,
        attachments: [PastedImage]
    ) async throws -> any OpenGrokPagerSessionAdapter {
        deliveries.append(ImageAttachmentDelivery(request: request, images: attachments))
        let session = ImageAttachmentSession(
            completeImmediately: !holdFirstSession || deliveries.count > 1
        )
        if deliveries.count == 1 {
            firstSession = session
        }
        return session
    }

    func finishFirstSession() async {
        await firstSession?.finish()
    }
}

private actor ImageAttachmentLegacyRuntime: OpenGrokPagerRuntimeAdapter {
    private(set) var requests: [OpenGrokPagerRequest] = []

    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        requests.append(request)
        return ImageAttachmentSession(completeImmediately: true)
    }
}

private actor ImageAttachmentSession: OpenGrokPagerSessionAdapter {
    nonisolated let sessionID: String? = "image-attachment-session"
    nonisolated let events: AsyncThrowingStream<OpenGrokPagerEvent, Error>
    private let continuation: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation

    init(completeImmediately: Bool) {
        let stream = AsyncThrowingStream<OpenGrokPagerEvent, Error>.makeStream()
        events = stream.stream
        continuation = stream.continuation
        if completeImmediately {
            continuation.yield(.completed(OpenGrokPagerMinimalCompletion(
                sessionID: "image-attachment-session"
            )))
            continuation.finish()
        }
    }

    func finish() {
        continuation.yield(.completed(OpenGrokPagerMinimalCompletion(
            sessionID: "image-attachment-session"
        )))
        continuation.finish()
    }

    func cancel() {
        continuation.yield(.cancelled)
        continuation.finish()
    }

    func close() {
        continuation.finish()
    }
}

private actor ImageAttachmentRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private var events: [OpenGrokPagerInteractiveEvent] = []

    var notices: [String] {
        events.compactMap { event in
            if case .notice(let notice) = event { return notice }
            return nil
        }
    }

    var queueCounts: [Int] {
        events.compactMap { event in
            if case .queueChanged(let count) = event { return count }
            return nil
        }
    }

    func begin() {}
    func restoreTerminal() {}

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }
}

private struct ImageAttachmentSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws {}
}
