// PagerDashboardCommandTests.swift
//
// Wave 18 B1-d: `/dashboard` and the Ctrl+G / Ctrl+\ chords at the
// controller seam. Upstream contract at pin 650c1db7:
// `slash/commands/dashboard.rs` (copy, aliases, the minimal ModeSupport
// refusal) and `actions/defaults.rs:44-55,890` (the chords, previously
// predeclared-unbound in this port "until the backing surface exists" —
// which B1-t and B1-d are). The roster's build and attach dispatch are
// pinned in `Tests/OpenGrokCLITests/LiveDashboardOverlayTests.swift`.

import Foundation
@testable import OpenGrokPager
import OpenGrokPagerCommandUI
import OpenGrokTerminalCore
import Testing

@Suite("/dashboard and the roster chords at the controller seam")
struct PagerDashboardCommandTests {
    @Test("registry row carries upstream's copy and aliases verbatim")
    func registryRowIsVerbatim() {
        let commands = OpenGrokPagerInteractiveController.builtinCommands
        let dashboard = commands.first { $0.name == "dashboard" }
        // dashboard.rs:27-52 — /sessions survives the sessions-modal
        // removal as an alias; /agents-dashboard is the long form.
        #expect(dashboard?.summary
            == "Open the Agent Dashboard — a fullscreen overview of every running session")
        #expect(dashboard?.usage == "/dashboard")
        #expect(dashboard?.aliases.sorted() == ["agents-dashboard", "sessions"])

        // The pinned RELATIVE pair (mod.rs:117-118): /dashboard follows
        // /rename (upstream's /cd between it and /theme lands with B1-c).
        let names = commands.map(\.name)
        let renameIndex = names.firstIndex(of: "rename")
        #expect(renameIndex != nil)
        #expect(names.firstIndex(of: "dashboard") == renameIndex.map { $0 + 1 })
    }

    @Test("/dashboard dispatches the roster; /sessions rides the alias")
    func dashboardDispatchesTheRoster() async throws {
        let harness = try await runDashboardInputs(
            [.paste("/dashboard"), .key(KeyEvent(key: .escape)), .key(KeyEvent(key: .enter)),
             .paste("/sessions"), .key(KeyEvent(key: .escape)), .key(KeyEvent(key: .enter))],
            mode: .fullScreen
        )
        #expect(await harness.overlays == [.showDashboard, .showDashboard])
        #expect(await harness.notices.isEmpty)
    }

    @Test("minimal refuses with upstream's why-fragment verbatim")
    func minimalRefusesWithUpstreamCopy() async throws {
        // mode_support.rs:47-51 over dashboard.rs:55-59.
        let harness = try await runDashboardInputs(
            [.paste("/dashboard"), .key(KeyEvent(key: .escape)), .key(KeyEvent(key: .enter))],
            mode: .minimal
        )
        #expect(await harness.notices == [
            "/dashboard isn't available in minimal mode (minimal is single-session). Run /fullscreen to switch this session."
        ])
        #expect(await harness.overlays.isEmpty)
    }

    @Test("Ctrl+G and Ctrl+backslash forward as global commands")
    func chordsForwardAsGlobalCommands() async throws {
        // defaults.rs:44-55 (ToggleTasks) and :890 (OpenDashboard) — bound
        // now that the surfaces exist; the render layer owns both, so they
        // forward like the permission-mode pair.
        let harness = try await runDashboardInputs(
            [.key(KeyEvent(key: .char("g"), modifiers: [.control])),
             .key(KeyEvent(key: .char("\\"), modifiers: [.control]))],
            mode: .fullScreen
        )
        #expect(await harness.globals == [.toggleTasks, .openDashboard])
    }

    @Test("the raw FS byte spelling of Ctrl+backslash binds too")
    func rawFSByteBinds() async throws {
        // Terminals report Ctrl+\ as 0x1C — the Ctrl+C `\u{3}` precedent.
        let harness = try await runDashboardInputs(
            [.key(KeyEvent(key: .char("\u{1c}"), modifiers: [.control]))],
            mode: .fullScreen
        )
        #expect(await harness.globals == [.openDashboard])
    }

    @Test("/dashboard is in the help text")
    func helpTextListsDashboard() {
        #expect(OpenGrokPagerInteractiveController.helpText.contains("/dashboard"))
    }
}

private func runDashboardInputs(
    _ events: [InputEvent],
    mode: OpenGrokPagerMode
) async throws -> DashboardRecordingRenderer {
    let renderer = DashboardRecordingRenderer()
    let controller = OpenGrokPagerInteractiveController(
        input: AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        },
        runtime: DashboardTestRuntime(),
        renderer: renderer,
        output: DashboardSilentOutput()
    )
    let result = try await controller.run(
        .init(prompt: "", mode: mode, sessionID: "sess-1")
    )
    #expect(result.submittedPrompts.isEmpty)
    return renderer
}

private actor DashboardRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
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

    var globals: [OpenGrokPagerGlobalCommand] {
        events.compactMap {
            if case .global(let command) = $0 { return command }
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

private struct DashboardSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

private actor DashboardTestRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        throw CocoaError(.featureUnsupported)
    }
}
