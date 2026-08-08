// LiveTimestampsTests.swift
//
// `[ui] show_timestamps` through the LIVE seam (AGENTS.md §3): the real
// `LiveInteractiveControllerRenderer` painting into a captured sink, with
// the effects asserted where they land — the config file in an isolated
// OPENGROK_HOME, the painted toast, and the stamped frame bytes. Every
// asserted instant is injected: resume tests write fixed instants into the
// session's rewind sidecar and assert those exact digits in the frame, so
// no assertion here depends on the wall clock's current time. The
// controller half (dispatch → `.overlay(.toggleTimestamps)`) is pinned in
// `Tests/OpenGrokPagerTests/PagerTimestampsCommandTests.swift`; the exact
// paint geometry is pinned against `renderPagerFrame` in
// `Tests/OpenGrokPagerRenderTests/PagerTimestampsRenderTests.swift`.

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class TimestampsCapturingSink: PagerTerminalSink, @unchecked Sendable {
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
    /// tokens because the cell differ moves the cursor between runs.
    var strippedText: String {
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

/// A wall-clock instant built from local-calendar components, so the local
/// short format paints exactly these digits on any machine — the injected
/// clock every resume assertion reads through.
private func fixedInstant(hour: Int, minute: Int) -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 8
    components.day = 8
    components.hour = hour
    components.minute = minute
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    guard let date = calendar.date(from: components) else {
        Issue.record("calendar could not resolve \(hour):\(minute)")
        return Date(timeIntervalSince1970: 0)
    }
    return date
}

private struct TimestampsFixture {
    let home: URL
    let sink: TimestampsCapturingSink
    let renderer: LiveInteractiveControllerRenderer

    init(
        configTOML: String? = nil,
        conversationHistory: LiveConversationHistory? = nil
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-timestamps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let configTOML {
            try configTOML.write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        let environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
        sink = TimestampsCapturingSink()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
            write: { _ in }
        )
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: sink,
            workingDirectory: home.path,
            modelName: "unknown",
            uiConfiguration: LiveInteractiveControllerRenderer.resolveUIConfig(
                workingDirectory: home,
                environment: environment
            ),
            sessionID: "timestamps-live",
            conversationHistory: conversationHistory,
            openGrokHome: home,
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

/// A two-turn persisted session — the durable transcript `/resume` projects
/// from. The per-turn instants live in the rewind sidecar, which each test
/// writes into ITS OWN fixture home (where the resume path reads it),
/// through the same `LiveRewindStore` the live turn loop appends through, so
/// the file is byte-for-byte what a real session leaves behind.
private func makeResumableSession(
    home: URL,
    sessionID: String
) async throws -> LiveConversationHistory {
    let store = LiveConversationStore(openGrokHome: home)
    var record = LiveConversationRecord.new(
        sessionID: sessionID,
        workingDirectory: home
    )
    record.items = [
        .user("first question"),
        .assistant(AssistantItem(content: "First answer.")),
        .user("second question"),
        .assistant(AssistantItem(content: "Second answer.")),
    ]
    try await store.save(record)
    return LiveConversationHistory(record: record, store: store)
}

@Suite("Live timestamps", .serialized)
struct LiveTimestampsTests {
    @Test("/timestamps persists into [ui] show_timestamps — and the default is ON")
    func togglePersistsToConfig() async throws {
        let fixture = try TimestampsFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()

        // No config file: the hydrated value is the `true` default
        // (`TIMESTAMPS_DEFAULT`, appearance/cache.rs:28), so the FIRST toggle
        // must write `false`. Writing `false` first is the whole
        // absent-means-on startup claim in one observable.
        try await fixture.renderer.render(.overlay(.toggleTimestamps))
        // Toast from `set_timestamps` (setters.rs:1551):
        // `save_success_toast("Timestamps", new)` → "✓ Timestamps: off".
        #expect(await fixture.waitForFrame(containing: "Timestamps"))
        #expect(fixture.configText.contains("[ui]"))
        #expect(fixture.configText.contains("show_timestamps = false"))

        try await fixture.renderer.render(.overlay(.toggleTimestamps))
        #expect(fixture.configText.contains("show_timestamps = true"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("startup honors show_timestamps = false: the first toggle turns it ON")
    func startupReadsConfig() async throws {
        let fixture = try TimestampsFixture(configTOML: """
            [ui]
            show_timestamps = false
            """)
        defer { fixture.dispose() }
        try await fixture.renderer.begin()

        // If construction had not hydrated the user value, the default-true
        // live value would make this toggle write `false`. Writing `true` is
        // only reachable from a live value that started `false`.
        try await fixture.renderer.render(.overlay(.toggleTimestamps))
        #expect(await fixture.waitForFrame(containing: "Timestamps"))
        #expect(fixture.configText.contains("show_timestamps = true"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a resumed transcript shows the persisted instants, not load time")
    func resumeShowsPersistedInstants() async throws {
        // Two DISTINCT fixed instants: a bug that re-stamped restored blocks
        // with `Date()` would paint one identical now-time on both prompts —
        // it cannot reproduce two different persisted wall times.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-ts-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let history = try await makeResumableSession(home: home, sessionID: "ts-resume")

        let fixture = try TimestampsFixture(conversationHistory: history)
        defer { fixture.dispose() }
        // The rewind sidecar must live where the resume path looks for it —
        // the renderer's own home, keyed by the resumed session ID.
        let sidecar = LiveRewindStore(openGrokHome: fixture.home, sessionID: "ts-resume")
        await sidecar.append(LiveRewindPoint(
            promptIndex: 0,
            createdAt: fixedInstant(hour: 15, minute: 7),
            promptText: "first question"
        ))
        await sidecar.append(LiveRewindPoint(
            promptIndex: 1,
            createdAt: fixedInstant(hour: 9, minute: 41),
            promptText: "second question"
        ))

        try await fixture.renderer.begin()
        try await fixture.renderer.render(.sessionResumed(sessionID: "ts-resume"))
        #expect(await fixture.waitForFrame(containing: "3:07"))
        #expect(fixture.sink.strippedText.contains("9:41"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("show_timestamps = false suppresses the stamps on the same resumed transcript")
    func configOffPaintsNoStamps() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-ts-off-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let history = try await makeResumableSession(home: home, sessionID: "ts-off")

        let fixture = try TimestampsFixture(
            configTOML: "[ui]\nshow_timestamps = false\n",
            conversationHistory: history
        )
        defer { fixture.dispose() }
        let sidecar = LiveRewindStore(openGrokHome: fixture.home, sessionID: "ts-off")
        await sidecar.append(LiveRewindPoint(
            promptIndex: 0,
            createdAt: fixedInstant(hour: 15, minute: 7),
            promptText: "first question"
        ))

        try await fixture.renderer.begin()
        try await fixture.renderer.render(.sessionResumed(sessionID: "ts-off"))
        #expect(await fixture.waitForFrame(containing: "First answer."))
        #expect(!fixture.sink.strippedText.contains("3:07"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a live-appended user block is stamped at push")
    func liveAppendStampsAtPush() async throws {
        // The stamp text is the current wall time (upstream's
        // `created_at: Some(Local::now())` at push, entry.rs:198), so the
        // assertion is presence-shaped: the short format always ends in
        // AM or PM, and neither token exists anywhere in the frame before
        // the block lands. No specific wall time is asserted.
        let fixture = try TimestampsFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        let before = fixture.sink.strippedText
        #expect(!before.contains("AM") && !before.contains("PM"))

        try await fixture.renderer.render(.interjected(text: "stamped side prompt"))
        #expect(await fixture.waitForFrame(containing: "stamped"))
        let after = fixture.sink.strippedText
        #expect(after.contains("AM") || after.contains("PM"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a settings-modal commit flips the LIVE value, not only the file")
    func modalCommitFlipsLiveValue() async throws {
        let fixture = try TimestampsFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()

        // Deep-link straight to the row — reachable only because the row is
        // no longer on the hidden list — and toggle it with Space. The row
        // default is `true` (defs.rs:666-667), so the commit writes `false`.
        try await fixture.renderer.render(.overlay(.settings(deepLinkKey: "show_timestamps")))
        let routing = try await fixture.renderer.handleInput(.key(KeyEvent(
            key: .char(" "),
            character: " "
        )))
        #expect(routing == .consumed)
        #expect(fixture.configText.contains("show_timestamps = false"))

        // The §3 catch: had the commit only written the file, the live value
        // would still be true and this toggle would write `false` again.
        // Writing `true` proves the modal commit reached the live state the
        // next paint reads.
        try await fixture.renderer.render(.overlay(.toggleTimestamps))
        #expect(fixture.configText.contains("show_timestamps = true"))
        try await fixture.renderer.restoreTerminal()
    }
}
