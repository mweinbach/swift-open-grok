// PagerCompactModeCommandTests.swift
//
// `/compact-mode` at the controller seam (AGENTS.md §3): real input events
// into the real controller, evidence taken from what lands on the render
// adapter. The live half — the user-value flip, the persist into
// `[ui] compact_mode`, and the compact frame itself — is pinned in
// `Tests/OpenGrokCLITests/LiveCompactModeTests.swift` and
// `Tests/OpenGrokPagerRenderTests/PagerCompactModeRenderTests.swift`.

import Foundation
@testable import OpenGrokPager
import OpenGrokPagerCommandUI
import OpenGrokTerminalCore
import Testing

@Suite("/compact-mode at the controller seam")
struct PagerCompactModeCommandTests {
    @Test("/compact-mode resolves from the registry with upstream's copy verbatim")
    func resolvesFromRegistry() {
        let registry = PagerCommandRegistry(
            commands: OpenGrokPagerInteractiveController.builtinCommands
        )
        guard case .available(let command) = registry.resolve(
            PagerCommandInvocation(name: "compact-mode")
        ) else {
            Issue.record("/compact-mode should resolve")
            return
        }
        // Name, description, and usage byte-exact from compact_mode.rs:16-27;
        // no aliases upstream.
        #expect(command.name == "compact-mode")
        #expect(command.aliases.isEmpty)
        #expect(command.summary == "Toggle compact UI (less padding, more content)")
        #expect(command.usage == "/compact-mode")
    }

    @Test("/compact-mode sits between /multiline and /vim-mode, upstream's display order")
    func registeredBetweenMultilineAndVimMode() {
        // slash/commands/mod.rs:108-110: multiline, compact_mode, vim_mode.
        let names = OpenGrokPagerInteractiveController.builtinCommands.map(\.name)
        let multilineIndex = names.firstIndex(of: "multiline")
        let compactIndex = names.firstIndex(of: "compact-mode")
        let vimIndex = names.firstIndex(of: "vim-mode")
        #expect(multilineIndex != nil && compactIndex != nil && vimIndex != nil)
        if let multilineIndex, let compactIndex, let vimIndex {
            #expect(compactIndex == multilineIndex + 1)
            #expect(vimIndex == compactIndex + 1)
        }
    }

    @Test("/compact-mode emits .overlay(.toggleCompactMode)")
    func dispatchesToggle() async throws {
        let renderer = try await runCompactModeCommands(["/compact-mode"])
        #expect(await renderer.overlays == [.toggleCompactMode])
        #expect(await renderer.notices.isEmpty)
    }

    @Test("arguments are ignored — same dispatch either way")
    func argumentsAreIgnored() async throws {
        // compact_mode.rs:28 declares `_args`: `/compact-mode on` is the same
        // toggle, never an on/off setter.
        let renderer = try await runCompactModeCommands(["/compact-mode", "/compact-mode on"])
        #expect(await renderer.overlays == [.toggleCompactMode, .toggleCompactMode])
        #expect(await renderer.notices.isEmpty)
    }

    @Test("/compact-mode is in the help text, which also feeds the command palette")
    func helpTextListsCompactMode() {
        #expect(OpenGrokPagerInteractiveController.helpText.contains("/compact-mode"))
    }
}

private func runCompactModeCommands(
    _ lines: [String]
) async throws -> CompactModeRecordingRenderer {
    var events: [InputEvent] = []
    for line in lines {
        events.append(.paste(line))
        events.append(.key(KeyEvent(key: .escape)))
        events.append(.key(KeyEvent(key: .enter)))
    }
    let renderer = CompactModeRecordingRenderer()
    let controller = OpenGrokPagerInteractiveController(
        input: AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        },
        runtime: CompactModeTestRuntime(),
        renderer: renderer,
        output: CompactModeSilentOutput()
    )
    let result = try await controller.run(.init(prompt: "", mode: .inline))
    #expect(result.submittedPrompts.isEmpty)
    return renderer
}

private actor CompactModeRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
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

private struct CompactModeSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

private actor CompactModeTestRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw CancellationError()
    }
}
