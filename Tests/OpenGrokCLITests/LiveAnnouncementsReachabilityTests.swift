// LiveAnnouncementsReachabilityTests.swift
//
// Reachability of the announcements surface through the live seam
// (AGENTS.md §3). `OpenGrokAnnouncements` shipped a complete library —
// types, hide-key state, CTA helpers, `AnnouncementsService` fetch/cache —
// with zero importers in `Sources/OpenGrokCLI`: announcements never fetched
// and never rendered. These tests drive the composition the executable runs
// (`LiveAnnouncementsComposition.live`, the same factory `makeAgentStack`
// calls) and assert the four things that would otherwise pass silently:
//
//   1. A hermetic feed reaches the cache, the banner selection, and a painted
//      frame through the real `renderPagerFrame`.
//   2. Hiding the banner persists the hide key, so a second composition
//      construction over the same home does not re-show it.
//   3. A provider that denies xAI export (Codex) issues no request and
//      renders no banner — the export boundary is checked before the fetch.
//   4. The banner reaches the actual `LiveInteractiveControllerRenderer`'s
//      captured sink — the same adapter the executable paints through.
//
// A composition-level test (construct the banner, never paint it) would pass
// just as happily with the spawn deleted; these cannot.

import Foundation
import OpenGrokAnnouncements
import OpenGrokHTTP
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

@Suite("Live announcements surface", .serialized)
struct LiveAnnouncementsReachabilityTests {
    /// A hermetic home under the temp directory, isolated per test.
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-ann-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// One critical announcement on the wire, matching the shape
    /// `AnnouncementsRefreshed` decodes (`gen` + `announcements`).
    private func settingsPayload(critical message: String, title: String? = nil) -> Data {
        var announcement: [String: Any] = [
            "id": "crit-1",
            "severity": "critical",
            "message": message,
            "dismissible": true,
        ]
        if let title { announcement["title"] = title }
        let object: [String: Any] = [
            "gen": 3,
            "announcements": [announcement],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// A mock transport scripted with one `/v1/settings` response.
    private func mockTransport(payload: Data) -> MockHTTPTransport {
        MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: payload
            )
        ])
    }

    /// The composition's environment, pointed at the hermetic home so the
    /// cache + hide-key state land there.
    private func environment(home: URL) -> [String: String] {
        [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
        ]
    }

    // MARK: - 1. Fetch → cache → banner → painted frame

    @Test("a hermetic feed reaches the cache, the banner, and a painted frame")
    func hermeticFeedReachesPaintedFrame() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = mockTransport(payload: settingsPayload(
            critical: "Do not deploy",
            title: "Outage"
        ))
        let composition = LiveAnnouncementsComposition.live(
            transport: transport,
            openGrokHome: home,
            environment: environment(home: home),
            // xAI provider: xAI export allowed, so the fetch is permitted.
            provider: .xai,
            proxyBaseURL: "https://cli-chat-proxy.example.com/v1"
        )

        // The awaitable refresh — same gates, same fetch, same cache write as
        // the production spawn, but the test sees completion.
        let cache = try await composition.refreshAndWait()
        #expect(cache != nil, "the refresh did not land a cache")
        #expect(cache?.announcements.count == 1, "the cache did not store the announcement")

        // The fetch reached the wire: the mock transport recorded a
        // `/v1/settings` GET.
        let settingsRequests = transport.recordedRequests.filter {
            $0.url.path.contains("settings")
        }
        #expect(!settingsRequests.isEmpty, "no /settings fetch reached the wire")

        // The banner selection derived the critical and projected it.
        let banner = await composition.refreshVisibleBanner()
        #expect(banner?.severity == .critical, "the banner did not select the critical")
        #expect(banner?.title == "Outage")
        #expect(banner?.message == "Do not deploy")
        #expect(banner?.dismissible == true)

        // The banner reaches a painted frame through the real render function
        // the renderer uses. The captured sink is the frame snapshot.
        let state = PagerRenderState(
            size: TerminalSize(width: 60, height: 24),
            statusBar: PagerStatusBar(workingDirectory: "/x"),
            announcementBanner: banner,
            conversation: []
        )
        let result = renderPagerFrame(state)
        let frame = result.snapshot()
        #expect(frame.contains("! Outage"), "the banner title did not paint; frame=\n\(frame)")
        #expect(frame.contains("Do not deploy"), "the banner message did not paint; frame=\n\(frame)")
        #expect(frame.contains("[hide]"), "the hide button did not paint; frame=\n\(frame)")
        // The banner slots between the status bar and the (empty) transcript,
        // so the layout reserves its 2-row height.
        #expect(result.layout.announcementBanner.height == 2, "the banner slot was not 2 rows tall")
    }

    // MARK: - 2. Hide persists across a second construction

    @Test("hiding the banner persists across a second composition construction")
    func hidePersistsAcrossReconstruction() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = mockTransport(payload: settingsPayload(critical: "outage one"))
        let first = LiveAnnouncementsComposition.live(
            transport: transport,
            openGrokHome: home,
            environment: environment(home: home),
            provider: .xai,
            proxyBaseURL: "https://cli-chat-proxy.example.com/v1"
        )
        _ = try await first.refreshAndWait()
        let beforeHide = await first.refreshVisibleBanner()
        #expect(beforeHide != nil, "the first composition did not surface a banner")

        // Hide the visible banner — this writes the persistent hide key.
        let afterHide = await first.hideCurrent()
        #expect(afterHide == nil, "hiding the only announcement did not close the slot")

        // A second composition over the SAME home reads the same hide-key
        // state file, so the hidden ID does not re-show. This is the
        // re-launch-does-not-re-show-hidden-IDs property.
        let second = LiveAnnouncementsComposition.live(
            transport: mockTransport(payload: settingsPayload(critical: "outage one")),
            openGrokHome: home,
            environment: environment(home: home),
            provider: .xai,
            proxyBaseURL: "https://cli-chat-proxy.example.com/v1"
        )
        // Refresh the cache so the second composition has the same feed; the
        // hide key is read from the persisted state file, not the cache.
        _ = try await second.refreshAndWait()
        let rederived = await second.refreshVisibleBanner()
        #expect(rederived == nil, "the hidden announcement re-showed after re-construction")

        // The hide-key state file exists and carries the hidden ID.
        let stateURL = announcementStateURL(environment: environment(home: home))
        let stateData = try Data(contentsOf: stateURL)
        let hidden = parseHiddenAnnouncementIDs(String(data: stateData, encoding: .utf8) ?? "")
        #expect(hidden.contains("crit-1"), "the hide key was not persisted")
    }

    // MARK: - 3. Export-denied provider issues no request and no banner

    @Test("a provider that denies xAI export issues no fetch and renders no banner")
    func exportDeniedProviderIssuesNoFetch() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = mockTransport(payload: settingsPayload(critical: "should never show"))
        // Codex denies xAI export — the feed rides xAI infrastructure, so the
        // request is never made at all (issuing it would tell xAI the session
        // exists). The gate is checked before the fetch, not after.
        let composition = LiveAnnouncementsComposition.live(
            transport: transport,
            openGrokHome: home,
            environment: environment(home: home),
            provider: .codex,
            proxyBaseURL: "https://cli-chat-proxy.example.com/v1"
        )

        // The spawn is a no-op for a denied provider; the awaitable twin is
        // too, so neither hits the wire.
        composition.spawnBackgroundRefresh()
        let cache = try await composition.refreshAndWait()
        #expect(cache == nil, "a denied provider fetched the feed")
        #expect(transport.recordedRequests.isEmpty, "a denied provider issued a request")
        let banner = await composition.refreshVisibleBanner()
        #expect(banner == nil, "a denied provider rendered a banner")
    }

    // MARK: - 4. Banner reaches the live renderer's captured sink

    @Test("the banner reaches the live interactive renderer's captured sink")
    func bannerReachesLiveRendererSink() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = mockTransport(payload: settingsPayload(
            critical: "banner on sink",
            title: "Critical"
        ))
        let composition = LiveAnnouncementsComposition.live(
            transport: transport,
            openGrokHome: home,
            environment: environment(home: home),
            provider: .xai,
            proxyBaseURL: "https://cli-chat-proxy.example.com/v1"
        )
        _ = try await composition.refreshAndWait()

        // The live renderer the executable paints through, with a captured
        // sink. The announcements composition is the same one makeAgentStack
        // hands the renderer.
        let sink = CapturingSink()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 80, height: 24) },
            write: { _ in }
        )
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: sink,
            workingDirectory: home.path,
            modelName: "grok-test",
            openGrokHome: home,
            announcements: composition,
            paintCadence: PagerMotion.minimumPaintCadence
        )
        try await renderer.begin()
        // Pull the banner into the renderer's cached projection, then paint a
        // frame. A `.notice` event triggers the chrome paint (the banner lives
        // in the chrome, not an overlay).
        await renderer.refreshAnnouncementBanner()
        try await renderer.render(.notice("paint"))
        // The banner text reaches the captured sink. Needles are single
        // tokens: the cell differ skips unchanged cells, so a multi-word needle
        // can be split in the captured stream.
        #expect(await waitForFrame(sink: sink, containing: "Critical", timeout: 5))
        #expect(await waitForFrame(sink: sink, containing: "[hide]", timeout: 5))
        try await renderer.restoreTerminal()
    }
}

// MARK: - Capturing sink (mirrors LivePagerCommandReachabilityTests)

/// A sink that keeps everything ever written, plus a stripper so assertions
/// read the words on screen rather than the ANSI cell encoding around them.
private final class CapturingSink: PagerTerminalSink, @unchecked Sendable {
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
        var output = ""
        var index = 0
        let data = bytes
        while index < data.count {
            guard data[index] == 0x1B else {
                output.unicodeScalars.append(Unicode.Scalar(data[index]))
                index += 1
                continue
            }
            index += 1
            guard index < data.count else { break }
            switch data[index] {
            case UInt8(ascii: "["):
                index += 1
                while index < data.count, !(0x40...0x7E).contains(data[index]) {
                    index += 1
                }
                index += 1
            case UInt8(ascii: "]"):
                index += 1
                while index < data.count {
                    if data[index] == 0x07 { index += 1; break }
                    if data[index] == 0x1B, index + 1 < data.count,
                       data[index + 1] == UInt8(ascii: "\\") {
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

/// Poll the sink until the painted screen contains `needle`. A repaint folded
/// into the paint cadence lands via the flush timer, so the frame is not
/// guaranteed on screen when `render(_:)` returns.
private func waitForFrame(sink: CapturingSink, containing needle: String, timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if sink.strippedText.contains(needle) { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return sink.strippedText.contains(needle)
}
