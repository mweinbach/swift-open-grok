// PagerFastCommandTests.swift
//
// `/fast` at the controller seam (AGENTS.md §3): real input events into the
// real controller, evidence taken from what lands on the render adapter. The
// live half — toggle semantics, error copies, and the tier reaching the
// outbound request body — is pinned in
// `Tests/OpenGrokCLITests/LiveFastModeTests.swift`.

import Foundation
@testable import OpenGrokPager
import OpenGrokPagerCommandUI
import OpenGrokTerminalCore
import Testing

@Suite("/fast at the controller seam")
struct PagerFastCommandTests {
    @Test("/fast resolves from the registry with upstream's copy verbatim")
    func resolvesFromRegistry() {
        let registry = PagerCommandRegistry(
            commands: OpenGrokPagerInteractiveController.builtinCommands
        )
        guard case .available(let command) = registry.resolve(
            PagerCommandInvocation(name: "fast")
        ) else {
            Issue.record("/fast should resolve")
            return
        }
        // Name, description, and usage byte-exact from fast.rs:11-25.
        #expect(command.name == "fast")
        #expect(command.summary == "Toggle Fast mode (priority routing) for the current model")
        #expect(command.usage == "/fast")
    }

    @Test("/fast is registered immediately after /effort, upstream's display order")
    func registeredAfterEffort() {
        // slash/commands/mod.rs:102-105: model, effort, fast, always-approve.
        let names = OpenGrokPagerInteractiveController.builtinCommands.map(\.name)
        let effortIndex = names.firstIndex(of: "effort")
        let fastIndex = names.firstIndex(of: "fast")
        #expect(effortIndex != nil && fastIndex != nil)
        if let effortIndex, let fastIndex {
            #expect(fastIndex == effortIndex + 1)
        }
    }

    @Test("/fast emits .overlay(.fastMode)")
    func dispatchesFastMode() async throws {
        let renderer = try await runFastCommands(["/fast"])
        #expect(await renderer.overlays == [.fastMode])
        #expect(await renderer.notices.isEmpty)
    }

    @Test("arguments are ignored — same dispatch either way")
    func argumentsAreIgnored() async throws {
        // fast.rs:31 declares `_args`: `/fast extra` is the same action.
        let renderer = try await runFastCommands(["/fast", "/fast extra"])
        #expect(await renderer.overlays == [.fastMode, .fastMode])
        #expect(await renderer.notices.isEmpty)
    }
}

private func runFastCommands(
    _ lines: [String]
) async throws -> FastRecordingRenderer {
    var events: [InputEvent] = []
    for line in lines {
        events.append(.paste(line))
        events.append(.key(KeyEvent(key: .escape)))
        events.append(.key(KeyEvent(key: .enter)))
    }
    let renderer = FastRecordingRenderer()
    let controller = OpenGrokPagerInteractiveController(
        input: AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        },
        runtime: FastTestRuntime(),
        renderer: renderer,
        output: FastSilentOutput()
    )
    let result = try await controller.run(.init(prompt: "", mode: .inline))
    #expect(result.submittedPrompts.isEmpty)
    return renderer
}

private actor FastRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private var events: [OpenGrokPagerInteractiveEvent] = []

    func begin() {}
    func restoreTerminal() {}

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }

    var overlays: [OpenGrokPagerOverlayRequest] {
        events.compactMap {
            if case .overlay(let request) = $0 { return request }
            return nil
        }
    }

    var notices: [String] {
        events.compactMap {
            if case .notice(let message) = $0 { return message }
            return nil
        }
    }
}

private struct FastSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

private actor FastTestRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw CancellationError()
    }
}
