// LivePagerDocsReachabilityTests.swift
//
// The render-layer half of `/docs`, through the LIVE adapter (AGENTS.md §3):
// the real `LiveInteractiveControllerRenderer` painting into a captured sink
// in an isolated `$OPENGROK_HOME`, with effects asserted where they land —
// the painted guides list, the painted guide content, the injected browser
// opener's received URL, and the painted unknown-target error, the last
// driven end-to-end through the real controller from typed input. The
// controller half (registry pins, dispatch arms, byte-exact copy, corpus
// integrity) is pinned in `Tests/OpenGrokPagerTests/PagerDocsCommandTests.swift`.

import Foundation
import OpenGrokHTTP
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

// MARK: - Fixtures

private final class DocsCapturingSink: PagerTerminalSink, CustomReflectable,
    @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    /// A failed `#expect` mirrors captured values; without this, Swift
    /// Testing dumps the whole byte buffer as decimal text (the Wave 15 D3
    /// runner balloon).
    var customMirror: Mirror {
        lock.lock(); defer { lock.unlock() }
        return Mirror(self, children: ["byteCount": bytes.count])
    }

    var strippedText: String {
        lock.lock(); defer { lock.unlock() }
        var plain: [UInt8] = []
        plain.reserveCapacity(bytes.count / 4)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B else {
                plain.append(bytes[index])
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
        // Decode as UTF-8, NOT one scalar per byte — a byte-per-scalar
        // decode mangles multi-byte glyphs and hides painted rows
        // (the `ForkCapturingSink` lesson).
        return String(decoding: plain, as: UTF8.self)
    }
}

/// Records every URL the composition hands the browser opener.
private final class OpenedURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        urls.append(url)
    }

    var all: [URL] {
        lock.lock(); defer { lock.unlock() }
        return urls
    }
}

/// Auth services whose only live leg is the injected opener — `/docs web`
/// never logs in, so the transport and codex flow are inert placeholders.
private func docsAuthServices(
    openBrowser: (@Sendable (URL) -> Void)?
) -> LivePagerAuthServices {
    LivePagerAuthServices(
        makeTransport: { URLSessionHTTPTransport() },
        codexBrowserLogin: { _, _, _, _ in throw CancellationError() },
        openBrowser: openBrowser
    )
}

/// The live renderer over an isolated `$HOME`/`$OPENGROK_HOME`, so no test
/// can read the developer's real configuration or open a real browser.
private struct DocsRendererFixture {
    let home: URL
    let sink: DocsCapturingSink
    let renderer: LiveInteractiveControllerRenderer

    init(authServices: LivePagerAuthServices = docsAuthServices(openBrowser: nil)) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-docs-reach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        sink = DocsCapturingSink()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
            write: { _ in }
        )
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: sink,
            workingDirectory: home.path,
            modelName: "test-model",
            sessionID: "docs-live",
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: ["HOME": home.path, "OPENGROK_HOME": home.path],
            authServices: authServices
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    /// The painted frame with all whitespace removed — the diff encoder
    /// skips unchanged cells, so multi-word needles never match raw capture.
    func paintedCompact() -> String {
        sink.strippedText.filter { !$0.isWhitespace }
    }

    func waitForPaint(of marker: String, timeout: TimeInterval = 5) async -> Bool {
        let needle = marker.filter { !$0.isWhitespace }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !paintedCompact().contains(needle) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return paintedCompact().contains(needle)
    }

    /// Run the REAL controller over this renderer with typed input — the
    /// full live seam, from keystrokes to paint. Each line is typed, the
    /// dropdown closed with Esc (so Enter submits the typed text, not the
    /// highlighted suggestion), and submitted.
    func runController(submitting lines: [String]) async throws {
        var events: [InputEvent] = []
        for line in lines {
            events.append(.paste(line))
            events.append(.key(KeyEvent(key: .escape)))
            events.append(.key(KeyEvent(key: .enter)))
        }
        let controller = OpenGrokPagerInteractiveController(
            input: AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            },
            runtime: DocsUnusedRuntime(),
            renderer: renderer,
            output: DocsDiscardingOutput()
        )
        _ = try await controller.run(.init(prompt: "", mode: .inline))
    }
}

private struct DocsUnusedRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw CancellationError()
    }
}

private struct DocsDiscardingOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

// MARK: - Tests

@Suite("/docs live seam", .serialized)
struct LivePagerDocsReachabilityTests {
    @Test("typed /docs paints the How-to Guides list end-to-end")
    func bareDocsPaintsGuidesList() async throws {
        let fixture = try DocsRendererFixture()
        defer { fixture.dispose() }
        // Through the REAL controller: keystrokes → dispatch → overlay
        // intent → painted list. A composition-level render call would pass
        // even if the dispatch arm never emitted the intent.
        try await fixture.runController(submitting: ["/docs"])

        #expect(await fixture.waitForPaint(of: "How-to Guides"))
        // The label truncates at this sheet width — the right-aligned
        // 49-char description gets full width and the label yields, exactly
        // upstream's rule (`picker.rs:1017-1023`: `max_label_width =
        // width - right_width - …`). "Getting Star" is what actually
        // paints at 120 columns; asserting the full title would pin a
        // layout upstream doesn't produce either.
        #expect(await fixture.waitForPaint(of: "Getting Star"))
        // A row description paints in the detail column (`summary` is
        // filter-haystack only and never drawn).
        #expect(await fixture.waitForPaint(
            of: "Installation, first launch, and basic interaction"
        ))
        // The modal budgets 15 content rows and the filter field takes two
        // of them (`PagerOverlayRender` height calc + `drawListBody`), so
        // ~13 data rows paint in the first frame; index 11 is safely inside
        // the window. Its label truncates like every other long label, so
        // the row is pinned by its full-width detail description instead.
        // The rows below the fold are proven live by scrolling in
        // `selectionScrollsToTheReferenceTable`.
        #expect(await fixture.waitForPaint(
            of: "Per-directory instructions and precedence rules"
        ))
    }

    @Test("selecting the first row opens that guide's real content")
    func selectionOpensGuideContent() async throws {
        let fixture = try DocsRendererFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.howtoGuides))
        #expect(await fixture.waitForPaint(of: "How-to Guides"))

        // Row 0 is Getting Started; Enter opens its viewer.
        let selected = try await fixture.renderer.handleInput(
            .key(KeyEvent(key: .enter))
        )
        #expect(selected == .consumed)
        // The corpus body, not just the title the list already painted:
        // this phrase exists only inside 01-getting-started.md.
        #expect(await fixture.waitForPaint(of: "ChatGPT Codex optimizations"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("cursor movement selects a different guide")
    func selectionMovesWithTheCursor() async throws {
        let fixture = try DocsRendererFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        // Without a prompt state the bottom sheet collapses and arrow keys
        // stop reaching the list (the Wave 14 U4b fixture trap) — cursor
        // movement silently no-ops while Enter still selects row 0.
        try await fixture.renderer.render(
            .promptChanged(OpenGrokPagerInteractivePromptState())
        )
        try await fixture.renderer.render(.overlay(.howtoGuides))
        #expect(await fixture.waitForPaint(of: "How-to Guides"))

        // One step down is row 1, Authentication (upstream corpus order).
        let moved = try await fixture.renderer.handleInput(.key(KeyEvent(key: .down)))
        #expect(moved == .consumed)
        let selected = try await fixture.renderer.handleInput(.key(KeyEvent(key: .enter)))
        #expect(selected == .consumed)
        // A short heading from 02-authentication.md — long paragraph lines
        // clip at the viewer width, so a needle deep inside one never
        // paints regardless of correctness.
        #expect(await fixture.waitForPaint(of: "Browser Login (Default)"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("scrolling past the 15-row window reaches the reference table")
    func selectionScrollsToTheReferenceTable() async throws {
        let fixture = try DocsRendererFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        // Prompt state first — the collapsed sheet swallows cursor keys
        // (see selectionMovesWithTheCursor).
        try await fixture.renderer.render(
            .promptChanged(OpenGrokPagerInteractivePromptState())
        )
        try await fixture.renderer.render(.overlay(.howtoGuides))
        #expect(await fixture.waitForPaint(of: "How-to Guides"))

        // 25 steps down from row 0 lands on row 25, the last row — the
        // second reference doc, below the initial 15-row window either way
        // (clamped or wrapped, 26 rows put step 25 on index 25).
        for _ in 0..<25 {
            let moved = try await fixture.renderer.handleInput(.key(KeyEvent(key: .down)))
            #expect(moved == .consumed)
        }
        let selected = try await fixture.renderer.handleInput(.key(KeyEvent(key: .enter)))
        #expect(selected == .consumed)
        // A short heading from custom-hooks.md — proof the REFERENCE_DOCS
        // table is live at this seam, not just listed. (Long paragraph
        // lines clip at the viewer width; a mid-paragraph needle cannot
        // paint.)
        #expect(await fixture.waitForPaint(of: "Why Use Hooks?"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a second bare /docs toggles the open picker closed")
    func secondDocsTogglesPickerClosed() async throws {
        let fixture = try DocsRendererFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.howtoGuides))
        #expect(await fixture.waitForPaint(of: "How-to Guides"))
        // The open picker captures keys.
        let whileOpen = try await fixture.renderer.handleInput(.key(KeyEvent(key: .down)))
        #expect(whileOpen == .consumed)

        // Upstream toggles closed (`dispatch_open_howto_guides`,
        // `dispatch/settings/ui.rs:256-259`). The captured frame is
        // cumulative, so absence cannot be asserted on paint; the observable
        // is input routing — with no capturing overlay left, keys fall
        // through to the composer.
        try await fixture.renderer.render(.overlay(.howtoGuides))
        let afterToggle = try await fixture.renderer.handleInput(.key(KeyEvent(key: .down)))
        #expect(afterToggle == .notHandled)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("typed /docs web hands BUILD_DOCS_URL to the injected opener")
    func docsWebInvokesInjectedOpener() async throws {
        let opened = OpenedURLBox()
        let fixture = try DocsRendererFixture(
            authServices: docsAuthServices(openBrowser: { opened.append($0) })
        )
        defer { fixture.dispose() }
        try await fixture.runController(submitting: ["/docs web"])

        // Bounded poll: the opener is called inside the overlay dispatch,
        // which runs on the renderer actor after `run` returns its events.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, opened.all.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        // Asserted on the URL the opener received — the whole point of the
        // seam (never `_ =` the effect the test exists to observe).
        #expect(opened.all.map(\.absoluteString) == ["https://docs.x.ai/build/overview"])
    }

    @Test("without an opener, /docs web paints the manual-URL fallback")
    func docsWebWithoutOpenerPaintsManualURL() async throws {
        let fixture = try DocsRendererFixture(
            authServices: docsAuthServices(openBrowser: nil)
        )
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.openURL(PagerDocs.buildDocsURL)))

        // Upstream's `browser_unavailable_message` copy
        // (`pager-render/src/link_opener.rs:48-54`).
        #expect(await fixture.waitForPaint(of: "Could not open a browser."))
        #expect(await fixture.waitForPaint(of: "https://docs.x.ai/build/overview"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("typed /docs Getting Started paints that guide directly")
    func docsTitlePaintsGuide() async throws {
        let fixture = try DocsRendererFixture()
        defer { fixture.dispose() }
        try await fixture.runController(submitting: ["/docs Getting Started"])

        #expect(await fixture.waitForPaint(of: "Getting Started"))
        #expect(await fixture.waitForPaint(of: "ChatGPT Codex optimizations"))
    }

    @Test("typed unknown target paints upstream's error copy")
    func unknownTargetPaintsError() async throws {
        let fixture = try DocsRendererFixture()
        defer { fixture.dispose() }
        try await fixture.runController(submitting: ["/docs No Such Guide"])

        // The byte-exact copy is pinned at the controller seam; here the
        // needles prove the notice reaches the screen, including the Rust
        // {:?}-quoted echo of what the user typed.
        #expect(await fixture.waitForPaint(of: "Unknown docs target \"No Such Guide\"."))
        #expect(await fixture.waitForPaint(of: "(e.g. /docs Getting Started)"))
    }
}
