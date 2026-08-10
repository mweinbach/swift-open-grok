// PagerExpandCommandTests.swift
//
// `/expand` and the minimal Ctrl+E chord at the controller seam
// (AGENTS.md §3). Upstream contract at pin 650c1db7:
// `slash/commands/expand.rs`, `mode_support.rs:52-56` (the UseInstead
// refusal), and `minimal_key_intercept` (`app_view.rs:4750-4777`, gated on
// `is_minimal()`). The re-print half — the ring pop, the uncapped
// insertBefore — is pinned in
// `Tests/OpenGrokPagerRenderTests/MinimalFrameHostTests.swift`.

import Foundation
@testable import OpenGrokPager
import OpenGrokPagerCommandUI
import OpenGrokTerminalCore
import Testing

@Suite("/expand and Ctrl+E at the controller seam")
struct PagerExpandCommandTests {
    @Test("registry row carries upstream's copy verbatim, between /transcript and /context")
    func registryRowIsVerbatim() {
        let commands = OpenGrokPagerInteractiveController.builtinCommands
        let expand = commands.first { $0.name == "expand" }
        // expand.rs:19-33: name, description, usage; no aliases.
        #expect(expand?.summary
            == "Re-print the last collapsed block, fully expanded (minimal mode)")
        #expect(expand?.usage == "/expand")
        #expect(expand?.aliases.isEmpty == true)

        // slash/commands/mod.rs:95-98: transcript → (edit_prompt, absent
        // here) → expand → context.
        let names = commands.map(\.name)
        let transcriptIndex = names.firstIndex(of: "transcript")
        let expandIndex = names.firstIndex(of: "expand")
        let contextIndex = names.firstIndex(of: "context")
        #expect(transcriptIndex != nil && expandIndex != nil && contextIndex != nil)
        if let transcriptIndex, let expandIndex, let contextIndex {
            #expect(transcriptIndex < expandIndex)
            #expect(expandIndex < contextIndex)
        }
    }

    @Test("/expand in minimal dispatches the expand intent")
    func expandInMinimalDispatches() async throws {
        let harness = try await runExpandInputs(
            [.paste("/expand"), .key(KeyEvent(key: .escape)), .key(KeyEvent(key: .enter))],
            mode: .minimal, sessionID: "s1"
        )
        #expect(await harness.overlays == [.minimalExpandLast])
        #expect(await harness.notices.isEmpty)
    }

    @Test("outside minimal the refusal names the live affordance instead")
    func outsideMinimalTheRefusalNamesTheAffordance() async throws {
        // mode_support.rs:52-56, the UseInstead arm — the fold is a live
        // scrollback affordance in fullscreen, so the remedy names it.
        let harness = try await runExpandInputs(
            [.paste("/expand"), .key(KeyEvent(key: .escape)), .key(KeyEvent(key: .enter))],
            mode: .fullScreen, sessionID: "s1"
        )
        #expect(await harness.notices == [
            "/expand isn't available in fullscreen mode — press Tab to focus the scrollback, then → on the block."
        ])
        #expect(await harness.overlays.isEmpty)
    }

    @Test("Ctrl+E in minimal rides the /expand dispatch")
    func ctrlEInMinimalRidesTheExpandDispatch() async throws {
        // minimal_key_intercept (app_view.rs:4758-4759): the chord and the
        // command are twins — one dispatch, one ring.
        let harness = try await runExpandInputs(
            [.key(KeyEvent(key: .char("e"), modifiers: [.control]))],
            mode: .minimal, sessionID: "s1"
        )
        #expect(await harness.overlays == [.minimalExpandLast])
    }

    @Test("Ctrl+E outside minimal stays the composer's end-of-line chord")
    func ctrlEOutsideMinimalStaysWithTheComposer() async throws {
        // The intercept is gated on is_minimal (app_view.rs:3261): in
        // fullscreen the chord belongs to the editor (EditorKeys.swift:37,
        // moveLogicalLineEnd) and must dispatch nothing.
        let harness = try await runExpandInputs(
            [.key(KeyEvent(key: .char("e"), modifiers: [.control]))],
            mode: .fullScreen, sessionID: "s1"
        )
        #expect(await harness.overlays.isEmpty)
        #expect(await harness.notices.isEmpty)
    }
}

private func runExpandInputs(
    _ events: [InputEvent],
    mode: OpenGrokPagerMode,
    sessionID: String?
) async throws -> ExpandRecordingRenderer {
    let renderer = ExpandRecordingRenderer()
    let controller = OpenGrokPagerInteractiveController(
        input: AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        },
        runtime: ExpandTestRuntime(),
        renderer: renderer,
        output: ExpandSilentOutput()
    )
    let result = try await controller.run(
        .init(prompt: "", mode: mode, sessionID: sessionID)
    )
    #expect(result.submittedPrompts.isEmpty)
    return renderer
}

private actor ExpandRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
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

private struct ExpandSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

private actor ExpandTestRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        throw CocoaError(.featureUnsupported)
    }
}
