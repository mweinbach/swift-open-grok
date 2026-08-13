// LiveScrollStreamTests.swift
//
// Sole live scroll-normalizer integration through
// `LiveInteractiveControllerRenderer` (AGENTS.md §3): injected monotonic
// times, no sleeps. Overflow via `testingMaximumScrollOffset`. Forced
// `.wheel` follows the 16 ms redraw cadence (no `justPromoted`), so notch
// assertions sum event + dedicated scroll-clock tick lines and match a
// pure `MouseScrollState` reference with the same priced config. Tests
// call `testingResetMouseScrollState(at:)` before `sec(...)` gestures;
// production keeps the uptime-initialized state. Project+user reset
// coverage asserts re-resolve into config, open modal seed, and behavior.

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class ScrollStreamCapturingSink: PagerTerminalSink, @unchecked Sendable {
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

private struct ScrollStreamFixture {
    let home: URL
    let projectRoot: URL
    let sink: ScrollStreamCapturingSink
    let renderer: LiveInteractiveControllerRenderer

    init(
        configTOML: String? = nil,
        projectConfigTOML: String? = nil,
        environmentExtras: [String: String] = [:],
        terminalProgram: String? = "Apple_Terminal"
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opengrok-scroll-stream-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let configTOML {
            try configTOML.write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        projectRoot = home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        if let projectConfigTOML {
            let opengrok = projectRoot.appendingPathComponent(".opengrok", isDirectory: true)
            try FileManager.default.createDirectory(at: opengrok, withIntermediateDirectories: true)
            try projectConfigTOML.write(
                to: opengrok.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        // Resolve against the project cwd whenever a project config is planted
        // so authority merge includes `.opengrok/config.toml`.
        let cwd = projectConfigTOML == nil ? home : projectRoot
        sink = ScrollStreamCapturingSink()
        var environment: [String: String] = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
        ]
        if let terminalProgram {
            environment["TERM_PROGRAM"] = terminalProgram
        }
        for (key, value) in environmentExtras {
            environment[key] = value
        }
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: cwd.path,
            modelName: "alpha-model",
            modelCatalog: [
                LiveModelPickerEntry(id: "alpha-model", providerID: "xai", name: "alpha-model"),
                LiveModelPickerEntry(id: "beta-model", providerID: "xai", name: "beta-model"),
            ],
            terminalProgram: terminalProgram,
            uiConfiguration: LiveInteractiveControllerRenderer.resolveUIConfig(
                workingDirectory: cwd,
                environment: environment
            ),
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment
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
        return sink.text.filter { !$0.isWhitespace }.contains(compact)
    }
}

private func withScrollFixture(
    configTOML: String? = nil,
    projectConfigTOML: String? = nil,
    environmentExtras: [String: String] = [:],
    terminalProgram: String? = "Apple_Terminal",
    _ body: (ScrollStreamFixture) async throws -> Void
) async throws {
    let fixture = try ScrollStreamFixture(
        configTOML: configTOML,
        projectConfigTOML: projectConfigTOML,
        environmentExtras: environmentExtras,
        terminalProgram: terminalProgram
    )
    do {
        try await body(fixture)
        try await fixture.renderer.restoreTerminal()
        fixture.dispose()
    } catch {
        try? await fixture.renderer.restoreTerminal()
        fixture.dispose()
        throw error
    }
}

/// Build deterministic transcript overflow via many completed user/assistant
/// turns (separate blocks, long wrapping bodies). Overflow is proven through
/// `testingMaximumScrollOffset`, not by scraping off-screen sink bytes —
/// the alt-screen only holds the visible viewport.
private func seedTallTranscript(_ fixture: ScrollStreamFixture) async throws {
    let renderer = fixture.renderer
    // Width-100 terminal: ~30-word lines wrap to multiple rows per turn.
    // Twelve turns >> one viewport of conversation rows.
    for turn in 0..<12 {
        let prompt = "scroll-user-\(turn) "
            + String(repeating: "prompt-wrap-\(turn) ", count: 24)
        let reply = "scroll-assistant-\(turn) "
            + String(repeating: "reply-wrap-\(turn) ", count: 32)
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
    // Drain a coalesced flush so painted geometry matches layout bookkeeping.
    if await renderer.testingHasPendingFlushTask() {
        await renderer.testingFlushPendingFrameNow()
    }
    let maxOffset = await renderer.testingMaximumScrollOffset()
    #expect(maxOffset > 40)
    try await parkMidViewport(renderer)
}

/// Leave follow-tail via real viewport events with verified headroom above
/// and below (`testingMaximumScrollOffset` − offset). Re-park after settings
/// commits so a prior gesture that re-engaged follow-tail cannot poison the
/// next wheel assertion.
private func parkMidViewport(_ renderer: LiveInteractiveControllerRenderer) async throws {
    let maxBefore = await renderer.testingMaximumScrollOffset()
    #expect(maxBefore > 20)
    try await renderer.render(.viewport(.bottom))
    #expect(await renderer.testingFollowsBottom())
    // One page-up from the bottom leaves ~one viewport of room below and
    // (with max > 20) room above for signed invert assertions.
    try await renderer.render(.viewport(.pageUp))
    #expect(await !renderer.testingFollowsBottom())
    let offset = await renderer.testingTranscriptScrollOffset()
    let maxOffset = await renderer.testingMaximumScrollOffset()
    #expect(offset > 10)
    #expect(maxOffset - offset > 10)
}

/// Pure-normalizer reference for the same priced config + timestamps the
/// live seam uses. Forced `.wheel` does not `justPromoted`-flush, so three
/// 1 ms reports often return 0 until cadence ticks — that is pinned behavior.
private func pureNotchTotal(
    config: ScrollConfig,
    direction: ScrollDirection,
    originMs: Int
) -> Int {
    // Same epoch as `testingResetMouseScrollState(at: sec(originMs))`.
    var state = MouseScrollState(now: sec(originMs))
    var total = 0
    var now = sec(originMs)
    for step in 0..<3 {
        let update = state.onScrollEvent(now: now, direction: direction, config: config)
        total += update.lines
        now = sec(originMs + step + 1)
    }
    now = sec(originMs + 2)
    for _ in 0..<64 {
        guard state.hasActiveStream, let delay = state.deadline(now: now) else { break }
        now += max(delay, 0.001)
        let update = state.onTick(now: now)
        total += update.lines
    }
    return total
}

/// Drive one Apple-profile wheel notch (3 reports) then drain the dedicated
/// scroll-clock ticks at returned deadlines. Returns total applied lines
/// across events + ticks (status asserted at every step).
private func applyWheelNotch(
    _ renderer: LiveInteractiveControllerRenderer,
    direction: ScrollDirection,
    originMs: Int
) async throws -> Int {
    // Align last-redraw epoch with injected `sec(...)` (production uses
    // uptime; tests must reset explicitly before deterministic clocks).
    await renderer.testingResetMouseScrollState(at: sec(originMs))
    var total = 0
    var eventLines: [Int] = []
    for step in 0..<3 {
        let lines = try await renderer.testingApplyTranscriptScroll(
            direction: direction,
            at: sec(originMs + step)
        )
        eventLines.append(lines)
        total += lines
    }
    #expect(eventLines.count == 3)
    var now = sec(originMs + 2)
    var tickLines: [Int] = []
    for _ in 0..<64 {
        guard await renderer.testingHasActiveScrollStream() else { break }
        guard let delay = await renderer.testingScrollClockDeadline(at: now) else { break }
        now += max(delay, 0.001)
        let lines = try await renderer.testingHandleScrollClockTick(at: now)
        tickLines.append(lines)
        total += lines
    }
    // Every status was captured into eventLines/tickLines (no drops).
    #expect(eventLines.reduce(0, +) + tickLines.reduce(0, +) == total)
    return total
}

/// Seconds helper matching `MouseScrollState`'s `TimeInterval` clock.
private func sec(_ ms: Int) -> TimeInterval {
    TimeInterval(ms) / 1000.0
}

@Suite("Live scroll stream normalizer", .serialized)
struct LiveScrollStreamTests {
    @Test("3-event auto stream prices 3 lines through the live renderer")
    func threeEventWheelStreamLines() async throws {
        try await withScrollFixture { fixture in
            let renderer = fixture.renderer
            try await renderer.begin()
            try await seedTallTranscript(fixture)
            #expect(await !renderer.testingFollowsBottom())
            let config = await renderer.testingPricedScrollConfig()
            #expect(config.mode == .auto)
            #expect(config.eventsPerTick == 3)
            #expect(config.wheelLinesPerTick == 3)
            #expect(!config.invertDirection)
            let before = await renderer.testingTranscriptScrollOffset()

            // Auto + ept=3 promotes on the 3rd report and flushes immediately
            // (`justPromoted`) — no cadence tick required.
            await renderer.testingResetMouseScrollState(at: sec(1))
            let l1 = try await renderer.testingApplyTranscriptScroll(direction: .down, at: sec(1))
            #expect(l1 == 0)
            let l2 = try await renderer.testingApplyTranscriptScroll(direction: .down, at: sec(2))
            #expect(l2 == 0)
            #expect(await renderer.testingTranscriptScrollOffset() == before)
            let l3 = try await renderer.testingApplyTranscriptScroll(direction: .down, at: sec(3))
            #expect(l3 == 3)
            #expect(await renderer.testingTranscriptScrollOffset() == before + 3)
            #expect(await renderer.testingHasActiveScrollStream())
            #expect(l1 + l2 + l3 == pureNotchTotal(
                config: config, direction: .down, originMs: 1
            ))
        }
    }

    @Test("trackpad residual drains on scroll-clock tick; protocol deadline/tick exercised")
    func trackpadResidualTickViaProtocol() async throws {
        try await withScrollFixture { fixture in
            let renderer = fixture.renderer
            try await renderer.begin()
            try await seedTallTranscript(fixture)
            await renderer.testingApplySetting(.commit(key: "scroll_mode", value: .string("trackpad")))
            let config = await renderer.testingPricedScrollConfig()
            #expect(config.mode == .trackpad)
            #expect(config.eventsPerTick == 3)
            #expect(await !renderer.testingHasActiveScrollStream())
            try await parkMidViewport(renderer)

            let before = await renderer.testingTranscriptScrollOffset()
            await renderer.testingResetMouseScrollState(at: sec(1))
            var eventLines = 0
            for i in 0..<8 {
                let lines = try await renderer.testingApplyTranscriptScroll(
                    direction: .down,
                    at: sec(1 + i * 2)
                )
                eventLines += lines
            }
            #expect(await renderer.testingHasActiveScrollStream())
            let afterEvents = await renderer.testingTranscriptScrollOffset()
            #expect(afterEvents == before + eventLines)
            let atLastEvent = sec(1 + 7 * 2)
            let deadline = await renderer.testingScrollClockDeadline(at: atLastEvent)
            #expect(deadline != nil)
            let tickAt = atLastEvent + max(deadline ?? 0.02, 0.001)

            let tickLines = try await renderer.testingHandleScrollClockTick(at: tickAt)
            let afterTick = await renderer.testingTranscriptScrollOffset()
            #expect(afterTick == afterEvents + tickLines)
            #expect(afterTick > before)
            let next = await renderer.testingScrollClockDeadline(at: tickAt)
            if await renderer.testingHasActiveScrollStream() {
                #expect(next != nil)
            } else {
                #expect(next == nil)
            }
        }
    }

    @Test("invert_scroll live commit flips signed delivery")
    func invertScrollLiveCommit() async throws {
        try await withScrollFixture { fixture in
            let renderer = fixture.renderer
            try await renderer.begin()
            try await seedTallTranscript(fixture)
            await renderer.testingApplySetting(.commit(key: "scroll_mode", value: .string("wheel")))
            #expect(await !renderer.testingHasActiveScrollStream())
            try await parkMidViewport(renderer)
            #expect(await !renderer.testingFollowsBottom())

            let config = await renderer.testingPricedScrollConfig()
            #expect(config.mode == .wheel)
            #expect(config.eventsPerTick == 3)
            #expect(config.wheelLinesPerTick == 3)
            #expect(!config.invertDirection)
            // Forced wheel skips promote-flush; event+tick total must match pure.
            let expectedDown = pureNotchTotal(config: config, direction: .down, originMs: 1_000)
            #expect(expectedDown == 3)

            let mid = await renderer.testingTranscriptScrollOffset()
            let downLines = try await applyWheelNotch(renderer, direction: .down, originMs: 1_000)
            #expect(downLines == expectedDown)
            let afterDown = await renderer.testingTranscriptScrollOffset()
            #expect(afterDown == mid + downLines)
            #expect(await !renderer.testingFollowsBottom())

            await renderer.testingApplySetting(.commit(key: "invert_scroll", value: .bool(true)))
            let inverted = await renderer.testingPricedScrollConfig()
            #expect(inverted.invertDirection)
            #expect(inverted.mode == .wheel)
            #expect(inverted.eventsPerTick == 3)
            #expect(inverted.wheelLinesPerTick == 3)
            #expect(await !renderer.testingHasActiveScrollStream())
            #expect(await !renderer.testingFollowsBottom())
            #expect(await renderer.testingTranscriptScrollOffset() == afterDown)
            #expect(afterDown > 3)

            // Fresh monotonic origin after cancelStream on rebuild.
            let expectedUp = pureNotchTotal(config: inverted, direction: .down, originMs: 2_000)
            #expect(expectedUp == -3)
            let upLines = try await applyWheelNotch(renderer, direction: .down, originMs: 2_000)
            #expect(upLines == expectedUp)
            let afterInvert = await renderer.testingTranscriptScrollOffset()
            #expect(afterInvert == afterDown + upLines)
            #expect(afterInvert == mid)
        }
    }

    @Test("speed/lines/mode live commit then next wheel uses rebuilt config; reset restores profile")
    func liveCommitAndResetRestoreProfile() async throws {
        try await withScrollFixture { fixture in
            let renderer = fixture.renderer
            try await renderer.begin()
            try await seedTallTranscript(fixture)

            let profile = await renderer.testingPricedScrollConfig()
            #expect(profile.mode == .auto)
            #expect(profile.eventsPerTick == 3)
            #expect(profile.wheelLinesPerTick == 3)
            #expect(!profile.invertDirection)
            #expect(profile.speedMultiplier == mouseScrollSpeedToMultiplier(50))

            await renderer.testingApplySetting(.commit(key: "scroll_mode", value: .string("wheel")))
            await renderer.testingApplySetting(.commit(key: "scroll_lines", value: .integer(1)))
            await renderer.testingApplySetting(.commit(key: "scroll_speed", value: .integer(50)))
            let overridden = await renderer.testingPricedScrollConfig()
            #expect(overridden.mode == .wheel)
            #expect(overridden.eventsPerTick == 3)
            #expect(overridden.wheelLinesPerTick == 1)
            #expect(overridden.trackpadLinesPerTick == 1)
            #expect(!overridden.invertDirection)
            #expect(await !renderer.testingHasActiveScrollStream())

            try await parkMidViewport(renderer)
            #expect(await !renderer.testingFollowsBottom())
            let expectedOne = pureNotchTotal(config: overridden, direction: .down, originMs: 1_000)
            #expect(expectedOne == 1)
            let before = await renderer.testingTranscriptScrollOffset()
            // ept=3 + wheel + 1 line/tick → events may return 0; ticks deliver 1.
            let applied = try await applyWheelNotch(renderer, direction: .down, originMs: 1_000)
            #expect(applied == expectedOne)
            #expect(await renderer.testingTranscriptScrollOffset() == before + 1)
            #expect(await !renderer.testingFollowsBottom())

            await renderer.testingApplySetting(.resetRequested(key: "scroll_lines"))
            await renderer.testingApplySetting(.resetRequested(key: "scroll_mode"))
            await renderer.testingApplySetting(.resetRequested(key: "scroll_speed"))
            let restored = await renderer.testingPricedScrollConfig()
            #expect(restored.mode == .auto)
            #expect(restored.eventsPerTick == profile.eventsPerTick)
            #expect(restored.wheelLinesPerTick == profile.wheelLinesPerTick)
            #expect(restored.trackpadLinesPerTick == profile.trackpadLinesPerTick)
            #expect(abs(restored.speedMultiplier - profile.speedMultiplier) < 0.0001)
            #expect(await !renderer.testingHasActiveScrollStream())

            // Profile auto notch promotes on the 3rd report (immediate +3).
            try await parkMidViewport(renderer)
            let afterReset = await renderer.testingTranscriptScrollOffset()
            let expectedProfile = pureNotchTotal(
                config: restored, direction: .down, originMs: 3_000
            )
            #expect(expectedProfile == 3)
            let profileLines = try await applyWheelNotch(
                renderer, direction: .down, originMs: 3_000
            )
            #expect(profileLines == expectedProfile)
            #expect(await renderer.testingTranscriptScrollOffset() == afterReset + 3)
        }
    }

    @Test("capturing overlay cancels active transcript stream and keeps one-row selection")
    func modalCancelsAndQuarantinesStream() async throws {
        try await withScrollFixture { fixture in
            let renderer = fixture.renderer
            try await renderer.begin()
            try await seedTallTranscript(fixture)

            await renderer.testingResetMouseScrollState(at: sec(1))
            let e1 = try await renderer.testingApplyTranscriptScroll(direction: .down, at: sec(1))
            #expect(e1 == 0)
            let e2 = try await renderer.testingApplyTranscriptScroll(direction: .down, at: sec(2))
            #expect(e2 == 0)
            #expect(await renderer.testingHasActiveScrollStream())
            #expect(await renderer.testingScrollClockDeadline(at: sec(2)) != nil)

            try await renderer.render(.overlay(.modelPicker(query: nil)))
            #expect(await fixture.waitForPaint(containing: "alpha-model (current)"))

            let offsetWithOverlay = await renderer.testingTranscriptScrollOffset()
            let selectedBefore = try #require(await renderer.testingFocusedOverlaySelectedIndex())
            let focusedID = try #require(await renderer.testingFocusedOverlayID())
            let focused = try #require(
                await renderer.lastOverlayBounds.last(where: { $0.id == focusedID })
            )

            // Deadline while capturing must disarm and cancel the stream.
            #expect(await renderer.testingScrollClockDeadline(at: sec(10)) == nil)
            #expect(await !renderer.testingHasActiveScrollStream())

            let inside = try await renderer.handleInput(.mouse(MouseEvent(
                kind: .scrollDown,
                x: focused.frame.x + focused.frame.width / 2,
                y: focused.frame.y + focused.frame.height / 2,
                button: MouseEvent.noButton
            )))
            #expect(inside == .consumed)
            #expect(await renderer.testingTranscriptScrollOffset() == offsetWithOverlay)
            #expect(await renderer.testingFocusedOverlaySelectedIndex() == selectedBefore + 1)
            #expect(await !renderer.testingHasActiveScrollStream())
            #expect(await renderer.testingScrollClockDeadline(at: sec(11)) == nil)
        }
    }

    @Test("suspend and restore cancel stream and disarm scroll-clock deadline")
    func suspendAndRestoreDisarmDeadline() async throws {
        try await withScrollFixture { fixture in
            let renderer = fixture.renderer
            try await renderer.begin()
            try await seedTallTranscript(fixture)

            await renderer.testingResetMouseScrollState(at: sec(1))
            let s1 = try await renderer.testingApplyTranscriptScroll(direction: .down, at: sec(1))
            #expect(s1 == 0)
            let s2 = try await renderer.testingApplyTranscriptScroll(direction: .down, at: sec(2))
            #expect(s2 == 0)
            #expect(await renderer.testingScrollClockDeadline(at: sec(2)) != nil)
            #expect(await renderer.testingHasActiveScrollStream())

            await renderer.testingSuspendScrollClock()
            #expect(await renderer.testingLocalMotionHold())
            #expect(await renderer.testingScrollClockDeadline(at: sec(3)) == nil)
            #expect(await !renderer.testingHasActiveScrollStream())
            // Tick while held must not flush (no child-screen paint).
            let offsetAtHold = await renderer.testingTranscriptScrollOffset()
            let heldTick = try await renderer.testingHandleScrollClockTick(at: sec(100))
            #expect(heldTick == 0)
            #expect(await renderer.testingTranscriptScrollOffset() == offsetAtHold)

            await renderer.testingResumeScrollClock()
            // Stream stays cancelled after resume — needs a new wheel event.
            #expect(await renderer.testingScrollClockDeadline(at: sec(4)) == nil)

            await renderer.testingResetMouseScrollState(at: sec(5))
            let r1 = try await renderer.testingApplyTranscriptScroll(direction: .down, at: sec(5))
            #expect(r1 == 0)
            let r2 = try await renderer.testingApplyTranscriptScroll(direction: .down, at: sec(6))
            #expect(r2 == 0)
            #expect(await renderer.testingHasActiveScrollStream())

            try await renderer.restoreTerminal()
            #expect(await renderer.testingRestored())
            #expect(await renderer.testingScrollClockDeadline(at: sec(7)) == nil)
            #expect(await !renderer.testingHasActiveScrollStream())
        }
    }

    @Test("initial UiConfig hydration reads scroll fields into live config")
    func initialHydrationReadsScrollFields() async throws {
        let toml = """
        [ui]
        scroll_speed = 1
        scroll_mode = "wheel"
        scroll_lines = 2
        invert_scroll = true
        """
        try await withScrollFixture(configTOML: toml) { fixture in
            let config = await fixture.renderer.testingScrollConfig()
            #expect(config.mode == .wheel)
            #expect(config.wheelLinesPerTick == 2)
            #expect(config.trackpadLinesPerTick == 2)
            #expect(config.invertDirection)
            #expect(abs(config.speedMultiplier - mouseScrollSpeedToMultiplier(1)) < 0.0001)
        }
    }

    @Test("reset of user scroll_lines re-resolves project value into config, modal, and wheel behavior")
    func projectScrollRevealedAfterUserReset() async throws {
        // Project layer wins over user in effective merge for the same key;
        // the live settings commit still updates the actor (and user file)
        // until a successful reset re-resolves effective `[ui]`.
        let projectTOML = """
        [ui]
        scroll_mode = "wheel"
        scroll_lines = 5
        """
        try await withScrollFixture(projectConfigTOML: projectTOML) { fixture in
            let renderer = fixture.renderer
            let cold = await renderer.testingScrollConfig()
            #expect(cold.mode == .wheel)
            #expect(cold.wheelLinesPerTick == 5)
            #expect(cold.trackpadLinesPerTick == 5)
            #expect(!cold.invertDirection)

            try await renderer.begin()
            try await seedTallTranscript(fixture)

            await renderer.testingApplySetting(
                .commit(key: "scroll_lines", value: .integer(1))
            )
            await renderer.testingApplySetting(
                .commit(key: "invert_scroll", value: .bool(true))
            )
            let overridden = await renderer.testingPricedScrollConfig()
            #expect(overridden.mode == .wheel)
            #expect(overridden.wheelLinesPerTick == 1)
            #expect(overridden.trackpadLinesPerTick == 1)
            #expect(overridden.invertDirection)
            #expect(await !renderer.testingHasActiveScrollStream())

            try await parkMidViewport(renderer)
            #expect(await !renderer.testingFollowsBottom())
            // Sibling invert stays armed: wheel-down prices negative (up).
            let expectedOne = pureNotchTotal(
                config: overridden, direction: .down, originMs: 1_000
            )
            #expect(expectedOne == -1)
            let before = await renderer.testingTranscriptScrollOffset()
            #expect(before > 1) // upward room for the inverted 1-line notch
            let appliedOne = try await applyWheelNotch(
                renderer, direction: .down, originMs: 1_000
            )
            #expect(appliedOne == expectedOne)
            #expect(await renderer.testingTranscriptScrollOffset() == before - 1)

            // Assert against the OPEN modal (§3) — a fresh settingsOverlay()
            // would re-seed and hide a missed syncOpenSettings… call.
            try await renderer.render(.overlay(.settings(deepLinkKey: "scroll_lines")))
            #expect(await renderer.openSettingsRowValue(forKey: "scroll_lines") == .integer(1))
            #expect(await renderer.openSettingsRowValue(forKey: "invert_scroll") == .bool(true))

            await renderer.testingApplySetting(.resetRequested(key: "scroll_lines"))
            let revealed = await renderer.testingPricedScrollConfig()
            #expect(revealed.mode == .wheel)
            #expect(revealed.wheelLinesPerTick == 5)
            #expect(revealed.trackpadLinesPerTick == 5)
            // Sibling user commit survives the lines reset + full re-resolve.
            #expect(revealed.invertDirection)
            #expect(await !renderer.testingHasActiveScrollStream())
            #expect(await renderer.openSettingsRowValue(forKey: "scroll_lines") == .integer(5))
            #expect(await renderer.openSettingsRowValue(forKey: "invert_scroll") == .bool(true))

            let userTOML = try String(
                contentsOf: fixture.home.appendingPathComponent("config.toml"),
                encoding: .utf8
            )
            #expect(!userTOML.contains("scroll_lines"))
            #expect(userTOML.contains("invert_scroll"))

            // Capturing settings must not quarantine the next transcript wheel.
            #expect(try await renderer.handleInput(.key(KeyEvent(key: .escape))) == .consumed)
            #expect(await renderer.testingFocusedOverlayID() == nil)

            try await parkMidViewport(renderer)
            let expectedFive = pureNotchTotal(
                config: revealed, direction: .down, originMs: 2_000
            )
            #expect(expectedFive == -5)
            let mid = await renderer.testingTranscriptScrollOffset()
            #expect(mid > 5) // upward room for the project-restored 5-line notch
            let appliedFive = try await applyWheelNotch(
                renderer, direction: .down, originMs: 2_000
            )
            #expect(appliedFive == expectedFive)
            #expect(await renderer.testingTranscriptScrollOffset() == mid - 5)
        }
    }

    @Test("tmux multiplexer forces conservative 1/1 profile at construction")
    func tmuxMultiplexerProfile() async throws {
        try await withScrollFixture(
            environmentExtras: ["TMUX": "/tmp/tmux-501/default,123,0"]
        ) { fixture in
            let config = await fixture.renderer.testingScrollConfig()
            #expect(config.eventsPerTick == 1)
            #expect(config.wheelLinesPerTick == 1)
        }
    }
}
