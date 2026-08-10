// PagerScreenModeSwitchCommandTests.swift
//
// B2-S2: `/minimal` and `/fullscreen` at the controller seam (AGENTS.md §3):
// real input events into the real controller, evidence taken from what
// lands on the render adapter. The upstream contract is
// `slash/commands/screen_mode_switch.rs` and `mode_support.rs` at pin
// 650c1db7; the exec half (argv rebuild, env override, the actual re-exec)
// is pinned in `Tests/OpenGrokCLITests/LiveScreenModeRelaunchTests.swift`.

import Foundation
@testable import OpenGrokPager
import OpenGrokPagerCommandUI
import OpenGrokTerminalCore
import Testing

@Suite("/minimal and /fullscreen at the controller seam")
struct PagerScreenModeSwitchCommandTests {
    @Test("registry rows carry upstream's copy verbatim, in the context→model neighborhood")
    func registryRowsAreVerbatim() {
        let commands = OpenGrokPagerInteractiveController.builtinCommands

        let minimal = commands.first { $0.name == "minimal" }
        // screen_mode_switch.rs:36-60: name, description, usage; no aliases
        // for /minimal.
        #expect(minimal?.summary
            == "Reopen this session in minimal (scrollback-native) mode — switch back with /fullscreen")
        #expect(minimal?.usage == "/minimal")
        #expect(minimal?.aliases.isEmpty == true)

        let fullscreen = commands.first { $0.name == "fullscreen" }
        #expect(fullscreen?.summary
            == "Reopen this session in fullscreen mode — switch back with /minimal")
        #expect(fullscreen?.usage == "/fullscreen")
        #expect(fullscreen?.aliases == ["full"])

        // Upstream registers the pair between /context and /model
        // (slash/commands/mod.rs:99-102); this port's `/usage` sits inside
        // that neighborhood, so the pinned RELATIVE order is
        // context → … → minimal → fullscreen → model.
        let names = commands.map(\.name)
        let contextIndex = names.firstIndex(of: "context")
        let minimalIndex = names.firstIndex(of: "minimal")
        let fullscreenIndex = names.firstIndex(of: "fullscreen")
        let modelIndex = names.firstIndex(of: "model")
        #expect(contextIndex != nil && minimalIndex != nil)
        if let contextIndex, let minimalIndex, let fullscreenIndex, let modelIndex {
            #expect(contextIndex < minimalIndex)
            #expect(fullscreenIndex == minimalIndex + 1)
            #expect(fullscreenIndex < modelIndex)
        }
    }

    @Test("/minimal from fullscreen relaunches the active session and quits the loop")
    func minimalFromFullscreenRelaunches() async throws {
        let harness = try await runSwitchCommands(
            ["/minimal"], mode: .fullScreen, sessionID: "sess-abc"
        )
        #expect(await harness.overlays == [
            .relaunchInScreenMode(minimal: true, sessionID: "sess-abc")
        ])
        #expect(await harness.notices.isEmpty)
    }

    @Test("/fullscreen (and /full) from minimal relaunches the active session")
    func fullscreenFromMinimalRelaunches() async throws {
        let harness = try await runSwitchCommands(
            ["/full"], mode: .minimal, sessionID: "sess-xyz"
        )
        #expect(await harness.overlays == [
            .relaunchInScreenMode(minimal: false, sessionID: "sess-xyz")
        ])
        #expect(await harness.notices.isEmpty)
    }

    @Test("already-in-mode refusals use upstream's copy and never relaunch")
    func alreadyInModeRefusals() async throws {
        // mode_support.rs:55: "You're already in {current} mode."
        let minimal = try await runSwitchCommands(
            ["/minimal"], mode: .minimal, sessionID: "s1"
        )
        #expect(await minimal.notices == ["You're already in minimal mode."])
        #expect(await minimal.overlays.isEmpty)

        let fullscreen = try await runSwitchCommands(
            ["/fullscreen"], mode: .fullScreen, sessionID: "s1"
        )
        #expect(await fullscreen.notices == ["You're already in fullscreen mode."])
        #expect(await fullscreen.overlays.isEmpty)
    }

    // The S2 inline ruling (recorded divergence): upstream's inline is the
    // full layout, so /fullscreen there refuses AlreadyInMode; THIS port's
    // inline is a degraded ≤12-row strip, so from it BOTH switchers are
    // real transitions.
    @Test("from inline, both switchers relaunch")
    func fromInlineBothSwitchersRelaunch() async throws {
        let minimal = try await runSwitchCommands(
            ["/minimal"], mode: .inline, sessionID: "s2"
        )
        #expect(await minimal.overlays == [
            .relaunchInScreenMode(minimal: true, sessionID: "s2")
        ])

        let fullscreen = try await runSwitchCommands(
            ["/fullscreen"], mode: .inline, sessionID: "s2"
        )
        #expect(await fullscreen.overlays == [
            .relaunchInScreenMode(minimal: false, sessionID: "s2")
        ])
    }

    @Test("without a session there is nothing to reopen")
    func withoutASessionThereIsNothingToReopen() async throws {
        // screen_mode_switch.rs:76-80.
        let harness = try await runSwitchCommands(
            ["/minimal"], mode: .fullScreen, sessionID: nil
        )
        #expect(await harness.notices == ["No active session to reopen in minimal mode"])
        #expect(await harness.overlays.isEmpty)
    }

    @Test("the switchers are in the help text, which also feeds the palette")
    func helpTextListsTheSwitchers() {
        let help = OpenGrokPagerInteractiveController.helpText
        #expect(help.contains("/minimal"))
        #expect(help.contains("/fullscreen"))
    }
}

private func runSwitchCommands(
    _ lines: [String],
    mode: OpenGrokPagerMode,
    sessionID: String?
) async throws -> SwitchRecordingRenderer {
    var events: [InputEvent] = []
    for line in lines {
        events.append(.paste(line))
        events.append(.key(KeyEvent(key: .escape)))
        events.append(.key(KeyEvent(key: .enter)))
    }
    let renderer = SwitchRecordingRenderer()
    let controller = OpenGrokPagerInteractiveController(
        input: AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        },
        runtime: SwitchTestRuntime(),
        renderer: renderer,
        output: SwitchSilentOutput()
    )
    let result = try await controller.run(
        .init(prompt: "", mode: mode, sessionID: sessionID)
    )
    #expect(result.submittedPrompts.isEmpty)
    return renderer
}

private actor SwitchRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
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

private struct SwitchSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

private actor SwitchTestRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        throw CocoaError(.featureUnsupported)
    }
}
