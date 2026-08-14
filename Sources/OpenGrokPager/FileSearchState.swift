// FileSearchState.swift
//
// File search state: owns results, dropdown selection, and @-replacement state.
//
// Manages:
// - The current AtContext (parsed from prompt text + cursor)
// - Fuzzy match results
// - Dropdown selection state (selected index, hovered index, scroll offset)
// - Stale result fencing via minGeneration
// - Text replacement logic when a result is accepted

import Foundation
import OpenGrokPagerRender

/// Replacement to apply to the prompt text after accepting a fuzzy result.
public struct FileSearchReplacement: Sendable, Equatable, Hashable {
    /// Range in the prompt text to replace (excludes the `@` and any `!` prefix).
    public var range: Range<Int>
    /// Replacement text (the normalized path, possibly with trailing space or `/`).
    public var text: String
    /// Where to place the cursor after replacement.
    public var cursor: Int
    /// Whether the @-context should be cleared (an already-present directory was committed).
    public var dismiss: Bool

    public init(
        range: Range<Int>,
        text: String,
        cursor: Int,
        dismiss: Bool
    ) {
        self.range = range
        self.text = text
        self.cursor = cursor
        self.dismiss = dismiss
    }
}

/// Results snapshot from the fuzzy matcher daemon.
public struct FuzzyMatcherDaemonResults: Sendable, Equatable {
    public var topk: [FuzzyMatchResult]
    public var numItems: Int
    public var isDone: Bool
    public var generation: Int

    public init(
        topk: [FuzzyMatchResult] = [],
        numItems: Int = 0,
        isDone: Bool = true,
        generation: Int = 0
    ) {
        self.topk = topk
        self.numItems = numItems
        self.isDone = isDone
        self.generation = generation
    }
}

/// Build accepted directory replacement text: append `/` for drill-down and a
/// trailing space when the token ends the prompt.
private func acceptText(path: String, atEnd: Bool) -> String {
    var text = path
    text.append("/")
    if atEnd {
        text.append(" ")
    }
    return text
}

/// File search state for @-completion.
public struct FileSearchState: Sendable {
    /// Directory the matcher walks.
    public private(set) var root: String
    /// Latest results snapshot.
    public private(set) var results: FuzzyMatcherDaemonResults
    /// Current @-context (if cursor is inside an @-token).
    public private(set) var context: AtContext?
    /// Selected index in the dropdown list (keyboard-driven).
    public private(set) var selected: Int
    /// Hovered index in the dropdown list (mouse-driven).
    public private(set) var hovered: Int?
    /// Scroll offset for the dropdown list.
    public private(set) var scrollOffset: Int
    /// Floor for accepted result generations: the stale-result fence.
    public private(set) var minGeneration: Int
    /// Directory being drilled into; keeps the @-token alive when its name has whitespace.
    public private(set) var drillPrefix: String?

    /// Create a new file search state rooted at the given path.
    public init(root: String = ".") {
        self.root = root
        self.results = FuzzyMatcherDaemonResults()
        self.context = nil
        self.selected = 0
        self.hovered = nil
        self.scrollOffset = 0
        self.minGeneration = 0
        self.drillPrefix = nil
    }

    /// Point @-completion at a new tree.
    public mutating func retarget(root: String) {
        self = FileSearchState(root: root)
    }

    // MARK: - Visibility & Mode Properties

    /// Whether the dropdown should be visible.
    public var isVisible: Bool {
        context != nil && !results.topk.isEmpty
    }

    /// Whether the current query is in directory-only mode.
    public var isDirMode: Bool {
        context?.isDirMode ?? false
    }

    /// Whether the current query is in hidden-mode.
    public var isHiddenMode: Bool {
        context?.isHiddenMode ?? false
    }

    /// Number of result items.
    public var resultCount: Int {
        results.topk.count
    }

    /// Total items the matcher knows about.
    public var totalItems: Int {
        results.numItems
    }

    // MARK: - Context Updates

    /// Anchor (or clear) the drilled directory for whitespace-aware detection.
    public mutating func setDrillPrefix(_ prefix: String?) {
        self.drillPrefix = prefix
    }

    /// Clear drill prefix.
    public mutating func clearDrillPrefix() {
        self.drillPrefix = nil
    }

    /// Recompute the @-context from the current prompt text and cursor position.
    public mutating func updateContext(text: String, cursor: Int) {
        let newCtx = AtContext.detectWithDrill(text: text, cursor: cursor, drillPrefix: drillPrefix)

        switch (self.context, newCtx) {
        case (nil, let .some(ctx)):
            // Fresh `@` token is never a drill — drop any stale anchor.
            drillPrefix = nil
            startQuery(restart: true, query: ctx.matcherQuery)
        case (let .some(old), let .some(new)):
            // Drop a stale anchor once the @-token's path content no longer starts with it.
            if let prefix = drillPrefix {
                let pathStart = new.pathRange.lowerBound
                if pathStart <= text.count {
                    let afterStart = String(text.dropFirst(pathStart))
                    if !afterStart.hasPrefix(prefix) {
                        drillPrefix = nil
                    }
                } else {
                    drillPrefix = nil
                }
            }
            let restart = (old.isHiddenMode != new.isHiddenMode)
            startQuery(restart: restart, query: new.matcherQuery)
        case (.some, nil):
            // Leaving @-mode: clear results and drill anchor.
            context = nil
            drillPrefix = nil
            results = FuzzyMatcherDaemonResults()
            return
        case (nil, nil):
            return
        }

        self.context = newCtx
    }

    /// Clear the context (e.g. on Esc).
    public mutating func clearContext() {
        self.context = nil
        self.drillPrefix = nil
        self.results = FuzzyMatcherDaemonResults()
    }

    private mutating func startQuery(restart: Bool, query: String) {
        self.minGeneration += 1
        self.selected = 0
        self.hovered = nil
        self.scrollOffset = 0
    }

    // MARK: - Navigation

    /// Move selection by delta items (negative = up, positive = down).
    public mutating func moveSelection(delta: Int) {
        let len = results.topk.count
        guard len > 0 else { return }
        let maxIdx = len - 1
        let current = min(selected, maxIdx)
        selected = max(0, min(maxIdx, current + delta))
    }

    /// Select the next item in the results.
    public mutating func selectNext() {
        moveSelection(delta: 1)
    }

    /// Select the previous item in the results.
    public mutating func selectPrevious() {
        moveSelection(delta: -1)
    }

    /// Select the first item in the results.
    public mutating func selectFirst() {
        selected = 0
    }

    /// Select the last item in the results.
    public mutating func selectLast() {
        if !results.topk.isEmpty {
            selected = results.topk.count - 1
        }
    }

    /// Scroll up by rows.
    public mutating func scrollUp(rows: Int = 1) {
        scrollOffset = max(0, scrollOffset - rows)
    }

    /// Scroll down by rows.
    public mutating func scrollDown(rows: Int = 1) {
        let maxOffset = max(0, results.topk.count - 1)
        scrollOffset = min(maxOffset, scrollOffset + rows)
    }

    /// Move selection by a page (half of visible height).
    public mutating func pageMove(delta: Int, visibleRows: Int) {
        let half = max(1, visibleRows / 2)
        moveSelection(delta: delta * half)
    }

    /// Ensure the selected item is visible in the dropdown viewport.
    public mutating func ensureVisible(visibleRows: Int) {
        guard visibleRows > 0 else { return }
        if selected < scrollOffset {
            scrollOffset = selected
        } else if selected >= scrollOffset + visibleRows {
            scrollOffset = selected + 1 - visibleRows
        }
    }

    /// Set the hovered index. Returns `true` if changed.
    @discardableResult
    public mutating func setHovered(_ index: Int?) -> Bool {
        let clamped: Int?
        if let i = index, i >= 0, i < results.topk.count {
            clamped = i
        } else {
            clamped = nil
        }
        let changed = (clamped != hovered)
        self.hovered = clamped
        return changed
    }

    /// Select the hovered item (for click-to-accept).
    /// Returns `true` if there was a valid hovered item to select.
    @discardableResult
    public mutating func selectHovered() -> Bool {
        if let idx = hovered, idx >= 0, idx < results.topk.count {
            self.selected = idx
            return true
        }
        return false
    }

    /// Get the currently selected fuzzy match result.
    public func selectedResult() -> FuzzyMatchResult? {
        guard selected >= 0, selected < results.topk.count else { return nil }
        return results.topk[selected]
    }

    // MARK: - Results Updates & Replacement

    /// Update results from the background matcher, respecting minGeneration.
    @discardableResult
    public mutating func setResults(_ newResults: FuzzyMatcherDaemonResults) -> Bool {
        guard context != nil else { return false }
        if newResults.generation >= minGeneration {
            self.minGeneration = newResults.generation
            self.results = newResults
            if !self.results.topk.isEmpty {
                self.selected = min(self.selected, self.results.topk.count - 1)
            }
            return true
        }
        return false
    }

    /// Compute the text replacement for accepting the currently selected
    /// directory (drill-down acceptance).
    public func tryReplace(src: String) -> FileSearchReplacement? {
        guard let ctx = context else { return nil }
        guard selected >= 0, selected < results.topk.count else { return nil }
        let res = results.topk[selected]

        // Dir-only contract: this always appends `/`, so it is valid only for a
        // directory chosen in dir mode.
        if !res.isDir || !ctx.isDirMode {
            return nil
        }

        // Replace only the path portion of the @-token (preserving `@` and any
        // hidden-mode `!` marker).
        let range = ctx.pathRange
        let path = normalizeDisplayPath(res.path)
        let atEnd = (range.upperBound == src.count)

        guard range.lowerBound >= 0, range.upperBound <= src.count, range.lowerBound <= range.upperBound else {
            return nil
        }

        let startIdx = src.index(src.startIndex, offsetBy: range.lowerBound)
        let endIdx = src.index(src.startIndex, offsetBy: range.upperBound)
        let currentSlice = String(src[startIdx..<endIdx])

        let noOp = (currentSlice == acceptText(path: path, atEnd: false))
        let text = acceptText(path: path, atEnd: noOp && atEnd)

        var cursor = range.lowerBound + text.count
        if noOp && !atEnd {
            cursor += 1
        }

        return FileSearchReplacement(
            range: range,
            text: text,
            cursor: cursor,
            dismiss: noOp
        )
    }

    /// Install a test context + results snapshot for testing acceptance flows.
    public mutating func setTestState(
        context: AtContext,
        results: [FuzzyMatchResult],
        selected: Int = 0
    ) {
        self.context = context
        self.results = FuzzyMatcherDaemonResults(
            topk: results,
            numItems: results.count,
            isDone: true,
            generation: self.minGeneration
        )
        self.minGeneration += 1
        self.selected = selected
    }
}
