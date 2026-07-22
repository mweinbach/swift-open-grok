// Diff.swift
//
// Large-safe buffer diff (avoids u16 truncation) and hyperlink-aware variants.

import Foundation

/// A single cell update to emit to the backend.
public struct CellUpdate: Sendable, Equatable {
    public var x: Int
    public var y: Int
    public var cell: Cell

    public init(x: Int, y: Int, cell: Cell) {
        self.x = x
        self.y = y
        self.cell = cell
    }
}

/// Like ratatui `Buffer::diff` but safe for buffers whose `width * height > UInt16.max`.
public func diffLarge(previous: CellBuffer, next: CellBuffer) -> [CellUpdate] {
    precondition(previous.area == next.area || previous.content.count == next.content.count)
    let area = next.area
    let width = max(area.width, 1)
    var updates: [CellUpdate] = []
    var invalidated = 0
    var toSkip = 0

    let count = min(previous.content.count, next.content.count)
    for i in 0..<count {
        let current = next.content[i]
        let prev = previous.content[i]
        if !current.skip && (current != prev || invalidated > 0) && toSkip == 0 {
            let x = area.x + (i % width)
            let y = area.y + (i / width)
            updates.append(CellUpdate(x: x, y: y, cell: current))
        }
        let currentWidth = max(current.displayWidth, 0)
        let previousWidth = max(prev.displayWidth, 0)
        toSkip = currentWidth > 0 ? currentWidth - 1 : 0
        let affected = max(currentWidth, previousWidth)
        invalidated = max(affected, invalidated)
        if invalidated > 0 { invalidated -= 1 }
    }
    return updates
}

/// Like `diffLarge` but also rewrites cells whose hyperlink changed.
public func diffLargeWithLinks(
    previous: CellBuffer,
    next: CellBuffer,
    prevIds: [UInt32],
    nextIds: [UInt32],
    prevTable: [LinkRef],
    nextTable: [LinkRef]
) -> [CellUpdate] {
    let area = next.area
    let width = max(area.width, 1)
    var updates: [CellUpdate] = []
    var invalidated = 0
    var toSkip = 0

    let count = min(previous.content.count, next.content.count)
    for i in 0..<count {
        let current = next.content[i]
        let prev = previous.content[i]
        let linkChanged = resolveLink(ids: nextIds, table: nextTable, index: i)
            != resolveLink(ids: prevIds, table: prevTable, index: i)
        if !current.skip && (current != prev || linkChanged || invalidated > 0) && toSkip == 0 {
            let x = area.x + (i % width)
            let y = area.y + (i / width)
            updates.append(CellUpdate(x: x, y: y, cell: current))
        }
        let currentWidth = max(current.displayWidth, 0)
        let previousWidth = max(prev.displayWidth, 0)
        toSkip = currentWidth > 0 ? currentWidth - 1 : 0
        let affected = max(currentWidth, previousWidth)
        invalidated = max(affected, invalidated)
        if invalidated > 0 { invalidated -= 1 }
    }
    return updates
}

public func resolveLink(ids: [UInt32], table: [LinkRef], index: Int) -> LinkRef? {
    guard index < ids.count else { return nil }
    let id = ids[index]
    if id == 0 { return nil }
    let tableIndex = Int(id) - 1
    guard tableIndex >= 0, tableIndex < table.count else { return nil }
    return table[tableIndex]
}
