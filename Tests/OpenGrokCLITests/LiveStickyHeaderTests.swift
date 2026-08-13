// LiveStickyHeaderTests.swift
//
// Sticky-header integration through the LIVE seam (AGENTS.md §3): multiple
// completed turns + forced scroll publish last-painted header rows; PageUp
// subtracts header+2 via `pagerPageScrollRows`; pinned/gap clicks remap
// through the frozen sticky hit model; compact keeps rows=0 / old page;
// `$OPENGROK_HOME/pager.toml` `[scrollback.display].sticky_headers` (default
// true, no env, no settings row) gates the same geometry; scrollbar drag
// and timeline jump stay on logical offsets (no double-count).

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class StickyHeaderCapturingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

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

private struct StickyHeaderFixture {
    let home: URL
    let sink: StickyHeaderCapturingSink
    let renderer: LiveInteractiveControllerRenderer
    let terminalHeight: Int
    let terminalWidth: Int

    init(
        configTOML: String? = nil,
        pagerTOML: String? = nil,
        workingDirectory: URL? = nil,
        terminalHeight: Int = 28,
        terminalWidth: Int = 100,
        paintCadence: TimeInterval = PagerMotion.minimumPaintCadence
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-sticky-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let configTOML {
            try configTOML.write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        if let pagerTOML {
            try pagerTOML.write(
                to: home.appendingPathComponent("pager.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        self.terminalHeight = terminalHeight
        self.terminalWidth = terminalWidth
        let environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
        sink = StickyHeaderCapturingSink()
        let height = terminalHeight
        let width = terminalWidth
        let cwd = workingDirectory ?? home
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: width, height: height) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: cwd.path,
            modelName: "alpha-model",
            modelCatalog: [
                LiveModelPickerEntry(id: "alpha-model", providerID: "xai", name: "alpha-model"),
                LiveModelPickerEntry(id: "beta-model", providerID: "xai", name: "beta-model"),
            ],
            uiConfiguration: LiveInteractiveControllerRenderer.resolveUIConfig(
                workingDirectory: cwd,
                environment: environment
            ),
            sessionID: "sticky-header",
            openGrokHome: home,
            paintCadence: paintCadence,
            environment: environment
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    func flushIfNeeded() async {
        if await renderer.testingHasPendingFlushTask() {
            await renderer.testingFlushPendingFrameNow()
        }
    }

    /// Conversation viewport height from last-painted hit geometry (or the
    /// layout probe when a paint has not published a hit yet).
    func conversationViewportHeight() async -> Int {
        if let height = await renderer.lastConversationHit?.conversation.height, height > 0 {
            return height
        }
        return max(1, await renderer.testingLastConversationHeight())
    }

    /// Poll until `predicate` holds or timeout. Geometry-only — never scrapes
    /// sink text (follow-tail often shows assistant rows, not user prompts).
    func settle(
        timeout: TimeInterval = 5,
        _ predicate: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await predicate()
    }

    /// Several completed wrapping turns so forced scroll past a user prompt
    /// pins a sticky header (headerScreenRows > 0) with headroom for PageUp.
    ///
    /// Settles on scroll geometry probes only — never asserts prompt text is
    /// visible (bottom viewport frequently shows assistant content).
    /// - Parameter expectStickyHeader: when false (compact), settle only on
    ///   `!followsBottom` after pageUp; header rows stay 0.
    func seedTallTurns(count: Int = 8, expectStickyHeader: Bool = true) async throws {
        try await renderer.begin()
        for turn in 0..<count {
            let prompt = "sticky-user-\(turn) "
                + String(repeating: "prompt-wrap-\(turn) ", count: 20)
            let reply = "sticky-assistant-\(turn) "
                + String(repeating: "reply-wrap-\(turn) ", count: 28)
            try await renderer.render(.turnStarted(OpenGrokPagerRequest(
                prompt: prompt,
                mode: .fullScreen
            )))
            try await renderer.render(.session(.output(reply + "\n")))
            try await renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
                lifecycle: .completed,
                sessionID: nil,
                forwardedEventCount: 0,
                terminalRestored: false
            )))
        }
        // Drain coalesced flush so layout bookkeeping matches painted geometry.
        await flushIfNeeded()
        let overflowSettled = await settle {
            let hit = await self.renderer.lastConversationHit
            let maxOffset = await self.renderer.testingMaximumScrollOffset()
            let viewport = await self.conversationViewportHeight()
            return hit != nil && maxOffset > viewport
        }
        #expect(overflowSettled)
        #expect(await renderer.lastConversationHit != nil)
        let viewport = await conversationViewportHeight()
        #expect(await renderer.testingMaximumScrollOffset() > viewport)

        try await renderer.render(.viewport(.bottom))
        await flushIfNeeded()
        let atBottom = await settle {
            let follows = await self.renderer.testingFollowsBottom()
            let offset = await self.renderer.testingTranscriptScrollOffset()
            let maximum = await self.renderer.testingMaximumScrollOffset()
            return follows && offset == maximum && maximum > 0
        }
        #expect(atBottom)

        // Leave follow-tail so a sticky pin is painted (scroll past prompts).
        try await renderer.render(.viewport(.pageUp))
        await flushIfNeeded()
        let afterPageUp = await settle {
            let leftFollow = await !self.renderer.testingFollowsBottom()
            if !expectStickyHeader { return leftFollow }
            let headerRows = await self.renderer.testingLastHeaderScreenRows()
            return leftFollow && headerRows > 0
        }
        #expect(afterPageUp)
        #expect(await !renderer.testingFollowsBottom())
        if expectStickyHeader {
            #expect(await renderer.testingLastHeaderScreenRows() > 0)
        }
    }

    /// Walk logical offsets with real line scroll until `lastConversationHit`
    /// shows a pinned sticky (pushed-only after PageUp is legitimate — not a
    /// failure). Optionally require `gapRow` for the gap-click fixture.
    ///
    /// Bounded by `testingMaximumScrollOffset` steps per direction. Returns
    /// the painted hit at the found offset; callers assert entry/hit identity.
    @discardableResult
    func seekPinnedSticky(requireGap: Bool = false) async throws -> PagerConversationHitModel {
        func matches(_ hit: PagerConversationHitModel?) -> Bool {
            guard let hit, hit.sticky.pinned != nil else { return false }
            if requireGap { return hit.sticky.gapRow != nil }
            return true
        }

        await flushIfNeeded()
        if let hit = await renderer.lastConversationHit, matches(hit) {
            return hit
        }

        let maximum = await renderer.testingMaximumScrollOffset()

        // Cover [current → top], then [top → bottom] so pushed-only mid
        // states are skipped without treating them as errors.
        var upSteps = 0
        while upSteps <= maximum {
            let offset = await renderer.testingTranscriptScrollOffset()
            if offset <= 0 { break }
            try await renderer.render(.viewport(.lineUp))
            await flushIfNeeded()
            upSteps += 1
            if let hit = await renderer.lastConversationHit, matches(hit) {
                return hit
            }
        }

        var downSteps = 0
        while downSteps <= maximum {
            let offset = await renderer.testingTranscriptScrollOffset()
            let maxOffset = await renderer.testingMaximumScrollOffset()
            if offset >= maxOffset { break }
            try await renderer.render(.viewport(.lineDown))
            await flushIfNeeded()
            downSteps += 1
            if let hit = await renderer.lastConversationHit, matches(hit) {
                return hit
            }
        }

        let final = await renderer.lastConversationHit
        let pinned = final?.sticky.pinned
        let gap = final?.sticky.gapRow
        let gapSuffix = requireGap
            ? " (requireGap); gapRow=\(String(describing: gap))"
            : ""
        Issue.record(
            "no pinned sticky within max offset \(maximum)\(gapSuffix); last pinned=\(String(describing: pinned))"
        )
        return try #require(final.flatMap { matches($0) ? $0 : nil })
    }
}

private func pinnedHeaderPoint(
    in model: PagerConversationHitModel
) -> (entryIdx: Int, x: Int, y: Int)? {
    guard model.sticky.hasHeader,
          let pinned = model.sticky.pinned,
          let startRow = model.sticky.pinnedScreenRow,
          pinned.visibleHeight > 0
    else { return nil }
    let x = model.conversation.x + PagerLayoutMetrics.chromeWidth + 2
    let y = model.conversation.y + startRow
    guard model.blockIndex(atScreenY: y) == pinned.entryIdx else { return nil }
    return (pinned.entryIdx, x, y)
}

private func stickyGapPoint(
    in model: PagerConversationHitModel
) -> (x: Int, y: Int)? {
    guard let gap = model.sticky.gapRow else { return nil }
    let x = model.conversation.x + PagerLayoutMetrics.chromeWidth + 2
    let y = model.conversation.y + gap
    guard model.blockIndex(atScreenY: y) == nil else { return nil }
    return (x, y)
}

@Suite("Live sticky header", .serialized)
struct LiveStickyHeaderTests {
    @Test("forced scroll publishes sticky header rows > 0")
    func forcedScrollPublishesHeaderRows() async throws {
        let fixture = try StickyHeaderFixture()
        defer { fixture.dispose() }
        try await fixture.seedTallTurns()

        let headerRows = await fixture.renderer.testingLastHeaderScreenRows()
        #expect(headerRows > 0)
        #expect(await fixture.renderer.testingStickyHeadersEnabled() == true)
        let hit = try #require(await fixture.renderer.lastConversationHit)
        #expect(hit.sticky.hasHeader)
        #expect(hit.sticky.headerScreenRows == headerRows)
        #expect(fixture.sink.text.contains("sticky-user-"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("PageUp delta excludes sticky header and the 2-row overlap")
    func pageUpExcludesHeaderAndOverlap() async throws {
        let fixture = try StickyHeaderFixture()
        defer { fixture.dispose() }
        try await fixture.seedTallTurns()

        // Action-time snapshot (same path as PageUp) — not last-painted header.
        let expectedDelta = await fixture.renderer.testingCurrentPageScrollRows()
        #expect(expectedDelta >= 1)
        let headerRows = await fixture.renderer.testingCurrentHeaderScreenRows()
        #expect(headerRows > 0)

        let before = await fixture.renderer.testingTranscriptScrollOffset()
        #expect(before >= expectedDelta)
        try await fixture.renderer.render(.viewport(.pageUp))
        await fixture.flushIfNeeded()
        let after = await fixture.renderer.testingTranscriptScrollOffset()
        #expect(before - after == expectedDelta)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("PageUp uses action-time header under coalesced stale lastHeaderScreenRows")
    func pageUpUsesActionTimeHeaderWhenPaintCoalesced() async throws {
        // Long cadence: line scrolls fold without refreshing last-painted
        // header rows. PageUp must recompute from current scrollOffset.
        let fixture = try StickyHeaderFixture(paintCadence: 2.0)
        defer { fixture.dispose() }
        try await fixture.seedTallTurns()
        // Re-arm cadence from a fresh paint so the following lineUps coalesce.
        await fixture.flushIfNeeded()

        let paintedHeader = await fixture.renderer.testingLastHeaderScreenRows()
        #expect(paintedHeader > 0)

        // Walk toward a less-collapsed pin without flushing paint caches.
        let maximum = await fixture.renderer.testingMaximumScrollOffset()
        var foundLarger = false
        for _ in 0..<maximum {
            let offset = await fixture.renderer.testingTranscriptScrollOffset()
            if offset <= 0 { break }
            try await fixture.renderer.render(.viewport(.lineUp))
            // Do not flush — leave lastHeaderScreenRows at the painted value.
            let currentHeader = await fixture.renderer.testingCurrentHeaderScreenRows()
            if currentHeader > paintedHeader {
                foundLarger = true
                break
            }
        }
        #expect(foundLarger)

        let stalePainted = await fixture.renderer.testingLastHeaderScreenRows()
        #expect(stalePainted == paintedHeader)

        let currentHeader = await fixture.renderer.testingCurrentHeaderScreenRows()
        #expect(currentHeader > stalePainted)
        let expectedDelta = await fixture.renderer.testingCurrentPageScrollRows()
        // Same snapshot pair page scroll uses (viewport + header together).
        let staleDelta = pagerPageScrollRows(
            viewportHeight: max(1, await fixture.renderer.testingLastConversationHeight()),
            headerScreenRows: stalePainted
        )
        // Larger action-time header → smaller page stride than stale paint.
        #expect(expectedDelta < staleDelta)

        let before = await fixture.renderer.testingTranscriptScrollOffset()
        #expect(before >= expectedDelta)
        try await fixture.renderer.render(.viewport(.pageUp))
        let after = await fixture.renderer.testingTranscriptScrollOffset()
        #expect(before - after == expectedDelta)
        await fixture.flushIfNeeded()
        try await fixture.renderer.restoreTerminal()
    }

    @Test("half-page uses full viewport height / 2 (Rust half_page_*, not content band)")
    func halfPageUsesFullViewport() async throws {
        let fixture = try StickyHeaderFixture()
        defer { fixture.dispose() }
        try await fixture.seedTallTurns()

        let headerRows = await fixture.renderer.testingLastHeaderScreenRows()
        #expect(headerRows > 0)
        let viewport = await fixture.renderer.testingLastConversationHeight()
        // Rust `half_page_up`: `viewport_height / 2` — full conversation
        // rect, not `contentHeight/2` after sticky subtraction.
        let expectedHalf = max(1, viewport / 2)

        let before = await fixture.renderer.testingTranscriptScrollOffset()
        #expect(before >= expectedHalf)
        try await fixture.renderer.render(.viewport(.halfPageUp))
        await fixture.flushIfNeeded()
        let after = await fixture.renderer.testingTranscriptScrollOffset()
        #expect(before - after == expectedHalf)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("click pinned sticky header selects that user block")
    func pinnedHeaderClickSelectsUser() async throws {
        let fixture = try StickyHeaderFixture()
        defer { fixture.dispose() }
        try await fixture.seedTallTurns()

        // PageUp may land pushed-only; walk until a pinned header exists.
        let model = try await fixture.seekPinnedSticky()
        let pinned = try #require(model.sticky.pinned)
        let point = try #require(pinnedHeaderPoint(in: model))
        #expect(point.entryIdx == pinned.entryIdx)
        #expect(model.blockIndex(atScreenY: point.y) == pinned.entryIdx)

        let down = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: point.x, y: point.y, button: .left
        )))
        #expect(down == .consumed)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == nil)

        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: point.x, y: point.y, button: .left
        )))
        #expect(up == .focusScrollback)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == pinned.entryIdx)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("click sticky gap does not select")
    func stickyGapClickIsNoOp() async throws {
        let fixture = try StickyHeaderFixture()
        defer { fixture.dispose() }
        try await fixture.seedTallTurns()

        let model = try await fixture.seekPinnedSticky(requireGap: true)
        #expect(model.sticky.pinned != nil)
        let gapRow = try #require(model.sticky.gapRow)
        let point = try #require(stickyGapPoint(in: model))
        #expect(point.y == model.conversation.y + gapRow)
        #expect(model.blockIndex(atScreenY: point.y) == nil)

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: point.x, y: point.y, button: .left
        )))
        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: point.x, y: point.y, button: .left
        )))
        #expect(up == .consumed)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == nil)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("pending click freeze still selects via sticky hit snapshot")
    func pendingClickFreezeUsesStickySnapshot() async throws {
        let fixture = try StickyHeaderFixture()
        defer { fixture.dispose() }
        try await fixture.seedTallTurns()

        let model = try await fixture.seekPinnedSticky()
        let pinned = try #require(model.sticky.pinned)
        let point = try #require(pinnedHeaderPoint(in: model))
        #expect(point.entryIdx == pinned.entryIdx)
        #expect(model.blockIndex(atScreenY: point.y) == pinned.entryIdx)

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: point.x, y: point.y, button: .left
        )))
        // Scroll away before up — completion remaps the frozen down snapshot,
        // not live geometry (same pending_scrollback_click rule).
        try await fixture.renderer.render(.viewport(.pageDown))
        await fixture.flushIfNeeded()

        let up = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .up, x: point.x, y: point.y, button: .left
        )))
        #expect(up == .focusScrollback)
        #expect(await fixture.renderer.testingScrollbackSelectedIndex() == pinned.entryIdx)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("compact mode keeps header rows 0 and old page delta (viewport - 2)")
    func compactKeepsOldPageSemantics() async throws {
        let fixture = try StickyHeaderFixture(configTOML: "[ui]\ncompact_mode = true\n")
        defer { fixture.dispose() }
        // Compact: settle pageUp on offset/follow only — header stays 0.
        try await fixture.seedTallTurns(expectStickyHeader: false)

        let headerRows = await fixture.renderer.testingCurrentHeaderScreenRows()
        #expect(headerRows == 0)
        #expect(await fixture.renderer.testingLastHeaderScreenRows() == 0)
        let hit = try #require(await fixture.renderer.lastConversationHit)
        #expect(!hit.sticky.hasHeader)

        let expectedDelta = await fixture.renderer.testingCurrentPageScrollRows()
        let viewport = await fixture.renderer.testingLastConversationHeight()
        #expect(expectedDelta == max(1, max(0, viewport - 2)))

        let before = await fixture.renderer.testingTranscriptScrollOffset()
        #expect(before >= expectedDelta)
        try await fixture.renderer.render(.viewport(.pageUp))
        await fixture.flushIfNeeded()
        let after = await fixture.renderer.testingTranscriptScrollOffset()
        #expect(before - after == expectedDelta)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("absent pager.toml sticky_headers defaults true on the live renderer")
    func absentPagerTomlDefaultsTrue() async throws {
        let fixture = try StickyHeaderFixture()
        defer { fixture.dispose() }
        #expect(await fixture.renderer.testingStickyHeadersEnabled() == true)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("malformed sticky_headers diagnostic reaches a live system note")
    func malformedStickyHeadersDiagnosticIsVisible() async throws {
        let fixture = try StickyHeaderFixture(pagerTOML: """
        [scrollback.display]
        sticky_headers = "nope"
        """)
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        #expect(await fixture.renderer.testingStickyHeadersEnabled() == true)
        let notes = await fixture.renderer.testingSystemMessageTexts()
        #expect(notes.contains { $0.contains("sticky_headers") })
        #expect(fixture.sink.text.contains("sticky_headers"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("absent sticky_headers key does not emit a diagnostic note")
    func absentStickyHeadersKeyIsSilent() async throws {
        let fixture = try StickyHeaderFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        let notes = await fixture.renderer.testingSystemMessageTexts()
        #expect(!notes.contains { $0.contains("sticky_headers") })
        try await fixture.renderer.restoreTerminal()
    }

    @Test("pager.toml sticky_headers false disables pin, page, and hit geometry")
    func pagerTomlFalseDisablesSticky() async throws {
        let fixture = try StickyHeaderFixture(pagerTOML: """
        [scrollback.display]
        sticky_headers = false
        """)
        defer { fixture.dispose() }
        #expect(await fixture.renderer.testingStickyHeadersEnabled() == false)
        try await fixture.seedTallTurns(expectStickyHeader: false)

        #expect(await fixture.renderer.testingCurrentHeaderScreenRows() == 0)
        #expect(await fixture.renderer.testingLastHeaderScreenRows() == 0)
        let hit = try #require(await fixture.renderer.lastConversationHit)
        #expect(!hit.sticky.hasHeader)
        #expect(hit.sticky.pinned == nil)
        #expect(hit.sticky.pushed == nil)
        #expect(hit.sticky.headerScreenRows == 0)

        let expectedDelta = await fixture.renderer.testingCurrentPageScrollRows()
        let viewport = await fixture.renderer.testingLastConversationHeight()
        #expect(expectedDelta == max(1, max(0, viewport - 2)))

        let before = await fixture.renderer.testingTranscriptScrollOffset()
        #expect(before >= expectedDelta)
        try await fixture.renderer.render(.viewport(.pageUp))
        await fixture.flushIfNeeded()
        let after = await fixture.renderer.testingTranscriptScrollOffset()
        #expect(before - after == expectedDelta)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("pager.toml sticky_headers true enables sticky headers")
    func pagerTomlTrueEnablesSticky() async throws {
        let fixture = try StickyHeaderFixture(pagerTOML: """
        [scrollback.display]
        sticky_headers = true
        """)
        defer { fixture.dispose() }
        #expect(await fixture.renderer.testingStickyHeadersEnabled() == true)
        try await fixture.seedTallTurns()
        #expect(await fixture.renderer.testingLastHeaderScreenRows() > 0)
        let hit = try #require(await fixture.renderer.lastConversationHit)
        #expect(hit.sticky.hasHeader)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("compact overrides pager.toml sticky_headers true")
    func compactOverridesPagerTomlTrue() async throws {
        let fixture = try StickyHeaderFixture(
            configTOML: "[ui]\ncompact_mode = true\n",
            pagerTOML: """
            [scrollback.display]
            sticky_headers = true
            """
        )
        defer { fixture.dispose() }
        #expect(await fixture.renderer.testingStickyHeadersEnabled() == true)
        try await fixture.seedTallTurns(expectStickyHeader: false)
        #expect(await fixture.renderer.testingCurrentHeaderScreenRows() == 0)
        let hit = try #require(await fixture.renderer.lastConversationHit)
        #expect(!hit.sticky.hasHeader)
        let expectedDelta = await fixture.renderer.testingCurrentPageScrollRows()
        let viewport = await fixture.renderer.testingLastConversationHeight()
        #expect(expectedDelta == max(1, max(0, viewport - 2)))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("config.toml [ui] sticky_headers is not the authority")
    func uiConfigTomlDoesNotGateSticky() async throws {
        // Pin stores the key in pager.toml, not config.toml `[ui]`.
        let fixture = try StickyHeaderFixture(configTOML: """
        [ui]
        sticky_headers = false
        """)
        defer { fixture.dispose() }
        #expect(await fixture.renderer.testingStickyHeadersEnabled() == true)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("project .opengrok/pager.toml does not override $OPENGROK_HOME")
    func projectPagerTomlIsNotAuthority() async throws {
        let fixture = try StickyHeaderFixture()
        defer { fixture.dispose() }

        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-sticky-proj-\(UUID().uuidString)", isDirectory: true)
        let projectConfig = project.appendingPathComponent(".opengrok", isDirectory: true)
        try FileManager.default.createDirectory(at: projectConfig, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try """
        [scrollback.display]
        sticky_headers = false
        """.write(
            to: projectConfig.appendingPathComponent("pager.toml"),
            atomically: true,
            encoding: .utf8
        )

        let environment = ["HOME": fixture.home.path, "OPENGROK_HOME": fixture.home.path]
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 28) },
                write: { _ in }
            ),
            sink: StickyHeaderCapturingSink(),
            workingDirectory: project.path,
            modelName: "alpha-model",
            uiConfiguration: LiveInteractiveControllerRenderer.resolveUIConfig(
                workingDirectory: project,
                environment: environment
            ),
            sessionID: "sticky-project",
            openGrokHome: fixture.home,
            environment: environment
        )
        #expect(await renderer.testingStickyHeadersEnabled() == true)
        try await renderer.restoreTerminal()
    }

    @Test("settings overlay has no sticky_headers row")
    func noSettingsRow() async throws {
        let fixture = try StickyHeaderFixture()
        defer { fixture.dispose() }
        let overlay = await fixture.renderer.settingsOverlay()
        #expect(overlay.registry.find("sticky_headers") == nil)
        let visibleKeys = Set(overlay.visibleRows.compactMap(\.settingKey))
        #expect(!visibleKeys.contains("sticky_headers"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("scrollbar drag uses logical offset; no header double-count")
    func scrollbarDragNoHeaderDoubleCount() async throws {
        let fixture = try StickyHeaderFixture()
        defer { fixture.dispose() }
        try await fixture.seedTallTurns()
        // Return to bottom so the gutter publishes, then settle.
        try await fixture.renderer.render(.viewport(.bottom))
        await fixture.flushIfNeeded()

        let sb = try #require(await fixture.renderer.lastScrollbarHit)
        let midY = sb.rect.y + max(1, sb.rect.height / 2)

        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: sb.rect.x, y: sb.rect.y, button: .left
        )))
        let afterPaint = try #require(await fixture.renderer.lastScrollbarHit)
        // Hit model maps track Y → logical scrollOffset (sticky band does
        // not rescale the thumb). Live apply must match that formula.
        let expectedMid = afterPaint.offset(atScreenY: midY)
        _ = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .drag, x: afterPaint.rect.x, y: midY, button: .left
        )))
        let offset = await fixture.renderer.testingTranscriptScrollOffset()
        #expect(offset == expectedMid)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("timeline rail tick jump uses logical offset without header adjust")
    func timelineJumpNoHeaderDoubleCount() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-sticky-rail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try "[ui]\nshow_timeline = true\n".write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let store = LiveConversationStore(openGrokHome: home)
        var record = LiveConversationRecord.new(sessionID: "sticky-rail", workingDirectory: home)
        record.items = [
            .user("alpha sticky rail question"),
            .assistant(AssistantItem(
                content: (0..<30).map { "afill \($0)" }.joined(separator: "\n\n")
            )),
            .user("zebra sticky rail question"),
            .assistant(AssistantItem(
                content: (0..<30).map { "bfill \($0)" }.joined(separator: "\n\n")
            )),
        ]
        try await store.save(record)
        let history = LiveConversationHistory(record: record, store: store)

        let environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
        let sink = StickyHeaderCapturingSink()
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
            sessionID: "sticky-rail",
            conversationHistory: history,
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment
        )
        try await renderer.begin()
        try await renderer.render(.sessionResumed(sessionID: "sticky-rail"))
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

        let before = await renderer.testingTranscriptScrollOffset()
        // Same pinned rail tick geometry as LiveTimelineTests (x=98, y=13).
        // Rail → revealBlock uses logical block starts; sticky must not be
        // subtracted again on the live side.
        let routing = try await renderer.handleInput(.mouse(MouseEvent(
            kind: .down, x: 98, y: 13, button: .left
        )))
        #expect(routing == .consumed)
        if await renderer.testingHasPendingFlushTask() {
            await renderer.testingFlushPendingFrameNow()
        }
        let after = await renderer.testingTranscriptScrollOffset()
        #expect(after != before)
        #expect(await !renderer.testingFollowsBottom())
        let hit = try #require(await renderer.lastConversationHit)
        // Painted hit model and live offset agree on the logical scroll
        // (not scrollForContent / header-adjusted).
        #expect(hit.scrollOffset == after)
        #expect(await renderer.testingScrollbackSelectedIndex() == nil)
        try await renderer.restoreTerminal()
    }

    @Test("append and resize recompute last-painted sticky header rows")
    func appendAndResizeRecompute() async throws {
        let fixture = try StickyHeaderFixture(terminalHeight: 28)
        defer { fixture.dispose() }
        try await fixture.seedTallTurns(count: 6)

        let before = await fixture.renderer.testingLastHeaderScreenRows()
        #expect(before > 0)
        let maxBefore = await fixture.renderer.testingMaximumScrollOffset()
        let hitBefore = try #require(await fixture.renderer.lastConversationHit)
        let blockCountBefore = hitBefore.blockStartLines.count

        // Append more body under follow-off so layout heights change and a
        // fresh paint republishes header rows. Settle on geometry — not
        // sink text (append may land below the viewport).
        try await fixture.renderer.testingAppendConversationItem(
            .message(PagerMessage(
                role: .assistant,
                text: (0..<40).map { "sticky-resize-fill-\($0)" }.joined(separator: "\n")
            ))
        )
        await fixture.flushIfNeeded()
        let appendSettled = await fixture.settle {
            let hit = await fixture.renderer.lastConversationHit
            guard let hit else { return false }
            let maxOffset = await fixture.renderer.testingMaximumScrollOffset()
            let headerRows = await fixture.renderer.testingLastHeaderScreenRows()
            return hit.blockStartLines.count == blockCountBefore + 1
                && maxOffset >= maxBefore
                && headerRows == hit.sticky.headerScreenRows
        }
        #expect(appendSettled)

        let afterAppend = await fixture.renderer.testingLastHeaderScreenRows()
        let hitAfter = try #require(await fixture.renderer.lastConversationHit)
        #expect(afterAppend == hitAfter.sticky.headerScreenRows)
        #expect(hitAfter.blockStartLines.count == blockCountBefore + 1)

        // Forced re-scroll after growth still republishes a consistent cache.
        try await fixture.renderer.render(.viewport(.pageUp))
        await fixture.flushIfNeeded()
        let pageSettled = await fixture.settle {
            let leftFollow = await !fixture.renderer.testingFollowsBottom()
            let headerRows = await fixture.renderer.testingLastHeaderScreenRows()
            let hit = await fixture.renderer.lastConversationHit
            return leftFollow
                && headerRows > 0
                && hit?.sticky.headerScreenRows == headerRows
        }
        #expect(pageSettled)
        let afterPage = await fixture.renderer.testingLastHeaderScreenRows()
        let hitPage = try #require(await fixture.renderer.lastConversationHit)
        #expect(afterPage == hitPage.sticky.headerScreenRows)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("Home / bottom / line scroll ignore sticky header subtraction")
    func homeBottomLineUnchanged() async throws {
        let fixture = try StickyHeaderFixture()
        defer { fixture.dispose() }
        try await fixture.seedTallTurns()

        let headerRows = await fixture.renderer.testingLastHeaderScreenRows()
        #expect(headerRows > 0)
        let mid = await fixture.renderer.testingTranscriptScrollOffset()

        try await fixture.renderer.render(.viewport(.lineUp))
        await fixture.flushIfNeeded()
        #expect(await fixture.renderer.testingTranscriptScrollOffset() == mid - 1)

        try await fixture.renderer.render(.viewport(.lineDown))
        await fixture.flushIfNeeded()
        #expect(await fixture.renderer.testingTranscriptScrollOffset() == mid)

        try await fixture.renderer.render(.viewport(.top))
        await fixture.flushIfNeeded()
        #expect(await fixture.renderer.testingTranscriptScrollOffset() == 0)
        #expect(await !fixture.renderer.testingFollowsBottom())

        try await fixture.renderer.render(.viewport(.bottom))
        await fixture.flushIfNeeded()
        let maxOffset = await fixture.renderer.testingMaximumScrollOffset()
        #expect(await fixture.renderer.testingTranscriptScrollOffset() == maxOffset)
        #expect(await fixture.renderer.testingFollowsBottom())
        try await fixture.renderer.restoreTerminal()
    }
}
