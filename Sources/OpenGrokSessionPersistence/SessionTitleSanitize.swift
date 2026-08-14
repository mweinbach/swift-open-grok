// SessionTitleSanitize.swift
//
// Title sanitization and limits for session renaming.
// Ported from `crates/codegen/xai-grok-shell/src/session/persistence.rs`.

import Foundation

public let maxTitleBytes = 4096
public let maxTitleScalars = 100

/// Whether a character is a forbidden title character (C0/C1 controls, bidi overrides).
public func isForbiddenTitleCharacter(_ character: Character) -> Bool {
    for scalar in character.unicodeScalars {
        if scalar.properties.generalCategory == .control {
            return true
        }
        let v = scalar.value
        if (v <= 0x1F) || (v >= 0x7F && v <= 0x9F) || v == 0x200E || v == 0x200F || (v >= 0x202A && v <= 0x202E) || (v >= 0x2066 && v <= 0x2069) {
            return true
        }
    }
    return false
}

/// Drop C0/C1 and bidi/format controls, then trim.
public func sanitizeRenameTitle(_ title: String) -> String {
    let filtered = title.filter { !isForbiddenTitleCharacter($0) }
    return filtered.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Sanitize then cap to `maxTitleScalars`. Returns nil if blank.
public func sanitizeAndCapTitle(_ title: String) -> String? {
    let cleaned = sanitizeRenameTitle(title)
    if cleaned.isEmpty { return nil }
    if cleaned.count <= maxTitleScalars {
        return cleaned
    }
    return String(cleaned.prefix(maxTitleScalars))
}
