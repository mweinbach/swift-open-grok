// LiveMouseReportingToggleTests.swift
//
// Live seam for the opt-in mouse-reporting toggle gate: startup resolve from
// effective UiConfig/env (no process-cwd footgun), slash toggle bytes/state
// when on, and catalog omission when off.

import Foundation
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class MouseToggleCapturingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    var raw: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

@Suite("Live mouse-reporting toggle gate")
struct LiveMouseReportingToggleTests {
    @Test("resolveUIConfig defaults the gate off")
    func resolveDefaultsOff() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-mouse-gate-default-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let resolved = LiveInteractiveControllerRenderer.resolveUIConfig(
            workingDirectory: home,
            environment: ["HOME": home.path, "OPENGROK_HOME": home.path]
        )
        #expect(resolved.mouseReportingToggleEnabled == false)
    }

    @Test("parsed UiConfig field is the fallback when effective TOML omits the key")
    func uiStructFallback() {
        // Rust `resolve_mouse_reporting_toggle_falls_back_to_ui_struct`
        // (util/config/resolve/ui.rs:162-170).
        var ui = UiConfig()
        ui.mouseReportingToggle = true
        let resolved = resolveMouseReportingToggle(
            document: nil,
            ui: ui,
            environment: [:]
        )
        #expect(resolved == Resolved(value: true, source: .config))
    }

    @Test("GROK_MOUSE_REPORTING_TOGGLE wins over [ui] config in resolveUIConfig")
    func resolveEnvWins() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-mouse-gate-env-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try """
        [ui]
        mouse_reporting_toggle = false
        """.write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let resolved = LiveInteractiveControllerRenderer.resolveUIConfig(
            workingDirectory: home,
            environment: [
                "HOME": home.path,
                "OPENGROK_HOME": home.path,
                "GROK_MOUSE_REPORTING_TOGGLE": "true"
            ]
        )
        #expect(resolved.mouseReportingToggleEnabled == true)
    }

    @Test("[ui].mouse_reporting_toggle seeds the live renderer gate")
    func configSeedsRendererGate() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-mouse-gate-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try """
        [ui]
        mouse_reporting_toggle = true
        """.write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
        let uiConfiguration = LiveInteractiveControllerRenderer.resolveUIConfig(
            workingDirectory: home,
            environment: environment
        )
        #expect(uiConfiguration.mouseReportingToggleEnabled == true)
        let sink = MouseToggleCapturingSink()
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: home.path,
            modelName: "alpha-model",
            uiConfiguration: uiConfiguration,
            sessionID: "mouse-toggle-config",
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment
        )
        #expect(await renderer.testingMouseReportingToggleEnabled() == true)
    }

    @Test("slash toggle when gate on writes disable/enable mouse sequences")
    func slashTogglesWireBytesWhenOn() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-mouse-toggle-bytes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "GROK_MOUSE_REPORTING_TOGGLE": "1"
        ]
        let uiConfiguration = LiveInteractiveControllerRenderer.resolveUIConfig(
            workingDirectory: home,
            environment: environment
        )
        #expect(uiConfiguration.mouseReportingToggleEnabled == true)
        let sink = MouseToggleCapturingSink()
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: home.path,
            modelName: "alpha-model",
            uiConfiguration: uiConfiguration,
            sessionID: "mouse-toggle-bytes",
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment
        )

        try await renderer.begin()
        try await renderer.testingDismissWelcomeOverlay()
        #expect(await renderer.testingIsMouseReportingEnabled() == true)

        try await renderer.render(.overlay(.toggleMouseReporting))
        let reportingOff = await renderer.testingIsMouseReportingEnabled()
        #expect(reportingOff == false)
        #expect(sink.raw.contains("\u{1B}[?1006l"))
        let stickyOff = await renderer.testingStickyToast()
        #expect(stickyOff == LiveInteractiveControllerRenderer.mouseOffHintScrollback)
        try await renderer.testingForcePaint()
        let paintedOff = await renderer.testingLastPaintedToast()
        #expect(paintedOff == LiveInteractiveControllerRenderer.mouseOffHintPrompt)
        let messages = await renderer.testingSystemMessageTexts()
        #expect(!messages.contains { text in
            text.contains("Mouse reporting off") || text.contains("Mouse reporting on")
        })

        try await renderer.render(.overlay(.toggleMouseReporting))
        let reportingOn = await renderer.testingIsMouseReportingEnabled()
        #expect(reportingOn == true)
        #expect(sink.raw.contains("\u{1B}[?1006h"))
        let stickyOn = await renderer.testingStickyToast()
        #expect(stickyOn == nil)
        try await renderer.testingForcePaint()
        let paintedOn = await renderer.testingLastPaintedToast()
        #expect(paintedOn == LiveInteractiveControllerRenderer.mouseReportingOnToast)
    }

    @Test("help / palette omit /toggle-mouse-reporting when gate is off")
    func helpOmitsWhenOff() {
        let rows = LivePagerOverlayText.commandRows(mouseReportingToggleEnabled: false)
        #expect(!rows.contains { $0.id.contains("toggle-mouse-reporting") })
        let onRows = LivePagerOverlayText.commandRows(mouseReportingToggleEnabled: true)
        #expect(onRows.contains { $0.id.contains("toggle-mouse-reporting") })
    }

    @Test("failed terminal write leaves mouse state unchanged; next toggle aims correctly")
    func failedWriteDoesNotDesyncState() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opengrok-mouse-toggle-fail-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "GROK_MOUSE_REPORTING_TOGGLE": "1"
        ]
        let uiConfiguration = LiveInteractiveControllerRenderer.resolveUIConfig(
            workingDirectory: home,
            environment: environment
        )
        let sink = MouseToggleFailingSink()
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: home.path,
            modelName: "alpha-model",
            uiConfiguration: uiConfiguration,
            sessionID: "mouse-toggle-fail",
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment
        )

        try await renderer.begin()
        try await renderer.testingDismissWelcomeOverlay()
        #expect(await renderer.testingIsMouseReportingEnabled() == true)
        // Startup enable already landed; clear so later assertions name only
        // mid-session toggle bytes.
        sink.clear()
        sink.failNextDisable = true

        var threw = false
        do {
            try await renderer.render(.overlay(.toggleMouseReporting))
        } catch is MouseToggleWriteFailure {
            threw = true
        }
        #expect(threw)
        // In-memory flag stays on — no false "off" note, next toggle still
        // aims at disable, and restore still treats reporting as active.
        let stillEnabled = await renderer.testingIsMouseReportingEnabled()
        #expect(stillEnabled == true)
        #expect(sink.raw.isEmpty)
        let sticky = await renderer.testingStickyToast()
        #expect(sticky == nil)
        let painted = await renderer.testingLastPaintedToast()
        #expect(painted == nil)
        let messages = await renderer.testingSystemMessageTexts()
        #expect(!messages.contains { text in
            text.contains("Mouse reporting off") || text.contains("Mouse reporting on")
        })

        // Successful toggle still disables (correct direction), not a no-op
        // or an enable against a falsely-flipped latch.
        try await renderer.render(.overlay(.toggleMouseReporting))
        #expect(await renderer.testingIsMouseReportingEnabled() == false)
        #expect(sink.raw.contains("\u{1B}[?1006l"))
        #expect(!sink.raw.contains("\u{1B}[?1006h"))

        try await renderer.render(.overlay(.toggleMouseReporting))
        #expect(await renderer.testingIsMouseReportingEnabled() == true)
        #expect(sink.raw.contains("\u{1B}[?1006h"))

        // Restore still emits the tracking reset while reporting is on.
        try await renderer.restoreTerminal()
        #expect(sink.raw.contains("\u{1B}[?1006l"))
    }

    @Test("minimal mode refuses mouse toggle without flipping capture or sticky")
    func minimalModeRefusesMouseToggle() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opengrok-mouse-toggle-minimal-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "GROK_MOUSE_REPORTING_TOGGLE": "1"
        ]
        let sink = MouseToggleCapturingSink()
        let renderer = LiveInteractiveControllerRenderer(
            mode: .minimal,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: home.path,
            modelName: "alpha-model",
            sessionID: "mouse-toggle-minimal",
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment
        )
        try await renderer.begin()
        let before = await renderer.testingIsMouseReportingEnabled()
        try await renderer.render(.overlay(.toggleMouseReporting))
        #expect(await renderer.testingIsMouseReportingEnabled() == before)
        #expect(await renderer.testingStickyToast() == nil)
        let notes = await renderer.testingSystemMessageTexts()
        #expect(notes.contains { $0.contains("Mouse capture stays off in minimal mode") })
        #expect(sink.raw.contains("Mouse capture stays off in minimal mode"))
    }
}

/// Fails the first mid-session mouse-disable write, then records everything.
private final class MouseToggleFailingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    var failNextDisable = false

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        let text = String(decoding: newBytes, as: UTF8.self)
        if failNextDisable, text.contains("\u{1B}[?1006l") {
            failNextDisable = false
            throw MouseToggleWriteFailure()
        }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    func clear() {
        lock.lock(); defer { lock.unlock() }
        bytes.removeAll(keepingCapacity: false)
    }

    var raw: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private struct MouseToggleWriteFailure: Error {}
