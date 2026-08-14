// KittyKeyboardProtocol.swift
//
// Kitty keyboard enhancement protocol flag query, negotiation, and state tracking.
// Ported from `crates/codegen/xai-grok-pager-render/src/terminal/kitty_keyboard.rs`.

import Foundation

/// Kitty keyboard enhancement flags negotiated with the terminal emulator.
public struct KeyboardEnhancementFlags: OptionSet, Sendable, Equatable, CustomStringConvertible {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let disambiguateEscapeCodes = KeyboardEnhancementFlags(rawValue: 1 << 0)
    public static let reportEventTypes = KeyboardEnhancementFlags(rawValue: 1 << 1)
    public static let reportAlternateKeys = KeyboardEnhancementFlags(rawValue: 1 << 2)
    public static let reportAllKeysAsEscapeCodes = KeyboardEnhancementFlags(rawValue: 1 << 3)
    public static let reportAssociatedText = KeyboardEnhancementFlags(rawValue: 1 << 4)

    public var description: String {
        var parts: [String] = []
        if contains(.disambiguateEscapeCodes) { parts.append("DISAMBIGUATE_ESCAPE_CODES") }
        if contains(.reportEventTypes) { parts.append("REPORT_EVENT_TYPES") }
        if contains(.reportAlternateKeys) { parts.append("REPORT_ALTERNATE_KEYS") }
        if contains(.reportAllKeysAsEscapeCodes) { parts.append("REPORT_ALL_KEYS_AS_ESCAPE_CODES") }
        if contains(.reportAssociatedText) { parts.append("REPORT_ASSOCIATED_TEXT") }
        return "KeyboardEnhancementFlags(\(parts.joined(separator: " | ")))"
    }
}

/// Highest packed `alacritty_terminal` version that mis-encodes `REPORT_EVENT_TYPES`.
/// 0.24.1 (Alacritty 0.14.0) -> 2401.
public let ALACRITTY_BROKEN_EVENT_TYPES_MAX_PACKED: UInt32 = 2401

/// Computes negotiated Kitty keyboard enhancement flags.
public func negotiatedKittyFlags(
    skipReason: String?,
    da2Packed: UInt32?
) -> KeyboardEnhancementFlags {
    if skipReason != nil {
        return []
    }
    var flags: KeyboardEnhancementFlags = [.disambiguateEscapeCodes]
    let misEncodesReleases = da2Packed.map { $0 <= ALACRITTY_BROKEN_EVENT_TYPES_MAX_PACKED } ?? false
    if !misEncodesReleases {
        flags.insert(.reportEventTypes)
    }
    return flags
}

/// Global thread-safe record of pushed Kitty keyboard flags.
public final class KittyKeyboardState: @unchecked Sendable {
    public static let shared = KittyKeyboardState()

    private let lock = NSLock()
    private var pushedFlags: KeyboardEnhancementFlags = []

    private init() {}

    public func setPushedFlags(_ flags: KeyboardEnhancementFlags) {
        lock.lock()
        defer { lock.unlock() }
        pushedFlags = flags
    }

    public func currentPushedFlags() -> KeyboardEnhancementFlags {
        lock.lock()
        defer { lock.unlock() }
        return pushedFlags
    }

    public func kittyFlagsPushed() -> Bool {
        !currentPushedFlags().isEmpty
    }

    public func kittyReleasesReported() -> Bool {
        currentPushedFlags().contains(.reportEventTypes)
    }

    public func kittyEventTypesWithheld() -> Bool {
        let flags = currentPushedFlags()
        return !flags.isEmpty && !flags.contains(.reportEventTypes)
    }

    public func takeKittyFlagsPushed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let hadFlags = !pushedFlags.isEmpty
        pushedFlags = []
        return hadFlags
    }
}

/// Escape sequences for Kitty keyboard enhancement protocol.
public enum KittyKeyboardSequences {
    public static func pushFlags(_ flags: KeyboardEnhancementFlags) -> String {
        "\u{1B}[>\(flags.rawValue)u"
    }

    public static let popFlags = "\u{1B}[<u"
}
