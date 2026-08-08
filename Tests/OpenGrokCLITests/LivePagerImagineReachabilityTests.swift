// LivePagerImagineReachabilityTests.swift
//
// `/imagine` at both seams (AGENTS.md §3). Composition seam: the
// registration gate (`required_tools: ["image_gen"]`, `imagine.rs:8,37-39`)
// and the dispatch arms with byte-exact copy (`imagine.rs:41-55`,
// `xai-grok-tools-api/src/slash_commands.rs:111-125`). Live seam: the real
// `LiveInteractiveControllerRenderer` painting into a captured sink in an
// isolated `$OPENGROK_HOME`, driven end-to-end through the real controller
// from typed input, with the injection asserted where it lands — the prompt
// the RUNTIME adapter is asked to run. Asserting the handler's return alone
// would pass with the submit path deleted.

import Foundation
@testable import OpenGrokCLI
import OpenGrokPager
import OpenGrokPagerMinimal
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing

// MARK: - Expected copy (upstream literals, not the port's own constants)

/// `imagine_usage_message` (`slash_commands.rs:111-114`), byte-exact.
/// Pinned as a literal so a drifted `imagineUsageMessage()` fails here
/// instead of validating itself.
private let expectedUsage = "Usage: /imagine <description>\n"
    + "Provide a text description to generate an image."

/// `imagine_instruction(prompt)` (`slash_commands.rs:117-125`), byte-exact
/// for a fixed prompt.
private func expectedInstruction(_ prompt: String) -> String {
    "Call the image_gen tool immediately, passing the user's prompt below "
        + "verbatim — do not rewrite, embellish, or expand it. "
        + "After the tool completes, briefly acknowledge and mention "
        + "where the image was saved.\n\nPrompt: \(prompt)"
}

@Suite("/imagine at the composition seam")
struct LivePagerImagineCommandTests {
    @Test("the row exists iff image_gen is advertised, copy verbatim")
    func registrationGateAndCopy() throws {
        // Gate ON: the advertised toolset carries image_gen (imagine.rs:8).
        let rows = LiveImagineCommand.registrations(
            advertisedToolNames: ["image_gen", "read_file", "run_terminal_cmd"]
        )
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        // imagine.rs:13-15 via IMAGINE_COMMAND_NAME (slash_commands.rs:102).
        #expect(row.name == "imagine")
        // imagine.rs:17-19.
        #expect(row.summary == "Generate an image from a text description")
        // imagine.rs:21-23.
        #expect(row.usage == "/imagine <description>")

        // Gate OFF: no image_gen, no row — including when only image_edit
        // survived the credential resolution.
        #expect(LiveImagineCommand.registrations(advertisedToolNames: []).isEmpty)
        #expect(LiveImagineCommand.registrations(
            advertisedToolNames: ["image_edit", "read_file", "grep"]
        ).isEmpty)
    }

    @Test("empty and whitespace prompts echo upstream's usage copy, byte-exact")
    func emptyPromptEchoesUsage() {
        // imagine.rs:42-45 — `args.trim()` then the usage message as a
        // `CommandResult::Message`, mapped onto the notice channel.
        #expect(LiveImagineCommand.outcome(rawArgumentTail: "") == .notice(expectedUsage))
        #expect(LiveImagineCommand.outcome(rawArgumentTail: "   ") == .notice(expectedUsage))
    }

    @Test("a prompt expands to imagine_instruction, byte-exact, prompt verbatim")
    func promptExpandsToInstruction() {
        // imagine.rs:47-54 — the InjectSkill payload text.
        #expect(
            LiveImagineCommand.outcome(rawArgumentTail: "a golden sunset")
                == .submit(expectedInstruction("a golden sunset"))
        )
        // `args.trim()` only trims the ends; interior spacing and quotes are
        // the user's prose and must survive verbatim.
        #expect(
            LiveImagineCommand.outcome(rawArgumentTail: "  a  \"quoted\"  scene  ")
                == .submit(expectedInstruction("a  \"quoted\"  scene"))
        )
    }
}

@Suite("/imagine live seam", .serialized)
struct LivePagerImagineReachabilityTests {
    @Test("typed /imagine <prose> submits the exact instruction into the session seam")
    func typedImagineReachesSessionSeam() async throws {
        let fixture = try ImagineRendererFixture()
        defer { fixture.dispose() }
        let runtime = ImagineRecordingRuntime()
        try await fixture.runController(
            submitting: ["/imagine sunset over water"],
            runtime: runtime,
            localCommands: LiveImagineCommand.registrations(
                advertisedToolNames: ["image_gen"]
            )
        )
        // The seam: what the runtime was actually asked to run. Byte-exact —
        // the injected instruction, not the typed command line.
        #expect(runtime.captured == [expectedInstruction("sunset over water")])
    }

    @Test("typed bare /imagine paints the usage message and starts no turn")
    func typedBareImaginePaintsUsage() async throws {
        let fixture = try ImagineRendererFixture()
        defer { fixture.dispose() }
        let runtime = ImagineRecordingRuntime()
        try await fixture.runController(
            submitting: ["/imagine"],
            runtime: runtime,
            localCommands: LiveImagineCommand.registrations(
                advertisedToolNames: ["image_gen"]
            )
        )
        // The byte-exact copy is pinned at the composition seam; these
        // needles prove the notice reaches the painted screen.
        #expect(await fixture.waitForPaint(of: "Usage: /imagine <description>"))
        #expect(await fixture.waitForPaint(
            of: "Provide a text description to generate an image."
        ))
        #expect(runtime.captured.isEmpty)
    }

    @Test("with image tools off the row is absent and typed /imagine is unknown")
    func absentGateLeavesNoRow() async throws {
        let fixture = try ImagineRendererFixture()
        defer { fixture.dispose() }
        let runtime = ImagineRecordingRuntime()
        // The gate the composition applies: no image_gen in the advertised
        // toolset, no registration — the handler stays installed, proving
        // absence comes from the gate and not from a missing closure.
        try await fixture.runController(
            submitting: ["/imagine sunset over water"],
            runtime: runtime,
            localCommands: LiveImagineCommand.registrations(
                advertisedToolNames: ["read_file", "grep"]
            )
        )
        #expect(await fixture.waitForPaint(of: "unknown command: /imagine"))
        #expect(runtime.captured.isEmpty)
    }
}

// MARK: - Fixtures (the LivePagerDocsReachabilityTests shape)

private final class ImagineCapturingSink: PagerTerminalSink, CustomReflectable,
    @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    /// A failed `#expect` mirrors captured values; without this, Swift
    /// Testing dumps the whole byte buffer as decimal text.
    var customMirror: Mirror {
        lock.lock(); defer { lock.unlock() }
        return Mirror(self, children: ["byteCount": bytes.count])
    }

    var strippedText: String {
        lock.lock(); defer { lock.unlock() }
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
                    if bytes[index] == 0x07 { index += 1; break }
                    if bytes[index] == 0x1B, index + 1 < bytes.count,
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
        // Decode as UTF-8, NOT one scalar per byte — a byte-per-scalar
        // decode mangles multi-byte glyphs and hides painted rows.
        return String(decoding: plain, as: UTF8.self)
    }
}

private struct ImagineRendererFixture {
    let home: URL
    let sink: ImagineCapturingSink
    let renderer: LiveInteractiveControllerRenderer

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opengrok-imagine-reach-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        sink = ImagineCapturingSink()
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
            sessionID: "imagine-live",
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: ["HOME": home.path, "OPENGROK_HOME": home.path]
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    /// The painted frame with all whitespace removed — the diff encoder
    /// skips unchanged cells, so multi-word needles never match raw capture.
    func paintedCompact() -> String {
        sink.strippedText.filter { !$0.isWhitespace }
    }

    func waitForPaint(of marker: String, timeout: TimeInterval = 5) async -> Bool {
        let needle = marker.filter { !$0.isWhitespace }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !paintedCompact().contains(needle) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return paintedCompact().contains(needle)
    }

    /// Run the REAL controller over this renderer with typed input, with
    /// `/imagine` registered exactly as the composition registers it and
    /// dispatched through the same `LiveImagineCommand` arm the composition
    /// installs. Each line is typed, the dropdown closed with Esc (so Enter
    /// submits the typed text, not the highlighted suggestion), and
    /// submitted.
    func runController(
        submitting lines: [String],
        runtime: ImagineRecordingRuntime,
        localCommands: [OpenGrokPagerCommandRegistration]
    ) async throws {
        var events: [InputEvent] = []
        for line in lines {
            events.append(.paste(line))
            events.append(.key(KeyEvent(key: .escape)))
            events.append(.key(KeyEvent(key: .enter)))
        }
        let controller = OpenGrokPagerInteractiveController(
            input: AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            },
            runtime: runtime,
            renderer: renderer,
            output: ImagineDiscardingOutput(),
            localCommands: localCommands,
            localCommandHandler: { invocation in
                // The composition's `/imagine` arm, verbatim: the raw tail,
                // never the tokenizer's rejoin.
                LiveImagineCommand.outcome(
                    rawArgumentTail: OpenGrokPagerInteractiveController
                        .rawArgumentTail(of: invocation)
                )
            }
        )
        _ = try await controller.run(.init(prompt: "", mode: .inline))
    }
}

/// Records every prompt the controller asks the runtime to run — the session
/// seam the injection must reach — and completes the turn immediately.
private final class ImagineRecordingRuntime: OpenGrokPagerRuntimeAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var prompts: [String] = []

    var captured: [String] {
        lock.lock(); defer { lock.unlock() }
        return prompts
    }

    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        // `NSLock.lock()` is async-unavailable; the scoped form is not.
        lock.withLock { prompts.append(request.prompt) }
        return ImagineCompletingSession()
    }
}

private struct ImagineCompletingSession: OpenGrokPagerSessionAdapter {
    var sessionID: String? { "imagine-turn" }
    var events: AsyncThrowingStream<OpenGrokPagerEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(OpenGrokPagerMinimalCompletion()))
            continuation.finish()
        }
    }
    func cancel() async {}
    func close() async {}
}

private struct ImagineDiscardingOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}
