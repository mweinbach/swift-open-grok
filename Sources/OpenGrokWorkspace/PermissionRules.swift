// PermissionRules.swift
//
// Permission rule-string DSL. Ported from
// `xai-grok-workspace/src/permission/rules.rs`.

import Foundation

public enum RuleParseError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedToolPrefix(String)
    case unknownToolPrefix(String)
    case malformedRule(String)

    public var description: String {
        switch self {
        case .unsupportedToolPrefix(let p): return "unsupported tool prefix: \(p)"
        case .unknownToolPrefix(let p): return "unknown tool prefix: \(p)"
        case .malformedRule(let d): return "malformed rule: \(d)"
        }
    }
}

/// Parse a permission rule string into a native `PermissionRule`.
public func parsePermissionRule(
    _ rule: String,
    action: RuleAction,
    source: PermissionRuleSource = .unknown
) throws -> PermissionRule {
    let rule = rule.trimmingCharacters(in: .whitespacesAndNewlines)

    if let openParen = findFirstUnescaped(rule, Character("(")) {
        let prefix = String(rule[..<openParen]).trimmingCharacters(in: .whitespaces)
        let afterOpen = rule.index(after: openParen)
        let contentAndClose = rule[afterOpen...]
        guard let closeRel = findLastUnescaped(String(contentAndClose), Character(")")) else {
            throw RuleParseError.malformedRule("missing closing parenthesis")
        }
        let closeIdx = contentAndClose.index(contentAndClose.startIndex, offsetBy: closeRel)
        let rawContent = String(contentAndClose[..<closeIdx]).trimmingCharacters(in: .whitespaces)
        var pattern: String
        if rawContent.isEmpty || rawContent == "*" {
            pattern = ""
        } else {
            pattern = unescapeRuleContent(rawContent)
        }

        guard let tool = toolNameToFilter(prefix) else {
            if prefix == "EnterWorktree" {
                throw RuleParseError.unsupportedToolPrefix(prefix)
            }
            throw RuleParseError.unknownToolPrefix(prefix)
        }

        if tool == .bash {
            pattern = stripBashColonWildcard(pattern)
        }
        let stripped = stripDomainPrefix(pattern)
        pattern = stripped.pattern
        let mode = stripped.mode

        return PermissionRule(
            action: action,
            tool: tool,
            pattern: pattern.isEmpty ? nil : pattern,
            patternMode: mode,
            source: source
        )
    }

    if let tool = toolNameToFilter(rule) {
        return PermissionRule(action: action, tool: tool, pattern: nil, source: source)
    }

    if rule == "*" || rule == "Any" {
        return PermissionRule(action: action, tool: .any, pattern: nil, source: source)
    }

    return PermissionRule(
        action: action,
        tool: .any,
        pattern: rule.isEmpty ? nil : rule,
        source: source
    )
}

public func toolNameToFilter(_ name: String) -> ToolFilter? {
    switch name {
    case "Bash": return .bash
    case "Read", "NotebookRead": return .read
    case "Edit", "Write", "NotebookEdit": return .edit
    case "MCPTool": return .mcp
    case "Grep", "Glob": return .grep
    case "WebFetch": return .webFetch
    case "WebSearch": return .webSearch
    case "Any", "*": return .any
    default: return nil
    }
}

func stripBashColonWildcard(_ pattern: String) -> String {
    // `Bash(cmd:*)` → prefix `cmd`
    if pattern.hasSuffix(":*") {
        return String(pattern.dropLast(2))
    }
    return pattern
}

func stripDomainPrefix(_ pattern: String) -> (pattern: String, mode: PatternMode) {
    if pattern.hasPrefix("domain:") {
        return (String(pattern.dropFirst("domain:".count)), .domain)
    }
    return (pattern, .glob)
}

/// Three ordered literal replacements, matching `rules.rs:277`.
///
/// A generic "strip the backslash before any character" loop is wrong here:
/// `Bash(find . -name \*.rs)` must keep its `\*` so the pattern stays a
/// literal asterisk. Stripping it turns the pattern into a glob, which widens
/// allow rules and narrows deny rules.
func unescapeRuleContent(_ s: String) -> String {
    s.replacingOccurrences(of: "\\(", with: "(")
        .replacingOccurrences(of: "\\)", with: ")")
        .replacingOccurrences(of: "\\\\", with: "\\")
}

func findFirstUnescaped(_ s: String, _ target: Character) -> String.Index? {
    let bytes = Array(s.utf8)
    let targetByte = target.asciiValue!
    var i = 0
    while i < bytes.count {
        if bytes[i] == targetByte && isUnescaped(bytes, i) {
            return s.index(s.startIndex, offsetBy: i)
        }
        i += 1
    }
    return nil
}

func findLastUnescaped(_ s: String, _ target: Character) -> Int? {
    let bytes = Array(s.utf8)
    let targetByte = target.asciiValue!
    var i = bytes.count
    while i > 0 {
        i -= 1
        if bytes[i] == targetByte && isUnescaped(bytes, i) {
            return i
        }
    }
    return nil
}

func isUnescaped(_ bytes: [UInt8], _ pos: Int) -> Bool {
    var bs = 0
    var i = pos
    while i > 0 {
        i -= 1
        if bytes[i] == UInt8(ascii: "\\") {
            bs += 1
        } else {
            break
        }
    }
    return bs % 2 == 0
}

/// Apply `defaultMode` synthetic rules onto a config.
public func applyDefaultMode(_ mode: DefaultPermissionMode, to config: inout PermissionConfig) {
    let effects = mode.effects
    config.promptPolicy = effects.promptPolicy
    if effects.acceptEdits {
        config.rules.append(PermissionRule(
            action: .allow,
            tool: .edit,
            pattern: nil,
            source: .synthetic
        ))
    }
    if effects.bypassPermissions {
        config.rules.append(PermissionRule(
            action: .allow,
            tool: .any,
            pattern: nil,
            source: .synthetic
        ))
    }
}
