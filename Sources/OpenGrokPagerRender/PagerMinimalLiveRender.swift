// PagerMinimalLiveRender.swift
//
// Wave 18 B2-M3: the minimal-mode live tail and the viewport-sizing half of
// the overlay host — `xai-grok-pager-minimal/src/live.rs` (`draw_tail`
// :422-493, `tail_height` :732-750) and `overlay.rs` (`sync_viewport`
// :143-191, `will_commit` :199-211, `content_target` :343-358,
// `modal_target` :125-132, `app_modal_target` :110-112) at pin 650c1db7.
//
// The AppView-owned frame composition around these (status row, prompt
// widget, todo//btw panels, dropdown/modal rendering) is the M4 frame
// program's territory — it computes the chrome heights and passes them into
// the sizing math here. What THIS file owns is everything whose drift makes
// the prompt jump: the tail must start exactly where the frontier scan
// stops, measure blocks with exactly the committed constructor, and the
// viewport must be sized to the POST-commit tail before the commit runs.

import OpenGrokMinimalScrollback
import OpenGrokTerminalCore

// MARK: - The minimal transcript store

/// The frontier state bound to its renderable payloads: each
/// `MinimalScrollbackState` entry owns one `PagerConversationItem`, pushed
/// and updated by the frame driver (M4). Upstream runs the pipeline ON the
/// production `ScrollbackState`, whose entries ARE the render blocks; the
/// port's pure state carries only the classification, so the payload rides
/// here, keyed by the entry id the state assigned — identity the commit
/// flags can travel with across removals (the M1 cursor arithmetic).
public final class MinimalTranscript {
    public let state = MinimalScrollbackState()
    private var items: [MinimalEntryID: PagerConversationItem] = [:]
    /// Entries pushed with an explicit classification (the BgTask lifecycle
    /// override) keep it across payload updates — re-deriving would silently
    /// drop the one classification the item model cannot express.
    private var pinnedBlocks: Set<MinimalEntryID> = []

    public init() {}

    /// Derive the pipeline classification from a renderable item. The item
    /// model has no BgTask variant — a background-task lifecycle card must
    /// be pushed with an explicit `block:` override or it gates on
    /// `isRunning` like any tool and wedges the frontier (`commit.rs:67-77`).
    ///
    /// A running/pending tool derives `error: nil`; that is safe because
    /// `isCommittable` holds running TOOLS regardless — the driver keeps
    /// `entry.isRunning` in lockstep with the card state, and only a
    /// finalized card's success is ever read by the display-mode policy.
    static func classify(_ item: PagerConversationItem) -> MinimalBlock {
        switch item {
        case .message(let message):
            switch message.role {
            case .assistant: return .agentMessage(message.text)
            case .reasoning: return .thinking(message.text)
            case .user: return .userPrompt(message.text)
            case .system, .error: return .system(message.text)
            }
        case .tool(let card):
            let kind: MinimalToolKind
            switch card.kind {
            case .read: kind = .read
            // `create` is the edit family: upstream's Edit block covers file
            // writes, and the policy's "diffs always full" applies to both.
            case .edit, .create: kind = .edit
            case .execute: kind = .execute
            case .search: kind = .search
            case .list: kind = .listDir
            case .fetch: kind = .webFetch
            case .webSearch: kind = .webSearch
            // Specialized kinds without a minimal-pipeline body yet fall
            // through as generic/other so frontier classification still works.
            case .memorySearch, .integrationSearch, .useTool, .skill, .generic:
                kind = .other(card.name)
            }
            let error: String?
            switch card.state {
            case .failed: error = "failed"
            case .cancelled: error = "cancelled"
            case .running, .pending, .succeeded: error = nil
            }
            return .toolCall(kind: kind, error: error)
        case .separator(let text):
            return .stub(text)
        }
    }

    /// Append an item; `block` overrides the derived classification (the
    /// BgTask case), `running` marks the entry still-streaming.
    @discardableResult
    public func push(
        _ item: PagerConversationItem,
        block: MinimalBlock? = nil,
        running: Bool = false
    ) -> MinimalEntryID {
        let resolved = block ?? Self.classify(item)
        let entry = running
            ? MinimalScrollbackEntry.running(resolved)
            : MinimalScrollbackEntry(resolved)
        let id = state.push(entry)
        items[id] = item
        if block != nil {
            pinnedBlocks.insert(id)
        }
        return id
    }

    /// Replace an entry's payload (streaming updates, state transitions),
    /// re-deriving its classification unless it was pushed pinned. `false`
    /// when the id is gone (removed by rewind / clear).
    @discardableResult
    public func updateItem(_ id: MinimalEntryID, _ item: PagerConversationItem) -> Bool {
        guard let index = state.indexOfID(id) else { return false }
        items[id] = item
        if !pinnedBlocks.contains(id) {
            state.updateEntry(at: index) { $0.block = Self.classify(item) }
        }
        return true
    }

    public func item(for id: MinimalEntryID) -> PagerConversationItem? {
        items[id]
    }

    public func item(at index: Int) -> PagerConversationItem? {
        guard let entry = state.entry(at: index) else { return nil }
        return items[entry.id]
    }

    /// Removal pass-throughs keep the payload store in sync with the
    /// frontier state — an orphaned payload is a leak, a missing one paints
    /// an empty block.
    @discardableResult
    public func removeEntry(_ id: MinimalEntryID) -> Bool {
        guard state.removeEntry(id) else { return false }
        items.removeValue(forKey: id)
        pinnedBlocks.remove(id)
        return true
    }

    @discardableResult
    public func removeFrom(_ index: Int) -> [MinimalScrollbackEntry] {
        let removed = state.removeFrom(index)
        for entry in removed {
            items.removeValue(forKey: entry.id)
            pinnedBlocks.remove(entry.id)
        }
        return removed
    }

    public func clear() {
        state.clear()
        items.removeAll()
        pinnedBlocks.removeAll()
    }
}

// MARK: - Live tail

public enum MinimalLiveRender {
    /// Height (rows) of the tail that will REMAIN after this frame's commit
    /// pass — the entries the commit will NOT consume, from the frontier
    /// scan's stop point onward (`tail_height`, `live.rs:732-750`).
    ///
    /// Sizing the viewport to this POST-commit tail is load-bearing: the
    /// overlay host resizes just BEFORE the commit runs, so the viewport is
    /// already at its post-commit height when `insertBefore` prints the
    /// finalized blocks and repositions it to sit directly after them.
    /// Sizing to the current (taller, still-streaming) tail left the
    /// viewport oversized at commit time, and the collapse that followed
    /// stranded the prompt at the top of the screen (upstream's
    /// "snaps to top" bug).
    ///
    /// Measures with exactly the committed constructor
    /// (`MinimalCommitRender.committedLines`) — one layout on both sides of
    /// the frontier is what keeps a block's height from flipping as it
    /// crosses (K5; the prompt jumps otherwise).
    public static func tailHeight(
        _ transcript: MinimalTranscript,
        turnRunning: Bool,
        width: Int,
        theme: PagerRenderTheme
    ) -> Int {
        let gap = Int(minimalBlockGap)
        var index = scanFrontier(transcript.state, turnRunning: turnRunning).tailStart
        var total = 0
        while let entry = transcript.state.entry(at: index) {
            let item = transcript.item(for: entry.id)
            if let item {
                let block = MinimalCommitRender.committedLines(
                    item: item,
                    displayMode: entry.displayMode,
                    width: width,
                    theme: theme
                )
                total += block.height + gap
            }
            index += 1
        }
        return total
    }

    /// Render the uncommitted tail (entries past the commit frontier) into
    /// `area`, bottom-anchored so the most recent output is always visible;
    /// when the run is taller than the area the topmost visible entry is
    /// clipped from the top (`draw_tail`, `live.rs:422-493`).
    ///
    /// Starts at the shared `scanFrontier` stop point so it renders exactly
    /// the entries `tailHeight` measured — the viewport was sized to that,
    /// and any disagreement makes the prompt jump on commit.
    public static func drawTail(
        _ transcript: MinimalTranscript,
        turnRunning: Bool,
        area: TerminalRect,
        theme: PagerRenderTheme,
        into buffer: inout CellBuffer
    ) {
        guard area.height > 0, area.width > 0 else { return }
        let width = area.width
        var blocks: [MinimalCommittedBlock] = []
        var index = scanFrontier(transcript.state, turnRunning: turnRunning).tailStart
        while let entry = transcript.state.entry(at: index) {
            if let item = transcript.item(for: entry.id) {
                blocks.append(MinimalCommitRender.committedLines(
                    item: item,
                    displayMode: entry.displayMode,
                    width: width,
                    theme: theme
                ))
            }
            index += 1
        }
        guard !blocks.isEmpty else { return }

        let gap = Int(minimalBlockGap)
        let total = blocks.reduce(0) { $0 + $1.height + gap }
        var skipTop = max(0, total - area.height)
        var y = area.y
        let bottom = area.y + area.height
        for block in blocks {
            let slotHeight = block.height + gap
            if skipTop >= slotHeight {
                skipTop -= slotHeight
                continue
            }
            let slotSkip = skipTop
            skipTop = 0
            let entrySkip = min(slotSkip, block.height)
            let visible = block.height - entrySkip
            if visible > 0 {
                let drawHeight = min(visible, bottom - y)
                if drawHeight == 0 { break }
                for row in 0..<drawHeight {
                    MinimalCommitRender.paintRow(
                        block.lines[entrySkip + row],
                        at: y + row,
                        originX: area.x,
                        chrome: block.chromeWidth,
                        width: width,
                        into: &buffer
                    )
                }
                y += drawHeight
                if y >= bottom { break }
            }
            let gapSkipped = slotSkip - entrySkip
            y += min(max(0, gap - gapSkipped), bottom - y)
            if y >= bottom { break }
        }
    }

    // MARK: - Viewport sizing (the overlay host's load-bearing half)

    /// Whether the commit pass will print at least one block this frame —
    /// the shared `scanFrontier` projection, gated on a commit hold
    /// (`will_commit`, `overlay.rs:199-211`; the hold is the centered
    /// app-modal, whose detection belongs to the M4 frame program).
    public static func willCommit(
        _ transcript: MinimalTranscript,
        turnRunning: Bool,
        holdCommits: Bool
    ) -> Bool {
        if holdCommits { return false }
        return scanFrontier(transcript.state, turnRunning: turnRunning).willCommit
    }

    /// Grow / shrink the live viewport to `target` rows (`sync_viewport`,
    /// `overlay.rs:143-191`). The live region is content-anchored, NOT
    /// bottom-pinned: it sits directly after the committed conversation, and
    /// steady state is a no-op.
    ///
    /// Two resize paths, gated on whether a commit is about to run:
    ///
    /// - `willCommit`: only pre-set the viewport HEIGHT (to the post-commit
    ///   size) and keep the current top — `insertBefore` then prints the
    ///   finalized block, scrolls the overflow, clears the vacated rows, and
    ///   repositions the correctly-sized viewport itself. Using the area
    ///   setter skips `setViewportHeight`'s clear + grow-time scroll, which
    ///   would be redundant work right before `insertBefore` does its own.
    ///   (The stored inline height is briefly out of sync with the area —
    ///   harmless, upstream carries the same note: grow/shrink is judged
    ///   against the live area height and resyncs next frame.)
    /// - otherwise (overlay open/close, idle prompt edits):
    ///   `setViewportHeight` — top-fixed, growing DOWNWARD into the empty
    ///   space below so committed content is never scrolled away and closing
    ///   an overlay leaves no blank band; it scrolls committed rows up only
    ///   when the growth would overflow the screen bottom, and its clear
    ///   wipes stale overlay rows on shrink. The result is deliberately
    ///   discarded as upstream discards it (`overlay.rs:189`) — a failed
    ///   resize surfaces on the next frame's draw, and there is no caller
    ///   that could retry it sooner.
    public static func syncViewport(
        terminal: Terminal,
        target: Int,
        willCommit: Bool
    ) {
        let current = terminal.viewportArea
        guard current.height != target else { return }
        if willCommit {
            terminal.setViewportArea(TerminalRect(
                x: current.x, y: current.y, width: current.width, height: target
            ))
        } else {
            try? terminal.setViewportHeight(target)
        }
    }

    // MARK: - Sizing math (M4's compute-target consumes these)

    /// `[terminal] minimal_live_rows` default (`config.rs:1445`).
    public static let minimalLiveRowsDefault = 10

    /// Moderate target height for a centered app-modal panel
    /// (`MINIMAL_APP_MODAL_ROWS`, `overlay.rs:105`). Deliberately well below
    /// a full screen: closing the modal leaves a blank band equal to
    /// `target - base`, and a screen-tall band was upstream's "bunch of
    /// blank space" dogfooding complaint — committed rows scrolled into
    /// native scrollback cannot be pulled back.
    public static let minimalAppModalRows = 18

    /// Target viewport height for a centered app-modal: never below the
    /// live region's base, never above the screen ceiling
    /// (`app_modal_target`, `overlay.rs:110-112`).
    public static func appModalTarget(base: Int, ceiling: Int) -> Int {
        min(max(minimalAppModalRows, base), ceiling)
    }

    /// Target viewport height for a prompt-replacing modal (permission /
    /// question / rewind): the modal, one status row, and the uncommitted
    /// tail ABOVE it (`modal_target`, `overlay.rs:125-132`). Reserving the
    /// tail is load-bearing: a tool blocked on a permission is held
    /// uncommitted in the tail (`isPendingUserInput`), so the tail is where
    /// its diff/command preview is drawn — sizing to the modal alone shows
    /// "Allow Edit to …?" with no visible diff. Floored at `base` and at 3;
    /// capped at `ceiling` (overflow bottom-anchors and clips in `drawTail`).
    public static func modalTarget(tailHeight: Int, modalHeight: Int, base: Int, ceiling: Int) -> Int {
        max(min(max(tailHeight + modalHeight + 1, base), ceiling), 3)
    }

    /// Viewport height sized to exactly its content: tail + todo panel +
    /// btw panel + status row + overlay/info + prompt, floored at 2
    /// (status + prompt) and capped at the screen (`content_target`,
    /// `overlay.rs:343-358`). Content-anchoring is the point: when a turn is
    /// "thinking" with nothing streamed the tail is empty and the prompt
    /// sits right under the conversation instead of floating below a fixed
    /// empty region.
    public static func contentTarget(
        tailHeight: Int,
        todosHeight: Int,
        btwHeight: Int,
        overlayHeight: Int,
        promptHeight: Int,
        ceiling: Int
    ) -> Int {
        let total = tailHeight + todosHeight + btwHeight + 1 + overlayHeight + promptHeight
        return min(max(total, 2), max(2, ceiling))
    }
}
