// PagerTimelineRail.swift
//
// The timeline sidebar's pure geometry: a tick rail (one tick per turn) that
// replaces the scrollbar in its gutter while `[ui] show_timeline` is on. Tick
// position encodes conversation order, not scroll proportion.
//
// Port of `xai-grok-pager/src/views/timeline.rs` (rail geometry, hit-testing,
// chevron targets) plus the viewport-derivation half of
// `xai-grok-pager/src/scrollback/state/timeline.rs` (active turn, ▲/▼
// targets), collapsed onto this port's line model: upstream partitions cached
// per-entry `virtual_y` rows (`timeline.rs:120-137`); here the same partition
// runs over the prompt blocks' first painted line indices, which are the same
// quantity for a transcript laid out as one flat line list.
//
// Geometry is computed once per frame into a `PagerTimelineRail` consumed by
// both the renderer and mouse hit-testing, so they cannot drift
// (`views/timeline.rs:5-6`).

import OpenGrokTerminalCore

/// The rail's fixed geometry constants (`views/timeline.rs:17-25`).
public enum PagerTimelineMetrics {
    /// Columns reserved for the rail (widest tick) — `RAIL_WIDTH`
    /// (`views/timeline.rs:18`).
    public static let railWidth = 2
    /// Terminals narrower than this hide the rail (the transcript needs the
    /// columns more than the navigator) — `MIN_TERMINAL_WIDTH`
    /// (`views/timeline.rs:22`).
    public static let minTerminalWidth = 60
    /// Minimum turns before the rail appears (a 1-turn timeline is noise) —
    /// `MIN_TURNS` (`views/timeline.rs:25`).
    public static let minTurns = 2
}

/// What part of the rail a screen position lands on
/// (`TimelineHit`, `views/timeline.rs:63-70`).
public enum PagerTimelineHit: Sendable, Equatable, Hashable {
    /// A turn tick (turn index).
    case tick(Int)
    /// The ▲ chevron (previous turn).
    case up
    /// The ▼ chevron (next turn).
    case down
}

/// The viewport-derived turn state the rail is built from, gathered once per
/// frame (`RailViewport`, `views/timeline.rs:96-105`).
public struct PagerTimelineViewport: Sendable, Equatable {
    /// Turn at the viewport top (the highlighted tick), if any.
    public var active: Int?
    /// ▲ target: nearest turn strictly above the viewport top.
    public var upTarget: Int?
    /// ▼ target: nearest turn below the viewport top.
    public var downTarget: Int?
    /// Viewport is scrolled to the bottom — pins the tick window to the tail.
    public var atBottom: Bool

    public init(
        active: Int? = nil,
        upTarget: Int? = nil,
        downTarget: Int? = nil,
        atBottom: Bool = false
    ) {
        self.active = active
        self.upTarget = upTarget
        self.downTarget = downTarget
        self.atBottom = atBottom
    }
}

/// Per-frame rail geometry: where the ticks and chevrons landed
/// (`TimelineRail`, `views/timeline.rs:29-59`).
public struct PagerTimelineRail: Sendable, Equatable {
    /// Full rail rect (hit target), spanning the transcript rows.
    public var rect: TerminalRect
    /// Turn indices currently shown as ticks (windowed around the active
    /// turn when the conversation has more turns than rows).
    public var window: Range<Int>
    /// First tick row.
    public var ticksY: Int
    /// Active turn (viewport top), if any.
    public var active: Int?
    /// The ▲ target: nearest turn STRICTLY above the viewport top, NOT
    /// `active - 1` — stepping from `active` could target trailing turns
    /// that no scroll can bring to the top (upstream's stuck-▲ bug,
    /// `views/timeline.rs:39-46`).
    public var upTarget: Int?
    /// The ▼ target: nearest turn below the viewport top, so ▼ jumps exactly
    /// like clicking its tick. `nil` only when the last turn already owns
    /// the top (`views/timeline.rs:47-55`).
    public var downTarget: Int?
    /// Chevron rows.
    public var upY: Int
    public var downY: Int

    public init(
        rect: TerminalRect,
        window: Range<Int>,
        ticksY: Int,
        active: Int?,
        upTarget: Int?,
        downTarget: Int?,
        upY: Int,
        downY: Int
    ) {
        self.rect = rect
        self.window = window
        self.ticksY = ticksY
        self.active = active
        self.upTarget = upTarget
        self.downTarget = downTarget
        self.upY = upY
        self.downY = downY
    }

    /// Hit-test a screen position. The whole rail width is the target
    /// (`TimelineRail::hit`, `views/timeline.rs:187-204`).
    public func hit(x: Int, y: Int) -> PagerTimelineHit? {
        guard rect.contains(x: x, y: y) else { return nil }
        if y == upY { return .up }
        if y == downY { return .down }
        if y >= ticksY {
            let relative = y - ticksY
            if relative < window.count {
                return .tick(window.lowerBound + relative)
            }
        }
        return nil
    }
}

/// Columns to reserve for the rail this frame — the single eligibility policy
/// (setting, terminal width, turn count); geometry feasibility (enough rows)
/// stays in `pagerComputeTimelineRail`. Port of `rail_width`
/// (`views/timeline.rs:75-90`) minus its `is_subagent_view` arm: this port
/// has no subagent scrollback view, so that gate is vacuously false. The
/// scrollbar-config force (`views/agent.rs:364-368`: a disabled scrollbar
/// zeroes the rail, which needs the gutter's geometry) lives at the
/// `renderPagerFrame` call site, where the config flag is.
public func pagerTimelineRailWidth(
    showTimeline: Bool,
    terminalWidth: Int,
    turnCount: Int
) -> Int {
    if showTimeline
        && terminalWidth >= PagerTimelineMetrics.minTerminalWidth
        && turnCount >= PagerTimelineMetrics.minTurns
    {
        return PagerTimelineMetrics.railWidth
    }
    return 0
}

/// Compute rail geometry for this frame, or `nil` when the rail should not
/// render (too few turns / no room for chevrons + at least one tick).
/// Port of `compute_rail` (`views/timeline.rs:109-168`).
public func pagerComputeTimelineRail(
    scrollbackArea: TerminalRect,
    railX: Int,
    turnCount: Int,
    viewport: PagerTimelineViewport
) -> PagerTimelineRail? {
    guard turnCount >= PagerTimelineMetrics.minTurns else { return nil }
    let height = scrollbackArea.height
    // Chevrons take 2 rows; require at least 1 tick row
    // (`views/timeline.rs:119-123`).
    let maxTicks = height - 2
    guard maxTicks > 0 else { return nil }

    let window: Range<Int>
    if turnCount <= maxTicks {
        window = 0..<turnCount
    } else {
        // More turns than rows: slide a window that keeps the active tick
        // visible. At the bottom, prefer the tail so the newest ticks stay
        // on screen — but never exclude the viewport-top (active) turn, or
        // no tick would highlight (`views/timeline.rs:125-145`).
        let tailStart = turnCount - maxTicks
        let start: Int
        if viewport.atBottom {
            start = viewport.active.map { min($0, tailStart) } ?? tailStart
        } else {
            start = min(
                max(0, (viewport.active ?? turnCount - 1) - maxTicks / 2),
                tailStart
            )
        }
        window = start..<(start + maxTicks)
    }

    // Center the chevron + tick stack vertically, like the web rail
    // (`views/timeline.rs:147-151`).
    let totalRows = window.count + 2
    let top = scrollbackArea.y + (height - totalRows) / 2
    let ticksY = top + 1
    let downY = ticksY + window.count

    return PagerTimelineRail(
        rect: TerminalRect(
            x: railX,
            y: scrollbackArea.y,
            width: PagerTimelineMetrics.railWidth,
            height: scrollbackArea.height
        ),
        window: window,
        ticksY: ticksY,
        active: viewport.active,
        upTarget: viewport.upTarget,
        downTarget: viewport.downTarget,
        upY: top,
        downY: downY
    )
}

/// The turn a rail interaction jumps to, derived from the rail's own fields —
/// the same state that dims the chevrons, so display and action cannot
/// disagree. `nil` = end stop (dim chevron, click is a no-op). Port of
/// `chevron_target` (`views/timeline.rs:177-183`).
public func pagerTimelineChevronTarget(
    _ rail: PagerTimelineRail,
    _ hit: PagerTimelineHit
) -> Int? {
    switch hit {
    case .tick(let turnIndex): return turnIndex
    case .up: return rail.upTarget
    case .down: return rail.downTarget
    }
}

/// The block indices of the transcript's turn-starting user prompts, in
/// conversation order — THE turn enumeration, shared by the rail's geometry
/// and the `/jump` picker so the two navigators can never disagree about
/// what a turn is. Upstream's counterpart is `ScrollbackState::turns`
/// (one `Turn` per `UserPrompt` entry, `scrollback/state/timeline.rs:47-64`),
/// which both `timeline_entries()` and the rail's viewport reads walk.
public func pagerTimelineTurnBlockIndices(_ items: [PagerConversationItem]) -> [Int] {
    var indices: [Int] = []
    for (index, item) in items.enumerated() {
        if case .message(let message) = item, message.role == .user {
            indices.append(index)
        }
    }
    return indices
}

/// Derive the rail's viewport-turn state from the prompt blocks' first
/// painted line indices (monotone in turn order) and the resolved scroll
/// offset. Port of `active_turn_for_viewport` / `turn_above_viewport_top` /
/// `turn_below_viewport_top` (`scrollback/state/timeline.rs:83-137`) with the
/// partition running over prompt line rows instead of cached `virtual_y`;
/// the `ViewMode::SingleTurn` arms have no port counterpart (this port
/// renders all turns in one scrollback).
///
/// `atBottom` is upstream's `!has_content_below()` (`nav.rs:632-637`),
/// which is `scrollOffset >= maximumOffset` over this port's line model.
public func pagerTimelineViewport(
    promptLineIndices: [Int],
    scrollOffset: Int,
    maximumOffset: Int
) -> PagerTimelineViewport {
    guard !promptLineIndices.isEmpty else {
        return PagerTimelineViewport(atBottom: scrollOffset >= maximumOffset)
    }
    let top = scrollOffset
    // Prompt rows are monotone in turn order, so these are partition points
    // (`prompts_above_top`, `timeline.rs:120-137`).
    let atOrAbove = promptLineIndices.prefix(while: { $0 <= top }).count
    let strictlyAbove = promptLineIndices.prefix(while: { $0 < top }).count
    // The focused turn: the last turn whose prompt is at/above the viewport
    // top, or the FIRST turn while pre-turn content owns the top
    // (`active_turn_for_viewport`, `timeline.rs:83-91` — `saturating_sub`).
    let active = max(0, atOrAbove - 1)
    // ▲ steps to the last turn STRICTLY above — from mid-turn it first
    // aligns the current turn's own prompt (`timeline.rs:99-104`).
    let upTarget = strictlyAbove > 0 ? strictlyAbove - 1 : nil
    // ▼ steps to the nearest turn below the top; before the first prompt
    // this is the first turn (`timeline.rs:108-115`).
    let downTarget = atOrAbove < promptLineIndices.count ? atOrAbove : nil
    return PagerTimelineViewport(
        active: active,
        upTarget: upTarget,
        downTarget: downTarget,
        atBottom: scrollOffset >= maximumOffset
    )
}
