// StyleAndCell.swift
//
// Cell styles, colors, and the terminal cell value type.

import Foundation

/// Color depth negotiated with the host terminal.
public enum TerminalColorDepth: Sendable, Equatable, Codable, Hashable {
    case monochrome
    case sixteenColor
    case twoFiftySixColor
    case trueColor
}

/// A terminal color.
public enum TerminalColor: Sendable, Equatable, Hashable, Codable {
    case reset
    case black, red, green, yellow, blue, magenta, cyan, white
    case brightBlack, brightRed, brightGreen, brightYellow
    case brightBlue, brightMagenta, brightCyan, brightWhite
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
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

/// A cell style modifier (bit flags).
public struct CellStyle: Sendable, Equatable, Codable, OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let bold = CellStyle(rawValue: 1 << 0)
    public static let italic = CellStyle(rawValue: 1 << 1)
    public static let underline = CellStyle(rawValue: 1 << 2)
    public static let reverse = CellStyle(rawValue: 1 << 3)
    public static let strike = CellStyle(rawValue: 1 << 4)
    public static let dim = CellStyle(rawValue: 1 << 5)
    public static let blink = CellStyle(rawValue: 1 << 6)
    public static let hidden = CellStyle(rawValue: 1 << 7)
}

/// Full cell paint attributes.
public struct CellAttributes: Sendable, Equatable, Hashable {
    public var style: CellStyle
    public var foreground: TerminalColor
    public var background: TerminalColor

    public init(
        style: CellStyle = [],
        foreground: TerminalColor = .reset,
        background: TerminalColor = .reset
    ) {
        self.style = style
        self.foreground = foreground
        self.background = background
    }

    public static let empty = CellAttributes()
}

/// A single terminal cell: a grapheme plus styling.
public struct Cell: Sendable, Equatable {
    public var grapheme: String
    public var style: CellStyle
    public var foreground: TerminalColor
    public var background: TerminalColor
    public var displayWidth: Int
    /// When true the cell is a wide-character continuation (skip on draw).
    public var skip: Bool

    public init(
        grapheme: String = " ",
        style: CellStyle = [],
        foreground: TerminalColor = .reset,
        background: TerminalColor = .reset,
        displayWidth: Int? = nil,
        skip: Bool = false
    ) {
        self.grapheme = grapheme
        self.style = style
        self.foreground = foreground
        self.background = background
        if let displayWidth {
            self.displayWidth = displayWidth
        } else if skip {
            self.displayWidth = 0
        } else {
            let w = UnicodeDisplayWidth.width(of: grapheme)
            self.displayWidth = max(w, grapheme.isEmpty ? 0 : 0)
            if self.displayWidth == 0 && !grapheme.isEmpty && grapheme != " " {
                // Zero-width content still occupies a cell slot of width 0 for
                // diff purposes; empty/" " defaults to 1 for blank cells.
                self.displayWidth = 0
            } else if grapheme == " " || grapheme.isEmpty {
                self.displayWidth = 1
            }
        }
        self.skip = skip
    }

    public static var blank: Cell { Cell(grapheme: " ", displayWidth: 1) }

    public var attributes: CellAttributes {
        CellAttributes(style: style, foreground: foreground, background: background)
    }

    public mutating func setSymbol(_ symbol: String) {
        grapheme = symbol
        skip = false
        let w = UnicodeDisplayWidth.width(of: symbol)
        displayWidth = symbol == " " || symbol.isEmpty ? 1 : w
    }
}

/// Hyperlink region on a single screen row (absolute viewport coordinates).
public struct LinkSpan: Sendable, Equatable, Hashable {
    public var row: Int
    public var colStart: Int
    public var colEnd: Int
    public var url: String
    public var id: UInt32?

    public init(row: Int, colStart: Int, colEnd: Int, url: String, id: UInt32? = nil) {
        self.row = row
        self.colStart = colStart
        self.colEnd = colEnd
        self.url = url
        self.id = id
    }
}

/// Resolved hyperlink target stored in a frame's link table.
public struct LinkRef: Sendable, Equatable, Hashable {
    public var url: String
    public var id: UInt32?

    public init(url: String, id: UInt32? = nil) {
        self.url = url
        self.id = id
    }
}
