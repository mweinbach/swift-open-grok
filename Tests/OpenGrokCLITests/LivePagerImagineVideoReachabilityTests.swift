// LivePagerImagineVideoReachabilityTests.swift
//
// The Rust command gates registration on the advertised `image_to_video`
// tool, returns its exact usage for blank arguments, and injects the complete
// video workflow as a real model turn. The live tests drive the interactive
// controller and assert on the prompt the session runtime actually receives.
//
// Rust reference, pin 00e176c8:
// `xai-grok-pager/src/slash/commands/imagine_video.rs:9-55`;
// `xai-grok-tools-api/src/slash_commands.rs:127-181`.

import Foundation
@testable import OpenGrokCLI
import OpenGrokPager
import OpenGrokPagerMinimal
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing

private let expectedImagineVideoUsage = "Usage: /imagine-video <description>\n"
    + "Provide a text description to generate a video."

// Keep this independent from `imagineVideoInstruction`: comparing the
// injected prompt against that same function would miss drift in both seams.
private let expectedImagineVideoSkill = """
# Imagine Video

Video starts from an image — there is no text-to-video tool. \
Default to `image_to_video`; use `reference_to_video` only when the user \
explicitly asks for it or a shot genuinely needs multiple reference images.

## Default: single clip

Unless the user asks for a long video, multiple scenes, or a multi-shot sequence, \
generate **one** video:

1. Create a source image with `image_gen` that stages the first frame \
(composition, subject, lighting).
2. Call `image_to_video` with that image and a short prompt describing the motion \
or camera move (1–2 sentences, present tense).
3. After the tool completes, mention the saved file path so the user can find it.

## Longer / multi-shot videos

When the user requests a longer video, multiple scenes, or a narrative sequence:

1. **Plan the story as shots** — break the idea into distinct shots, one beat each.
2. **Favor frequent, short shots** — prefer more 6s clips over fewer long ones; more cuts keep it dynamic.
3. **Create each shot's source image** with `image_gen` (or `image_edit` to combine references), keeping characters and settings consistent across shots.
4. **Animate each shot with `image_to_video`** — the source image becomes frame 1.
5. **Assemble with FFmpeg** using stream copy (`ffmpeg -f concat ... -c copy` — never re-encode). \
Keep every shot at the same resolution and frame rate so the concat works. \
After assembly, mention the final output path.

## Shot guidance

- **Prompt-craft:** one short, vivid moment in present tense with a clear camera movement, in 1–2 sentences.
- **Minimal but interesting:** one clear subject, one simple motion or camera move per shot. Avoid complex multi-action animation; make the shot compelling through composition, lighting, and a strong moment.
- **Complex source image?** Intricate frames (busy geometry, fine detail, heavy reflections) warp when animated. Keep the subject fixed and move only the camera (slow push-in, orbit, or parallax), or break into simpler shots. For new shots, generate a simpler, animation-friendly base image rather than animating a busy one.
- **`image_to_video` animates from frame 1** — stage the first frame with `image_gen`/`image_edit` before animating.
- **Aspect ratio:** set it on the source image (`image_gen` `aspect_ratio`); don't re-crop an existing video.
- **Duration:** 6s or 10s only (prefer 6s); round to the nearest.
- **Real people:** reference-first — drive the video from a verified reference image; never animate a named person without one.
- Don't loop the same clip unless asked.
"""

private func expectedImagineVideoInstruction(_ prompt: String) -> String {
    "\(expectedImagineVideoSkill)\n\nUser prompt: \(prompt)"
}

@Suite("/imagine-video at the composition seam")
struct LivePagerImagineVideoCommandTests {
    @Test("the row exists iff image_to_video is advertised, with upstream copy")
    func registrationGateAndCopy() throws {
        let registrations = LiveImagineVideoCommand.registrations(
            advertisedToolNames: ["image_to_video", "read_file"]
        )
        let registration = try #require(registrations.first)
        #expect(registrations.count == 1)
        #expect(registration.name == "imagine-video")
        #expect(registration.summary == "Generate a video from a text description")
        #expect(registration.usage == "/imagine-video <description>")

        #expect(LiveImagineVideoCommand.registrations(advertisedToolNames: []).isEmpty)
        #expect(LiveImagineVideoCommand.registrations(
            advertisedToolNames: ["image_gen", "image_edit", "reference_to_video"]
        ).isEmpty)
    }

    @Test("empty and whitespace-only prompts return upstream's exact usage")
    func blankPromptReturnsUsage() {
        #expect(
            LiveImagineVideoCommand.outcome(rawArgumentTail: "")
                == .notice(expectedImagineVideoUsage)
        )
        #expect(
            LiveImagineVideoCommand.outcome(rawArgumentTail: "  \t\n  ")
                == .notice(expectedImagineVideoUsage)
        )
    }

    @Test("nonempty prompts inject the complete upstream video workflow")
    func promptInjectsExactInstruction() {
        #expect(
            LiveImagineVideoCommand.outcome(rawArgumentTail: "a cat playing piano")
                == .submit(expectedImagineVideoInstruction("a cat playing piano"))
        )
        #expect(
            LiveImagineVideoCommand.outcome(
                rawArgumentTail: "  a  \"quoted\"  camera move  "
            ) == .submit(expectedImagineVideoInstruction("a  \"quoted\"  camera move"))
        )
    }
}

@Suite("/imagine-video live seam", .serialized)
struct LivePagerImagineVideoReachabilityTests {
    @Test("typed /imagine-video submits the complete instruction into the runtime")
    func typedImagineVideoReachesSessionSeam() async throws {
        let fixture = try ImagineVideoRendererFixture()
        defer { fixture.dispose() }
        let runtime = ImagineVideoRecordingRuntime()
        let result = try await fixture.runController(
            submitting: "/imagine-video a cat playing piano",
            runtime: runtime,
            localCommands: LiveImagineVideoCommand.registrations(
                advertisedToolNames: ["image_to_video"]
            )
        )

        let expected = expectedImagineVideoInstruction("a cat playing piano")
        #expect(runtime.captured == [expected])
        #expect(result.submittedPrompts == [expected])
        #expect(result.completedTurnCount == 1)
    }

    @Test("typed prose retains its quotes and interior whitespace")
    func typedImagineVideoPreservesRawArgumentTail() async throws {
        let fixture = try ImagineVideoRendererFixture()
        defer { fixture.dispose() }
        let runtime = ImagineVideoRecordingRuntime()
        let result = try await fixture.runController(
            submitting: "/imagine-video  a  \"quoted\"  camera move  ",
            runtime: runtime,
            localCommands: LiveImagineVideoCommand.registrations(
                advertisedToolNames: ["image_to_video"]
            )
        )

        let expected = expectedImagineVideoInstruction("a  \"quoted\"  camera move")
        #expect(runtime.captured == [expected])
        #expect(result.submittedPrompts == [expected])
        #expect(result.completedTurnCount == 1)
    }

    @Test("typed bare /imagine-video paints its usage without starting a turn")
    func typedBareImagineVideoPaintsUsage() async throws {
        let fixture = try ImagineVideoRendererFixture()
        defer { fixture.dispose() }
        let runtime = ImagineVideoRecordingRuntime()
        let result = try await fixture.runController(
            submitting: "/imagine-video",
            runtime: runtime,
            localCommands: LiveImagineVideoCommand.registrations(
                advertisedToolNames: ["image_to_video"]
            )
        )

        #expect(await fixture.waitForPaint(of: "Usage: /imagine-video <description>"))
        #expect(await fixture.waitForPaint(
            of: "Provide a text description to generate a video."
        ))
        #expect(runtime.captured.isEmpty)
        #expect(result.submittedPrompts.isEmpty)
        #expect(result.completedTurnCount == 0)
    }

    @Test("without image_to_video, the command is absent and cannot start a turn")
    func missingVideoToolLeavesCommandUnknown() async throws {
        let fixture = try ImagineVideoRendererFixture()
        defer { fixture.dispose() }
        let runtime = ImagineVideoRecordingRuntime()
        let result = try await fixture.runController(
            submitting: "/imagine-video a cat playing piano",
            runtime: runtime,
            localCommands: LiveImagineVideoCommand.registrations(
                advertisedToolNames: ["image_gen", "reference_to_video"]
            )
        )

        #expect(await fixture.waitForPaint(of: "unknown command: /imagine-video"))
        #expect(runtime.captured.isEmpty)
        #expect(result.submittedPrompts.isEmpty)
        #expect(result.completedTurnCount == 0)
    }
}

private final class ImagineVideoCapturingSink: PagerTerminalSink, CustomReflectable,
    @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock()
        defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    var customMirror: Mirror {
        lock.lock()
        defer { lock.unlock() }
        return Mirror(self, children: ["byteCount": bytes.count])
    }

    var strippedText: String {
        lock.lock()
        defer { lock.unlock() }
        var plain: [UInt8] = []
        plain.reserveCapacity(bytes.count / 4)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B else {
                plain.append(bytes[index])
                index += 1
                continue
            }
            index += 1
            guard index < bytes.count else { break }
            switch bytes[index] {
            case UInt8(ascii: "["):
                index += 1
                while index < bytes.count, !(0x40...0x7E).contains(bytes[index]) {
                    index += 1
                }
                index += 1
            case UInt8(ascii: "]"):
                index += 1
                while index < bytes.count {
                    if bytes[index] == 0x07 {
                        index += 1
                        break
                    }
                    if bytes[index] == 0x1B,
                       index + 1 < bytes.count,
                       bytes[index + 1] == UInt8(ascii: "\\") {
                        index += 2
                        break
                    }
                    index += 1
                }
            default:
                index += 1
            }
        }
        return String(decoding: plain, as: UTF8.self)
    }
}

private struct ImagineVideoRendererFixture {
    let home: URL
    let sink: ImagineVideoCapturingSink
    let renderer: LiveInteractiveControllerRenderer

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-imagine-video-reach-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        sink = ImagineVideoCapturingSink()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
            write: { _ in }
        )
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: sink,
            workingDirectory: home.path,
            modelName: "test-model",
            sessionID: "imagine-video-live",
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: ["HOME": home.path, "OPENGROK_HOME": home.path]
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    func waitForPaint(of marker: String, timeout: TimeInterval = 5) async -> Bool {
        let needle = marker.filter { !$0.isWhitespace }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline,
              !sink.strippedText.filter({ !$0.isWhitespace }).contains(needle) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return sink.strippedText.filter { !$0.isWhitespace }.contains(needle)
    }

    func runController(
        submitting line: String,
        runtime: ImagineVideoRecordingRuntime,
        localCommands: [OpenGrokPagerCommandRegistration]
    ) async throws -> OpenGrokPagerInteractiveResult {
        let events: [InputEvent] = [
            .paste(line),
            .key(KeyEvent(key: .escape)),
            .key(KeyEvent(key: .enter)),
        ]
        let controller = OpenGrokPagerInteractiveController(
            input: AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            },
            runtime: runtime,
            renderer: renderer,
            output: ImagineVideoDiscardingOutput(),
            localCommands: localCommands,
            localCommandHandler: { invocation in
                LiveImagineVideoCommand.outcome(
                    rawArgumentTail: OpenGrokPagerInteractiveController
                        .rawArgumentTail(of: invocation)
                )
            }
        )
        return try await controller.run(.init(prompt: "", mode: .inline))
    }
}

private final class ImagineVideoRecordingRuntime: OpenGrokPagerRuntimeAdapter,
    @unchecked Sendable {
    private let lock = NSLock()
    private var prompts: [String] = []

    var captured: [String] {
        lock.lock()
        defer { lock.unlock() }
        return prompts
    }

    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        lock.withLock { prompts.append(request.prompt) }
        return ImagineVideoCompletingSession()
    }
}

private struct ImagineVideoCompletingSession: OpenGrokPagerSessionAdapter {
    var sessionID: String? { "imagine-video-turn" }

    var events: AsyncThrowingStream<OpenGrokPagerEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(OpenGrokPagerMinimalCompletion()))
            continuation.finish()
        }
    }

    func cancel() async {}
    func close() async {}
}

private struct ImagineVideoDiscardingOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_: OpenGrokPagerInteractiveEvent) async throws {}
}
