// PagerMouseReportingToggleCommandTests.swift
//
// `/toggle-mouse-reporting` + scrollback Ctrl+R at the controller seam
// (AGENTS.md §3): real input events into the real controller, evidence from
// the render adapter. Gate off → hidden/unavailable; gate on → slash and
// scrollback Ctrl+R emit `.overlay(.toggleMouseReporting)`; prompt Ctrl+R
// stays inert.

import Foundation
@testable import OpenGrokPager
import OpenGrokPagerCommandUI
import OpenGrokTerminalCore
import Testing

@Suite("/toggle-mouse-reporting gate at the controller seam")
struct PagerMouseReportingToggleCommandTests {
    @Test("static builtin table keeps the timestamps → timeline → toggle order")
    func registeredAfterTimeline() {
        let names = OpenGrokPagerInteractiveController.builtinCommands.map(\.name)
        let timelineIndex = names.firstIndex(of: "timeline")
        let mouseIndex = names.firstIndex(of: "toggle-mouse-reporting")
        #expect(timelineIndex != nil && mouseIndex != nil)
        if let timelineIndex, let mouseIndex {
            #expect(mouseIndex == timelineIndex + 1)
        }
    }

    @Test("gate off: command is hidden from the session catalog and visible ACP list")
    func hiddenWhenGateOff() {
        let session = OpenGrokPagerInteractiveController.sessionBuiltinCommands(
            workflowsEnabled: true,
            mouseReportingToggleEnabled: false
        )
        let mouse = session.first { $0.name == "toggle-mouse-reporting" }
        #expect(mouse?.isHidden == true)
        #expect(mouse?.availability.isAvailable == false)

        let visible = OpenGrokPagerInteractiveController.visibleBuiltinCommandCatalog(
            mouseReportingToggleEnabled: false
        )
        #expect(!visible.contains { $0.name == "toggle-mouse-reporting" })

        let registry = PagerCommandRegistry(commands: session)
        let completions = registry.completions(for: "/")
        #expect(!completions.contains { $0.commandName == "toggle-mouse-reporting" })
    }

    @Test("gate on: command is present and available")
    func presentWhenGateOn() {
        let session = OpenGrokPagerInteractiveController.sessionBuiltinCommands(
            workflowsEnabled: true,
            mouseReportingToggleEnabled: true
        )
        let mouse = session.first { $0.name == "toggle-mouse-reporting" }
        #expect(mouse?.isHidden == false)
        #expect(mouse?.availability == .available)

        let visible = OpenGrokPagerInteractiveController.visibleBuiltinCommandCatalog(
            mouseReportingToggleEnabled: true
        )
        #expect(visible.contains { $0.name == "toggle-mouse-reporting" })
    }

    @Test("gate off: direct dispatch returns the upstream unavailable hint")
    func directDispatchRefusesWhenOff() async throws {
        let renderer = try await runMouseToggle(
            lines: ["/toggle-mouse-reporting"],
            mouseReportingToggleEnabled: false
        )
        #expect(await renderer.overlays.isEmpty)
        #expect(await renderer.notices == [
            OpenGrokPagerInteractiveController.mouseReportingToggleUnavailableMessage
        ])
    }

    @Test("gate on: slash emits .overlay(.toggleMouseReporting)")
    func slashTogglesWhenOn() async throws {
        let renderer = try await runMouseToggle(
            lines: ["/toggle-mouse-reporting"],
            mouseReportingToggleEnabled: true
        )
        #expect(await renderer.overlays == [.toggleMouseReporting])
        #expect(await renderer.notices.isEmpty)
    }

    @Test("gate on: scrollback Ctrl+R emits the same toggle overlay")
    func scrollbackCtrlRTogglesWhenOn() async throws {
        let renderer = try await runMouseToggle(
            events: [
                .key(KeyEvent(key: .tab)),
                .key(KeyEvent(
                    key: .char("r"),
                    modifiers: .control,
                    character: "r"
                )),
            ],
            mouseReportingToggleEnabled: true
        )
        #expect(await renderer.focusChanges == [.scrollback])
        #expect(await renderer.overlays == [.toggleMouseReporting])
    }

    @Test("gate on: prompt Ctrl+R does not emit the toggle")
    func promptCtrlRInertWhenOn() async throws {
        let renderer = try await runMouseToggle(
            events: [
                .key(KeyEvent(
                    key: .char("r"),
                    modifiers: .control,
                    character: "r"
                )),
            ],
            mouseReportingToggleEnabled: true
        )
        #expect(await renderer.focusChanges.isEmpty)
        #expect(await renderer.overlays.isEmpty)
        #expect(await renderer.notices.isEmpty)
    }

    @Test("gate off: scrollback Ctrl+R does not toggle")
    func scrollbackCtrlRInertWhenOff() async throws {
        let renderer = try await runMouseToggle(
            events: [
                .key(KeyEvent(key: .tab)),
                .key(KeyEvent(
                    key: .char("r"),
                    modifiers: .control,
                    character: "r"
                )),
            ],
            mouseReportingToggleEnabled: false
        )
        #expect(await renderer.focusChanges == [.scrollback])
        #expect(await renderer.overlays.isEmpty)
    }

    @Test("help text hides /toggle-mouse-reporting when the gate is off")
    func helpTextRespectsGate() {
        #expect(OpenGrokPagerInteractiveController.helpText.contains("/toggle-mouse-reporting"))
        #expect(!OpenGrokPagerInteractiveController.helpText(
            mouseReportingToggleEnabled: false
        ).contains("/toggle-mouse-reporting"))
        #expect(OpenGrokPagerInteractiveController.helpText(
            mouseReportingToggleEnabled: true
        ).contains("/toggle-mouse-reporting"))
    }
}

private func runMouseToggle(
    lines: [String] = [],
    events: [InputEvent] = [],
    mouseReportingToggleEnabled: Bool
) async throws -> MouseToggleRecordingRenderer {
    var script: [InputEvent] = events
    for line in lines {
        script.append(.paste(line))
        script.append(.key(KeyEvent(key: .escape)))
        script.append(.key(KeyEvent(key: .enter)))
    }
    let renderer = MouseToggleRecordingRenderer()
    let controller = OpenGrokPagerInteractiveController(
        input: AsyncStream { continuation in
            for event in script { continuation.yield(event) }
            continuation.finish()
        },
        runtime: MouseToggleTestRuntime(),
        renderer: renderer,
        output: MouseToggleSilentOutput(),
        mouseReportingToggleEnabled: mouseReportingToggleEnabled
    )
    let result = try await controller.run(.init(prompt: "", mode: .inline))
    #expect(result.submittedPrompts.isEmpty)
    return renderer
}

private actor MouseToggleRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
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

    var focusChanges: [OpenGrokPagerFocusRegion] {
        events.compactMap {
            if case .focusChanged(let region) = $0 { return region }
            return nil
        }
    }
}

private struct MouseToggleSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

private actor MouseToggleTestRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw CancellationError()
    }
}
