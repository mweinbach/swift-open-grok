// TerminalBackend.swift
//
// Backend protocol and in-memory recording backend for tests / pure rendering.

import Foundation

/// Clear region kind.
public enum ClearType: Sendable, Equatable {
    case all
    case afterCursor
    case currentLine
    case untilNewLine
}

/// Interface between the terminal double-buffer and the host I/O layer.
public protocol TerminalBackend: AnyObject {
    func draw(_ updates: [CellUpdate]) throws
    func hideCursor() throws
    func showCursor() throws
    func cursorPosition() throws -> TerminalPoint
    func setCursorPosition(_ position: TerminalPoint) throws
    func clear() throws
    func clearRegion(_ type: ClearType) throws
    func appendLines(_ n: Int) throws
    func size() throws -> TerminalSize
    func flush() throws
    /// Writable byte sink for raw ANSI (scrollback / resize paths / OSC 8).
    var writer: TerminalWriter { get }
}

extension TerminalBackend {
    /// Emit cell updates with OSC 8 hyperlink envelopes around runs that share
    /// a link. Mirrors Rust `emit_frame_with_links`: each linked run is wrapped
    /// once and `draw` is invoked exactly once per run (no double emission).
    public func drawWithLinks(
        _ updates: [CellUpdate],
        linkIds: [UInt32],
        linkTable: [LinkRef],
        area: TerminalRect
    ) throws {
        guard !updates.isEmpty else { return }
        let width = max(area.width, 1)

        func resolve(_ x: Int, _ y: Int) -> LinkRef? {
            let idx = (y - area.y) * width + (x - area.x)
            return resolveLink(ids: linkIds, table: linkTable, index: idx)
        }

        var i = 0
        while i < updates.count {
            let link = resolve(updates[i].x, updates[i].y)
            var j = i + 1
            while j < updates.count {
                if resolve(updates[j].x, updates[j].y) != link { break }
                j += 1
            }
            let run = Array(updates[i..<j])
            if let link {
                try writer.write(string: ANSIOutput.osc8Open(url: link.url, id: link.id))
                do {
                    try draw(run)
                } catch {
                    try? writer.write(string: ANSIOutput.osc8Close)
                    throw error
                }
                try writer.write(string: ANSIOutput.osc8Close)
            } else {
                try draw(run)
            }
            i = j
        }
    }
}

/// Appendable byte writer used by scrollback/resize helpers.
public protocol TerminalWriter: AnyObject {
    func write(bytes: [UInt8]) throws
    func write(string: String) throws
    func flush() throws
}

/// Simple in-memory writer.
public final class MemoryTerminalWriter: TerminalWriter, @unchecked Sendable {
    public private(set) var buffer: [UInt8] = []
    public private(set) var flushCount = 0

    public init() {}

    public func write(bytes: [UInt8]) throws {
        buffer.append(contentsOf: bytes)
    }

    public func write(string: String) throws {
        buffer.append(contentsOf: string.utf8)
    }

    public func flush() throws {
        flushCount += 1
    }

    public var utf8String: String {
        String(bytes: buffer, encoding: .utf8) ?? ""
    }

    public func reset() {
        buffer.removeAll(keepingCapacity: true)
        flushCount = 0
    }
}

/// Backend that records draw operations and writes cell symbols + OSC 8 via the writer.
public final class RecordingBackend: TerminalBackend {
    public let memoryWriter = MemoryTerminalWriter()
    public private(set) var appendedLines: Int = 0
    public private(set) var hiddenCursor = false
    public private(set) var cursor = TerminalPoint(x: 0, y: 0)
    public var terminalSize: TerminalSize

    public init(size: TerminalSize = TerminalSize(width: 80, height: 24)) {
        self.terminalSize = size
    }

    public var writer: TerminalWriter { memoryWriter }

    public func draw(_ updates: [CellUpdate]) throws {
        for u in updates where !u.cell.skip {
            try memoryWriter.write(string: u.cell.grapheme)
        }
    }

    public func hideCursor() throws { hiddenCursor = true }
    public func showCursor() throws { hiddenCursor = false }
    public func cursorPosition() throws -> TerminalPoint { cursor }
    public func setCursorPosition(_ position: TerminalPoint) throws { cursor = position }
    public func clear() throws {}
    public func clearRegion(_ type: ClearType) throws { _ = type }
    public func appendLines(_ n: Int) throws { appendedLines += n }
    public func size() throws -> TerminalSize { terminalSize }
    public func flush() throws { try memoryWriter.flush() }

    public func resize(to size: TerminalSize) {
        terminalSize = size
    }
}
