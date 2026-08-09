// LiveReleaseNotesReachabilityTests.swift
//
// The render-layer half of `/release-notes`, through the LIVE adapter
// (AGENTS.md §3): the real `LiveInteractiveControllerRenderer` painting into
// a captured sink in an isolated `$OPENGROK_HOME`, with effects asserted
// where they land — the painted document overlay fed by a seeded
// `CHANGELOG.md` under `GROK_CHANGELOG_OFFLINE`, the scrolled below-fold
// content, the painted offline error copy, and the export-boundary gate
// proven against a recording transport that must never be hit. The
// controller half (registry copy, alias, relative order, dispatch) is
// pinned in `Tests/OpenGrokPagerTests/PagerReleaseNotesCommandTests.swift`;
// the client itself in `Tests/OpenGrokShellBaseTests/ChangelogTests.swift`.

import Foundation
import OpenGrokHTTP
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokShellBase
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

// MARK: - Fixtures

private final class ReleaseNotesCapturingSink: PagerTerminalSink, CustomReflectable,
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
        // decode mangles multi-byte glyphs and hides painted rows.
        return String(decoding: plain, as: UTF8.self)
    }
}

/// The live renderer over an isolated `$HOME`/`$OPENGROK_HOME`. The
/// environment carries `GROK_CHANGELOG_OFFLINE` when a test wants the
/// deterministic cache-only arm; the export-boundary tests omit it and
/// inject a recording transport instead.
private struct ReleaseNotesRendererFixture {
    let home: URL
    let sink: ReleaseNotesCapturingSink
    let renderer: LiveInteractiveControllerRenderer

    /// `gateTransport`/`exportPolicy` build an injected `ChangelogManager`
    /// over this fixture's own home — the export-boundary tests' seam. When
    /// `gateTransport` is nil the renderer gets no client and its dispatch
    /// falls back to the cache-only manager, the headless arm.
    init(
        offline: Bool = true,
        gateTransport: (any HTTPTransport)? = nil,
        exportPolicy: XaiServicePolicy = .allowed
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opengrok-relnotes-reach-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
        if offline {
            environment["GROK_CHANGELOG_OFFLINE"] = "1"
        }
        let changelog = gateTransport.map { transport in
            ChangelogManager.fromEnvironment(
                environment,
                transport: transport,
                exportPolicy: exportPolicy
            )
        }
        sink = ReleaseNotesCapturingSink()
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
            sessionID: "release-notes-live",
            openGrokHome: home,
            changelog: changelog,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment,
            authServices: LivePagerAuthServices(
                makeTransport: { URLSessionHTTPTransport() },
                codexBrowserLogin: { _, _, _, _ in throw CancellationError() },
                openBrowser: nil
            )
        )
    }

    func seedMarkdown(_ content: String) throws {
        try content.write(
            to: home.appendingPathComponent("CHANGELOG.md"),
            atomically: true,
            encoding: .utf8
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
            runtime: ReleaseNotesUnusedRuntime(),
            renderer: renderer,
            output: ReleaseNotesDiscardingOutput()
        )
        _ = try await controller.run(.init(prompt: "", mode: .inline))
    }
}

private struct ReleaseNotesUnusedRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw CancellationError()
    }
}

private struct ReleaseNotesDiscardingOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

// MARK: - Tests

@Suite("/release-notes live seam", .serialized)
struct LiveReleaseNotesReachabilityTests {
    @Test("typed /release-notes paints the seeded changelog end-to-end")
    func typedCommandPaintsSeededChangelog() async throws {
        let fixture = try ReleaseNotesRendererFixture()
        defer { fixture.dispose() }
        try fixture.seedMarkdown("""
        # What's new

        Solar flare mitigation for the harness dish.
        """)
        // Through the REAL controller: keystrokes → dispatch → `.releaseNotes`
        // intent → offline fetch of the seeded cache → painted document
        // overlay. A composition-level render call would pass even if the
        // dispatch arm never emitted the intent.
        try await fixture.runController(submitting: ["/release-notes"])

        #expect(await fixture.waitForPaint(of: "Release Notes"))
        #expect(await fixture.waitForPaint(
            of: "Solar flare mitigation for the harness dish."
        ))
    }

    @Test("typed /changelog (the alias) paints the same overlay")
    func typedAliasPaintsSeededChangelog() async throws {
        let fixture = try ReleaseNotesRendererFixture()
        defer { fixture.dispose() }
        try fixture.seedMarkdown("Alias route sanity needle.\n")
        try await fixture.runController(submitting: ["/changelog"])

        #expect(await fixture.waitForPaint(of: "Release Notes"))
        #expect(await fixture.waitForPaint(of: "Alias route sanity needle."))
    }

    @Test("the release-notes overlay scrolls to below-fold content")
    func overlayScrollsToBelowFoldContent() async throws {
        let fixture = try ReleaseNotesRendererFixture()
        defer { fixture.dispose() }
        // 60 single-line paragraphs: far past the modal's row budget at
        // 40 terminal rows, so the last item cannot be in the first frame's
        // window and only a real scroll can paint it. The sink captures the
        // DIFF stream, and the encoder skips every cell that happens to
        // match the cell it replaces — even a coincidental one — so the
        // scroll-proof needle must live in columns the numbered fillers
        // (21 chars wide) never painted: past column 21, where every prior
        // row cell was blank and every needle cell must therefore repaint.
        var items = (0..<59).map { "Release note item \(String(format: "%03d", $0))" }
        items.append("The final entry sits well past the fold: OMEGATAILMARKER")
        try fixture.seedMarkdown(items.joined(separator: "\n\n") + "\n")
        try await fixture.renderer.begin()
        // Prompt state first — without it the collapsed sheet swallows keys
        // (the Wave 14 U4b fixture trap the /docs tests document).
        try await fixture.renderer.render(
            .promptChanged(OpenGrokPagerInteractivePromptState())
        )
        try await fixture.renderer.render(.overlay(.releaseNotes))
        #expect(await fixture.waitForPaint(of: "Release Notes"))
        #expect(await fixture.waitForPaint(of: "Release note item 000"))

        // End scrolls the text overlay to its bottom (`PagerOverlays.handle`,
        // the same path ↑/↓/PgDn take). The evidence is the PAINT of the
        // last item, not the routing value — a consumed key that never
        // repainted would still fail here.
        let routed = try await fixture.renderer.handleInput(.key(KeyEvent(key: .end)))
        #expect(routed == .consumed)
        #expect(await fixture.waitForPaint(of: "OMEGATAILMARKER"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("offline with no cache paints upstream's exact error copy")
    func offlineWithoutCachePaintsErrorCopy() async throws {
        let fixture = try ReleaseNotesRendererFixture()
        defer { fixture.dispose() }
        // No seeded CHANGELOG.md: the offline arm has nothing to serve.
        try await fixture.runController(submitting: ["/release-notes"])

        // Byte-exact upstream copy (release_notes.rs:33), asserted on the
        // painted frame like every command error at this seam.
        #expect(await fixture.waitForPaint(of: "No release notes available (offline)."))
    }

    @Test("a denied export boundary issues no request at the live seam")
    func deniedBoundaryIssuesNoRequestAtLiveSeam() async throws {
        // A scripted response that must never be served. NOT offline: the
        // gate, not the offline flag, is what must stop the fetch here.
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: Data("# must never be fetched\n".utf8)
            ),
        ])
        let fixture = try ReleaseNotesRendererFixture(
            offline: false,
            gateTransport: transport,
            exportPolicy: .denied
        )
        defer { fixture.dispose() }

        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.releaseNotes))

        // No request left the composition, and with no disk cache the
        // command answered with the offline copy — the denied arm IS the
        // offline arm, never a wire call.
        #expect(await fixture.waitForPaint(of: "No release notes available (offline)."))
        #expect(
            transport.recordedRequests.isEmpty,
            "a denied provider issued a changelog request from the live seam"
        )
        try await fixture.renderer.restoreTerminal()
    }

    @Test("an allowed export boundary fetches and paints (gate positive control)")
    func allowedBoundaryFetchesAndPaints() async throws {
        // Both parallel artifact fetches receive the same markdown body, so
        // the mock's serve order cannot matter; the JSON arm fails its parse
        // and stays honestly nil.
        let body = Data("Gate-open remote changelog body.\n".utf8)
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: body),
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: body),
        ])
        let fixture = try ReleaseNotesRendererFixture(
            offline: false,
            gateTransport: transport,
            exportPolicy: .allowed
        )
        defer { fixture.dispose() }

        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.releaseNotes))

        // Without this arm the denied test above would pass vacuously
        // against a transport nothing ever calls.
        #expect(await fixture.waitForPaint(of: "Gate-open remote changelog body."))
        #expect(transport.recordedRequests.count == 2)
        try await fixture.renderer.restoreTerminal()
    }
}
