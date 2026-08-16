// LiveFpsHudTests.swift
//
// Live-seam FPS HUD (`GROK_FPS` / `/debug fps`) against pin 650c1db7.
// Overlay presence, env truthiness, ignored `[animation].show_fps`, and
// samples only after an enabled paint (not coalesced requests).

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class FpsHudCapturingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    var text: String {
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

private struct FpsHudFixture {
    let home: URL
    let sink: FpsHudCapturingSink
    let renderer: LiveInteractiveControllerRenderer

    init(
        grokFPS: String? = nil,
        pagerTOML: String? = nil,
        paintCadence: TimeInterval = PagerMotion.minimumPaintCadence,
        mode: OpenGrokPagerMode = .fullScreen
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-fps-hud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let pagerTOML {
            try pagerTOML.write(
                to: home.appendingPathComponent("pager.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        var environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
        if let grokFPS {
            environment[pagerFpsHudEnvironmentVariable] = grokFPS
        }
        sink = FpsHudCapturingSink()
        renderer = LiveInteractiveControllerRenderer(
            mode: mode,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: home.path,
            modelName: "alpha-model",
            sessionID: "fps-hud",
            openGrokHome: home,
            paintCadence: paintCadence,
            environment: environment
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: home)
    }
}

@Suite("Live FPS HUD")
struct LiveFpsHudTests {
    @Test("GROK_FPS raw truthiness enables the overlay")
    func envTruthinessPaintsOverlay() async throws {
        for truthy in ["1", "full", " "] {
            let fixture = try FpsHudFixture(grokFPS: truthy)
            defer { fixture.cleanup() }
            try await fixture.renderer.begin()
            try await fixture.renderer.testingDismissWelcomeOverlay()
            let enabled = await fixture.renderer.testingFpsHudEnabled()
            #expect(enabled)
            let overlay = await fixture.renderer.testingLastPaintedFpsHud()
            #expect(overlay != nil, "GROK_FPS=\(truthy) must paint the HUD")
            #expect(overlay?.body.hasPrefix("fps:") == true)
            #expect(fixture.sink.text.contains(pagerFpsHudTitle))
            let records = await fixture.renderer.testingFpsHudRecordCount()
            #expect(records >= 1)
        }
        for falsy: String? in [nil, "", "0"] {
            let fixture = try FpsHudFixture(grokFPS: falsy)
            defer { fixture.cleanup() }
            try await fixture.renderer.begin()
            try await fixture.renderer.testingDismissWelcomeOverlay()
            let enabled = await fixture.renderer.testingFpsHudEnabled()
            #expect(enabled == false)
            let overlay = await fixture.renderer.testingLastPaintedFpsHud()
            #expect(overlay == nil)
            #expect(!fixture.sink.text.contains(pagerFpsHudTitle))
            let records = await fixture.renderer.testingFpsHudRecordCount()
            #expect(records == 0)
        }
    }

    @Test("[animation].show_fps in pager.toml does not enable the HUD")
    func showFpsTomlDoesNotEnable() async throws {
        let fixture = try FpsHudFixture(
            grokFPS: nil,
            pagerTOML: """
            [animation]
            show_fps = true
            fps = 12
            """
        )
        defer { fixture.cleanup() }
        try await fixture.renderer.begin()
        try await fixture.renderer.testingDismissWelcomeOverlay()
        let enabled = await fixture.renderer.testingFpsHudEnabled()
        #expect(enabled == false)
        let overlay = await fixture.renderer.testingLastPaintedFpsHud()
        #expect(overlay == nil)
        #expect(!fixture.sink.text.contains(pagerFpsHudTitle))
        let animationFPS = await fixture.renderer.animationFPS
        #expect(animationFPS == 12)
    }

    @Test("first committed GROK_FPS frame paints the placeholder")
    func firstCommittedEnvFramePaintsPlaceholder() async throws {
        let fixture = try FpsHudFixture(grokFPS: "1")
        defer { fixture.cleanup() }
        try await fixture.renderer.begin()
        #expect(await fixture.renderer.testingFpsHudEnabled())
        let overlay = await fixture.renderer.testingLastPaintedFpsHud()
        #expect(overlay != nil)
        #expect(overlay?.body == pagerFpsHudEmptyBody)
        #expect(fixture.sink.text.contains(pagerFpsHudTitle))
        #expect(await fixture.renderer.testingFpsHudRecordCount() == 1)
    }

    @Test("/debug fps toggles overlay presence and clears on disable")
    func debugFpsTogglesOverlay() async throws {
        let fixture = try FpsHudFixture(grokFPS: nil)
        defer { fixture.cleanup() }
        try await fixture.renderer.begin()
        try await fixture.renderer.testingDismissWelcomeOverlay()
        let beforeHud = await fixture.renderer.testingLastPaintedFpsHud()
        #expect(beforeHud == nil)
        let recordsBefore = await fixture.renderer.testingFpsHudRecordCount()
        #expect(recordsBefore == 0)

        try await fixture.renderer.render(.overlay(.debug(argument: "fps")))
        let enabled = await fixture.renderer.testingFpsHudEnabled()
        #expect(enabled)
        let painted = await fixture.renderer.testingLastPaintedFpsHud()
        #expect(painted != nil)
        #expect(painted?.body == pagerFpsHudEmptyBody)
        #expect(fixture.sink.text.contains(pagerFpsHudTitle))
        #expect(fixture.sink.text.contains(pagerFpsHudEmptyBody))
        let recordsEnabled = await fixture.renderer.testingFpsHudRecordCount()
        #expect(recordsEnabled == 1)
        let toast = await fixture.renderer.testingLastPaintedToast()
        #expect(toast == nil)
        let notes = await fixture.renderer.testingSystemMessageTexts()
        #expect(notes.isEmpty)

        try await fixture.renderer.render(.overlay(.debug(argument: "fps")))
        let disabled = await fixture.renderer.testingFpsHudEnabled()
        #expect(disabled == false)
        let cleared = await fixture.renderer.testingLastPaintedFpsHud()
        #expect(cleared == nil)
        // Disable does not record; count stays at the enabled-frame total.
        let recordsDisabled = await fixture.renderer.testingFpsHudRecordCount()
        #expect(recordsDisabled == 1)
    }

    @Test("bare /debug reports every toggle; unknown args list the full grammar")
    func debugBareAndUnknown() async throws {
        let fixture = try FpsHudFixture(grokFPS: "1")
        defer { fixture.cleanup() }
        try await fixture.renderer.begin()
        try await fixture.renderer.testingDismissWelcomeOverlay()

        try await fixture.renderer.render(.overlay(.debug(argument: "")))
        let status = await fixture.renderer.testingSystemMessageTexts()
        #expect(status.contains { $0.contains("fps on") })
        #expect(status.contains {
            $0.contains("scroll off")
                && $0.contains("log off")
                && $0.contains("/debug <scroll|fps|log>")
        })

        try await fixture.renderer.render(.overlay(.debug(argument: "wat")))
        let errors = await fixture.renderer.testingErrorMessageTexts()
        #expect(errors.contains {
            $0.contains("wat") && $0.contains("/debug [scroll|fps|log]")
        })
    }

    @Test("samples record only after an enabled paint, not coalesced requests")
    func samplesOnlyAfterEnabledPaint() async throws {
        // Cadence is clamped to `maximumPaintCadence` (0.1s); a 10s value
        // would silently shrink and make flush timing look like a hang.
        let fixture = try FpsHudFixture(
            grokFPS: nil,
            paintCadence: PagerMotion.maximumPaintCadence
        )
        defer { fixture.cleanup() }
        await fixture.renderer.testingSetMonotonicNow(1_000)
        try await fixture.renderer.begin()
        try await fixture.renderer.testingDismissWelcomeOverlay()
        let recordsBefore = await fixture.renderer.testingFpsHudRecordCount()
        #expect(recordsBefore == 0)

        try await fixture.renderer.render(.overlay(.debug(argument: "fps")))
        let recordsEnabled = await fixture.renderer.testingFpsHudRecordCount()
        #expect(recordsEnabled == 1)
        let firstBody = await fixture.renderer.testingLastPaintedFpsHud()?.body
        #expect(firstBody == pagerFpsHudEmptyBody)

        // Folded request must not record a second sample.
        try await fixture.renderer.testingAppendConversationItem(
            .message(PagerMessage(role: .system, text: "coalesce-probe"))
        )
        let scheduled = await fixture.renderer.testingHasScheduledFrame()
        #expect(scheduled)
        let recordsCoalesced = await fixture.renderer.testingFpsHudRecordCount()
        #expect(recordsCoalesced == 1)

        let due = await fixture.renderer.testingScheduledFrameAt()
        let flushAt = try #require(due) + 0.001
        let flushed = await fixture.renderer.testingFlushPendingFrame(at: flushAt)
        let recordsFlushed = await fixture.renderer.testingFpsHudRecordCount()
        #expect(recordsFlushed == 2, "flush painted=\(flushed)")
        // The recording frame snapshots currentOverlay *before* record+refresh,
        // so this paint still shows the placeholder. Cached stats become
        // visible on the next committed paint (one-frame lag).
        await fixture.renderer.testingSetMonotonicNow(
            1_000 + pagerFpsHudRefreshInterval
        )
        try await fixture.renderer.testingForcePaint()
        let sampled = await fixture.renderer.testingLastPaintedFpsHud()?.body
        #expect(sampled != nil)
        #expect(sampled != pagerFpsHudEmptyBody)
        #expect(sampled?.hasPrefix("fps:") == true)
        // Cell diffs may emit only changed glyphs — do not require the
        // full stats line in the cumulative stripped sink.
        #expect(fixture.sink.text.contains(pagerFpsHudTitle))
        #expect(fixture.sink.text.contains("fps:"))
    }

    @Test("action-time page layout does not record or consume overlay refresh")
    func pageScrollLayoutDoesNotRecordOrRefresh() async throws {
        let fixture = try FpsHudFixture(grokFPS: "1")
        defer { fixture.cleanup() }
        try await fixture.renderer.begin()
        try await fixture.renderer.testingDismissWelcomeOverlay()
        let records = await fixture.renderer.testingFpsHudRecordCount()
        #expect(records >= 1)
        let painted = await fixture.renderer.testingLastPaintedFpsHud()?.body
        #expect(painted != nil)
        #expect(painted?.hasPrefix("fps:") == true)

        _ = await fixture.renderer.testingCurrentPageScrollRows()
        let recordsAfter = await fixture.renderer.testingFpsHudRecordCount()
        #expect(recordsAfter == records)
        let stillPainted = await fixture.renderer.testingLastPaintedFpsHud()?.body
        #expect(stillPainted == painted)
    }

    @Test("minimal mode toggles FPS state without overlay snapshot or record")
    func minimalModeDoesNotClaimFpsPaint() async throws {
        let fixture = try FpsHudFixture(grokFPS: nil, mode: .minimal)
        defer { fixture.cleanup() }
        try await fixture.renderer.begin()
        let before = await fixture.renderer.testingFpsHudEnabled()
        #expect(before == false)
        #expect(await fixture.renderer.testingLastPaintedFpsHud() == nil)
        #expect(await fixture.renderer.testingFpsHudRecordCount() == 0)
        #expect(!fixture.sink.text.contains(pagerFpsHudTitle))

        try await fixture.renderer.render(.overlay(.debug(argument: "fps")))
        #expect(await fixture.renderer.testingFpsHudEnabled())
        #expect(await fixture.renderer.testingLastPaintedFpsHud() == nil)
        #expect(await fixture.renderer.testingFpsHudRecordCount() == 0)
        #expect(!fixture.sink.text.contains(pagerFpsHudTitle))
        #expect(!fixture.sink.text.contains(pagerFpsHudEmptyBody))
    }

    @Test("stale flush task cannot nil a newer timer")
    func staleFlushDoesNotNilNewerTimer() async throws {
        let fixture = try FpsHudFixture(
            grokFPS: nil,
            paintCadence: PagerMotion.maximumPaintCadence
        )
        defer { fixture.cleanup() }
        try await fixture.renderer.begin()
        try await fixture.renderer.testingDismissWelcomeOverlay()

        try await fixture.renderer.testingAppendConversationItem(
            .message(PagerMessage(role: .system, text: "arm-flush-1"))
        )
        #expect(await fixture.renderer.testingHasPendingFlushTask())
        let gen1 = await fixture.renderer.testingPendingFlushGeneration()

        try await fixture.renderer.testingForcePaint()
        #expect(await fixture.renderer.testingHasPendingFlushTask() == false)

        try await fixture.renderer.testingAppendConversationItem(
            .message(PagerMessage(role: .system, text: "arm-flush-2"))
        )
        #expect(await fixture.renderer.testingHasPendingFlushTask())
        let gen2 = await fixture.renderer.testingPendingFlushGeneration()
        #expect(gen2 != gen1)

        await fixture.renderer.testingCompleteFlushTask(generation: gen1)
        #expect(await fixture.renderer.testingHasPendingFlushTask())
        #expect(await fixture.renderer.testingPendingFlushGeneration() == gen2)
    }

    @Test("/debug is always registered; listed only on DEBUG binaries")
    func debugCommandVisibility() {
        #expect(
            OpenGrokPagerInteractiveController.builtinCommandCatalog
                .contains { $0.name == "debug" }
        )
        let visible = OpenGrokPagerInteractiveController.visibleBuiltinCommandCatalog()
        if OpenGrokPagerInteractiveController.debugCommandListedInCompletions {
            #expect(visible.contains { $0.name == "debug" })
        } else {
            #expect(!visible.contains { $0.name == "debug" })
        }
    }
}
