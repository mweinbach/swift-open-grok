// ModelGlobSet.swift
//
// Compiled glob matcher shared by `allowed_models`, `disabled_models`, and
// `hidden_models`. Patterns use globset syntax: `*`, `?`, `[...]`.

import Foundation

/// Compiled glob set. Fails closed on invalid patterns.
public struct ModelGlobSet: Sendable {
    private let patterns: [CompiledGlob]

    private init(patterns: [CompiledGlob]) {
        self.patterns = patterns
    }

    /// Compile a filter list (`nil` for None/empty). Invalid patterns return
    /// the bad pattern list in the error.
    public static func compile(_ patterns: [String]?) -> Result<ModelGlobSet?, ModelsError> {
        guard let patterns, !patterns.isEmpty else { return .success(nil) }
        var compiled: [CompiledGlob] = []
        var invalid: [String] = []
        for pat in patterns {
            if let g = CompiledGlob(pat) {
                compiled.append(g)
            } else {
                invalid.append(pat)
            }
        }
        if !invalid.isEmpty { return .failure(.invalidGlob(field: "models", patterns: invalid)) }
        return .success(ModelGlobSet(patterns: compiled))
    }

    public func matches(key: String, model: String) -> Bool {
        patterns.contains { $0.matches(key) || $0.matches(model) }
    }
}

/// Minimal glob matcher supporting `*`, `?`, and character classes.
struct CompiledGlob: Sendable {
    private let regex: NSRegularExpression

    init?(_ pattern: String) {
        // Reject unclosed character classes the same way globset fails closed.
        if hasUnclosedClass(pattern) { return nil }
        var regexPattern = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let ch = pattern[i]
            switch ch {
            case "*":
                regexPattern += ".*"
            case "?":
                regexPattern += "."
            case "[":
                // Find matching ]
                if let close = pattern[i...].dropFirst().firstIndex(of: "]") {
                    let body = pattern[pattern.index(after: i)..<close]
                    regexPattern += "[\(NSRegularExpression.escapedPattern(for: String(body)))]"
                    i = pattern.index(after: close)
                    continue
                } else {
                    return nil
                }
            case "\\":
                let next = pattern.index(after: i)
                if next < pattern.endIndex {
                    regexPattern += NSRegularExpression.escapedPattern(for: String(pattern[next]))
                    i = pattern.index(after: next)
                    continue
                } else {
                    regexPattern += "\\\\"
                }
            default:
                regexPattern += NSRegularExpression.escapedPattern(for: String(ch))
            }
            i = pattern.index(after: i)
        }
        regexPattern += "$"
        guard let re = try? NSRegularExpression(pattern: regexPattern, options: []) else {
            return nil
        }
        self.regex = re
    }

    func matches(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}

private func hasUnclosedClass(_ pattern: String) -> Bool {
    var inClass = false
    var i = pattern.startIndex
    while i < pattern.endIndex {
        let ch = pattern[i]
        if ch == "\\" {
            i = pattern.index(after: i)
            if i < pattern.endIndex { i = pattern.index(after: i) }
            continue
        }
        if ch == "[" { inClass = true }
        if ch == "]" { inClass = false }
        i = pattern.index(after: i)
    }
    return inClass
}
