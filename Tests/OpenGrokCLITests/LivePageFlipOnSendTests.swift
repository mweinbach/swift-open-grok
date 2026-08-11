// LivePageFlipOnSendTests.swift
//
// `[ui] page_flip_on_send` through the LIVE seam (AGENTS.md §3): the real
// `LiveInteractiveControllerRenderer` painting into a captured sink, with
// the scroll effect asserted where it lands — the viewport bytes after a
// second send on a tall resumed transcript. Upstream pins the same behavior
// in `pty_e2e/page_flip_on_send_pty.rs`.

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private let tailSentinel = "TAILSENTINEL_T1"
private let secondPromptMarker = "second-prompt-marker"

private final class PageFlipCapturingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    var strippedText: String {
        lock.lock(); defer { lock.unlock() }
        return strip(bytes)
    }

    func strippedText(from offset: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        guard offset < bytes.count else { return strip(bytes) }
        return strip(Array(bytes[offset...]))
    }

    var byteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return bytes.count
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        bytes.removeAll(keepingCapacity: true)
    }

    private func strip(_ bytes: [UInt8]) -> String {
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

private struct PageFlipFixture {
    let home: URL
    let sink: PageFlipCapturingSink
    let renderer: LiveInteractiveControllerRenderer

    init(
        configTOML: String? = nil,
        conversationHistory: LiveConversationHistory? = nil
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-page-flip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let configTOML {
            try configTOML.write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        let environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
        sink = PageFlipCapturingSink()
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
            sessionID: "page-flip-live",
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

/// One tall turn whose tail sits on screen after resume (follow-bottom) but
/// scrolls off when page-flip pins the next prompt at the viewport top.
private func makeTallFirstTurnSession(
    home: URL,
    sessionID: String
) async throws -> LiveConversationHistory {
    let store = LiveConversationStore(openGrokHome: home)
    var record = LiveConversationRecord.new(
        sessionID: sessionID,
        workingDirectory: home
    )
    var tallReply = "```\n"
    for index in 0..<80 {
        tallReply += "line \(index) payload\n"
    }
    tallReply += tailSentinel
    tallReply += "\n```\n"
    record.items = [
        .user("first prompt anchor"),
        .assistant(AssistantItem(content: tallReply)),
    ]
    try await store.save(record)
    return LiveConversationHistory(record: record, store: store)
}

@Suite("Live page flip on send", .serialized)
struct LivePageFlipOnSendTests {
    @Test("default send page-flips the new prompt to the viewport top")
    func sendPageFlipsByDefault() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-pf-on-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let history = try await makeTallFirstTurnSession(home: home, sessionID: "pf-on")

        let fixture = try PageFlipFixture(conversationHistory: history)
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.sessionResumed(sessionID: "pf-on"))
        #expect(await fixture.waitForFrame(containing: tailSentinel))
        fixture.sink.clear()

        try await fixture.renderer.render(.turnStarted(OpenGrokPagerRequest(
            prompt: secondPromptMarker,
            mode: .fullScreen
        )))
        #expect(await fixture.waitForFrame(containing: secondPromptMarker))
        #expect(!fixture.sink.strippedText.contains(tailSentinel))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("page_flip_on_send = false leaves the viewport unchanged on send")
    func sendKeepsViewportWhenDisabled() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-pf-off-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let history = try await makeTallFirstTurnSession(home: home, sessionID: "pf-off")

        let fixture = try PageFlipFixture(
            configTOML: "[ui]\npage_flip_on_send = false\n",
            conversationHistory: history
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.sessionResumed(sessionID: "pf-off"))
        #expect(await fixture.waitForFrame(containing: tailSentinel))
        fixture.sink.clear()

        try await fixture.renderer.render(.turnStarted(OpenGrokPagerRequest(
            prompt: secondPromptMarker,
            mode: .fullScreen
        )))
        #expect(await fixture.waitForFrame(containing: secondPromptMarker))
        #expect(fixture.sink.strippedText.contains(tailSentinel))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("the settings row is visible and a modal commit persists toggles")
    func settingsTogglePersists() async throws {
        let fixture = try PageFlipFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()

        let overlay = await fixture.renderer.settingsOverlay(deepLinkKey: "page_flip_on_send")
        let visibleKeys = Set(overlay.visibleRows.compactMap(\.settingKey))
        #expect(visibleKeys.contains("page_flip_on_send"))

        // Default is on; the first Space commit writes `false` — same path as
        // upstream's typed setter (`settings_e2e.rs:513-518`).
        try await fixture.renderer.render(.overlay(.settings(deepLinkKey: "page_flip_on_send")))
        let routing = try await fixture.renderer.handleInput(.key(KeyEvent(
            key: .char(" "),
            character: " "
        )))
        #expect(routing == .consumed)
        #expect(fixture.configText.contains("page_flip_on_send = false"))
        try await fixture.renderer.restoreTerminal()
    }
}
