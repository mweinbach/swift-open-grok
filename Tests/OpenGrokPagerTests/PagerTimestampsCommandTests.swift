// PagerTimestampsCommandTests.swift
//
// `/timestamps` at the controller seam (AGENTS.md §3): real input events
// into the real controller, evidence taken from what lands on the render
// adapter. The live half — the user-value flip, the persist into
// `[ui] show_timestamps`, and the painted stamp itself — is pinned in
// `Tests/OpenGrokCLITests/LiveTimestampsTests.swift` and
// `Tests/OpenGrokPagerRenderTests/PagerTimestampsRenderTests.swift`.

import Foundation
@testable import OpenGrokPager
import OpenGrokPagerCommandUI
import OpenGrokTerminalCore
import Testing

@Suite("/timestamps at the controller seam")
struct PagerTimestampsCommandTests {
    @Test("/timestamps resolves from the registry with upstream's copy verbatim")
    func resolvesFromRegistry() {
        let registry = PagerCommandRegistry(
            commands: OpenGrokPagerInteractiveController.builtinCommands
        )
        guard case .available(let command) = registry.resolve(
            PagerCommandInvocation(name: "timestamps")
        ) else {
            Issue.record("/timestamps should resolve")
            return
        }
        // Name, description, and usage byte-exact from timestamps.rs:12-23;
        // no aliases upstream.
        #expect(command.name == "timestamps")
        #expect(command.aliases.isEmpty)
        #expect(command.summary == "Toggle message timestamps on/off")
        #expect(command.usage == "/timestamps")
    }

    @Test("/timestamps sits immediately before /timeline, upstream's display order")
    func registeredBeforeTimeline() {
        // slash/commands/mod.rs:137-139: timestamps, timeline,
        // toggle_mouse_reporting — all three ported, so the pin is the full
        // adjacent triple (the /timeline half is in
        // PagerTimelineCommandTests).
        let names = OpenGrokPagerInteractiveController.builtinCommands.map(\.name)
        let timestampsIndex = names.firstIndex(of: "timestamps")
        let timelineIndex = names.firstIndex(of: "timeline")
        #expect(timestampsIndex != nil && timelineIndex != nil)
        if let timestampsIndex, let timelineIndex {
            #expect(timelineIndex == timestampsIndex + 1)
        }
    }

    @Test("/timestamps emits .overlay(.toggleTimestamps)")
    func dispatchesToggle() async throws {
        let renderer = try await runTimestampsCommands(["/timestamps"])
        #expect(await renderer.overlays == [.toggleTimestamps])
        #expect(await renderer.notices.isEmpty)
    }

    @Test("arguments are ignored — same dispatch either way")
    func argumentsAreIgnored() async throws {
        // timestamps.rs:29 declares `_args` and computes the toggle from the
        // cached value itself: `/timestamps on` is the same toggle, never an
        // on/off setter (the "on/off" arg_placeholder is dropdown copy only).
        let renderer = try await runTimestampsCommands(["/timestamps", "/timestamps on"])
        #expect(await renderer.overlays == [.toggleTimestamps, .toggleTimestamps])
        #expect(await renderer.notices.isEmpty)
    }

    @Test("/timestamps is in the help text, which also feeds the command palette")
    func helpTextListsTimestamps() {
        #expect(OpenGrokPagerInteractiveController.helpText.contains("/timestamps"))
    }
}

private func runTimestampsCommands(
    _ lines: [String]
) async throws -> TimestampsRecordingRenderer {
    var events: [InputEvent] = []
    for line in lines {
        events.append(.paste(line))
        events.append(.key(KeyEvent(key: .escape)))
        events.append(.key(KeyEvent(key: .enter)))
    }
    let renderer = TimestampsRecordingRenderer()
    let controller = OpenGrokPagerInteractiveController(
        input: AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        },
        runtime: TimestampsTestRuntime(),
        renderer: renderer,
        output: TimestampsSilentOutput()
    )
    let result = try await controller.run(.init(prompt: "", mode: .inline))
    #expect(result.submittedPrompts.isEmpty)
    return renderer
}

private actor TimestampsRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
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

private struct TimestampsSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

private actor TimestampsTestRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw CancellationError()
    }
}
