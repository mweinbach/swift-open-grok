// InputEvents.swift
//
// Adapter-facing input events for the terminal surface.

import Foundation

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
public struct KeyEvent: Sendable, Equatable, Hashable {
    public var key: KeyCode
    public var modifiers: KeyModifiers
    /// Raw character when the key encodes a printable or C0 character.
    public var character: Character?

    public init(key: KeyCode, modifiers: KeyModifiers = [], character: Character? = nil) {
        self.key = key
        self.modifiers = modifiers
        self.character = character
    }

    /// Convenience for simple string-key tests retained from the scaffold.
    public init(key: String, modifiers: KeyModifiers = []) {
        self.modifiers = modifiers
        switch key {
        case "Enter": self.key = .enter
        case "Backspace": self.key = .backspace
        case "Delete": self.key = .delete
        case "Esc", "Escape": self.key = .escape
        case "Tab": self.key = .tab
        case "Up": self.key = .up
        case "Down": self.key = .down
        case "Left": self.key = .left
        case "Right": self.key = .right
        case "Home": self.key = .home
        case "End": self.key = .end
        default:
            if key.count == 1, let c = key.first {
                self.key = .char(c)
                self.character = c
                return
            }
            self.key = .char(key.first ?? "?")
            self.character = key.first
            return
        }
        self.character = nil
    }
}

public enum KeyCode: Sendable, Equatable, Hashable {
    case char(Character)
    case enter
    case backspace
    case delete
    case escape
    case tab
    case backTab
    case up, down, left, right
    case home, end
    case pageUp, pageDown
    case insert
    case f(Int)
    case null
}

public struct KeyModifiers: Sendable, Equatable, Codable, OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let alt = KeyModifiers(rawValue: 1 << 2)
    public static let meta = KeyModifiers(rawValue: 1 << 3)
    public static let superKey = KeyModifiers(rawValue: 1 << 4)
}

/// A mouse event.
public struct MouseEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case down, up, drag, move, scrollUp, scrollDown, scrollLeft, scrollRight
    }
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
