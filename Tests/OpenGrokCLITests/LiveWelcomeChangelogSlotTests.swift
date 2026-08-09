// LiveWelcomeChangelogSlotTests.swift
//
// B2-W2 through the LIVE seam (AGENTS.md §3): the changelog startup
// prefetch and the welcome hero's info slot, asserted on the real
// `LiveInteractiveControllerRenderer` painting into a captured sink over an
// isolated `$OPENGROK_HOME` — never on the overlay value type alone.
//
// Upstream reference at pin 650c1db7: the one-shot post-auth prefetch
// (`app/event_loop.rs:1811-1816` — "off the render path so the welcome
// screen can display bullets and /release-notes uses the cached result"),
// the `ChangelogFetched` store (`dispatch/task_result.rs:3097-3101`:
// markdown + `bullets_from_entries(&entries, 3)`), the hero info slot
// (`views/welcome/hero_box.rs:544-588`: "Changelog" header, blank row,
// " • " bullets, hidden subtitle, `clickable.then_some(area)` CTA), the
// slot's availability gate (`views/welcome/mod.rs:1745-1752`:
// `changelog_height = 2 + bullets`, collapsed on empty), and the CTA/menu
// dispatch from already-available markdown (`app/app_view.rs:4380-4388`,
// `:4607-4614`).

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

/// Routes by artifact suffix instead of FIFO order: the changelog client
/// fetches `.external.md` and `.external.json` IN PARALLEL (`async let`,
/// upstream `changelog.rs:126-133`), so a scripted queue would serve the
/// two bodies in whichever order the scheduler ran the requests. Routing
/// makes the parallel fetch deterministic without touching production.
private final class RoutedChangelogTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HTTPRequest] = []
    let markdownBody: String
    let entriesBody: String

    init(markdownBody: String, entriesBody: String) {
        self.markdownBody = markdownBody
        self.entriesBody = entriesBody
    }

    var recordedRequests: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { recorded.append(request) }
        let body: String
        if request.url.absoluteString.hasSuffix(".external.md") {
            body = markdownBody
        } else {
            body = entriesBody
        }
        return HTTPResponse(
            metadata: HTTPResponseMetadata(statusCode: 200),
            body: Data(body.utf8)
        )
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            // The changelog client only buffers via send(); a stream call
            // would be a contract change worth failing loudly on.
            continuation.finish(throwing: CancellationError())
        }
    }
}

private final class SlotCapturingSink: PagerTerminalSink, CustomReflectable,
    @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

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

/// The live renderer over an isolated home. `transport`/`exportPolicy`
/// build the injected changelog client (the prefetch's network seam);
/// `seededMarkdown`/`seededEntriesJSON` pre-fill the disk cache for the
/// offline arms.
private struct ChangelogSlotFixture {
    let home: URL
    let sink: SlotCapturingSink
    let renderer: LiveInteractiveControllerRenderer
    let transport: RoutedChangelogTransport?

    init(
        transport: RoutedChangelogTransport? = nil,
        exportPolicy: XaiServicePolicy = .allowed,
        offline: Bool = false,
        seededMarkdown: String? = nil,
        seededEntriesJSON: String? = nil
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opengrok-welcome-slot-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let seededMarkdown {
            try seededMarkdown.write(
                to: home.appendingPathComponent("CHANGELOG.md"),
                atomically: true,
                encoding: .utf8
            )
        }
        if let seededEntriesJSON {
            try seededEntriesJSON.write(
                to: home.appendingPathComponent("CHANGELOG.json"),
                atomically: true,
                encoding: .utf8
            )
        }
        var environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
        if offline {
            environment["GROK_CHANGELOG_OFFLINE"] = "1"
        }
        self.transport = transport
        let changelog = transport.map { routed in
            ChangelogManager.fromEnvironment(
                environment,
                transport: routed,
                exportPolicy: exportPolicy
            )
        }
        sink = SlotCapturingSink()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 110, height: 34) },
            write: { _ in }
        )
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: sink,
            workingDirectory: home.path,
            modelName: "test-model",
            sessionID: "welcome-slot-live",
            openGrokHome: home,
            changelog: changelog,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    /// Begin, then await the REAL spawned prefetch — never a poll against
    /// wall time (the `pendingCodingDataWrite` awaiting precedent).
    func beginAndAwaitPrefetch() async throws {
        try await renderer.begin()
        await renderer.changelogPrefetch?.value
    }

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

    func welcomeRows() async -> [PagerOverlayBounds.Row] {
        await renderer.lastOverlayBounds
            .last { $0.id == LiveInteractiveControllerRenderer.welcomeOverlayID }?
            .rows ?? []
    }

    func rowCenter(_ rowID: String) async throws -> (x: Int, y: Int) {
        let rows = await welcomeRows()
        guard let row = rows.first(where: { $0.id == rowID }) else {
            throw CancellationError()
        }
        return (x: row.frame.x + row.frame.width / 2, y: row.frame.y)
    }
}

private let slotEntriesJSON = #"""
[
  {"category": "features", "description": "Slot bullet ALPHA lands", "breaking_change": false},
  {"category": "fixes", "description": "Slot bullet BRAVO lands", "breaking_change": false},
  {"category": "performance", "description": "Slot bullet CHARLIE lands", "breaking_change": false},
  {"category": "other", "description": "Slot bullet DELTA must never paint", "breaking_change": false}
]
"""#

// MARK: - Tests

@Suite("welcome changelog slot live seam", .serialized)
struct LiveWelcomeChangelogSlotTests {
    @Test("the startup prefetch fires once, off the render path, and fills the OPEN welcome in place")
    func prefetchFillsTheOpenWelcomeInPlace() async throws {
        let transport = RoutedChangelogTransport(
            markdownBody: "# Remote notes\n\nPrefetched body needle OMEGA.\n",
            entriesBody: slotEntriesJSON
        )
        let fixture = try ChangelogSlotFixture(transport: transport)
        defer { fixture.dispose() }

        // No fetch happens at construction — the prefetch is begin()'s
        // (upstream fires it from event-loop startup, never a frame).
        #expect(transport.recordedRequests.isEmpty)

        try await fixture.beginAndAwaitPrefetch()

        // The OPEN welcome updated in place: header + the first 3 bullets
        // (`bullets_from_entries(&entries, 3)`, task_result.rs:3099-3100),
        // never the 4th.
        #expect(await fixture.waitForPaint(of: "Changelog"))
        #expect(await fixture.waitForPaint(of: "Slot bullet ALPHA lands"))
        #expect(await fixture.waitForPaint(of: "Slot bullet BRAVO lands"))
        #expect(await fixture.waitForPaint(of: "Slot bullet CHARLIE lands"))
        #expect(!fixture.paintedCompact().contains("DELTA"))

        // The slot layout in paint order: header precedes the bullets
        // (hero_box.rs:559-585 — header at y, bullets from y+2).
        let painted = fixture.paintedCompact()
        let headerIndex = try #require(painted.range(of: "Changelog")?.lowerBound)
        let alphaIndex = try #require(
            painted.range(of: "SlotbulletALPHAlands")?.lowerBound
        )
        #expect(headerIndex < alphaIndex)

        // One-shot: exactly one md + one json request, ever — repaints and
        // the guard (`changelogPrefetch == nil`) add nothing.
        let urls = transport.recordedRequests.map(\.url.absoluteString)
        #expect(urls.count == 2)
        #expect(urls.contains { $0.hasSuffix(".external.md") })
        #expect(urls.contains { $0.hasSuffix(".external.json") })

        // The prefetch-filled Changelog menu row is present (W1's first-run
        // gap, closed): both the row and the CTA rect are published.
        let rowIDs = await fixture.welcomeRows().map(\.id)
        #expect(rowIDs.contains(LiveInteractiveControllerRenderer.welcomeChangelogRowID))
        #expect(rowIDs.contains(PagerWelcomeOverlay.changelogCTARowID))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a denied export boundary issues no request and paints no slot")
    func deniedBoundaryIssuesNothing() async throws {
        // Positive control: the allowed-policy arm of the SAME fixture shape
        // is `prefetchFillsTheOpenWelcomeInPlace`, which proves this
        // transport records requests when the boundary permits.
        let transport = RoutedChangelogTransport(
            markdownBody: "# never fetched\n",
            entriesBody: slotEntriesJSON
        )
        let fixture = try ChangelogSlotFixture(
            transport: transport,
            exportPolicy: .denied
        )
        defer { fixture.dispose() }
        try await fixture.beginAndAwaitPrefetch()

        #expect(transport.recordedRequests.isEmpty)
        // No data → no slot, no bare header, no menu row ("Changelog"
        // appears nowhere in the frame).
        #expect(!fixture.paintedCompact().contains("Changelog"))
        let rowIDs = await fixture.welcomeRows().map(\.id)
        #expect(!rowIDs.contains(PagerWelcomeOverlay.changelogCTARowID))
        #expect(!rowIDs.contains(LiveInteractiveControllerRenderer.welcomeChangelogRowID))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a seeded disk cache paints bullets offline — the prior-session arm")
    func seededDiskCachePaintsBulletsOffline() async throws {
        let fixture = try ChangelogSlotFixture(
            offline: true,
            seededMarkdown: "# Cached notes\n\nDisk-cache body needle SIERRA.\n",
            seededEntriesJSON: slotEntriesJSON
        )
        defer { fixture.dispose() }
        try await fixture.beginAndAwaitPrefetch()

        // The cache-only fetch (GROK_CHANGELOG_OFFLINE, changelog.rs:196-198)
        // feeds the same store: bullets painted, no network possible (the
        // composition has no transport at all).
        #expect(await fixture.waitForPaint(of: "Changelog"))
        #expect(await fixture.waitForPaint(of: "Slot bullet ALPHA lands"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("clicking the info-slot CTA opens the prefetched release notes")
    func ctaClickOpensPrefetchedReleaseNotes() async throws {
        let transport = RoutedChangelogTransport(
            markdownBody: "# Remote notes\n\nCTA click body needle TANGO.\n",
            entriesBody: slotEntriesJSON
        )
        let fixture = try ChangelogSlotFixture(transport: transport)
        defer { fixture.dispose() }
        try await fixture.beginAndAwaitPrefetch()
        #expect(await fixture.waitForPaint(of: "Slot bullet ALPHA lands"))

        // The whole block is the click target (`clickable.then_some(area)`,
        // hero_box.rs:587), dispatching the same ShowReleaseNotes the menu
        // row does (app_view.rs:4380-4388).
        let target = try await fixture.rowCenter(PagerWelcomeOverlay.changelogCTARowID)
        let routing = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down,
            x: target.x,
            y: target.y
        )))
        #expect(routing == .consumed)
        #expect(await fixture.waitForPaint(of: "Release Notes"))
        #expect(await fixture.waitForPaint(of: "CTA click body needle TANGO."))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("/release-notes after the prefetch serves the stored result without refetching")
    func releaseNotesServesTheStoredResultWithoutRefetching() async throws {
        let transport = RoutedChangelogTransport(
            markdownBody: "# Remote notes\n\nNo-refetch body needle VICTOR.\n",
            entriesBody: slotEntriesJSON
        )
        let fixture = try ChangelogSlotFixture(transport: transport)
        defer { fixture.dispose() }
        try await fixture.beginAndAwaitPrefetch()
        #expect(transport.recordedRequests.count == 2)

        // The command path (the `.releaseNotes` intent's renderer arm)
        // serves the in-memory copy — the recorded divergence from
        // upstream's re-fetching command (release_notes.rs:26), kept for
        // the prefetch comment's stated intent (event_loop.rs:1811-1812).
        try await fixture.renderer.render(.overlay(.releaseNotes))
        #expect(await fixture.waitForPaint(of: "Release Notes"))
        #expect(await fixture.waitForPaint(of: "No-refetch body needle VICTOR."))
        #expect(
            transport.recordedRequests.count == 2,
            "the command must not add requests after the prefetch"
        )
        try await fixture.renderer.restoreTerminal()
    }

    @Test("no data paints no slot and hides nothing else")
    func noDataPaintsNoSlot() async throws {
        let fixture = try ChangelogSlotFixture(offline: true)
        defer { fixture.dispose() }
        try await fixture.beginAndAwaitPrefetch()

        // The welcome itself is up (Quit always paints) but the slot — and
        // the bare "Changelog" header the all-or-nothing rule forbids — is
        // absent (`changelog_height` collapses on empty, mod.rs:1748-1752).
        #expect(await fixture.waitForPaint(of: "Quit"))
        #expect(!fixture.paintedCompact().contains("Changelog"))
        try await fixture.renderer.restoreTerminal()
    }
}
