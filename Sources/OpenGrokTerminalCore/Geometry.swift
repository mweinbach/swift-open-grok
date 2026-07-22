// Geometry.swift
//
// Terminal geometry types for the cell grid and viewport.

import Foundation

/// A rectangular region on the terminal grid (origin top-left, cell units).
public struct TerminalRect: Sendable, Equatable, Hashable, Codable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = max(0, x)
        self.y = max(0, y)
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public static var zero: TerminalRect { TerminalRect(x: 0, y: 0, width: 0, height: 0) }

    public var area: Int { width * height }
    public var left: Int { x }
    public var top: Int { y }
    public var right: Int { x + width }
    public var bottom: Int { y + height }

    public func contains(x: Int, y: Int) -> Bool {
        x >= self.x && x < right && y >= self.y && y < bottom
    }

    public func asSize() -> TerminalSize {
        TerminalSize(width: width, height: height)
    }

    public func asPosition() -> TerminalPoint {
        TerminalPoint(x: x, y: y)
    }
}

/// How the terminal viewport is positioned relative to the host screen.
public enum ViewportKind: Sendable, Equatable, Hashable {
    /// Entire terminal screen.
    case fullscreen
    /// Inline viewport of fixed height (chat-style bottom UI).
    case inline(height: Int)
    /// Fixed absolute rectangle (does not autoresize).
    case fixed(TerminalRect)
}

/// Options used when constructing a [`Terminal`].
public struct TerminalOptions: Sendable, Equatable {
    public var viewport: ViewportKind
    public init(viewport: ViewportKind = .fullscreen) {
        self.viewport = viewport
    }
}
