// OpenGrokTerminalCore.swift
//
// Platform-neutral terminal cell grid, viewport, capability, and input-event
// model (W2-S5 bootstrap scaffold). This target imports no AppKit, UIKit,
// SwiftUI, or platform console module; adapters exchange cells, capabilities,
// and input events only. The owning slice (W2-S5) replaces this scaffold with
// the full Unicode-aware cell grid, diff renderer, viewport, and ANSI/input
// parser; the protocols and value types here are the stable seam.
//
// Reference: xai-ratatui-inline, xai-ratatui-textarea (Ratatui-derived behavior
// reimplemented in a custom terminal abstraction).

import Foundation

/// A rectangular terminal size in cells.
public struct TerminalSize: Sendable, Equatable, Codable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        precondition(width >= 0 && height >= 0)
        self.width = width
        self.height = height
    }
}

/// Color depth negotiated with the host terminal.
public enum TerminalColorDepth: Sendable, Equatable, Codable {
    case monochrome
    case sixteenColor
    case twoFiftySixColor
    case trueColor
}

/// Terminal feature capabilities reported by the adapter.
public struct TerminalCapability: Sendable, Equatable, Codable {
    public var colorDepth: TerminalColorDepth
    public var supportsMouse: Bool
    public var supportsHyperlinks: Bool
    public var supportsSynchronizedOutput: Bool
    public var supportsAlternateScreen: Bool
    public var supportsFocusEvents: Bool
    public init(
        colorDepth: TerminalColorDepth = .trueColor,
        supportsMouse: Bool = true,
        supportsHyperlinks: Bool = true,
        supportsSynchronizedOutput: Bool = true,
        supportsAlternateScreen: Bool = true,
        supportsFocusEvents: Bool = true
    ) {
        self.colorDepth = colorDepth
        self.supportsMouse = supportsMouse
        self.supportsHyperlinks = supportsHyperlinks
        self.supportsSynchronizedOutput = supportsSynchronizedOutput
        self.supportsAlternateScreen = supportsAlternateScreen
        self.supportsFocusEvents = supportsFocusEvents
    }
}

/// A cell style modifier.
public struct CellStyle: Sendable, Equatable, Codable, OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let bold = CellStyle(rawValue: 1 << 0)
    public static let italic = CellStyle(rawValue: 1 << 1)
    public static let underline = CellStyle(rawValue: 1 << 2)
    public static let reverse = CellStyle(rawValue: 1 << 3)
    public static let strike = CellStyle(rawValue: 1 << 4)
}

/// A single terminal cell: a grapheme plus styling.
public struct Cell: Sendable, Equatable {
    public var grapheme: String
    public var style: CellStyle
    public var displayWidth: Int
    public init(grapheme: String, style: CellStyle = [], displayWidth: Int = 1) {
        self.grapheme = grapheme
        self.style = style
        self.displayWidth = displayWidth
    }
}

/// An input event delivered by the terminal adapter.
public enum InputEvent: Sendable, Equatable {
    case key(KeyEvent)
    case mouse(MouseEvent)
    case paste(String)
    case focusGained
    case focusLost
    case resize(TerminalSize)
}

/// A keyboard event.
public struct KeyEvent: Sendable, Equatable {
    public var key: String
    public var modifiers: KeyModifiers
    public init(key: String, modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

public struct KeyModifiers: Sendable, Equatable, Codable, OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let alt = KeyModifiers(rawValue: 1 << 2)
    public static let meta = KeyModifiers(rawValue: 1 << 3)
}

/// A mouse event.
public struct MouseEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case down, up, drag, scrollUp, scrollDown }
    public var kind: Kind
    public var x: Int
    public var y: Int
    public var button: Int
    public var modifiers: KeyModifiers
    public init(kind: Kind, x: Int, y: Int, button: Int = 0, modifiers: KeyModifiers = []) {
        self.kind = kind
        self.x = x
        self.y = y
        self.button = button
        self.modifiers = modifiers
    }
}

/// A read/write terminal surface backed by a cell grid.
public protocol TerminalSurface: Sendable {
    var size: TerminalSize { get }
    func cell(at point: TerminalPoint) -> Cell?
    mutating func setCell(_ cell: Cell, at point: TerminalPoint)
}

/// A 2D point on the terminal grid.
public struct TerminalPoint: Sendable, Equatable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}
