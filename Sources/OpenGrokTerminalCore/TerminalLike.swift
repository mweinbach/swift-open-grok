// TerminalLike.swift
//
// Abstraction used by scrollback/resize helpers + mock terminal for tests.

import Foundation

/// Terminal operations needed by emit-to-scrollback and resize helpers.
public protocol TerminalLike: AnyObject {
    func size() throws -> TerminalSize
    var viewportArea: TerminalRect { get }
    func clear() throws
    func resetBackBuffer()
    func setViewportArea(_ area: TerminalRect)
    var writer: TerminalWriter { get }
}

extension Terminal: TerminalLike {
    public var writer: TerminalWriter { backendRef.writer }
}

/// Execute a function with synchronized terminal output to prevent flicker.
///
/// Emits `\u{1B}[?2026h` / `\u{1B}[?2026l` around `body`. If `body` throws, the
/// end marker is still emitted so the terminal cannot hang in sync mode.
@discardableResult
public func withSynchronizedOutput<T: TerminalLike, R>(
    _ terminal: T,
    _ body: (T) throws -> R
) throws -> R {
    try terminal.writer.write(string: ANSIOutput.beginSynchronizedUpdate)
    do {
        let result = try body(terminal)
        try terminal.writer.write(string: ANSIOutput.endSynchronizedUpdate)
        try terminal.writer.flush()
        return result
    } catch {
        try? terminal.writer.write(string: ANSIOutput.endSynchronizedUpdate)
        try? terminal.writer.flush()
        throw error
    }
}

/// Mock terminal for unit tests (no real PTY / host I/O).
public final class MockTerminal: TerminalLike {
    public var terminalSize: TerminalSize
    public var viewportArea: TerminalRect
    public private(set) var clearCount = 0
    public private(set) var resetBackBufferCount = 0
    public private(set) var viewportUpdates: [TerminalRect] = []
    public let memoryWriter = MemoryTerminalWriter()

    public init(width: Int, height: Int, viewportHeight: Int) {
        let vh = min(max(viewportHeight, 0), height)
        self.terminalSize = TerminalSize(width: width, height: height)
        self.viewportArea = TerminalRect(
            x: 0,
            y: max(0, height - vh),
            width: width,
            height: vh
        )
    }

    public func size() throws -> TerminalSize { terminalSize }

    public func clear() throws {
        clearCount += 1
    }

    public func resetBackBuffer() {
        resetBackBufferCount += 1
        // Historical mock tracked resets via clear_count in Rust; keep both.
        clearCount += 1
    }

    public func setViewportArea(_ area: TerminalRect) {
        viewportUpdates.append(area)
        viewportArea = area
    }

    public var writer: TerminalWriter { memoryWriter }
}
