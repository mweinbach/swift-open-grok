// CursorRulesOnRead.swift
//
// Cursor project-rule reminders attached after successful file reads.
// Ported from `crates/codegen/xai-grok-tools/src/implementations/cursor_rules_on_read.rs`.

import Foundation
import OpenGrokShared

// MARK: - Rule Types

/// The categorization/activation kind of a Cursor rule.
public enum CursorRuleKind: Sendable, Codable, Equatable {
    case global
    case fileGlobbed([String])
    case agentFetched
    case manual
}

/// A parsed Cursor project rule from `.cursorrules` or `.cursor/rules/*.mdc`.
public struct ParsedCursorRule: Sendable, Codable, Equatable {
    public var fullPath: String
    public var scopeDir: String
    public var body: String
    public var kind: CursorRuleKind

    public init(
        fullPath: String,
        scopeDir: String,
        body: String,
        kind: CursorRuleKind
    ) {
        self.fullPath = fullPath
        self.scopeDir = scopeDir
        self.body = body
        self.kind = kind
    }
}

/// Parsed YAML frontmatter from a Cursor rule file.
public struct CursorRuleFrontmatter: Sendable, Equatable {
    public var alwaysApply: Bool?
    public var globs: [String]
    public var description: String?

    public init(
        alwaysApply: Bool? = nil,
        globs: [String] = [],
        description: String? = nil
    ) {
        self.alwaysApply = alwaysApply
        self.globs = globs
        self.description = description
    }
}

// MARK: - Frontmatter & Rule Parsing

/// Split YAML frontmatter from Markdown body.
/// Supports both Unix LF (`\n`) and Windows CRLF (`\r\n`) line endings.
public func splitFrontmatter(content: String) -> (frontmatter: String, body: String)? {
    guard content.hasPrefix("---") else { return nil }
    var rest = content.dropFirst(3)
    if rest.hasPrefix("\r\n") {
        rest = rest.dropFirst(1)
    } else if rest.hasPrefix("\n") {
        rest = rest.dropFirst(1)
    } else {
        return nil
    }

    let delimiters = ["\r\n---\r\n", "\r\n---\n", "\n---\r\n", "\n---\n"]
    for delimiter in delimiters {
        if let range = rest.range(of: delimiter) {
            let frontmatter = String(rest[..<range.lowerBound])
            let body = String(rest[range.upperBound...])
            return (frontmatter, body)
        }
    }

    if rest.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
        return ("", "")
    }

    return nil
}

/// Parse YAML frontmatter extracting `alwaysApply`, `globs`, and `description`.
public func parseFrontmatter(yaml: String) -> CursorRuleFrontmatter? {
    var alwaysApply: Bool? = nil
    var globs: [String] = []
    var description: String? = nil
    var sawField = false
    var inGlobsList = false

    let lines = yaml.components(separatedBy: CharacterSet.newlines)
    for rawLine in lines {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }

        if inGlobsList {
            if line.hasPrefix("-") {
                let item = String(line.dropFirst())
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                for part in item.split(separator: ",") {
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !trimmed.isEmpty {
                        globs.append(trimmed)
                    }
                }
                sawField = true
                continue
            } else if !line.contains(":") {
                continue
            } else {
                inGlobsList = false
            }
        }

        guard let colonIndex = line.firstIndex(of: ":") else { continue }
        let key = line[..<colonIndex].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: colonIndex)...]
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        switch key {
        case "alwaysApply", "always_apply":
            if value.caseInsensitiveCompare("true") == .orderedSame {
                alwaysApply = true
                sawField = true
            } else if value.caseInsensitiveCompare("false") == .orderedSame {
                alwaysApply = false
                sawField = true
            }
        case "globs":
            sawField = true
            if value.isEmpty {
                inGlobsList = true
            } else {
                var raw = value
                if raw.hasPrefix("[") && raw.hasSuffix("]") {
                    raw = String(raw.dropFirst().dropLast())
                }
                for part in raw.split(separator: ",") {
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !trimmed.isEmpty {
                        globs.append(trimmed)
                    }
                }
            }
        case "description":
            if !value.isEmpty {
                description = value
                sawField = true
            }
        default:
            break
        }
    }

    if sawField {
        return CursorRuleFrontmatter(alwaysApply: alwaysApply, globs: globs, description: description)
    }
    return nil
}

/// Parse a rule file's content into a `ParsedCursorRule`.
/// `.cursorrules` defaults to `.global` unless frontmatter overrides.
/// `.mdc` / `.md` files default to `.manual` unless frontmatter specifies `alwaysApply`, `globs`, or `description`.
public func parseCursorRule(
    scopeDir: String,
    fullPath: String,
    content: String
) -> ParsedCursorRule {
    let isCursorrulesFile = (fullPath as NSString).lastPathComponent == ".cursorrules"

    let (frontmatterStr, bodyStr): (String?, String)
    if let split = splitFrontmatter(content: content) {
        frontmatterStr = split.frontmatter
        bodyStr = split.body
    } else {
        frontmatterStr = nil
        bodyStr = content
    }

    let frontmatter = frontmatterStr.flatMap { parseFrontmatter(yaml: $0) }
    let kind: CursorRuleKind

    if let fm = frontmatter {
        if fm.alwaysApply == true {
            kind = .global
        } else if !fm.globs.isEmpty {
            kind = .fileGlobbed(fm.globs)
        } else if let desc = fm.description, !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            kind = .agentFetched
        } else if fm.alwaysApply == false {
            kind = .manual
        } else if isCursorrulesFile {
            kind = .global
        } else {
            kind = .manual
        }
    } else {
        if isCursorrulesFile {
            kind = .global
        } else {
            kind = .manual
        }
    }

    return ParsedCursorRule(
        fullPath: fullPath,
        scopeDir: scopeDir,
        body: bodyStr.trimmingCharacters(in: .whitespacesAndNewlines),
        kind: kind
    )
}

// MARK: - Path & Glob Utilities

/// Check whether a file extension matches Cursor rule file types (`.mdc` or `.md`).
public func isRuleFile(path: String) -> Bool {
    let ext = (path as NSString).pathExtension.lowercased()
    return ext == "mdc" || ext == "md"
}

/// Standardize and resolve a filesystem path, optionally anchoring relative paths to `root`.
public func normalizePath(_ path: String, relativeTo root: String? = nil) -> String {
    let absPath: String
    if path.hasPrefix("/") {
        absPath = path
    } else if let root {
        absPath = (root as NSString).appendingPathComponent(path)
    } else {
        absPath = path
    }
    let standardized = (absPath as NSString).standardizingPath
    let url = URL(fileURLWithPath: standardized)
    let resolved = url.resolvingSymlinksInPath().path
    return resolved.replacingOccurrences(of: "\\", with: "/")
}

/// Computes the relative path from `base` to `path` if `path` is within `base`.
public func relativePath(from base: String, to path: String) -> String? {
    let normBase = normalizePath(base)
    let normPath = normalizePath(path)
    if normBase == normPath {
        return ""
    }
    let baseWithSlash = normBase.hasSuffix("/") ? normBase : normBase + "/"
    if normPath.hasPrefix(baseWithSlash) {
        return String(normPath.dropFirst(baseWithSlash.count))
    }
    return nil
}

/// Tests whether `path` is equal to or inside `parent`.
public func isSubpath(_ path: String, of parent: String) -> Bool {
    let normPath = normalizePath(path)
    let normParent = normalizePath(parent)
    if normPath == normParent { return true }
    let parentWithSlash = normParent.hasSuffix("/") ? normParent : normParent + "/"
    return normPath.hasPrefix(parentWithSlash)
}

/// Returns the ancestor scope directories from `workspaceRoot` down to `readPath`'s parent directory.
public func ancestorScopeDirs(workspaceRoot: String, readPath: String) -> [String] {
    let normRoot = normalizePath(workspaceRoot)
    let normRead = normalizePath(readPath)
    let parent = (normRead as NSString).deletingLastPathComponent
    if !isSubpath(parent, of: normRoot) {
        return []
    }
    var dirs: [String] = []
    var current = parent
    while isSubpath(current, of: normRoot) {
        dirs.append(current)
        if current == normRoot {
            break
        }
        let next = (current as NSString).deletingLastPathComponent
        if next == current { break }
        current = next
    }
    return dirs.reversed()
}

/// Match a glob pattern against a candidate path string.
/// Supports `**` (recursive directory match), `*` (segment match), and `?` (character match).
public func globMatches(pattern: String, candidate: String) -> Bool {
    let pat = Array(pattern)
    let text = Array(candidate)

    func match(_ pi: Int, _ ti: Int) -> Bool {
        if pi == pat.count {
            return ti == text.count
        }

        // Handle **/ (zero or more directories)
        if pat[pi] == "*" && pi + 1 < pat.count && pat[pi + 1] == "*" {
            if pi + 2 < pat.count && pat[pi + 2] == "/" {
                // Option A: **/ matches 0 directories (skip **/)
                if match(pi + 3, ti) {
                    return true
                }
                // Option B: **/ matches one or more directory components
                var t = ti
                while t < text.count {
                    if text[t] == "/" {
                        if match(pi + 3, t + 1) || match(pi, t + 1) {
                            return true
                        }
                    }
                    t += 1
                }
                return false
            }

            // Case 2: ** at the end of pattern, matches everything remaining
            if pi + 2 == pat.count {
                return true
            }

            // Case 3: ** followed by something other than /
            var t = ti
            while t <= text.count {
                if match(pi + 2, t) {
                    return true
                }
                t += 1
            }
            return false
        }

        // Handle single * (matches within a path component, does not match /)
        if pat[pi] == "*" {
            var t = ti
            while true {
                if match(pi + 1, t) {
                    return true
                }
                if t >= text.count || text[t] == "/" {
                    break
                }
                t += 1
            }
            return false
        }

        // End of text check
        if ti >= text.count {
            return false
        }

        // Handle ?
        if pat[pi] == "?" {
            if text[ti] == "/" {
                return false
            }
            return match(pi + 1, ti + 1)
        }

        // Exact character match
        if pat[pi] == text[ti] {
            return match(pi + 1, ti + 1)
        }

        return false
    }

    return match(0, 0)
}

/// Normalizes relative glob pattern so single-segment globs (e.g. `*.swift`) become `**/*.swift`.
public func normalizeRelativeGlob(_ glob: String) -> String {
    if !glob.contains("/") || glob.hasSuffix("/") {
        return "**/\(glob)"
    } else {
        return glob
    }
}

/// Check if any glob pattern in `globs` matches `readPath` relative to `scopeDir`.
public func fileGlobsMatch(scopeDir: String, readPath: String, globs: [String]) -> Bool {
    let absoluteReadPath = normalizePath(readPath)
    let relativeCandidate = relativePath(from: scopeDir, to: readPath) ?? ""

    return globs.contains { glob in
        let normalized = glob.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("/") {
            return globMatches(pattern: normalized, candidate: absoluteReadPath)
        }
        return globMatches(pattern: normalized, candidate: relativeCandidate)
            || globMatches(pattern: normalizeRelativeGlob(normalized), candidate: relativeCandidate)
    }
}

/// Evaluates whether `rule` matches `readPath` within `workspaceRoot`.
public func ruleMatchesReadPath(
    rule: ParsedCursorRule,
    workspaceRoot: String,
    readPath: String
) -> Bool {
    let normScope = normalizePath(rule.scopeDir)
    let normRoot = normalizePath(workspaceRoot)
    let normRead = normalizePath(readPath)

    switch rule.kind {
    case .global:
        // Root global rules are loaded at session start as system prompt rules,
        // but nested global rules in subdirectories match reads within their scope.
        return normScope != normRoot && isSubpath(normRead, of: normScope)
    case .fileGlobbed(let globs):
        return fileGlobsMatch(scopeDir: normScope, readPath: normRead, globs: globs)
    case .agentFetched, .manual:
        return false
    }
}

// MARK: - Directory Scanning

/// Scan a directory for `.cursorrules` and `.cursor/rules/*.mdc` (or `*.md`) rules.
public func scanScopeDir(scopeDir: String) -> [ParsedCursorRule] {
    var rules: [ParsedCursorRule] = []
    let fm = FileManager.default

    // 1. Check <scopeDir>/.cursorrules
    let cursorrulesPath = (scopeDir as NSString).appendingPathComponent(".cursorrules")
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: cursorrulesPath, isDirectory: &isDir), !isDir.boolValue {
        if let content = try? String(contentsOfFile: cursorrulesPath, encoding: .utf8) {
            let fullPath = normalizePath(cursorrulesPath)
            rules.append(parseCursorRule(scopeDir: scopeDir, fullPath: fullPath, content: content))
        }
    }

    // 2. Check <scopeDir>/.cursor/rules
    let rulesDir = (scopeDir as NSString).appendingPathComponent(".cursor/rules")
    if fm.fileExists(atPath: rulesDir, isDirectory: &isDir), isDir.boolValue {
        var filesToRead: [String] = []
        var stack = [rulesDir]
        while let current = stack.popLast() {
            guard let entries = try? fm.contentsOfDirectory(atPath: current) else { continue }
            var subdirs: [String] = []
            var files: [String] = []
            for entry in entries {
                let full = (current as NSString).appendingPathComponent(entry)
                var entryIsDir: ObjCBool = false
                if fm.fileExists(atPath: full, isDirectory: &entryIsDir) {
                    if entryIsDir.boolValue {
                        subdirs.append(full)
                    } else if isRuleFile(path: full) {
                        files.append(full)
                    }
                }
            }
            subdirs.sort()
            files.sort()
            stack.append(contentsOf: subdirs.reversed())
            filesToRead.append(contentsOf: files)
        }

        filesToRead.sort()
        for file in filesToRead {
            if let content = try? String(contentsOfFile: file, encoding: .utf8) {
                let fullPath = normalizePath(file)
                rules.append(parseCursorRule(scopeDir: scopeDir, fullPath: fullPath, content: content))
            }
        }
    }

    return rules
}

// MARK: - Tracker Actor

/// Tracks discovered Cursor rules, scanned scope directories, and injected rule paths per session.
public actor CursorRulesOnReadTracker {
    public private(set) var scannedScopeDirs: Set<String>
    public private(set) var rules: [ParsedCursorRule]
    public private(set) var injectedRulePaths: Set<String>

    public init(
        scannedScopeDirs: Set<String> = [],
        rules: [ParsedCursorRule] = [],
        injectedRulePaths: Set<String> = []
    ) {
        self.scannedScopeDirs = scannedScopeDirs
        self.rules = rules
        self.injectedRulePaths = injectedRulePaths
    }

    /// Add an injected rule path to suppress future duplicates.
    public func markInjected(path: String, relativeTo root: String? = nil) {
        injectedRulePaths.insert(normalizePath(path, relativeTo: root))
    }

    /// Add multiple injected rule paths.
    public func markInjected(paths: Set<String>, relativeTo root: String? = nil) {
        for path in paths {
            injectedRulePaths.insert(normalizePath(path, relativeTo: root))
        }
    }

    /// Query and inject matching rules for a file read.
    public func rulesForRead(
        workspaceRoot: String,
        readPath: String
    ) -> [ParsedCursorRule] {
        let normRoot = normalizePath(workspaceRoot)
        let normRead = normalizePath(readPath)

        // Normalize injectedRulePaths against workspace root
        var normalizedInjected: Set<String> = []
        for path in injectedRulePaths {
            normalizedInjected.insert(normalizePath(path, relativeTo: normRoot))
        }
        injectedRulePaths = normalizedInjected

        let scopeDirs = ancestorScopeDirs(workspaceRoot: normRoot, readPath: normRead)
        guard !scopeDirs.isEmpty else { return [] }

        let dirsToScan = scopeDirs.filter { !scannedScopeDirs.contains($0) }
        for dir in dirsToScan {
            let discovered = scanScopeDir(scopeDir: dir)
            appendNewRules(discovered)
            scannedScopeDirs.insert(dir)
        }

        var matchingRules: [ParsedCursorRule] = []
        for rule in rules {
            if injectedRulePaths.contains(rule.fullPath) {
                continue
            }
            if ruleMatchesReadPath(rule: rule, workspaceRoot: normRoot, readPath: normRead) {
                injectedRulePaths.insert(rule.fullPath)
                matchingRules.append(rule)
            }
        }
        return matchingRules
    }

    private func appendNewRules(_ discovered: [ParsedCursorRule]) {
        var existingPaths = Set(rules.map(\.fullPath))
        for rule in discovered {
            if !existingPaths.contains(rule.fullPath) {
                existingPaths.insert(rule.fullPath)
                rules.append(rule)
            }
        }
    }
}

// MARK: - Rendering & Attachment Helpers

/// Renders matching rules into XML-style `<cursor_rule path="...">...</cursor_rule>` blocks.
public func renderCursorRuleBlocks(rules: [ParsedCursorRule], workspaceRoot: String) -> String {
    guard !rules.isEmpty else { return "" }
    return rules.map { rule in
        let relPath = relativePath(from: workspaceRoot, to: rule.fullPath) ?? rule.fullPath
        let body = rule.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return "<cursor_rule path=\"\(relPath)\">\n\(body)\n</cursor_rule>"
    }.joined(separator: "\n\n")
}

/// Renders matching rules into human-readable reminder text (Rust reference parity).
public func renderCursorRuleReminder(rules: [ParsedCursorRule]) -> String? {
    guard !rules.isEmpty else { return nil }
    var lines = ["The following rule files are relevant to the files you just read:"]
    for rule in rules {
        let body = rule.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(Rule file is empty.)"
            : rule.body.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("- \(rule.fullPath)\n\(body)")
    }
    lines.append("Consider these rules if they affect your changes.")
    return lines.joined(separator: "\n\n")
}

/// Helper function to evaluate and append Cursor rule reminders after a file read.
public func appendCursorRulesForRead(
    enabled: Bool,
    tracker: CursorRulesOnReadTracker,
    workspaceRoot: String,
    readPath: String,
    content: inout String,
    contentConcise: inout String?
) async {
    guard enabled else { return }
    let matching = await tracker.rulesForRead(workspaceRoot: workspaceRoot, readPath: readPath)
    guard !matching.isEmpty else { return }

    let blocks = renderCursorRuleBlocks(rules: matching, workspaceRoot: workspaceRoot)
    guard !blocks.isEmpty else { return }

    if !content.isEmpty {
        content.append("\n\n")
    }
    content.append(blocks)

    if var concise = contentConcise {
        if !concise.isEmpty {
            concise.append("\n\n")
        }
        concise.append(blocks)
        contentConcise = concise
    }
}
