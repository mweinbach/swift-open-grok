// LiveCompactModeTests.swift
//
// `[ui] compact_mode` through the LIVE seam (AGENTS.md §3): the real
// `LiveInteractiveControllerRenderer` painting into a captured sink, with the
// effects asserted where they land — the config file in an isolated
// OPENGROK_HOME, the painted toast, and the frame bytes. The controller half
// (dispatch → `.overlay(.toggleCompactMode)`) is pinned in
// `Tests/OpenGrokPagerTests/PagerCompactModeCommandTests.swift`; the exact
// layout deltas are pinned against `renderPagerFrame` in
// `Tests/OpenGrokPagerRenderTests/PagerCompactModeRenderTests.swift`.

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class CompactCapturingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    var rawBytes: [UInt8] {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }

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

private struct CompactModeFixture {
    let home: URL
    let sink: CompactCapturingSink
    let renderer: LiveInteractiveControllerRenderer

    init(
        configTOML: String? = nil,
        terminalHeight: Int = 30,
        conversationHistory: LiveConversationHistory? = nil
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-compact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let configTOML {
            try configTOML.write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        let environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
        sink = CompactCapturingSink()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 100, height: terminalHeight) },
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
            sessionID: "compact-live",
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

private func makeCompactSessionRecord(
    home: URL,
    sessionID: String,
    prompt: String,
    reply: String
) -> LiveConversationRecord {
    var record = LiveConversationRecord.new(sessionID: sessionID, workingDirectory: home)
    record.items = [
        .user(prompt),
        .assistant(AssistantItem(content: reply)),
    ]
    return record
}

@Suite("Live compact mode", .serialized)
struct LiveCompactModeTests {
    @Test("/compact-mode persists into [ui] compact_mode in the isolated home")
    func togglePersistsToConfig() async throws {
        let fixture = try CompactModeFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()

        try await fixture.renderer.render(.overlay(.toggleCompactMode))
        // The toast lands in the transcript ("✓ Compact mode: on",
        // `set_compact_mode`, setters.rs:1520-1521 via `save_success_toast`,
        // ui.rs:89-92) and the write lands in the file the next launch reads.
        #expect(await fixture.waitForFrame(containing: "Compact"))
        #expect(fixture.configText.contains("[ui]"))
        #expect(fixture.configText.contains("compact_mode = true"))

        try await fixture.renderer.render(.overlay(.toggleCompactMode))
        #expect(fixture.configText.contains("compact_mode = false"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("startup honors compact_mode = true: the first toggle turns it OFF")
    func startupReadsConfig() async throws {
        let fixture = try CompactModeFixture(configTOML: """
            [ui]
            compact_mode = true
            """)
        defer { fixture.dispose() }
        try await fixture.renderer.begin()

        // If construction had not hydrated the user value, this toggle would
        // write `true`. Writing `false` is only reachable from a live value
        // that started `true` — the whole startup claim in one observable.
        try await fixture.renderer.render(.overlay(.toggleCompactMode))
        #expect(await fixture.waitForFrame(containing: "Compact"))
        #expect(fixture.configText.contains("compact_mode = false"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a compact-config startup paints a different frame than the default")
    func startupCompactPaintsDenserFrame() async throws {
        // Same transcript, same size, same theme — only `[ui] compact_mode`
        // differs, so any byte difference is the compact layout (the pattern
        // `startupHydratesThemeAndInputModes` established for the palette).
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-compact-frame-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = LiveConversationStore(openGrokHome: home)
        let record = makeCompactSessionRecord(
            home: home,
            sessionID: "compact-paint",
            prompt: "measure the gaps",
            reply: "Measured."
        )
        try await store.save(record)

        let compactFixture = try CompactModeFixture(
            configTOML: "[ui]\ncompact_mode = true\n",
            conversationHistory: LiveConversationHistory(record: record, store: store)
        )
        defer { compactFixture.dispose() }
        let defaultFixture = try CompactModeFixture(
            conversationHistory: LiveConversationHistory(record: record, store: store)
        )
        defer { defaultFixture.dispose() }

        try await compactFixture.renderer.begin()
        try await defaultFixture.renderer.begin()
        try await compactFixture.renderer.render(.sessionResumed(sessionID: "compact-paint"))
        try await defaultFixture.renderer.render(.sessionResumed(sessionID: "compact-paint"))
        #expect(await compactFixture.waitForFrame(containing: "Measured."))
        #expect(await defaultFixture.waitForFrame(containing: "Measured."))
        #expect(compactFixture.sink.rawBytes != defaultFixture.sink.rawBytes)
        try await compactFixture.renderer.restoreTerminal()
        try await defaultFixture.renderer.restoreTerminal()
    }

    @Test("turning compact off on a short terminal says auto-compact still holds")
    func autoCompactToastOnShortTerminal() async throws {
        // 18 rows ≤ AUTO_COMPACT_MAX_ROWS (20): the derivation keeps the UI
        // compact after the user turns the setting off, and the toast must say
        // so instead of implying the layout will loosen
        // (`set_compact_mode`, setters.rs:1516-1519). This is also the pin on
        // the live actor actually consulting `pagerEffectiveCompact` with the
        // real terminal rows.
        let fixture = try CompactModeFixture(
            configTOML: "[ui]\ncompact_mode = true\n",
            terminalHeight: 18
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()

        try await fixture.renderer.render(.overlay(.toggleCompactMode))
        #expect(await fixture.waitForFrame(containing: "auto-compact"))
        #expect(fixture.configText.contains("compact_mode = false"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a settings-modal commit flips the LIVE value, not only the file")
    func modalCommitFlipsLiveValue() async throws {
        let fixture = try CompactModeFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()

        // Deep-link straight to the row — reachable only because the row is
        // no longer on the hidden list — and toggle it with Space.
        try await fixture.renderer.render(.overlay(.settings(deepLinkKey: "compact_mode")))
        let routing = try await fixture.renderer.handleInput(.key(KeyEvent(
            key: .char(" "),
            character: " "
        )))
        #expect(routing == .consumed)
        #expect(fixture.configText.contains("compact_mode = true"))

        // The §3 catch: had the commit only written the file, the live value
        // would still be false and this toggle would write `true` again.
        // Writing `false` proves the modal commit reached the live state the
        // next paint reads.
        try await fixture.renderer.render(.overlay(.toggleCompactMode))
        #expect(fixture.configText.contains("compact_mode = false"))
        try await fixture.renderer.restoreTerminal()
    }
}
