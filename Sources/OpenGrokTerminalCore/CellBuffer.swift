// CellBuffer.swift
//
// Row-major cell grid buffer used by the double-buffered terminal.

import Foundation

/// A rectangular cell buffer.
public struct CellBuffer: Sendable, Equatable {
    public private(set) var area: TerminalRect
    public private(set) var content: [Cell]

    public init(area: TerminalRect) {
        self.area = area
        let count = max(0, area.width * area.height)
        self.content = Array(repeating: .blank, count: count)
    }

    public static func empty(_ area: TerminalRect) -> CellBuffer {
        CellBuffer(area: area)
    }

    public var width: Int { area.width }
    public var height: Int { area.height }

    public subscript(index: Int) -> Cell {
        get { content[index] }
        set { content[index] = newValue }
    }

    public func index(x: Int, y: Int) -> Int? {
        guard area.contains(x: x, y: y) else { return nil }
        let localX = x - area.x
        let localY = y - area.y
        return localY * area.width + localX
    }

    public func cell(x: Int, y: Int) -> Cell? {
        guard let i = index(x: x, y: y) else { return nil }
        return content[i]
    }

    public mutating func setCell(_ cell: Cell, x: Int, y: Int) {
        guard let i = index(x: x, y: y) else { return }
        content[i] = cell
        // Mark trailing cells of wide graphemes as skip.
        let w = max(1, cell.displayWidth)
        if w > 1 {
            for dx in 1..<w {
                if let j = index(x: x + dx, y: y) {
                    content[j] = Cell(grapheme: "", displayWidth: 0, skip: true)
                }
            }
        }
    }

    /// Write a string starting at (x, y) with the given attributes.
    @discardableResult
    public mutating func setString(
        x: Int,
        y: Int,
        text: String,
        style: CellStyle = [],
        foreground: TerminalColor = .reset,
        background: TerminalColor = .reset
    ) -> Int {
        var col = x
        for grapheme in text {
            let s = String(grapheme)
            let w = max(UnicodeDisplayWidth.width(of: s), 0)
            let width = w == 0 ? 0 : w
            if width == 0 {
                // Zero-width: attach to previous or store in-place with width 0.
                if let i = index(x: col, y: y), col > x {
                    // Prefer attaching to previous cell symbol.
                    let prevIdx = index(x: col - 1, y: y) ?? i
                    content[prevIdx].grapheme += s
                } else if let i = index(x: col, y: y) {
                    content[i] = Cell(
                        grapheme: s,
                        style: style,
                        foreground: foreground,
                        background: background,
                        displayWidth: 0
                    )
                }
                continue
            }
            if col + width > area.right { break }
            setCell(
                Cell(
                    grapheme: s,
                    style: style,
                    foreground: foreground,
                    background: background,
                    displayWidth: width
                ),
                x: col,
                y: y
            )
            col += width
        }
        return col - x
    }

    public mutating func reset() {
        for i in content.indices {
            content[i] = .blank
        }
    }

    public mutating func resize(_ newArea: TerminalRect) {
        var next = CellBuffer(area: newArea)
        let copyW = min(area.width, newArea.width)
        let copyH = min(area.height, newArea.height)
        for row in 0..<copyH {
            for col in 0..<copyW {
                if let src = index(x: area.x + col, y: area.y + row),
                   let dst = next.index(x: newArea.x + col, y: newArea.y + row)
                {
                    next.content[dst] = content[src]
                }
            }
        }
        self = next
    }
}

/// A read/write terminal surface backed by a cell grid.
public protocol TerminalSurface: Sendable {
    var size: TerminalSize { get }
    func cell(at point: TerminalPoint) -> Cell?
    mutating func setCell(_ cell: Cell, at point: TerminalPoint)
}

extension CellBuffer: TerminalSurface {
    public var size: TerminalSize { area.asSize() }

    public func cell(at point: TerminalPoint) -> Cell? {
        cell(x: point.x, y: point.y)
    }

    public mutating func setCell(_ cell: Cell, at point: TerminalPoint) {
        setCell(cell, x: point.x, y: point.y)
    }
}
