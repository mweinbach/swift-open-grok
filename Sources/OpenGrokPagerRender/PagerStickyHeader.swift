import Foundation
import OpenGrokTerminalCore

// MARK: - Sticky header layout (scrollback/sticky.rs at pin 650c1db7)
//
// Pure 1D coordinate math for AllTurns sticky section headers. Mirrors
// `crates/codegen/xai-grok-pager/src/scrollback/sticky.rs` line-faithfully:
// gradual collapse, push-only / pinned-only, one-row content gap, clipTop,
// headerScreenRows, scrollForContent, and trap-free malformed clamps.

/// Gap row between header content and the scrollable transcript
/// (`HEADER_CONTENT_GAP`, sticky.rs:111).
public let pagerStickyHeaderContentGap = 1

/// Historical default minimum pinned height (`MIN_PINNED_HEIGHT`, sticky.rs:53).
/// Compute uses each descriptor's `minHeight` instead; kept for parity callers.
public let pagerMinPinnedHeight = 4

/// Cap on sticky `minHeight` from truncated-header seeds
/// (`MAX_TRUNCATED_HEADER_HEIGHT`, scrollback/state/types.rs:80).
public let pagerMaxTruncatedHeaderHeight = 6

/// Describes a prompt entry for sticky header computation
/// (`PromptDescriptor`, sticky.rs:29-49).
public struct PagerPromptDescriptor: Sendable, Equatable {
    /// Index of the prompt entry in the conversation / entries list.
    public var entryIdx: Int
    /// Y position in virtual scroll space.
    public var yVirtual: Int
    /// Total height when rendered inline in the timeline.
    public var fullHeight: Int
    /// Minimum height when fully collapsed as a sticky header.
    public var minHeight: Int
    /// Whether this prompt sticks when scrolled past. Non-sticky prompts still
    /// participate in push calculations but never become pinned.
    public var sticky: Bool

    public init(
        entryIdx: Int,
        yVirtual: Int,
        fullHeight: Int,
        minHeight: Int,
        sticky: Bool
    ) {
        self.entryIdx = max(0, entryIdx)
        self.yVirtual = max(0, yVirtual)
        self.fullHeight = max(0, fullHeight)
        self.minHeight = max(0, minHeight)
        self.sticky = sticky
    }
}

/// A prompt to render in the sticky header area (`RenderedPrompt`, sticky.rs:57-76).
public struct PagerRenderedPrompt: Sendable, Equatable {
    public var entryIdx: Int
    /// Full height budget for the block (`minHeight...fullHeight`).
    public var renderHeight: Int
    /// Rows clipped from the TOP after rendering to `renderHeight` (push only).
    public var clipTop: Int

    public init(entryIdx: Int, renderHeight: Int, clipTop: Int) {
        self.entryIdx = max(0, entryIdx)
        self.renderHeight = max(0, renderHeight)
        self.clipTop = max(0, clipTop)
    }

    /// Rows actually visible on screen after clipping (sticky.rs:80-83).
    public var visibleHeight: Int {
        max(0, renderHeight - clipTop)
    }

    /// True when `clipTop > 0` (scratch / partial copy needed) (sticky.rs:87-90).
    public var needsScratchBuffer: Bool {
        clipTop > 0
    }
}

/// Result of computing sticky header layout (`StickyHeaderLayout`, sticky.rs:101-110).
public struct PagerStickyHeaderLayout: Sendable, Equatable {
    /// Prompt being pushed off (clipped at top). Only during push transition.
    public var pushed: PagerRenderedPrompt?
    /// Main pinned prompt. Nil at timeline start (nothing scrolled past).
    public var pinned: PagerRenderedPrompt?

    public init(pushed: PagerRenderedPrompt? = nil, pinned: PagerRenderedPrompt? = nil) {
        self.pushed = pushed
        self.pinned = pinned
    }

    public static let empty = PagerStickyHeaderLayout()

    /// Height of header content only — pushed + gap-between + pinned.
    /// Does NOT include the gap after the header (sticky.rs:116-126).
    public var headerContentHeight: Int {
        let pushedVisible = pushed?.visibleHeight ?? 0
        let pinnedVisible = pinned?.visibleHeight ?? 0
        let gapBetween = (pushedVisible > 0 && pinnedVisible > 0) ? 1 : 0
        return pushedVisible + gapBetween + pinnedVisible
    }

    /// Total rows the header occupies on screen, including gap after when pinned
    /// (sticky.rs:137-150). Push-only (pushed, no pinned) has NO trailing gap.
    ///
    /// Deliberately **not** clamped to the viewport: `calculate_render_height`
    /// clamps the pinned/pushed body to `viewportHeight`, then a pinned layout
    /// still adds `HEADER_CONTENT_GAP`, so this can be `viewport + 1`. Rust
    /// keeps that figure for `scroll_for_content` continuity and saturates
    /// `content_height` to 0 (`sticky.rs:161-164`); paint must clamp the
    /// content line range separately (`pagerStickyVisibleContentRange`).
    public var headerScreenRows: Int {
        guard hasHeader else { return 0 }
        if pushed != nil, pinned == nil {
            return headerContentHeight
        }
        return headerContentHeight + pagerStickyHeaderContentGap
    }

    /// Alias for `headerScreenRows` (sticky.rs:154-157).
    public var contentStartRow: Int { headerScreenRows }

    /// Content-area height given viewport height (sticky.rs:161-164).
    /// Saturates at 0 when `headerScreenRows >= viewport` (including the
    /// viewport+1 pinned+gap case above).
    public func contentHeight(viewportHeight: Int) -> Int {
        max(0, max(0, viewportHeight) - headerScreenRows)
    }

    /// Scroll offset for the content area so bottom-line continuity holds:
    /// `scrollForContent = scrollOffset + headerScreenRows` (sticky.rs:184-187).
    /// May exceed total content lines when the header band is tall relative to
    /// a tiny viewport — callers must clamp before forming a `Range`.
    public func scrollForContent(_ scrollOffset: Int) -> Int {
        max(0, scrollOffset) + headerScreenRows
    }

    public var hasHeader: Bool {
        pushed != nil || pinned != nil
    }

    public var pinnedEntryIdx: Int? {
        pinned?.entryIdx
    }

    /// Screen row where the pinned header starts (sticky.rs:205-210).
    public var pinnedScreenRow: Int? {
        guard pinned != nil else { return nil }
        let pushedVisible = pushed?.visibleHeight ?? 0
        let gapAfterPushed = pushedVisible > 0 ? 1 : 0
        return pushedVisible + gapAfterPushed
    }

    /// Screen row of the gap after a pinned header (sticky.rs:215-218).
    public var gapRow: Int? {
        guard pinned != nil else { return nil }
        return headerContentHeight
    }

    /// Screen row where pushed header starts — always 0 when present (sticky.rs:221-223).
    public var pushedScreenRow: Int? {
        pushed.map { _ in 0 }
    }

    /// Gap between pushed and pinned when both present (sticky.rs:226-232).
    public var gapBetweenRow: Int? {
        guard let pushed, pinned != nil else { return nil }
        return pushed.visibleHeight
    }

    /// Map a header-relative screen row to the prompt entry index, or nil on a
    /// gap / outside the header (sticky.rs:238-261). Trap-free.
    public func entryAtHeaderRow(_ row: Int) -> Int? {
        guard hasHeader, row >= 0, row < headerScreenRows else { return nil }

        if let pushed, row < pushed.visibleHeight {
            return pushed.entryIdx
        }

        if let pinned {
            let pinnedStart = pinnedScreenRow ?? 0
            let pinnedEnd = pinnedStart + pinned.visibleHeight
            if row >= pinnedStart, row < pinnedEnd {
                return pinned.entryIdx
            }
        }
        return nil
    }

    /// Screen area of a header prompt: `(startRow, visibleHeight, isPushed)`
    /// relative to scrollback top (sticky.rs:267-286).
    public func headerEntryArea(entryIdx: Int) -> (startRow: Int, visibleHeight: Int, isPushed: Bool)? {
        if let pushed, pushed.entryIdx == entryIdx {
            let visible = pushed.visibleHeight
            if visible > 0 {
                return (0, visible, true)
            }
        }
        if let pinned, pinned.entryIdx == entryIdx {
            let visible = pinned.visibleHeight
            if visible > 0 {
                let start = pinnedScreenRow ?? 0
                return (start, visible, false)
            }
        }
        return nil
    }
}

/// Compute sticky header layout (`compute_sticky_layout`, sticky.rs:304-409).
///
/// - `prompts` must be sorted by `yVirtual` ascending.
/// - Trap-free under empty prompts, zero/negative viewport, and malformed heights.
public func computePagerStickyLayout(
    scrollOffset: Int,
    viewportHeight: Int,
    prompts: [PagerPromptDescriptor]
) -> PagerStickyHeaderLayout {
    let scroll = max(0, scrollOffset)
    let viewport = max(0, viewportHeight)
    if prompts.isEmpty || scroll == 0 {
        return .empty
    }

    guard let pinnedIdx = prompts.lastIndex(where: { $0.sticky && $0.yVirtual < scroll }) else {
        return .empty
    }

    let pinnedPrompt = prompts[pinnedIdx]
    let renderHeight = pagerStickyCalculateRenderHeight(
        prompt: pinnedPrompt,
        scrollOffset: scroll,
        viewportHeight: viewport
    )

    let nextPromptInfo: (PagerPromptDescriptor, Int)?
    if pinnedIdx + 1 < prompts.count {
        let next = prompts[pinnedIdx + 1]
        let nextNaiveRow = max(0, next.yVirtual - scroll)
        let headerWithGap = renderHeight + pagerStickyHeaderContentGap
        if nextNaiveRow <= headerWithGap {
            nextPromptInfo = (next, nextNaiveRow)
        } else {
            nextPromptInfo = nil
        }
    } else {
        nextPromptInfo = nil
    }

    if let (_, nextNaiveRow) = nextPromptInfo {
        if nextNaiveRow == 0 {
            return .empty
        }

        let pushedVisible = max(0, nextNaiveRow - 1)
        if pushedVisible == 0 {
            return .empty
        }

        let pushedRenderHeight = min(pinnedPrompt.fullHeight, renderHeight)
        let pushClip = max(0, pushedRenderHeight - pushedVisible)
        return PagerStickyHeaderLayout(
            pushed: PagerRenderedPrompt(
                entryIdx: pinnedPrompt.entryIdx,
                renderHeight: pushedRenderHeight,
                clipTop: pushClip
            ),
            pinned: nil
        )
    }

    return PagerStickyHeaderLayout(
        pushed: nil,
        pinned: PagerRenderedPrompt(
            entryIdx: pinnedPrompt.entryIdx,
            renderHeight: renderHeight,
            clipTop: 0
        )
    )
}

/// Gradual collapse height (`calculate_render_height`, sticky.rs:429-457).
func pagerStickyCalculateRenderHeight(
    prompt: PagerPromptDescriptor,
    scrollOffset: Int,
    viewportHeight: Int
) -> Int {
    let scrollPast = max(0, scrollOffset - prompt.yVirtual)
    // Cap before narrowing — values past Int.max/u16 collapse to min anyway.
    let cappedPast = min(scrollPast, Int(UInt16.max))
    let height = max(0, prompt.fullHeight - cappedPast)
    // `min_height.max(1).min(full_height.max(1))` (sticky.rs:453).
    let minHeight = min(max(1, prompt.minHeight), max(1, prompt.fullHeight))
    let viewport = max(0, viewportHeight)
    return min(max(height, minHeight), viewport)
}

// MARK: - Descriptors from laid-out conversation

/// Build prompt descriptors for `.message(.user)` only, using exact
/// `blockStartLines` / `blockHeights` from the layout that will paint.
///
/// Sticky is always `true` until a user-prompt expanded-fold seam exists in
/// this port (Rust: `!(is_foldable && display_mode == Expanded)`,
/// layout.rs:1211-1212). `minHeight` is an estimate capped at
/// `pagerMaxTruncatedHeaderHeight` (6) matching current user-prompt vpad/body.
public func pagerPromptDescriptors(
    conversation: [PagerConversationItem],
    blockStartLines: [Int],
    blockHeights: [Int],
    compact: Bool
) -> [PagerPromptDescriptor] {
    let count = min(conversation.count, min(blockStartLines.count, blockHeights.count))
    guard count > 0 else { return [] }
    var prompts: [PagerPromptDescriptor] = []
    prompts.reserveCapacity(count)
    for index in 0..<count {
        guard case .message(let message) = conversation[index], message.role == .user else {
            continue
        }
        let fullHeight = max(0, blockHeights[index])
        let minHeight = pagerStickyMinHeightEstimate(fullHeight: fullHeight, compact: compact)
        prompts.append(PagerPromptDescriptor(
            entryIdx: index,
            yVirtual: max(0, blockStartLines[index]),
            fullHeight: fullHeight,
            minHeight: minHeight,
            sticky: true
        ))
    }
    return prompts
}

/// Estimate sticky min height from the laid-out user prompt: vpad (0 compact /
/// 2 otherwise) plus a short body, capped at `pagerMaxTruncatedHeaderHeight`.
public func pagerStickyMinHeightEstimate(fullHeight: Int, compact: Bool) -> Int {
    let full = max(0, fullHeight)
    guard full > 0 else { return 1 }
    let vpad = compact ? 0 : 2
    let body = max(1, full - vpad)
    let bodyBudget = max(1, pagerMaxTruncatedHeaderHeight - vpad)
    let estimate = vpad + min(body, bodyBudget)
    return min(full, max(1, min(estimate, pagerMaxTruncatedHeaderHeight)))
}

/// Rows to advance for a full-page scroll (`page_scroll_rows`, nav.rs:430-436):
/// content area (viewport minus sticky header) less a 2-row overlap, at least 1.
///
/// Pure helper for the live owner — no layout cache required. Pass
/// `headerScreenRows: 0` when sticky is gated off (compact / disabled).
public func pagerPageScrollRows(viewportHeight: Int, headerScreenRows: Int) -> Int {
    let viewport = max(0, viewportHeight)
    let header = max(0, headerScreenRows)
    return max(1, max(0, viewport - header - 2))
}

/// Trap-free content paint range for sticky frames.
///
/// `scrollForContent` can exceed `lineCount` when a pinned header + trailing
/// gap reports `headerScreenRows == viewport + 1` (Rust parity) while content
/// height saturates to 0. Clamp the start into `0...lineCount`, then derive
/// the end from that start so `lowerBound <= upperBound` always holds.
public func pagerStickyVisibleContentRange(
    scrollForContent: Int,
    contentPaintHeight: Int,
    lineCount: Int
) -> Range<Int> {
    let count = max(0, lineCount)
    let start = min(max(0, scrollForContent), count)
    let end = min(count, start + max(0, contentPaintHeight))
    return start..<end
}

// MARK: - Sticky paint lines (reuse conversation layout rows)

/// Slice a block's laid-out lines for sticky paint: budget `renderHeight` from
/// the top (collapsed sticky view), then drop `clipTop` for push.
///
/// Divergence from Rust's budgeted block re-render (`render_sticky_header`,
/// scrollback_pane.rs:660-811): this port reuses the already-laid-out full
/// block lines rather than re-running the user-prompt renderer with
/// `max_lines`. Row/clip semantics match; ellipsis placement inside a
/// mid-collapse budget may differ cosmetically for multi-line prompts.
func pagerStickyHeaderLines(
    from layout: ConversationLayout,
    entryIdx: Int,
    renderHeight: Int,
    clipTop: Int
) -> [PaintLine] {
    let count = min(layout.blockStartLines.count, layout.blockHeights.count)
    guard entryIdx >= 0, entryIdx < count else { return [] }
    let start = layout.blockStartLines[entryIdx]
    let height = layout.blockHeights[entryIdx]
    guard height > 0, start >= 0, start < layout.lines.count else { return [] }

    let end = min(layout.lines.count, start + height)
    let block = Array(layout.lines[start..<end])
    let budget = max(0, min(renderHeight, block.count))
    let budgeted = Array(block.prefix(budget))
    let clip = max(0, min(clipTop, budgeted.count))
    return Array(budgeted.dropFirst(clip))
}
