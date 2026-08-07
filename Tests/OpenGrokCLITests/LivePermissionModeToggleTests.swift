// LivePermissionModeToggleTests.swift
//
// Runtime permission-mode toggles through the live pager seam: the controller
// forwards `Ctrl+O` / Shift+Tab to the renderer, which mutates the session
// pipeline handle and repaints the composer flag.

import Foundation
import OpenGrokFileTools
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokTerminalCore
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

// MARK: - Helpers

private actor RecordingPrompter: PermissionPrompter {
    private(set) var prompted: [String] = []
    private let answer: PermissionDecision

    init(answer: PermissionDecision) { self.answer = answer }

    func prompt(
        access: AccessKind,
        toolName: String,
        toolCallId: String
    ) async -> PermissionDecision {
        _ = (toolName, toolCallId)
        prompted.append(access.detail ?? "")
        return answer
    }

    func recorded() -> [String] { prompted }
}

private func makeLivePermissionStack(
    rules: [PermissionRule],
    cliAlwaysApprove: Bool = false
) -> (
    mode: LiveSessionPermissionMode,
    pipeline: PermissionPipeline,
    prompter: RecordingPrompter
) {
    let prompter = RecordingPrompter(answer: .reject("user said no"))
    let resolved = ResolvedPermissions(
        config: PermissionConfig(rules: rules, promptPolicy: .ask),
        alwaysApprove: cliAlwaysApprove
    )
    let pipeline = FileToolSession.makePipeline(
        policy: .prompt(prompter),
        workspaceRoot: "/work",
        resolved: resolved
    )
    let mode = LiveSessionPermissionMode(pipeline: pipeline, resolved: resolved)
    return (mode, pipeline, prompter)
}

private func bashRequest(_ command: String) -> PrepareToolAccessRequest {
    PrepareToolAccessRequest(
        access: .bash(command),
        toolName: "run_terminal_cmd",
        toolCallId: "call-1"
    )
}

private final class CapturingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    var strippedText: String {
        lock.lock(); defer { lock.unlock() }
        var output = ""
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B else {
                output.unicodeScalars.append(Unicode.Scalar(bytes[index]))
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
        return output
    }
}

private struct PermissionRendererFixture {
    let sink: CapturingSink
    let renderer: LiveInteractiveControllerRenderer
    let pipeline: PermissionPipeline
    let prompter: RecordingPrompter
    let mode: LiveSessionPermissionMode

    init(rules: [PermissionRule], cliAlwaysApprove: Bool = false) {
        let stack = makeLivePermissionStack(
            rules: rules,
            cliAlwaysApprove: cliAlwaysApprove
        )
        mode = stack.mode
        sink = CapturingSink()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
            write: { _ in }
        )
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: sink,
            workingDirectory: "/work",
            modelName: "test-model",
            permissionMode: stack.mode,
            paintCadence: PagerMotion.minimumPaintCadence
        )
        pipeline = stack.pipeline
        prompter = stack.prompter
    }

    func waitForFrame(containing needle: String, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sink.strippedText.contains(needle) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return sink.strippedText.contains(needle)
    }
}

private func makeInputStream(_ events: [InputEvent]) -> AsyncStream<InputEvent> {
    AsyncStream { continuation in
        for event in events { continuation.yield(event) }
        continuation.finish()
    }
}

private actor StubInteractiveRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(for request: OpenGrokPagerRequest) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw StubInteractiveError.noSession
    }

    func replaceSession(from request: OpenGrokPagerRequest) async throws -> String {
        _ = request
        throw StubInteractiveError.noSession
    }
}

private enum StubInteractiveError: Error, Sendable {
    case noSession
}

private struct SilentInteractiveOutput: OpenGrokPagerInteractiveOutputAdapter, Sendable {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws {
        _ = event
    }
}

// MARK: - Tests

@Suite("Live permission mode toggles", .serialized)
struct LivePermissionModeToggleTests {
    @Test("Ctrl+O toggles always-approve and repaints the composer flag")
    func toggleAlwaysApproveRepaintsFlag() async throws {
        // No compiled ask rules: default-path prompting is what yolo bypasses
        // (`PermissionManager.request` step 3 requires `!policyForcedPrompt`).
        let fixture = PermissionRendererFixture(rules: [])
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.global(.toggleAlwaysApprove))
        #expect(await fixture.waitForFrame(containing: "always-approve"))

        let autoPrepared = await fixture.pipeline.prepare(bashRequest("git push"))
        #expect(autoPrepared.mayDispatch)
        #expect(await fixture.prompter.recorded().isEmpty)

        try await fixture.renderer.render(.global(.toggleAlwaysApprove))
        #expect(await fixture.mode.composerFlags().isEmpty)

        let askPrepared = await fixture.pipeline.prepare(bashRequest("git push"))
        #expect(askPrepared.mayDispatch == false)
        #expect(await fixture.prompter.recorded() == ["git push"])
        try await fixture.renderer.restoreTerminal()
    }

    @Test("Shift+Tab cycles ask and always-approve")
    func cyclePermissionModeRepaintsFlag() async throws {
        let fixture = PermissionRendererFixture(rules: [])
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.global(.cyclePermissionMode))
        #expect(await fixture.waitForFrame(containing: "always-approve"))
        #expect(await fixture.mode.composerFlags().map(\.label) == ["always-approve"])

        try await fixture.renderer.render(.global(.cyclePermissionMode))
        #expect(await fixture.mode.composerFlags().isEmpty)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("deny rules still win over always-approve")
    func denyOutranksAlwaysApprove() async throws {
        let fixture = PermissionRendererFixture(rules: [
            PermissionRule(action: .deny, tool: .bash, pattern: "rm", source: .config),
            PermissionRule(action: .ask, tool: .bash, pattern: "*", source: .config),
        ])
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.global(.toggleAlwaysApprove))
        #expect(await fixture.waitForFrame(containing: "always-approve"))

        let prepared = await fixture.pipeline.prepare(bashRequest("rm -rf /"))
        #expect(prepared.mayDispatch == false)
        guard case .policyDeny = prepared.decision else {
            Issue.record("expected policy deny, got \(prepared.decision)")
            return
        }
        try await fixture.renderer.restoreTerminal()
    }

    @Test("controller forwards permission chords to the live renderer")
    func controllerForwardsPermissionChords() async throws {
        let stack = makeLivePermissionStack(rules: [])
        let sink = CapturingSink()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
            write: { _ in }
        )
        let renderer = LiveInteractiveControllerRenderer(
            mode: .inline,
            terminal: terminal,
            sink: sink,
            workingDirectory: "/work",
            modelName: "test-model",
            permissionMode: stack.mode,
            paintCadence: PagerMotion.minimumPaintCadence
        )
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .key(KeyEvent(key: .backTab)),
                .key(KeyEvent(
                    key: .char("o"),
                    modifiers: [.control],
                    character: "o"
                )),
            ]),
            runtime: StubInteractiveRuntime(),
            renderer: renderer,
            output: SilentInteractiveOutput()
        )

        let chordResult = try await controller.run(.init(prompt: "", mode: .inline))
        #expect(chordResult.submittedPrompts.isEmpty)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if sink.strippedText.contains("always-approve") { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(sink.strippedText.contains("always-approve"))
    }

    @Test("/always-approve toggles always-approve through the live renderer")
    func alwaysApproveSlashCommandRepaintsFlag() async throws {
        // Same live seam as Ctrl+O: slash → handleGlobal → applyGlobal.
        let stack = makeLivePermissionStack(rules: [])
        let sink = CapturingSink()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
            write: { _ in }
        )
        let renderer = LiveInteractiveControllerRenderer(
            mode: .inline,
            terminal: terminal,
            sink: sink,
            workingDirectory: "/work",
            modelName: "test-model",
            permissionMode: stack.mode,
            paintCadence: PagerMotion.minimumPaintCadence
        )
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .paste("/always-approve"),
                .key(KeyEvent(key: .enter)),
            ]),
            runtime: StubInteractiveRuntime(),
            renderer: renderer,
            output: SilentInteractiveOutput()
        )

        let slashResult = try await controller.run(.init(prompt: "", mode: .inline))
        #expect(slashResult.submittedPrompts.isEmpty)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if sink.strippedText.contains("always-approve") { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(sink.strippedText.contains("always-approve"))

        let autoPrepared = await stack.pipeline.prepare(bashRequest("git push"))
        #expect(autoPrepared.mayDispatch)
        #expect(await stack.prompter.recorded().isEmpty)
    }
}
