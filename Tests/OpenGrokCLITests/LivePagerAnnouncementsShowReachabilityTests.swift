// LivePagerAnnouncementsShowReachabilityTests.swift
//
// `/announcements` at both seams (AGENTS.md §3), now with the `show` arm.
// Composition seam: the conditional registration (copy verbatim from
// `slash/commands/announcements.rs:16-22`), the first-token dispatch
// (`announcements.rs:57-63`) and the byte-exact usage error
// (`announcements.rs:6`). Live seam: typed input through the REAL
// controller into the REAL `LiveAnnouncementsComposition` over the REAL
// persisted hide-key store in an isolated `$OPENGROK_HOME` — hide lands the
// key on disk (`router.rs:974-990`), show removes it (`router.rs:991-1005`)
// and the banner repaints through the real renderer. Un-hiding is a
// persisted store mutation, not a transient repaint; these tests assert it
// where it lands, on the state file.

import Foundation
import OpenGrokAnnouncements
@testable import OpenGrokCLI
import OpenGrokHTTP
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTerminalCore
import Testing

@Suite("/announcements at the composition seam")
struct LivePagerAnnouncementsCommandTests {
    @Test("the row exists iff a live surface exists, copy verbatim")
    func registrationGateAndCopy() throws {
        let rows = LiveAnnouncementsSlashCommand.registrations(surfaceAvailable: true)
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        // announcements.rs:12-14.
        #expect(row.name == "announcements")
        // announcements.rs:16-18.
        #expect(row.summary == "Show or hide announcements")
        // announcements.rs:20-22.
        #expect(row.usage == "/announcements hide | show")

        // No surface, no row (§4: never a dead dropdown entry). This gate
        // deliberately diverges from upstream's has-session-announcements
        // visibility — see the note on `registrations`.
        #expect(LiveAnnouncementsSlashCommand.registrations(surfaceAvailable: false).isEmpty)
    }

    @Test("the usage error is upstream's copy, byte-exact")
    func usageCopyIsByteExact() {
        // announcements.rs:6.
        #expect(LiveAnnouncementsSlashCommand.usageMessage == "Usage: /announcements hide | show")
    }

    @Test("dispatch takes the first whitespace token; everything else is the usage error")
    func firstTokenDispatch() async {
        // The arm is proven by which notice comes back with no surface
        // installed: hide/show reach their arms ("no announcement to …"),
        // anything else falls to the usage error — upstream's
        // `run_subcommands` / `run_invalid_or_empty_shows_usage`
        // (announcements.rs:87-115).
        func run(_ tail: String) async -> PagerLocalCommandOutcome {
            await LiveAnnouncementsSlashCommand.run(
                rawArgumentTail: tail,
                surface: nil,
                refreshBanner: {}
            )
        }
        #expect(await run("hide") == .notice("no announcement to hide"))
        #expect(await run("  hide  ") == .notice("no announcement to hide"))
        #expect(await run("hide extra") == .notice("no announcement to hide"))
        #expect(await run("show") == .notice("no announcement to show"))
        #expect(await run("show everything") == .notice("no announcement to show"))
        for invalid in ["", "foo", "next", "prev"] {
            #expect(
                await run(invalid) == .notice("Usage: /announcements hide | show"),
                "expected the usage error for \(String(reflecting: invalid))"
            )
        }
    }
}

@Suite("/announcements live seam", .serialized)
struct LivePagerAnnouncementsShowReachabilityTests {
    @Test("typed /announcements hide lands the hide key on the real persisted store")
    func typedHidePersistsTheKey() async throws {
        let fixture = try await AnnouncementsSlashFixture.withFetchedFeed()
        defer { fixture.dispose() }
        // Seed the composition's selection the way the composition does at
        // startup (the renderer's initial banner pull).
        let before = await fixture.composition.refreshVisibleBanner()
        #expect(before != nil, "the feed did not surface a banner to hide")

        try await fixture.runController(submitting: ["/announcements hide"])

        // The store mutation, asserted where it lands: the hide key is in
        // the state file the next launch reads.
        let hidden = fixture.hiddenIDsOnDisk()
        #expect(hidden.contains("crit-1"), "the hide key never reached the persisted store")
        #expect(await fixture.composition.currentBanner() == nil)
        #expect(await fixture.waitForPaint(of: "announcement hidden"))
    }

    @Test("typed /announcements show clears the keys on disk and repaints the banner")
    func typedShowClearsTheStoreAndRepaints() async throws {
        let fixture = try await AnnouncementsSlashFixture.withFetchedFeed()
        defer { fixture.dispose() }
        // Pre-hide through the same real store writer the hide arm uses, so
        // this test starts from the persisted-hidden state a re-launch would
        // see. This fixture's sink has never painted the banner, so its
        // appearance below can only come from the show arm's repaint.
        let visible = await fixture.composition.refreshVisibleBanner()
        #expect(visible != nil)
        let afterHide = await fixture.composition.hideCurrent()
        #expect(afterHide == nil, "hiding the only announcement did not close the slot")
        #expect(fixture.hiddenIDsOnDisk().contains("crit-1"))

        try await fixture.runController(submitting: ["/announcements show"])

        // Un-hiding is a persisted store mutation (router.rs:991-1005): the
        // key is gone from the file, not just from a repainted frame.
        #expect(
            !fixture.hiddenIDsOnDisk().contains("crit-1"),
            "the hide key survived /announcements show on disk"
        )
        #expect(await fixture.composition.currentBanner() != nil)
        // The banner repaints through the real renderer: title and message
        // reach the captured sink only after the show arm ran.
        #expect(await fixture.waitForPaint(of: "Outage"))
        #expect(await fixture.waitForPaint(of: "Do not deploy"))
        #expect(await fixture.waitForPaint(of: "announcement shown"))
    }

    @Test("typed bare /announcements paints upstream's usage error, byte-exact copy")
    func typedBarePaintsUsage() async throws {
        let fixture = try await AnnouncementsSlashFixture.withFetchedFeed()
        defer { fixture.dispose() }
        try await fixture.runController(submitting: ["/announcements"])
        #expect(await fixture.waitForPaint(of: "Usage: /announcements hide | show"))
    }
}

// MARK: - Fixture

/// The live `/announcements` slash surface: a real composition over a mock
/// `/v1/settings` feed, the real renderer painting into a captured sink,
/// and the real controller driven by typed input — with the command
/// registered and dispatched through the SAME `LiveAnnouncementsSlashCommand`
/// helpers the interactive composition installs.
private struct AnnouncementsSlashFixture {
    let home: URL
    let environment: [String: String]
    let composition: LiveAnnouncementsComposition
    let sink: AnnouncementsCapturingSink
    let renderer: LiveInteractiveControllerRenderer

    static func withFetchedFeed() async throws -> AnnouncementsSlashFixture {
        let fixture = try AnnouncementsSlashFixture()
        // The awaitable refresh — same gates, fetch, and cache write as the
        // production spawn, but the test sees completion.
        let cache = try await fixture.composition.refreshAndWait()
        #expect(cache?.announcements.count == 1, "the feed never reached the cache")
        return fixture
    }

    private init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opengrok-ann-slash-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
        ]

        // One dismissible critical on the wire, the shape
        // `AnnouncementsRefreshed` decodes.
        let payload = try JSONSerialization.data(withJSONObject: [
            "gen": 3,
            "announcements": [[
                "id": "crit-1",
                "severity": "critical",
                "title": "Outage",
                "message": "Do not deploy",
                "dismissible": true,
            ]],
        ] as [String: Any])
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: payload)
        ])
        composition = LiveAnnouncementsComposition.live(
            transport: transport,
            openGrokHome: home,
            environment: environment,
            provider: .xai,
            proxyBaseURL: "https://cli-chat-proxy.example.com/v1"
        )

        sink = AnnouncementsCapturingSink()
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
            sessionID: "announcements-live",
            openGrokHome: home,
            announcements: composition,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    /// The persisted hide-key set, read from the file itself — the store
    /// the next launch reads, not any in-memory mirror.
    func hiddenIDsOnDisk() -> Set<String> {
        let url = announcementStateURL(environment: environment)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            return []
        }
        return parseHiddenAnnouncementIDs(text)
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

    /// Run the REAL controller with typed input. Registration and dispatch
    /// are the same `LiveAnnouncementsSlashCommand` calls the interactive
    /// composition makes, over this fixture's real composition and renderer.
    func runController(submitting lines: [String]) async throws {
        var events: [InputEvent] = []
        for line in lines {
            events.append(.paste(line))
            events.append(.key(KeyEvent(key: .escape)))
            events.append(.key(KeyEvent(key: .enter)))
        }
        let composition = composition
        let renderer = renderer
        let controller = OpenGrokPagerInteractiveController(
            input: AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            },
            runtime: AnnouncementsUnusedRuntime(),
            renderer: renderer,
            output: AnnouncementsDiscardingOutput(),
            localCommands: LiveAnnouncementsSlashCommand.registrations(surfaceAvailable: true),
            localCommandHandler: { invocation in
                await LiveAnnouncementsSlashCommand.run(
                    rawArgumentTail: OpenGrokPagerInteractiveController
                        .rawArgumentTail(of: invocation),
                    surface: composition,
                    refreshBanner: { await renderer.refreshAnnouncementBanner() }
                )
            }
        )
        _ = try await controller.run(.init(prompt: "", mode: .inline))
    }
}

private final class AnnouncementsCapturingSink: PagerTerminalSink, CustomReflectable,
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
    /// Testing dumps the whole byte buffer as decimal text.
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

private struct AnnouncementsUnusedRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw CancellationError()
    }
}

private struct AnnouncementsDiscardingOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}
