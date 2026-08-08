// PagerTimelineCommandTests.swift
//
// `/timeline` at the controller seam (AGENTS.md §3): real input events into
// the real controller, evidence taken from what lands on the render adapter.
// The live half — the user-value flip, the persist into `[ui] show_timeline`,
// the fullscreen-only refusal, and the painted rail — is pinned in
// `Tests/OpenGrokCLITests/LiveTimelineTests.swift`; the rail's geometry and
// paint are pinned in
// `Tests/OpenGrokPagerRenderTests/PagerTimelineRailTests.swift`.

import Foundation
@testable import OpenGrokPager
import OpenGrokPagerCommandUI
import OpenGrokTerminalCore
import Testing

@Suite("/timeline at the controller seam")
struct PagerTimelineCommandTests {
    @Test("/timeline resolves from the registry with upstream's copy verbatim")
    func resolvesFromRegistry() {
        let registry = PagerCommandRegistry(
            commands: OpenGrokPagerInteractiveController.builtinCommands
        )
        guard case .available(let command) = registry.resolve(
            PagerCommandInvocation(name: "timeline")
        ) else {
            Issue.record("/timeline should resolve")
            return
        }
        // Name, description, and usage byte-exact from timeline.rs:13-19,
        // 27-29; no aliases upstream.
        #expect(command.name == "timeline")
        #expect(command.aliases.isEmpty)
        #expect(command.summary == "Toggle the timeline sidebar")
        #expect(command.usage == "/timeline")
    }

    @Test("/timeline sits between /timestamps and /toggle-mouse-reporting, upstream's display order")
    func registeredBetweenTimestampsAndMouseReporting() {
        // slash/commands/mod.rs:137-139: timestamps, timeline,
        // toggle_mouse_reporting — the adjacent triple, pinned on both sides.
        let names = OpenGrokPagerInteractiveController.builtinCommands.map(\.name)
        let timestampsIndex = names.firstIndex(of: "timestamps")
        let timelineIndex = names.firstIndex(of: "timeline")
        let mouseIndex = names.firstIndex(of: "toggle-mouse-reporting")
        #expect(timestampsIndex != nil && timelineIndex != nil && mouseIndex != nil)
        if let timestampsIndex, let timelineIndex, let mouseIndex {
            #expect(timelineIndex == timestampsIndex + 1)
            #expect(mouseIndex == timelineIndex + 1)
        }
    }

    @Test("/timeline emits .overlay(.toggleTimeline)")
    func dispatchesToggle() async throws {
        let renderer = try await runTimelineCommands(["/timeline"])
        #expect(await renderer.overlays == [.toggleTimeline])
        #expect(await renderer.notices.isEmpty)
    }

    @Test("arguments are ignored — same dispatch either way")
    func argumentsAreIgnored() async throws {
        // timeline.rs:31 declares `_args` and computes the toggle from the
        // cached value itself: `/timeline on` is the same toggle, never an
        // on/off setter.
        let renderer = try await runTimelineCommands(["/timeline", "/timeline on"])
        #expect(await renderer.overlays == [.toggleTimeline, .toggleTimeline])
        #expect(await renderer.notices.isEmpty)
    }

    @Test("/timeline is in the help text, which also feeds the command palette")
    func helpTextListsTimeline() {
        #expect(OpenGrokPagerInteractiveController.helpText.contains("/timeline"))
    }
}

private func runTimelineCommands(
    _ lines: [String]
) async throws -> TimelineRecordingRenderer {
    var events: [InputEvent] = []
    for line in lines {
        events.append(.paste(line))
        events.append(.key(KeyEvent(key: .escape)))
        events.append(.key(KeyEvent(key: .enter)))
    }
    let renderer = TimelineRecordingRenderer()
    let controller = OpenGrokPagerInteractiveController(
        input: AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        },
        runtime: TimelineTestRuntime(),
        renderer: renderer,
        output: TimelineSilentOutput()
    )
    let result = try await controller.run(.init(prompt: "", mode: .inline))
    #expect(result.submittedPrompts.isEmpty)
    return renderer
}

private actor TimelineRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
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

private struct TimelineSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

private actor TimelineTestRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw CancellationError()
    }
}
