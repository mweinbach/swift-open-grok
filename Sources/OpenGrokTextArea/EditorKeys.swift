// EditorKeys.swift
//
// Key event → EditCommand classification (port of editor_keys.rs).

import Foundation
import OpenGrokTerminalCore

/// On Windows, AltGr arrives as Ctrl+Alt; elsewhere it is composed before delivery.
public func isAltGr(_ modifiers: KeyModifiers) -> Bool {
    #if os(Windows)
    let withoutShift = modifiers.subtracting(.shift)
    return withoutShift == [.control, .alt]
    #else
    return false
    #endif
}

/// Classify a key event into a semantic edit command, or `nil` when the host
/// adapter owns the binding (Home/End visual, Enter, undo, etc.).
public func classifyKeyEvent(_ event: KeyEvent) -> EditCommand? {
    let mods = event.modifiers
    switch event.key {
    case .char(let ch):
        // Bare C0 Ctrl-B / Ctrl-F encodings.
        if mods.isEmpty {
            if ch == "\u{0002}" { return .moveGraphemeLeft }
            if ch == "\u{0006}" { return .moveGraphemeRight }
            if ch == "\u{0008}" || ch == "\u{007F}" { return .deleteGraphemeBackward }
        }
        if ch == "h" && mods == [.control, .alt] {
            return .deleteWordBackward(.small)
        }
        if ch == "w" && mods == [.control] {
            return .deleteWordBackward(.whitespaceDelimited)
        }
        if ch == "a" && mods == [.control] { return .moveLogicalLineStart }
        if ch == "e" && mods == [.control] { return .moveLogicalLineEnd }
        if ch == "b" && mods == [.control] { return .moveGraphemeLeft }
        if ch == "f" && mods == [.control] { return .moveGraphemeRight }
        if ch == "b" && mods == [.alt] { return .moveWordLeft(.small) }
        if ch == "f" && mods == [.alt] { return .moveWordRight(.small) }
        if ch == "u" && mods == [.control] { return .deleteToLineStart }
        if ch == "k" && mods == [.control] { return .deleteToLineEnd }
        if ch == "h" && mods == [.control] { return .deleteGraphemeBackward }
        if ch == "d" && mods == [.control] { return .deleteGraphemeForward }
        if ch == "d" && (mods.contains(.alt) || mods.contains(.superKey) || mods.contains(.meta)) {
            return .deleteWordForward(.small)
        }
        // Insert printable.
        if mods.isEmpty || mods == [.shift] {
            if !ch.isASCIIControl {
                let character: Character
                if mods.contains(.shift), ch.isASCIILowercaseASCII {
                    character = Character(String(ch).uppercased())
                } else {
                    character = ch
                }
                return .insert(character)
            }
        }
        if isAltGr(mods) && !ch.isASCIIControl {
            return .insert(ch)
        }
        return nil

    case .backspace:
        return backspaceCommand(mods)
    case .delete:
        return deleteCommand(mods)
    case .left:
        if mods.contains(.alt) || mods.contains(.control) {
            return .moveWordLeft(.small)
        }
        if mods.isEmpty { return .moveGraphemeLeft }
        return nil
    case .right:
        if mods.contains(.alt) || mods.contains(.control) {
            return .moveWordRight(.small)
        }
        if mods.isEmpty { return .moveGraphemeRight }
        return nil
    default:
        return nil
    }
}

/// Whether `event` is the undo chord (Ctrl/Cmd+z, not Shift+Z redo).
public func isUndoInput(_ event: KeyEvent) -> Bool {
    if case .char(let ch) = event.key, ch == "z" || ch == "Z" {
        // Only lowercase z for undo; uppercase is redo path.
        if ch == "Z" { return false }
        return event.modifiers.contains(.control)
            || event.modifiers.contains(.superKey)
            || event.modifiers.contains(.meta)
    }
    return false
}

private func backspaceCommand(_ modifiers: KeyModifiers) -> EditCommand {
    if modifiers == .alt || modifiers == .control {
        return .deleteWordBackward(.small)
    }
    if modifiers == .superKey || modifiers == .meta {
        return .deleteToLineStart
    }
    return .deleteGraphemeBackward
}

private func deleteCommand(_ modifiers: KeyModifiers) -> EditCommand {
    if modifiers.contains(.alt) || modifiers.contains(.control)
        || modifiers.contains(.superKey) || modifiers.contains(.meta)
    {
        return .deleteWordForward(.small)
    }
    return .deleteGraphemeForward
}

private extension Character {
    var isASCIIControl: Bool {
        guard let v = unicodeScalars.first?.value else { return true }
        return v < 0x20 || v == 0x7F
    }

    var isASCIILowercaseASCII: Bool {
        guard let v = unicodeScalars.first?.value else { return false }
        return (0x61...0x7A).contains(v)
    }
}
