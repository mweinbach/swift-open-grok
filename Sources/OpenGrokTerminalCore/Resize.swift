// Resize.swift
//
// Terminal resize: purge-and-rerender scrollback history, and viewport height
// adjustments for inline viewports.

import Foundation

public enum ViewportResizeError: Error, Equatable, CustomStringConvertible {
    case invalidHeight(requested: Int, terminalHeight: Int)

    public var description: String {
        switch self {
        case .invalidHeight(let requested, let terminalHeight):
            return "Invalid viewport height: \(requested) (terminal height: \(terminalHeight))"
        }
    }
}

/// Handles terminal resize by clearing the screen/scrollback and re-rendering
/// history (nuclear option for consistent reflow across hosts).
public func resizePurgeRerender<T: TerminalLike>(_ terminal: T, history: String) throws {
    let viewport = terminal.viewportArea
    let size = try terminal.size()

    try terminal.writer.write(string: ANSIOutput.clearScreenAndScrollbackHome)
    try terminal.writer.flush()

    let newlineCount = 1 + history.utf8.filter { $0 == 0x0A }.prefix(size.height).count

    try terminal.writer.write(string: history)
    for _ in 0..<viewport.height {
        try terminal.writer.write(string: "\r\n")
    }

    let viewportY: Int
    if newlineCount + viewport.height >= size.height {
        viewportY = max(0, size.height - viewport.height)
    } else {
        let segments = splitIntoLineSegments(history, termWidth: max(size.width, 1))
        let numVisible = min(segments.count, Int(UInt16.max))
        viewportY = min(numVisible, max(0, size.height - viewport.height))
    }

    try terminal.writer.flush()
    terminal.setViewportArea(TerminalRect(
        x: 0,
        y: viewportY,
        width: size.width,
        height: viewport.height
    ))
    try terminal.clear()
}

/// Resize the viewport to a new height with terminal dimensions unchanged.
///
/// - Shrinking: anchors to top (gap appears at bottom).
/// - Growing: expands down first, then pushes content up if needed.
public func resizeViewportHeight<T: TerminalLike>(_ terminal: T, newHeight: Int) throws {
    let size = try terminal.size()
    let current = terminal.viewportArea
    let oldHeight = current.height

    if newHeight == oldHeight { return }

    if newHeight == 0 || newHeight >= size.height {
        throw ViewportResizeError.invalidHeight(requested: newHeight, terminalHeight: size.height)
    }

    if newHeight > oldHeight {
        let growth = newHeight - oldHeight
        let bottomEdge = current.y + current.height
        let spaceBelow = max(0, size.height - bottomEdge)
        let newY: Int
        if spaceBelow >= growth {
            newY = current.y
        } else if spaceBelow > 0 {
            newY = max(0, current.y - (growth - spaceBelow))
        } else {
            newY = max(0, size.height - newHeight)
        }

        if newY < current.y {
            let scrollAmount = current.y - newY
            try terminal.writer.write(string: ANSIOutput.moveTo(column: 0, row: size.height - 1))
            for _ in 0..<scrollAmount {
                try terminal.writer.write(string: "\r\n")
            }
            try terminal.writer.flush()
        }

        try terminal.clear()
        terminal.setViewportArea(TerminalRect(
            x: 0,
            y: newY,
            width: current.width,
            height: newHeight
        ))
    } else {
        try terminal.clear()
        terminal.setViewportArea(TerminalRect(
            x: 0,
            y: current.y,
            width: current.width,
            height: newHeight
        ))
    }
}
