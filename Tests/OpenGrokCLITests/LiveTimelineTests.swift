// LiveTimelineTests.swift
//
// `[ui] show_timeline` through the LIVE seam (AGENTS.md §3): the real
// `LiveInteractiveControllerRenderer` painting into a captured sink, with
// the effects asserted where they land — the config file in an isolated
// OPENGROK_HOME, the painted toast, the rail glyphs in the frame bytes, and
// the viewport jump a rail click causes. The controller half (dispatch →
// `.overlay(.toggleTimeline)`) is pinned in
// `Tests/OpenGrokPagerTests/PagerTimelineCommandTests.swift`; the exact
// rail geometry and paint are pinned against `renderPagerFrame` in
// `Tests/OpenGrokPagerRenderTests/PagerTimelineRailTests.swift`.

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class TimelineCapturingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    /// CSI/OSC-stripped text; see the stripper note in
    /// `LivePagerCommandReachabilityTests` — words survive only as single
    /// tokens because the cell differ moves the cursor between runs. Unlike
    /// the timestamps sibling this stripper collects raw bytes and decodes
    /// UTF-8 once at the end, so the rail's multi-byte chevron glyphs
    /// (▴/▾) survive as characters the containment assertions can name.
    var strippedText: String {
        lock.lock(); defer { lock.unlock() }
        var output: [UInt8] = []
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B else {
                output.append(bytes[index])
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
        return String(decoding: output, as: UTF8.self)
    }
}

private struct TimelineFixture {
    let home: URL
    let sink: TimelineCapturingSink
    let renderer: LiveInteractiveControllerRenderer

    init(
        mode: OpenGrokPagerMode = .fullScreen,
        home: URL? = nil,
        configTOML: String? = nil,
        conversationHistory: LiveConversationHistory? = nil
    ) throws {
        let resolvedHome = home ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-timeline-\(UUID().uuidString)", isDirectory: true)
        self.home = resolvedHome
        try FileManager.default.createDirectory(
            at: resolvedHome,
            withIntermediateDirectories: true
        )
        if let configTOML {
            try configTOML.write(
                to: resolvedHome.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        let environment = ["HOME": resolvedHome.path, "OPENGROK_HOME": resolvedHome.path]
        sink = TimelineCapturingSink()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
            write: { _ in }
        )
        renderer = LiveInteractiveControllerRenderer(
            mode: mode,
            terminal: terminal,
            sink: sink,
            workingDirectory: resolvedHome.path,
            modelName: "unknown",
            uiConfiguration: LiveInteractiveControllerRenderer.resolveUIConfig(
                workingDirectory: resolvedHome,
                environment: environment
            ),
            sessionID: "timeline-live",
            conversationHistory: conversationHistory,
            openGrokHome: resolvedHome,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    var configText: String {
        (try? String(
            contentsOf: home.appendingPathComponent("config.toml"),
            encoding: .utf8
        )) ?? ""
    }

    func waitForFrame(containing needle: String, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sink.strippedText.contains(needle) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return sink.strippedText.contains(needle)
    }
}

/// A two-turn persisted session whose replies are BOTH tall enough that on a
/// 30-row viewport the second turn's prompt sits in the middle of the
/// transcript: not in the first screenful, not in the last. The frames a
/// resume paints (top-of-transcript and tail) can therefore never contain
/// its "zebra" token — only a jump that anchors that prompt to the viewport
/// top can paint it, which is what makes the rail click observable in an
/// accumulate-only byte sink.
private func makeTwoTurnSession(
    home: URL,
    sessionID: String
) async throws -> LiveConversationHistory {
    let store = LiveConversationStore(openGrokHome: home)
    var record = LiveConversationRecord.new(
        sessionID: sessionID,
        workingDirectory: home
    )
    // Paragraph breaks, not bare newlines: restored assistant text renders
    // as markdown, where single newlines soft-wrap into one paragraph — 41
    // "lines" would collapse to a few rows and the whole transcript would
    // fit one screen.
    record.items = [
        .user("alpha anchor question"),
        .assistant(AssistantItem(
            content: (0..<25).map { "afill \($0)" }.joined(separator: "\n\n")
        )),
        .user("second question zebra"),
        .assistant(AssistantItem(
            content: (0..<25).map { "bfill \($0)" }.joined(separator: "\n\n")
        )),
    ]
    try await store.save(record)
    return LiveConversationHistory(record: record, store: store)
}

@Suite("Live timeline", .serialized)
struct LiveTimelineTests {
    @Test("/timeline persists into [ui] show_timeline — and the default is OFF")
    func togglePersistsToConfig() async throws {
        let fixture = try TimelineFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()

        // No config file: the hydrated value is the `false` default — the
        // rail is opt-in (`SHOW_TIMELINE_DEFAULT = false`, ui_config.rs:392)
        // — so the FIRST toggle must write `true`. Writing `true` first is
        // the whole absent-means-off startup claim in one observable
        // (contrast timestamps, whose absent-means-on wrote `false` first).
        try await fixture.renderer.render(.overlay(.toggleTimeline))
        // Toast from `set_timeline` (setters.rs:1586):
        // `save_success_toast("Timeline sidebar", new)` → "✓ Timeline
        // sidebar: on".
        #expect(await fixture.waitForFrame(containing: "Timeline"))
        #expect(fixture.configText.contains("[ui]"))
        #expect(fixture.configText.contains("show_timeline = true"))

        try await fixture.renderer.render(.overlay(.toggleTimeline))
        #expect(fixture.configText.contains("show_timeline = false"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("startup honors show_timeline = true: the first toggle turns it OFF")
    func startupReadsConfig() async throws {
        let fixture = try TimelineFixture(configTOML: """
            [ui]
            show_timeline = true
            """)
        defer { fixture.dispose() }
        try await fixture.renderer.begin()

        // If construction had not hydrated the user value, the default-false
        // live value would make this toggle write `true`. Writing `false` is
        // only reachable from a live value that started `true`.
        try await fixture.renderer.render(.overlay(.toggleTimeline))
        #expect(await fixture.waitForFrame(containing: "Timeline"))
        #expect(fixture.configText.contains("show_timeline = false"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("inline mode refuses /timeline before any flip or persist")
    func inlineModeRefuses() async throws {
        // Upstream's `ModeSupport::FullscreenOnly` errors in minimal mode
        // BEFORE the command computes a toggle (`mode_support.rs:38-51`
        // over `timeline.rs:21-25`), so no config write can happen from a
        // mode that cannot paint the rail. The refusal note lands on the
        // transcript, which the inline strip does not paint into the sink,
        // so the pin is the durable half: the config stays untouched, and a
        // fullscreen session on the SAME home still sees the pristine
        // default — its first toggle writes `true`, which is unreachable if
        // the inline attempt had flipped-and-persisted anything.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-tl-inline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let inline = try TimelineFixture(mode: .inline, home: home)
        try await inline.renderer.begin()
        try await inline.renderer.render(.overlay(.toggleTimeline))
        #expect(!inline.configText.contains("show_timeline"))
        try await inline.renderer.restoreTerminal()

        let fullscreen = try TimelineFixture(home: home)
        try await fullscreen.renderer.begin()
        try await fullscreen.renderer.render(.overlay(.toggleTimeline))
        #expect(await fullscreen.waitForFrame(containing: "Timeline"))
        #expect(fullscreen.configText.contains("show_timeline = true"))
        try await fullscreen.renderer.restoreTerminal()
    }

    @Test("a settings-modal commit flips the LIVE value, not only the file")
    func modalCommitFlipsLiveValue() async throws {
        let fixture = try TimelineFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()

        // Deep-link straight to the row — reachable only because the row is
        // no longer on the hidden list — and toggle it with Space. The row
        // default is `false` (defs.rs:680-681), so the commit writes `true`.
        try await fixture.renderer.render(.overlay(.settings(deepLinkKey: "show_timeline")))
        let routing = try await fixture.renderer.handleInput(.key(KeyEvent(
            key: .char(" "),
            character: " "
        )))
        #expect(routing == .consumed)
        #expect(fixture.configText.contains("show_timeline = true"))

        // The §3 catch: had the commit only written the file, the live value
        // would still be false and this toggle would write `true` again.
        // Writing `false` proves the modal commit reached the live state the
        // next paint reads.
        try await fixture.renderer.render(.overlay(.toggleTimeline))
        #expect(fixture.configText.contains("show_timeline = false"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("the rail paints on a resumed two-turn transcript")
    func railPaintsOnResumedTranscript() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-tl-paint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let history = try await makeTwoTurnSession(home: home, sessionID: "tl-paint")

        let fixture = try TimelineFixture(
            configTOML: "[ui]\nshow_timeline = true\n",
            conversationHistory: history
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.sessionResumed(sessionID: "tl-paint"))
        // "restored." is the resume note's tail token — a single word, which
        // is all the cell differ guarantees survives the stripper.
        #expect(await fixture.waitForFrame(containing: "restored."))
        // Both chevrons landed in the frame bytes — the rail replaced the
        // scrollbar gutter (`views/timeline.rs:1-2`).
        #expect(await fixture.waitForFrame(containing: "\u{25B4}"))
        #expect(fixture.sink.strippedText.contains("\u{25BE}"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("config off paints no rail on the same transcript")
    func configOffPaintsNoRail() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-tl-off-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let history = try await makeTwoTurnSession(home: home, sessionID: "tl-off")

        let fixture = try TimelineFixture(conversationHistory: history)
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.sessionResumed(sessionID: "tl-off"))
        #expect(await fixture.waitForFrame(containing: "restored."))
        #expect(!fixture.sink.strippedText.contains("\u{25B4}"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("clicking a rail tick jumps the viewport to that turn")
    func clickTickJumpsToTurn() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-tl-click-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let history = try await makeTwoTurnSession(home: home, sessionID: "tl-click")

        let fixture = try TimelineFixture(
            configTOML: "[ui]\nshow_timeline = true\n",
            conversationHistory: history
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.sessionResumed(sessionID: "tl-click"))
        #expect(await fixture.waitForFrame(containing: "restored."))
        // The second turn's prompt sits mid-transcript (line ~47 of ~90):
        // neither the top-of-transcript frames nor the tail frames can have
        // painted its token yet.
        #expect(!fixture.sink.strippedText.contains("zebra"))

        // The tick for turn 1, from the same geometry the frame published:
        // 100×30 chrome puts the transcript at y=2, height 22; chromeWidth 5
        // and the 2-column reserve put the rail at x=98-99; 2 ticks + 2
        // chevrons centered in 22 rows start at y=11, so turn 1's tick row
        // is y=13. (The geometry rules themselves are pinned in
        // PagerTimelineRailTests; a chrome drift fails this click loudly.)
        let routing = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down,
            x: 98,
            y: 13
        )))
        #expect(routing == .consumed)
        // The jump anchored turn 1's prompt to the viewport top — the same
        // `revealBlock` seam `/jump` scrolls through, so a tick click and a
        // picker row cannot land differently.
        #expect(await fixture.waitForFrame(containing: "zebra"))
        try await fixture.renderer.restoreTerminal()
    }
}
