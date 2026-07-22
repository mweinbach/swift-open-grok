// Scrollback.swift
//
// Emit content into the terminal's native scrollback above an inline viewport.

import Foundation

/// Print `content` into scrollback above the current inline viewport, reserve
/// viewport space, and reposition the viewport.
public func emitToScrollback<T: TerminalLike>(_ terminal: T, content: String) throws {
    let size = try terminal.size()
    let viewport = terminal.viewportArea
    let terminalWidth = max(size.width, 1)

    let segments = splitIntoLineSegments(content, termWidth: terminalWidth)
    let newViewportY = min(
        viewport.y + segments.count,
        max(0, size.height - viewport.height)
    )

    // Position from viewport top and clear from this position down.
    try terminal.writer.write(string: ANSIOutput.moveTo(column: 0, row: viewport.y))
    try terminal.writer.write(string: ANSIOutput.clearFromCursorDown)

    try terminal.writer.write(string: ANSIOutput.moveTo(column: 0, row: viewport.y))
    for segment in segments {
        try terminal.writer.write(string: segment.rendered)
    }

    for _ in 0..<viewport.height {
        try terminal.writer.write(string: "\r\n")
    }

    try terminal.writer.write(string: ANSIOutput.moveTo(column: 0, row: newViewportY))
    try terminal.writer.write(string: ANSIOutput.clearFromCursorDown)
    try terminal.writer.flush()

    terminal.resetBackBuffer()

    if newViewportY != viewport.y {
        terminal.setViewportArea(TerminalRect(
            x: viewport.x,
            y: newViewportY,
            width: viewport.width,
            height: viewport.height
        ))
    }
}
