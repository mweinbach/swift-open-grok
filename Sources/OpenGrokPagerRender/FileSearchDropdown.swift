// FileSearchDropdown.swift
//
// Dropdown list renderer for @-completion file search results.
//
// Renders fuzzy match results as a scrollable list with:
// - Selection highlight (background color on selected row)
// - Fuzzy match character highlighting (accent color on matched chars)
// - Scrollbar when results exceed visible height
// - Truncation with `…` for long paths
// - Suffix `/` in directory mode

import Foundation
import OpenGrokTerminalCore

/// A single fuzzy match result for file search @-completion.
public struct FuzzyMatchResult: Sendable, Equatable, Hashable {
    /// Path of the matched entry.
    public var path: String
    /// Matcher score, higher is better.
    public var score: UInt32
    /// Matched character indices.
    public var indices: [UInt32]
    /// Whether this entry is a directory.
    public var isDir: Bool

    public init(
        path: String,
        score: UInt32 = 0,
        indices: [UInt32] = [],
        isDir: Bool = false
    ) {
        self.path = path
        self.score = score
        self.indices = indices
        self.isDir = isDir
    }
}

/// Normalize a display path (strip leading `./`).
public func normalizeDisplayPath(_ path: String) -> String {
    if path.hasPrefix("./") {
        return String(path.dropFirst(2))
    }
    return path
}

/// Dropdown renderer for @-completion file search results.
public enum FileSearchDropdown {
    /// Maximum number of visible rows in the dropdown (excluding separator).
    public static let maxDropdownRows = 8

    /// Non-selected prefix — same width as the arrow, just spaces.
    public static let itemPrefix = "  "
    public static let prefixWidth = PagerGlyphs.promptArrowWidth

    /// Desired height for the dropdown (separator + min(results, max_rows)).
    public static func dropdownHeight(
        resultCount: Int,
        isVisible: Bool,
        maxRows: Int = maxDropdownRows
    ) -> Int {
        guard isVisible, resultCount > 0 else { return 0 }
        let resultRows = min(resultCount, maxRows)
        return 1 + resultRows
    }

    /// Render the file search dropdown items into the given area.
    ///
    /// This renders ONLY the result rows (no borders or separators).
    /// Panel chrome (clear, borders, count hint) is handled by the caller.
    /// The `area` covers just the item rows.
    public static func renderDropdown(
        buffer: inout CellBuffer,
        area: TerminalRect,
        results: [FuzzyMatchResult],
        selected: Int,
        hovered: Int? = nil,
        scrollOffset: Int = 0,
        isDirMode: Bool = false,
        theme: PagerRenderTheme
    ) {
        guard area.height > 0, area.width >= 4, !results.isEmpty else {
            return
        }

        let needsScrollbar = results.count > area.height
        let contentWidth = needsScrollbar ? max(0, area.width - 2) : area.width
        let visibleRows = area.height

        for row in 0..<visibleRows {
            let idx = scrollOffset + row
            guard idx < results.count else { break }

            let item = results[idx]
            let y = area.y + row
            let isSelected = (idx == selected)
            let isHovered = (hovered == idx && !isSelected)

            renderFuzzyItem(
                buffer: &buffer,
                x: area.x,
                y: y,
                width: contentWidth,
                item: item,
                isSelected: isSelected,
                isHovered: isHovered,
                hoverBg: theme.bgHover,
                isDirMode: isDirMode,
                theme: theme
            )
        }

        // Scrollbar
        if needsScrollbar {
            let scrollbarX = area.x + area.width - 1
            let total = max(1, results.count)
            let viewH = max(1, area.height)
            let thumbHeight = max(1, (viewH * viewH) / total)
            let thumbTop = min(viewH - thumbHeight, (scrollOffset * viewH) / total)

            for row in 0..<area.height {
                let y = area.y + row
                let isThumb = row >= thumbTop && row < (thumbTop + thumbHeight)
                let glyph = isThumb ? "█" : "│"
                let fg = isThumb ? theme.grayDim : theme.grayDim
                let bg = theme.bgDark

                // Gap column
                if area.width >= 2 {
                    buffer.setCell(
                        Cell(grapheme: " ", style: [], foreground: .reset, background: theme.bgDark, displayWidth: 1),
                        x: scrollbarX - 1,
                        y: y
                    )
                }

                buffer.setCell(
                    Cell(grapheme: glyph, style: [], foreground: fg, background: bg, displayWidth: 1),
                    x: scrollbarX,
                    y: y
                )
            }
        }
    }

    /// Render a single fuzzy match item with character-level match highlighting.
    private static func renderFuzzyItem(
        buffer: inout CellBuffer,
        x: Int,
        y: Int,
        width: Int,
        item: FuzzyMatchResult,
        isSelected: Bool,
        isHovered: Bool,
        hoverBg: TerminalColor,
        isDirMode: Bool,
        theme: PagerRenderTheme
    ) {
        guard width >= prefixWidth + 1 else { return }

        let path = normalizeDisplayPath(item.path)
        let rowBg: TerminalColor = isSelected ? theme.bgVisual : (isHovered ? hoverBg : theme.bgLight)
        let textFg = theme.textPrimary
        let boldStyle: CellStyle = isSelected ? [.bold] : []

        // Fill row with background
        for col in x..<(x + width) {
            buffer.setCell(
                Cell(grapheme: " ", style: [], foreground: .reset, background: rowBg, displayWidth: 1),
                x: col,
                y: y
            )
        }

        // Arrow on selected row, blank gutter on the rest
        let prefix = isSelected ? PagerGlyphs.promptArrow : itemPrefix
        let prefixStyle = boldStyle
        var prefixCol = x
        for ch in prefix {
            let chWidth = max(1, UnicodeDisplayWidth.width(of: String(ch)))
            if prefixCol + chWidth <= x + width {
                buffer.setCell(
                    Cell(
                        grapheme: String(ch),
                        style: prefixStyle,
                        foreground: isSelected ? textFg : .reset,
                        background: rowBg,
                        displayWidth: chWidth
                    ),
                    x: prefixCol,
                    y: y
                )
            }
            prefixCol += chWidth
        }

        // Styles
        let matchFg = theme.fuzzyAccent
        let normalFg = textFg

        var remainingIndices = item.indices[...]
        var col = x + prefixWidth
        let maxCol = x + width

        for (charIdx, ch) in path.enumerated() {
            let chWidth = max(1, UnicodeDisplayWidth.width(of: String(ch)))
            if col + chWidth > maxCol {
                // Truncation: replace last visible character with '…'
                if col > x + prefixWidth {
                    buffer.setCell(
                        Cell(
                            grapheme: PagerGlyphs.ellipsis,
                            style: boldStyle,
                            foreground: normalFg,
                            background: rowBg,
                            displayWidth: 1
                        ),
                        x: max(x + prefixWidth, col - 1),
                        y: y
                    )
                }
                break
            }

            let isMatch = remainingIndices.first == UInt32(charIdx)
            if isMatch {
                remainingIndices.removeFirst()
            }

            let fg = isMatch ? matchFg : normalFg
            buffer.setCell(
                Cell(
                    grapheme: String(ch),
                    style: boldStyle,
                    foreground: fg,
                    background: rowBg,
                    displayWidth: chWidth
                ),
                x: col,
                y: y
            )

            col += chWidth
        }

        // In dir mode, append '/' after the path if there is room
        if isDirMode, col < maxCol {
            buffer.setCell(
                Cell(
                    grapheme: "/",
                    style: boldStyle,
                    foreground: normalFg,
                    background: rowBg,
                    displayWidth: 1
                ),
                x: col,
                y: y
            )
        }
    }
}
