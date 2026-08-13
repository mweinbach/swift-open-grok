// LiveMouseLinkClickTests.swift
//
// Transcript link mouse down/up against REAL last-painted `PagerRenderResult.links`
// (AGENTS.md §3), gated like pinned Rust
// `!has_native_link_hover() && is_link_modifier_held`:
// - sink `supportsHyperlinks` → terminal owns activation; bare click reaches
//   block/text selection and never calls urlOpener.
// - hyperlinks off → app arms only with control/meta/superKey; same-cell up
//   opens via injected opener. Standard-scheme filter still applies at paint.

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class LinkClickCapturingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private let hyperlinks: Bool

    init(supportsHyperlinks: Bool) {
        self.hyperlinks = supportsHyperlinks
    }

    var capabilities: PagerTerminalCapabilities {
        PagerTerminalCapabilities(supportsHyperlinks: hyperlinks)
    }

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

/// Thread-safe URL opener capture — never launches a browser.
private final class CapturedURLOpener: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    var opener: @Sendable (URL) -> Void {
        { [self] url in
            lock.lock(); defer { lock.unlock() }
            urls.append(url)
        }
    }

    var opened: [URL] {
        lock.lock(); defer { lock.unlock() }
        return urls
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return urls.count
    }
}

private struct LinkClickFixture {
    let home: URL
    let sink: LinkClickCapturingSink
    let renderer: LiveInteractiveControllerRenderer
    let opener: CapturedURLOpener
    let terminalHeight: Int
    let terminalWidth: Int
    let targetURL: String
    let supportsHyperlinks: Bool

    init(
        configTOML: String? = nil,
        terminalHeight: Int = 30,
        terminalWidth: Int = 100,
        paintCadence: TimeInterval = PagerMotion.minimumPaintCadence,
        targetURL: String = "https://example.com/link-click-unique",
        supportsHyperlinks: Bool = false
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-link-click-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let configTOML {
            try configTOML.write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        self.terminalHeight = terminalHeight
        self.terminalWidth = terminalWidth
        self.targetURL = targetURL
        self.supportsHyperlinks = supportsHyperlinks
        let environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
        sink = LinkClickCapturingSink(supportsHyperlinks: supportsHyperlinks)
        opener = CapturedURLOpener()
        let height = terminalHeight
        let width = terminalWidth
        let captured = opener
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: width, height: height) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: home.path,
            modelName: "alpha-model",
            modelCatalog: [
                LiveModelPickerEntry(id: "alpha-model", providerID: "xai", name: "alpha-model"),
                LiveModelPickerEntry(id: "beta-model", providerID: "xai", name: "beta-model"),
            ],
            uiConfiguration: LiveInteractiveControllerRenderer.resolveUIConfig(
                workingDirectory: home,
                environment: environment
            ),
            sessionID: "link-click",
            openGrokHome: home,
            paintCadence: paintCadence,
            environment: environment,
            urlOpener: captured.opener
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    func waitForPaint(containing needle: String, timeout: TimeInterval = 5) async -> Bool {
        let compact = needle.filter { !$0.isWhitespace }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sink.text.filter({ !$0.isWhitespace }).contains(compact) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return sink.text.filter({ !$0.isWhitespace }).contains(compact)
    }

    /// Seed a finished turn whose assistant body carries a markdown link,
    /// then wait until the live paint publishes that URL in `lastPaintedLinks`.
    func seedAssistantLink() async throws -> LinkSpan {
        try await renderer.begin()
        try await renderer.testingDismissWelcomeOverlay()
        let label = "LinkClickLabelUnique"
        let markdown = "see [\(label)](\(targetURL))\n"
        try await renderer.render(.turnStarted(OpenGrokPagerRequest(
            prompt: "link-prompt-unique-token",
            mode: .fullScreen
        )))
        try await renderer.render(.session(.output(markdown)))
        try await renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
            lifecycle: .completed,
            sessionID: nil,
            forwardedEventCount: 0,
            terminalRestored: false
        )))
        #expect(await waitForPaint(containing: label))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let span = await renderer.lastPaintedLinks.first(where: { $0.url == targetURL }) {
                return span
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return try #require(
            await renderer.lastPaintedLinks.first(where: { $0.url == targetURL })
        )
    }
}

/// App-owned open chord for non-native sinks (control stands in for the
/// non-macOS wire path; meta/superKey are accepted by the live gate too).
private let linkOpenModifiers: KeyModifiers = .control

@Suite("Live mouse transcript link click", .serialized)
struct LiveMouseLinkClickTests {
    @Test("native hyperlinks: bare click does not open and can block-select")
    func nativeBareClickSelectsWithoutOpening() async throws {
        let fixture = try LinkClickFixture(supportsHyperlinks: true)
        defer { fixture.dispose() }
        let span = try await fixture.seedAssistantLink()
        let x = span.colStart
        let y = span.row

        let down = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: x, y: y, button: .left
        )))
        #expect(down == .consumed)
        #expect(await fixture.renderer.testingPendingLinkClick() == nil)

        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: x, y: y, button: .left
        )))
        #expect(up == .focusScrollback)
        #expect(fixture.opener.count == 0)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() != nil)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("native hyperlinks: modifier still does not arm app opener")
    func nativeModifierDoesNotArmAppOpener() async throws {
        let fixture = try LinkClickFixture(supportsHyperlinks: true)
        defer { fixture.dispose() }
        let span = try await fixture.seedAssistantLink()

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: span.colStart, y: span.row, button: .left,
            modifiers: linkOpenModifiers
        )))
        #expect(await fixture.renderer.testingPendingLinkClick() == nil)
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: span.colStart, y: span.row, button: .left,
            modifiers: linkOpenModifiers
        )))
        #expect(fixture.opener.count == 0)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("non-native + modifier same-cell opens once and does not select the block")
    func nonNativeModifierSameCellOpensWithoutSelecting() async throws {
        let fixture = try LinkClickFixture(supportsHyperlinks: false)
        defer { fixture.dispose() }
        let span = try await fixture.seedAssistantLink()
        let x = span.colStart
        let y = span.row

        let down = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: x, y: y, button: .left, modifiers: linkOpenModifiers
        )))
        #expect(down == .consumed)
        #expect(await fixture.renderer.testingPendingLinkClick()?.url == fixture.targetURL)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == nil)
        #expect(fixture.opener.count == 0)

        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: x, y: y, button: .left, modifiers: linkOpenModifiers
        )))
        #expect(up == .consumed)
        #expect(fixture.opener.count == 1)
        #expect(fixture.opener.opened.first?.absoluteString == fixture.targetURL)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == nil)
        #expect(await fixture.renderer.testingPendingLinkClick() == nil)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("non-native without modifier does not open and can block-select")
    func nonNativeBareClickSelectsWithoutOpening() async throws {
        let fixture = try LinkClickFixture(supportsHyperlinks: false)
        defer { fixture.dispose() }
        let span = try await fixture.seedAssistantLink()

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: span.colStart, y: span.row, button: .left
        )))
        #expect(await fixture.renderer.testingPendingLinkClick() == nil)
        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: span.colStart, y: span.row, button: .left
        )))
        #expect(up == .focusScrollback)
        #expect(fixture.opener.count == 0)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() != nil)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("shift or alt alone are not link modifiers")
    func shiftAndAltDoNotArmLinkClick() async throws {
        let fixture = try LinkClickFixture(supportsHyperlinks: false)
        defer { fixture.dispose() }
        let span = try await fixture.seedAssistantLink()

        for mods: KeyModifiers in [.shift, .alt] {
            _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
                kind: .down, x: span.colStart, y: span.row, button: .left, modifiers: mods
            )))
            #expect(await fixture.renderer.testingPendingLinkClick() == nil)
            _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
                kind: .up, x: span.colStart, y: span.row, button: .left, modifiers: mods
            )))
            #expect(fixture.opener.count == 0)
        }
        try await fixture.renderer.restoreTerminal()
    }

    @Test("meta and superKey also arm when hyperlinks are off")
    func metaAndSuperKeyArmNonNative() async throws {
        for mods: KeyModifiers in [.meta, .superKey] {
            let fixture = try LinkClickFixture(supportsHyperlinks: false)
            defer { fixture.dispose() }
            let span = try await fixture.seedAssistantLink()
            _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
                kind: .down, x: span.colStart, y: span.row, button: .left, modifiers: mods
            )))
            #expect(await fixture.renderer.testingPendingLinkClick()?.url == fixture.targetURL)
            _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
                kind: .up, x: span.colStart, y: span.row, button: .left, modifiers: mods
            )))
            #expect(fixture.opener.count == 1)
            try await fixture.renderer.restoreTerminal()
        }
    }

    @Test("different-cell up does not open")
    func differentCellUpIsNoOp() async throws {
        let fixture = try LinkClickFixture(supportsHyperlinks: false)
        defer { fixture.dispose() }
        let span = try await fixture.seedAssistantLink()
        let x = span.colStart
        let y = span.row

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: x, y: y, button: .left, modifiers: linkOpenModifiers
        )))
        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: x + 1, y: y, button: .left, modifiers: linkOpenModifiers
        )))
        #expect(up == .consumed)
        #expect(fixture.opener.count == 0)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == nil)
        #expect(await fixture.renderer.testingPendingLinkClick() == nil)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("drag clears pending so release does not open")
    func dragClearsPendingLinkClick() async throws {
        let fixture = try LinkClickFixture(supportsHyperlinks: false)
        defer { fixture.dispose() }
        let span = try await fixture.seedAssistantLink()
        let x = span.colStart
        let y = span.row

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: x, y: y, button: .left, modifiers: linkOpenModifiers
        )))
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: x + 2, y: y, button: .left, modifiers: linkOpenModifiers
        )))
        #expect(await fixture.renderer.testingPendingLinkClick() == nil)
        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: x + 2, y: y, button: .left, modifiers: linkOpenModifiers
        )))
        #expect(up == .consumed)
        #expect(fixture.opener.count == 0)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("X10-style up with no button opens against the pending left-down")
    func x10StyleUpNoneOpens() async throws {
        let fixture = try LinkClickFixture(supportsHyperlinks: false)
        defer { fixture.dispose() }
        let span = try await fixture.seedAssistantLink()
        let x = span.colStart
        let y = span.row

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: x, y: y, button: .left, modifiers: linkOpenModifiers
        )))
        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: x, y: y, button: .none
        )))
        #expect(up == .consumed)
        #expect(fixture.opener.count == 1)
        #expect(fixture.opener.opened.first?.absoluteString == fixture.targetURL)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a capturing modal blocks transcript link open underneath")
    func capturingOverlayBlocksLinkOpen() async throws {
        let fixture = try LinkClickFixture(supportsHyperlinks: false)
        defer { fixture.dispose() }
        let span = try await fixture.seedAssistantLink()

        try await fixture.renderer.render(.overlay(.modelPicker(query: nil)))
        #expect(await fixture.waitForPaint(containing: "alpha-model (current)"))

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: span.colStart, y: span.row, button: .left,
            modifiers: linkOpenModifiers
        )))
        #expect(await fixture.renderer.testingPendingLinkClick() == nil)
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: span.colStart, y: span.row, button: .left,
            modifiers: linkOpenModifiers
        )))
        #expect(fixture.opener.count == 0)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("scrollbar gutter click keeps priority and does not open a link")
    func scrollbarPriorityOverLink() async throws {
        let fixture = try LinkClickFixture(terminalHeight: 18, supportsHyperlinks: false)
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.testingDismissWelcomeOverlay()
        let tall = (0..<60).map { "link-sb-fill-\($0)-unique" }.joined(separator: "\n")
        let label = "LinkSbLabelUnique"
        let body = tall + "\nsee [\(label)](\(fixture.targetURL))\n"
        try await fixture.renderer.render(.turnStarted(OpenGrokPagerRequest(
            prompt: "link-sb-prompt-unique",
            mode: .fullScreen
        )))
        try await fixture.renderer.render(.session(.output(body)))
        try await fixture.renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
            lifecycle: .completed,
            sessionID: nil,
            forwardedEventCount: 0,
            terminalRestored: false
        )))
        #expect(await fixture.waitForPaint(containing: "link-sb-fill-0-unique"))

        let model = try #require(await fixture.renderer.lastConversationHit)
        let gutterX = model.selectableEndX
        #expect(await fixture.renderer.lastScrollbarHit != nil)

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: gutterX, y: model.conversation.y, button: .left,
            modifiers: linkOpenModifiers
        )))
        #expect(await fixture.renderer.testingPendingLinkClick() == nil)
        #expect(await fixture.renderer.testingScrollbarDragging())
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: gutterX, y: model.conversation.y, button: .left
        )))
        #expect(fixture.opener.count == 0)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("timeline rail click keeps priority and does not open a link")
    func railPriorityOverLink() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-link-rail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try "[ui]\nshow_timeline = true\n".write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let targetURL = "https://example.com/link-rail-unique"
        let opener = CapturedURLOpener()
        let store = LiveConversationStore(openGrokHome: home)
        var record = LiveConversationRecord.new(sessionID: "rail-link", workingDirectory: home)
        record.items = [
            .user("alpha anchor question"),
            .assistant(AssistantItem(
                content: (0..<25).map { "afill \($0)" }.joined(separator: "\n\n")
                    + "\n\nsee [RailLinkLabel](\(targetURL))\n"
            )),
            .user("second question zebra"),
            .assistant(AssistantItem(
                content: (0..<25).map { "bfill \($0)" }.joined(separator: "\n\n")
            )),
        ]
        try await store.save(record)
        let history = LiveConversationHistory(record: record, store: store)

        let environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
        let sink = LinkClickCapturingSink(supportsHyperlinks: false)
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: home.path,
            modelName: "unknown",
            uiConfiguration: LiveInteractiveControllerRenderer.resolveUIConfig(
                workingDirectory: home,
                environment: environment
            ),
            sessionID: "rail-link",
            conversationHistory: history,
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment,
            urlOpener: opener.opener
        )
        try await renderer.begin()
        try await renderer.render(.sessionResumed(sessionID: "rail-link"))
        let deadline = Date().addingTimeInterval(5)
        var painted = false
        while Date() < deadline {
            if sink.text.filter({ !$0.isWhitespace }).contains("restored.") {
                painted = true
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(painted)

        let routing = try await renderer.handleInput(.mouse(MouseEvent(
            kind: .down,
            x: 98,
            y: 13,
            button: .left,
            modifiers: linkOpenModifiers
        )))
        #expect(routing == .consumed)
        #expect(await renderer.testingPendingLinkClick() == nil)
        #expect(opener.count == 0)
        try await renderer.restoreTerminal()
    }

    @Test("http https and mailto published spans open via urlOpener with modifier")
    func standardSchemesOpenLive() async throws {
        let cases: [(label: String, url: String)] = [
            ("HttpLabelUnique", "http://example.com/link-http-unique"),
            ("HttpsLabelUnique", "https://example.com/link-https-unique"),
            ("MailtoLabelUnique", "mailto:user@example.com"),
        ]
        for item in cases {
            let fixture = try LinkClickFixture(
                targetURL: item.url,
                supportsHyperlinks: false
            )
            defer { fixture.dispose() }
            try await fixture.renderer.begin()
            try await fixture.renderer.testingDismissWelcomeOverlay()
            try await fixture.renderer.render(.turnStarted(OpenGrokPagerRequest(
                prompt: "scheme-prompt-\(item.label)",
                mode: .fullScreen
            )))
            try await fixture.renderer.render(.session(.output(
                "see [\(item.label)](\(item.url))\n"
            )))
            try await fixture.renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
                lifecycle: .completed,
                sessionID: nil,
                forwardedEventCount: 0,
                terminalRestored: false
            )))
            #expect(await fixture.waitForPaint(containing: item.label))
            let span = try #require(
                await fixture.renderer.lastPaintedLinks.first(where: { $0.url == item.url })
            )
            _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
                kind: .down, x: span.colStart, y: span.row, button: .left,
                modifiers: linkOpenModifiers
            )))
            _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
                kind: .up, x: span.colStart, y: span.row, button: .left,
                modifiers: linkOpenModifiers
            )))
            #expect(fixture.opener.count == 1, "opener once for \(item.url)")
            #expect(fixture.opener.opened.first?.absoluteString == item.url)
            #expect(await fixture.renderer.testingScrollbackSelectedIndex() == nil)
            try await fixture.renderer.restoreTerminal()
        }
    }

    @Test("file javascript custom and relative paths do not publish or open or preempt selection")
    func unsafeSchemesRejectedLive() async throws {
        let unsafeURLs = [
            "file:///tmp/secret-link-unique",
            "javascript:alert(1)",
            "custom://something-unique",
            "videos/1.mp4",
        ]
        for unsafe in unsafeURLs {
            let fixture = try LinkClickFixture(supportsHyperlinks: false)
            defer { fixture.dispose() }
            try await fixture.renderer.begin()
            try await fixture.renderer.testingDismissWelcomeOverlay()
            let label = "UnsafeLabelUnique"
            try await fixture.renderer.testingAppendConversationItem(
                .message(PagerMessage(
                    role: .assistant,
                    text: label,
                    styledLines: [PagerStyledLine(spans: [
                        PagerStyledSpan(
                            text: label,
                            style: [.underline],
                            url: unsafe
                        )
                    ])]
                ))
            )
            #expect(await fixture.waitForPaint(containing: label))
            #expect(
                await !fixture.renderer.lastPaintedLinks.contains(where: { $0.url == unsafe }),
                "must not publish \(unsafe)"
            )
            #expect(await fixture.renderer.testingPendingLinkClick() == nil)

            let model = try #require(await fixture.renderer.lastConversationHit)
            let index = await fixture.renderer.testingConversationItemCount() - 1
            let point = try #require(linkContentPoint(in: model, blockIndex: index))

            let down = try await fixture.renderer.handleInput(.mouse(MouseEvent(
                kind: .down, x: point.x, y: point.y, button: .left,
                modifiers: linkOpenModifiers
            )))
            #expect(down == .consumed)
            #expect(await fixture.renderer.testingPendingLinkClick() == nil)
            let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
                kind: .up, x: point.x, y: point.y, button: .left,
                modifiers: linkOpenModifiers
            )))
            #expect(up == .focusScrollback)
            #expect(await fixture.renderer.testingScrollbackSelectedIndex() == index)
            #expect(fixture.opener.count == 0, "must not open \(unsafe)")
            try await fixture.renderer.restoreTerminal()
        }
    }
}

/// Content-band cell for a published block — same geometry the block-select
/// live seam uses (chrome + 2). Used when unsafe schemes leave no LinkSpan.
private func linkContentPoint(
    in model: PagerConversationHitModel,
    blockIndex: Int
) -> (x: Int, y: Int)? {
    guard model.blockStartLines.indices.contains(blockIndex),
          model.blockHeights.indices.contains(blockIndex),
          model.blockHeights[blockIndex] > 0
    else { return nil }
    let contentY = model.blockStartLines[blockIndex]
    let screenY = model.conversation.y + contentY - model.scrollOffset
    guard screenY >= model.conversation.y,
          screenY < model.conversation.y + model.conversation.height
    else { return nil }
    let x = model.conversation.x + PagerLayoutMetrics.chromeWidth + 2
    return (x, screenY)
}
