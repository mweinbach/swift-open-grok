import Foundation
import OpenGrokTerminalCore

/// Render-only snapshot; conversation ownership and wire decoding stay upstream.
public struct PagerFollowUpSuggestions: Sendable, Equatable, Hashable {
    public let sessionID: String
    public let responseID: String
    public let generation: UInt64
    public let connectionID: String?
    public let connectionGeneration: UInt64
    public var labels: [String]
    public var hoveredIndex: Int?

    public init(
        sessionID: String,
        responseID: String,
        generation: UInt64,
        connectionID: String? = nil,
        connectionGeneration: UInt64 = 0,
        labels: [String],
        hoveredIndex: Int? = nil
    ) {
        self.sessionID = sessionID
        self.responseID = responseID
        self.generation = generation
        self.connectionID = connectionID
        self.connectionGeneration = connectionGeneration
        self.labels = labels
        self.hoveredIndex = hoveredIndex
    }
}

/// The exact visible screen cells for one suggestion; clipped chips never exist.
public struct PagerFollowUpSuggestionChip: Sendable, Equatable, Hashable {
    public let sessionID: String
    public let responseID: String
    public let generation: UInt64
    public let connectionID: String?
    public let connectionGeneration: UInt64
    public let index: Int
    public let label: String
    public let frame: TerminalRect

    public init(
        sessionID: String,
        responseID: String,
        generation: UInt64,
        connectionID: String? = nil,
        connectionGeneration: UInt64 = 0,
        index: Int,
        label: String,
        frame: TerminalRect
    ) {
        self.sessionID = sessionID
        self.responseID = responseID
        self.generation = generation
        self.connectionID = connectionID
        self.connectionGeneration = connectionGeneration
        self.index = index
        self.label = label
        self.frame = frame
    }

    public func contains(x: Int, y: Int) -> Bool {
        frame.contains(x: x, y: y)
    }
}

public let pagerMaximumFollowUpChipLabelWidth = 48

/// Paint the contiguous fitting prefix exactly once and publish matching cells.
@discardableResult
public func pagerRenderFollowUpSuggestions(
    _ suggestions: PagerFollowUpSuggestions?,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) -> [PagerFollowUpSuggestionChip] {
    guard let suggestions, area.width > 0, area.height > 0 else { return [] }

    for x in area.x..<area.right {
        buffer.setCell(
            Cell(grapheme: " ", foreground: theme.textSecondary, background: theme.bgBase),
            x: x,
            y: area.y
        )
    }

    var chips: [PagerFollowUpSuggestionChip] = []
    var column = area.x
    for (index, rawLabel) in suggestions.labels.prefix(6).enumerated() {
        var safeScalars = String.UnicodeScalarView()
        for scalar in rawLabel.unicodeScalars where !pagerIsUnsafeDisplayScalar(scalar) {
            safeScalars.append(scalar)
        }
        let safeLabel = String(safeScalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeLabel.isEmpty else { break }

        let paintedLabel = pagerTruncatedFollowUpLabel(safeLabel)
        let text = "[ \(paintedLabel) ]"
        let width = UnicodeDisplayWidth.width(of: text)
        guard width > 0, column < area.right, width <= area.right - column else { break }

        let hovered = suggestions.hoveredIndex == index
        buffer.setString(
            x: column,
            y: area.y,
            text: text,
            foreground: hovered ? theme.textPrimary : theme.linkForeground,
            background: hovered ? theme.bgHover : theme.bgBase
        )
        chips.append(PagerFollowUpSuggestionChip(
            sessionID: suggestions.sessionID,
            responseID: suggestions.responseID,
            generation: suggestions.generation,
            connectionID: suggestions.connectionID,
            connectionGeneration: suggestions.connectionGeneration,
            index: index,
            label: safeLabel,
            frame: TerminalRect(x: column, y: area.y, width: width, height: 1)
        ))
        column += width + 1
    }
    return chips
}

public func pagerApplyFollowUpSuggestions(
    _ state: PagerRenderState,
    to result: inout PagerRenderResult
) {
    result.layout.followUpSuggestionChips = []
    guard let suggestions = state.followUpSuggestions,
          !suggestions.labels.isEmpty,
          !state.overlays.isActive,
          result.layout.input.height > 0,
          let area = result.layout.followUpSuggestions,
          area.height > 0
    else { return }
    let priorChromeEnd = max(
        result.layout.conversation.bottom,
        result.layout.completions.bottom,
        result.layout.turnStatus.bottom
    )
    guard area.y >= priorChromeEnd,
          area.y >= result.layout.bounds.y,
          area.bottom <= result.layout.input.y
    else { return }
    result.layout.followUpSuggestionChips = pagerRenderFollowUpSuggestions(
        suggestions,
        in: area,
        buffer: &result.buffer,
        theme: state.theme
    )
}

private func pagerTruncatedFollowUpLabel(_ label: String) -> String {
    guard UnicodeDisplayWidth.width(of: label) > pagerMaximumFollowUpChipLabelWidth else {
        return label
    }

    var output = ""
    var used = 0
    let budget = pagerMaximumFollowUpChipLabelWidth - 1
    for character in label {
        let grapheme = String(character)
        let width = UnicodeDisplayWidth.width(ofGrapheme: grapheme)
        guard used + width <= budget else { break }
        output.append(character)
        used += width
    }
    return output + "…"
}
