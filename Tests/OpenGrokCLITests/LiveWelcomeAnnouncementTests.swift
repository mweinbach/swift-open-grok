// LiveWelcomeAnnouncementTests.swift
//
// B2-W3 through the LIVE seam (AGENTS.md §3): the welcome hero's
// announcement arm fed by the REAL announcements pipeline (mock /v1/settings
// transport → real fetch → real cache → the same slot selection the chrome
// banner paints), with the expand toggle and the upgrade CTA asserted
// through real clicks on the published rects.
//
// Upstream reference at pin 650c1db7: the hero slot selection
// (`app/app_view.rs:4937-4964`), click-toggles-expansion (`:4389-4395`),
// the CTA dispatch re-resolving through the slot gate
// (`:4349-4355` → `dispatch/router.rs:1006-1018`), and the arbitration
// ("the announcement takes priority over the changelog",
// `views/welcome/hero_box.rs:349-378`).

import Foundation
import OpenGrokAnnouncements
import OpenGrokHTTP
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

// MARK: - Fixtures

private final class AnnouncementCapturingSink: PagerTerminalSink, CustomReflectable,
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

/// The live renderer plus a REAL announcements composition over a hermetic
/// home: the mock transport serves one `/v1/settings` payload, the real
/// fetch caches it, and `refreshAnnouncementBanner()` (the same seam
/// production's refresh drives) publishes the slot selection to both the
/// chrome state and the open welcome.
private struct WelcomeAnnouncementFixture {
    let home: URL
    let sink: AnnouncementCapturingSink
    let renderer: LiveInteractiveControllerRenderer
    let announcements: LiveAnnouncementsComposition

    init(
        settingsPayload: Data,
        seededChangelogJSON: String? = nil,
        seededChangelogMarkdown: String? = nil,
        openBrowser: (@Sendable (URL) -> Void)? = nil
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opengrok-welcome-ann-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let seededChangelogJSON {
            try seededChangelogJSON.write(
                to: home.appendingPathComponent("CHANGELOG.json"),
                atomically: true,
                encoding: .utf8
            )
        }
        if let seededChangelogMarkdown {
            try seededChangelogMarkdown.write(
                to: home.appendingPathComponent("CHANGELOG.md"),
                atomically: true,
                encoding: .utf8
            )
        }
        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            // The changelog prefetch stays on its deterministic cache-only
            // arm; these tests own the announcements pipeline instead.
            "GROK_CHANGELOG_OFFLINE": "1",
        ]
        announcements = LiveAnnouncementsComposition.live(
            transport: MockHTTPTransport(responses: [
                .init(metadata: HTTPResponseMetadata(statusCode: 200), body: settingsPayload)
            ]),
            openGrokHome: home,
            environment: environment,
            provider: .xai,
            proxyBaseURL: "https://cli-chat-proxy.example.com/v1"
        )
        sink = AnnouncementCapturingSink()
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
            sessionID: "welcome-ann-live",
            openGrokHome: home,
            announcements: announcements,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment,
            authServices: LivePagerAuthServices(
                makeTransport: { URLSessionHTTPTransport() },
                codexBrowserLogin: { _, _, _, _ in throw CancellationError() },
                openBrowser: openBrowser
            )
        )
    }

    /// begin() pushes the welcome; the awaited refresh + the renderer's
    /// refresh seam then land the slot selection deterministically (the
    /// production path is the same calls, spawned).
    func beginAndDeliverAnnouncements() async throws {
        try await renderer.begin()
        _ = try await announcements.refreshAndWait()
        await renderer.refreshAnnouncementBanner()
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
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

    func welcomeRow(_ rowID: String) async -> PagerOverlayBounds.Row? {
        await renderer.lastOverlayBounds
            .last { $0.id == LiveInteractiveControllerRenderer.welcomeOverlayID }?
            .rows.first { $0.id == rowID }
    }

    func waitForWelcomeRow(
        _ rowID: String,
        minimumHeight: Int = 0,
        maximumHeight: Int? = nil,
        timeout: TimeInterval = 5
    ) async -> PagerOverlayBounds.Row? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let row = await welcomeRow(rowID),
               row.frame.height >= minimumHeight,
               maximumHeight.map({ row.frame.height <= $0 }) ?? true {
                return row
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let row = await welcomeRow(rowID),
              row.frame.height >= minimumHeight,
              maximumHeight.map({ row.frame.height <= $0 }) ?? true
        else {
            return nil
        }
        return row
    }

    func click(_ row: PagerOverlayBounds.Row) async throws -> OpenGrokPagerInputRouting? {
        try await renderer.handleInput(.mouse(MouseEvent(
            kind: .down,
            x: row.frame.x + min(2, max(0, row.frame.width - 1)),
            y: row.frame.y
        )))
    }
}

private func promoPayload(
    message: String,
    ctaLabel: String = "Upgrade now",
    ctaURL: String = "https://x.ai/upgrade-welcome-test"
) -> Data {
    let object: [String: Any] = [
        "gen": 5,
        "announcements": [[
            "id": "promo-welcome-1",
            "severity": "promo",
            "message": message,
            "dismissible": true,
            "cta": ["label": ctaLabel, "url": ctaURL, "caption": ""],
        ]],
    ]
    return try! JSONSerialization.data(withJSONObject: object)
}

private let arbitrationChangelogJSON = #"""
[{"category": "features", "description": "Suppressed bullet WHISKEY", "breaking_change": false}]
"""#

// MARK: - Tests

@Suite("welcome announcement live seam", .serialized)
struct LiveWelcomeAnnouncementTests {
    @Test("the real pipeline's announcement owns the slot and suppresses the changelog")
    func announcementOwnsTheSlotOverChangelog() async throws {
        let fixture = try WelcomeAnnouncementFixture(
            settingsPayload: promoPayload(message: "Hero promo needle XRAY"),
            seededChangelogJSON: arbitrationChangelogJSON,
            seededChangelogMarkdown: "# notes\n\nbody\n"
        )
        defer { fixture.dispose() }
        try await fixture.beginAndDeliverAnnouncements()

        #expect(await fixture.waitForPaint(of: "Hero promo needle XRAY"))
        #expect(await fixture.waitForPaint(of: "[Upgrade now]"))
        // Arbitration (`hero_box.rs:349-378`): the announcement owns the
        // CURRENT frame's slot — its rects are published and the changelog's
        // are not. (The changelog arm legitimately paints BEFORE the
        // announcements land — upstream shows the same until its fetch
        // fills — and this sink accumulates bytes, so a `!contains` on the
        // cumulative paint would fail on that honest earlier frame; the
        // never-both pin on a single frame lives in
        // PagerWelcomeAnnouncementPaintTests.)
        #expect(await fixture.welcomeRow(PagerWelcomeOverlay.announcementCTARowID) != nil)
        #expect(await fixture.welcomeRow(PagerWelcomeOverlay.changelogCTARowID) == nil)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("an empty feed falls back to the W2 changelog arm")
    func emptyFeedFallsBackToChangelog() async throws {
        let empty = try JSONSerialization.data(withJSONObject: [
            "gen": 5, "announcements": [[String: Any]](),
        ])
        let fixture = try WelcomeAnnouncementFixture(
            settingsPayload: empty,
            seededChangelogJSON: arbitrationChangelogJSON,
            seededChangelogMarkdown: "# notes\n\nbody\n"
        )
        defer { fixture.dispose() }
        try await fixture.beginAndDeliverAnnouncements()

        #expect(await fixture.waitForPaint(of: "Changelog"))
        #expect(await fixture.waitForPaint(of: "Suppressed bullet WHISKEY"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("clicking the announcement toggles inline expansion, both directions")
    func clickTogglesExpansion() async throws {
        // Long enough to truncate at width 110 (collapsed = 2 wrapped
        // lines), so the block's row is published and click-toggles.
        let long = (1...12)
            .map { "Sentence \($0) of a deliberately long announcement body." }
            .joined(separator: " ")
        let fixture = try WelcomeAnnouncementFixture(
            settingsPayload: promoPayload(message: long)
        )
        defer { fixture.dispose() }
        try await fixture.beginAndDeliverAnnouncements()
        let collapsed = try #require(
            await fixture.waitForWelcomeRow(PagerWelcomeOverlay.announcementRowID)
        )
        // Expand: the block's published frame grows (`:4389-4395` toggle;
        // the tail text becomes reachable).
        #expect(try await fixture.click(collapsed) == .consumed)
        let expanded = try #require(
            await fixture.waitForWelcomeRow(
                PagerWelcomeOverlay.announcementRowID,
                minimumHeight: collapsed.frame.height + 1
            )
        )
        #expect(expanded.frame.height > collapsed.frame.height)

        // Collapse: the frame shrinks back. (The capturing sink accumulates
        // bytes, so "tail absent" cannot be asserted post-hoc — the frame
        // height is the observable that can shrink.)
        #expect(try await fixture.click(expanded) == .consumed)
        let recollapsed = try #require(
            await fixture.waitForWelcomeRow(
                PagerWelcomeOverlay.announcementRowID,
                maximumHeight: collapsed.frame.height
            )
        )
        #expect(recollapsed.frame.height == collapsed.frame.height)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("the upgrade CTA click re-resolves through the slot gate and opens the URL")
    func ctaClickOpensTheResolvedURL() async throws {
        let opened = OpenedURLBox()
        let fixture = try WelcomeAnnouncementFixture(
            settingsPayload: promoPayload(
                message: "CTA promo",
                ctaURL: "https://x.ai/upgrade-welcome-test"
            ),
            openBrowser: { opened.append($0) }
        )
        defer { fixture.dispose() }
        try await fixture.beginAndDeliverAnnouncements()
        #expect(await fixture.waitForPaint(of: "[Upgrade now]"))

        let cta = try #require(
            await fixture.welcomeRow(PagerWelcomeOverlay.announcementCTARowID)
        )
        #expect(try await fixture.click(cta) == .consumed)
        // The dispatch re-resolved the target through the live slot gate
        // (`router.rs:1006-1018`) and opened it on the browser seam.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, opened.all.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(opened.all.map(\.absoluteString) == ["https://x.ai/upgrade-welcome-test"])
        try await fixture.renderer.restoreTerminal()
    }
}
