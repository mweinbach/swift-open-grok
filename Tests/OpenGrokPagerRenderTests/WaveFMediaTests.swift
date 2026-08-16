import Foundation
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPagerRender

private func waveFJSON(_ value: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

private func waveFPNG(width: UInt32, height: UInt32, marker: UInt8) -> Data {
    var bytes = [UInt8](repeating: 0, count: 25)
    bytes.replaceSubrange(0..<8, with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    bytes[16] = UInt8((width >> 24) & 0xFF)
    bytes[17] = UInt8((width >> 16) & 0xFF)
    bytes[18] = UInt8((width >> 8) & 0xFF)
    bytes[19] = UInt8(width & 0xFF)
    bytes[20] = UInt8((height >> 24) & 0xFF)
    bytes[21] = UInt8((height >> 16) & 0xFF)
    bytes[22] = UInt8((height >> 8) & 0xFF)
    bytes[23] = UInt8(height & 0xFF)
    bytes[24] = marker
    return Data(bytes)
}

private final class WaveFVideoCommandHarness: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(String, [String])] = []
    let poster = waveFPNG(width: 800, height: 450, marker: 0)
    let firstFrame = waveFPNG(width: 640, height: 360, marker: 1)
    let secondFrame = waveFPNG(width: 640, height: 360, marker: 2)

    func run(
        executable: String,
        arguments: [String],
        environment _: [String: String]
    ) -> PagerVideoCommandResult? {
        lock.withLock { calls.append((executable, arguments)) }
        if executable == "/fake/ffprobe" {
            return PagerVideoCommandResult(
                status: 0,
                stdout: Data(#"{"streams":[{"width":800,"height":450,"r_frame_rate":"30/1"}],"format":{"duration":"1.0"}}"#.utf8)
            )
        }
        guard executable == "/fake/ffmpeg" else { return nil }
        if arguments.last == "-" {
            return PagerVideoCommandResult(status: 0, stdout: poster)
        }
        guard let pattern = arguments.last, pattern.hasSuffix("%06d.png") else { return nil }
        let directory = URL(fileURLWithPath: pattern).deletingLastPathComponent()
        try? secondFrame.write(to: directory.appendingPathComponent("000002.png"))
        try? firstFrame.write(to: directory.appendingPathComponent("000001.png"))
        return PagerVideoCommandResult(status: 0)
    }

    var recordedCalls: [(String, [String])] {
        lock.withLock { calls }
    }
}

@Suite("Wave F typed media and Kitty compositor", .serialized)
struct WaveFMediaTests {
    @Test("typed image and video outputs create media refs without prose parsing")
    func typedMediaRefs() {
        let image = PagerToolCard.make(
            name: "image_gen",
            output: "generation complete",
            state: .succeeded,
            structuredOutput: waveFJSON([
                "path": "/tmp/generated-image.png",
                "byte_size": 1234,
            ])
        )
        let video = PagerToolCard.make(
            name: "video_gen",
            output: "generation complete",
            state: .succeeded,
            structuredOutput: waveFJSON([
                "path": "/tmp/generated-video.mp4",
                "byte_size": 5678,
            ])
        )

        #expect(image.output == "generation complete")
        #expect(image.mediaRefs.count == 1)
        #expect(image.mediaRefs[0].path == "/tmp/generated-image.png")
        #expect(image.mediaRefs[0].kind == .image)
        #expect(image.mediaRefs[0].byteSize == 1234)
        #expect(video.mediaRefs.count == 1)
        #expect(video.mediaRefs[0].path == "/tmp/generated-video.mp4")
        #expect(video.mediaRefs[0].kind == .video)
        #expect(video.mediaRefs[0].byteSize == 5678)
    }

    @Test("media cards reserve inline rows and publish viewport geometry")
    func mediaCardPlacement() {
        let card = PagerToolCard.make(
            name: "image_gen",
            output: "no filepath in prose",
            state: .succeeded,
            structuredOutput: waveFJSON([
                "path": "/tmp/generated-image.png",
                "byte_size": 1234,
            ])
        )
        let result = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 64, height: 42),
            conversation: [.tool(card)],
            scrollPosition: .offset(0),
            showScrollbar: false,
            stickyHeadersEnabled: false
        ))

        #expect(result.snapshot().contains("/tmp/generated-image.png"))
        #expect(result.inlineMedia.count == 1)
        let placement = result.inlineMedia[0]
        #expect(placement.media == card.mediaRefs[0])
        #expect(placement.sourceRowOffset == 0)
        #expect(placement.rect.height == placement.fullRowCount)
        #expect(placement.rect.width > 0)
    }

    @Test("Kitty compositor transmits once, places every frame, crops, and clears by ID")
    func kittyLifecycle() throws {
        let media = PagerMediaRef(path: "/tmp/image.png", kind: .image)
        let loaded = PagerLoadedInlineMedia(
            pngData: Data([0x89, 0x50, 0x4E, 0x47]),
            width: 120,
            height: 80
        )
        var compositor = PagerInlineMediaCompositor(active: true) { _ in loaded }
        let placement = PagerInlineMediaPlacement(
            media: media,
            rect: TerminalRect(x: 7, y: 5, width: 20, height: 4),
            fullRowCount: 8
        )

        var firstWrites: [String] = []
        #expect(try compositor.postFlush(placements: [placement]) { firstWrites.append($0) })
        #expect(firstWrites.count == 2)
        #expect(firstWrites[0] == transmitKittyImage(
            imageData: loaded.pngData,
            imageId: 2
        ))
        #expect(firstWrites[1] == ANSIOutput.moveTo(column: 7, row: 5) + KittyGraphics.placeForScrollback(
            imageId: 2,
            imgW: 120,
            imgH: 80,
            areaWidth: 20,
            areaHeight: 4,
            fullRows: 8,
            topCropRows: 0
        ))

        var secondWrites: [String] = []
        #expect(try compositor.postFlush(placements: [placement]) { secondWrites.append($0) })
        #expect(secondWrites.count == 1)
        #expect(!secondWrites[0].contains("a=t"))

        let cropped = PagerInlineMediaPlacement(
            media: media,
            rect: TerminalRect(x: 7, y: 3, width: 20, height: 3),
            fullRowCount: 8,
            sourceRowOffset: 3
        )
        var cropWrites: [String] = []
        #expect(try compositor.postFlush(placements: [cropped]) { cropWrites.append($0) })
        #expect(cropWrites == [
            ANSIOutput.moveTo(column: 7, row: 3) + KittyGraphics.placeForScrollback(
                imageId: 2,
                imgW: 120,
                imgH: 80,
                areaWidth: 20,
                areaHeight: 3,
                fullRows: 8,
                topCropRows: 3
            )
        ])

        var clearWrites: [String] = []
        #expect(try compositor.postFlush(placements: []) { clearWrites.append($0) })
        #expect(clearWrites == [clearKittyImage(imageId: 2)])
        #expect(compositor.transmittedCount == 0)
    }

    @Test("iTerm2 environment never activates the scrollback compositor")
    func iterm2StaysOff() throws {
        let media = PagerMediaRef(path: "/tmp/image.png", kind: .image)
        var compositor = PagerInlineMediaCompositor(
            environment: ["TERM_PROGRAM": "iTerm.app"],
            enabled: true,
            terminalProgram: "iTerm.app",
            loader: { _ in
                PagerLoadedInlineMedia(pngData: Data([1]), width: 1, height: 1)
            }
        )
        var writes: [String] = []
        #expect(try compositor.postFlush(
            placements: [PagerInlineMediaPlacement(
                media: media,
                rect: TerminalRect(x: 0, y: 0, width: 10, height: 4),
                fullRowCount: 4
            )]
        ) { writes.append($0) } == false)
        #expect(writes.isEmpty)
    }

    @Test("video decoder extracts a one-second poster and ordered ten FPS frames")
    func videoPosterAndFrames() {
        let harness = WaveFVideoCommandHarness()
        let decoder = PagerInlineVideoDecoder(
            environment: [:],
            executableResolver: { name, _ in "/fake/\(name)" },
            runner: harness.run
        )

        let loaded = decoder.load(path: "/tmp/generated-video.mp4")

        #expect(decoder.isAvailable)
        #expect(loaded?.fps == 10)
        #expect(loaded?.frames.map(\.pngData) == [
            harness.poster,
            harness.firstFrame,
            harness.secondFrame,
        ])
        #expect(loaded?.frames.map(\.width) == [800, 640, 640])
        #expect(loaded?.frames.map(\.height) == [450, 360, 360])
        let calls = harness.recordedCalls
        #expect(calls.contains { executable, arguments in
            executable == "/fake/ffmpeg" && arguments.contains("-ss") && arguments.contains("1")
        })
        #expect(calls.contains { executable, arguments in
            executable == "/fake/ffmpeg"
                && arguments.contains("fps=10.0,scale=640:-2")
                && arguments.last?.hasSuffix("%06d.png") == true
        })
    }

    @Test("video compositor advances once per tick and holds the final frame")
    func videoPlaybackDoesNotLoop() throws {
        let media = PagerMediaRef(path: "/tmp/video.mp4", kind: .video)
        let frames = [
            PagerInlineMediaFrame(pngData: waveFPNG(width: 10, height: 10, marker: 0), width: 10, height: 10),
            PagerInlineMediaFrame(pngData: waveFPNG(width: 11, height: 11, marker: 1), width: 11, height: 11),
            PagerInlineMediaFrame(pngData: waveFPNG(width: 12, height: 12, marker: 2), width: 12, height: 12),
        ]
        var compositor = PagerInlineMediaCompositor(active: true) { _ in
            PagerLoadedInlineMedia(frames: frames, fps: 10)
        }
        let placement = PagerInlineMediaPlacement(
            media: media,
            rect: TerminalRect(x: 0, y: 0, width: 12, height: 4),
            fullRowCount: 4
        )
        var writes: [String] = []

        for now in [0.0, 0.11, 0.22, 0.33, 0.44] {
            _ = try compositor.postFlush(placements: [placement], now: now) {
                writes.append($0)
            }
        }

        let transmissions = writes.filter { $0.contains("a=t") }
        #expect(transmissions == [
            transmitKittyImage(imageData: frames[0].pngData, imageId: 2),
            transmitKittyImage(imageData: frames[1].pngData, imageId: 2),
            transmitKittyImage(imageData: frames[2].pngData, imageId: 2),
        ])
        #expect(writes.last == ANSIOutput.moveTo(column: 0, row: 0) + KittyGraphics.placeForScrollback(
            imageId: 2,
            imgW: 12,
            imgH: 12,
            areaWidth: 12,
            areaHeight: 4,
            fullRows: 4,
            topCropRows: 0
        ))
    }

    @Test("missing ffmpeg shows the compact install hint without inline placement")
    func missingFFmpegHint() {
        var card = PagerToolCard.make(
            name: "video_gen",
            output: "generation complete",
            state: .succeeded
        )
        card.mediaRefs = [PagerMediaRef(
            path: "/tmp/generated-video.mp4",
            kind: .video,
            videoInlineAvailable: false
        )]

        let result = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 64, height: 20),
            conversation: [.tool(card)],
            scrollPosition: .offset(0),
            showScrollbar: false,
            stickyHeadersEnabled: false
        ))
        let snapshot = result.snapshot()

        #expect(snapshot.contains("/tmp/generated-video.mp4"))
        #expect(snapshot.contains(pagerFFmpegHintText))
        #expect(snapshot.contains("[Open]"))
        #expect(result.inlineMedia.isEmpty)
    }
}
