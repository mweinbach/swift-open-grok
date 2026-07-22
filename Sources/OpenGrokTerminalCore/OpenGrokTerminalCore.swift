// OpenGrokTerminalCore.swift
//
// Platform-neutral terminal cell grid, viewport, ANSI segmentation, double-
// buffered diff rendering, hyperlink layer, synchronized output, and
// scrollback/resize helpers.
//
// Reference: xai-ratatui-inline (Ratatui-derived inline terminal).
//
// This target imports no AppKit, UIKit, SwiftUI, or platform console module;
// adapters exchange cells, capabilities, and input events only.

import Foundation

/// A rectangular terminal size in cells.
public struct TerminalSize: Sendable, Equatable, Codable, Hashable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        precondition(width >= 0 && height >= 0)
        self.width = width
        self.height = height
    }
}

/// A 2D point on the terminal grid.
public struct TerminalPoint: Sendable, Equatable, Hashable, Codable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}
