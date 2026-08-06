// BashSplit.swift
//
// Lightweight bash command segmentation without tree-sitter.
// Fail-closed: unparseable / high-risk constructs return nil → Ask.

import Foundation

/// Wrappers peeled for deny/ask/grants/safe lists. `sudo` / `xargs` / `nohup`
/// are intentionally NOT peeled.
private let peelableWrappers: Set<String> = [
    "nice", "ionice", "chrt", "stdbuf",
]

/// Setup commands skipped for "primary" classification.
public let setupCommands: Set<String> = [
    "cd", "export", "sleep", "true", ":", "shift", "umask", "ulimit",
]

/// Dangerous command **prefixes** (word-boundary matched). Always need a
/// prompt even with remembered grants. Mirrors Rust `is_dangerous_command_words`.
public let dangerousCommandPrefixes: [String] = [
    "rm", "chmod", "chown", "chgrp", "chattr",
    "pkill", "kill", "killall", "git push",
]

/// Additional high-risk commands (word-boundary) that force a prompt.
public let extendedDangerousPrefixes: [String] = [
    "rmdir", "dd", "mkfs", "shutdown", "reboot", "halt", "poweroff",
    "sudo", "su", "mount", "umount", "userdel", "passwd",
    "curl", "wget", "nc", "ncat", "bash", "sh", "zsh", "python", "python3",
    "perl", "ruby", "node", "osascript",
]

/// Built-in always-safe command prefixes (word-boundary). CWE-183: `tr`
/// must not match `truncate`; `git` must not match `gitleaks`.
public let alwaysSafeCommandPrefixes: [String] = [
    "ls", "cat", "pwd", "date", "whoami", "hostname", "uptime", "ps",
    "git status", "git branch", "git log", "git diff", "git ls-files",
    "git show", "git rev-parse",
    "grep", "rg",
    "cargo check",
    "kubectl get", "kubectl logs", "kubectl describe",
    "head", "tail", "wc", "sort", "uniq", "tr", "cut",
]

/// Broader safe list for classification (word-boundary on first token only).
public let safeCommands: Set<String> = [
    "ls", "pwd", "echo", "cat", "head", "tail", "wc", "true", "false",
    "date", "whoami", "hostname", "uname", "which", "type",
    "rg", "grep", "find", "fd", "bat", "less", "more", "file", "stat",
    "diff", "sort", "uniq", "tr", "cut", "awk", "sed", "jq",
]

/// CWE-183 word-boundary prefix match: equal, or pattern followed by space.
public func matchesCommandPrefix(_ cmd: String, pattern: String) -> Bool {
    if cmd == pattern { return true }
    if cmd.hasPrefix(pattern) {
        let idx = cmd.index(cmd.startIndex, offsetBy: pattern.count)
        return idx < cmd.endIndex && cmd[idx] == " "
    }
    return false
}

/// True when `rg` is invoked with `--pre` / `--pre=` (exec preprocessor).
public func rgHasPreFlag(_ words: [String]) -> Bool {
    words.contains { $0 == "--pre" || $0.hasPrefix("--pre=") }
}

public func isDangerousCommandWords(_ words: [String]) -> Bool {
    guard !words.isEmpty else { return false }
    let joined = words.joined(separator: " ")
    for p in dangerousCommandPrefixes where matchesCommandPrefix(joined, pattern: p) {
        return true
    }
    for p in extendedDangerousPrefixes where matchesCommandPrefix(joined, pattern: p) {
        return true
    }
    return false
}

public func isAlwaysSafeCommandWords(_ words: [String]) -> Bool {
    guard !words.isEmpty else { return false }
    if rgHasPreFlag(words) { return false }
    let joined = words.joined(separator: " ")
    for p in alwaysSafeCommandPrefixes where matchesCommandPrefix(joined, pattern: p) {
        return true
    }
    return false
}

/// Legacy name kept for callers.
///
/// Built with an explicit loop rather than `Set(mapA + mapB)`: that one
/// expression exceeds the Linux type checker's budget.
public let dangerousCommands: Set<String> = {
    var names = Set<String>()
    for prefix in dangerousCommandPrefixes + extendedDangerousPrefixes {
        let head = prefix.split(separator: " ").first.map(String.init) ?? prefix
        names.insert(head)
    }
    return names
}()

/// Split a script on `&&`, `||`, `;`, `|`, newlines into word-only segments.
/// Returns `nil` when high-risk constructs are detected (fail closed).
public func allCommandsFromScript(_ script: String) -> [[String]]? {
    // Fail closed on common high-risk constructs (subshells / substitutions /
    // process substitution / control flow / bare background).
    if script.contains("$(") || script.contains("`") || script.contains("${") {
        return nil
    }
    if script.contains("<(") || script.contains(">(") {
        return nil
    }
    // Control-flow keywords (word-ish): fail closed.
    let lower = " \(script.lowercased()) "
    for kw in [" while ", " for ", " if ", " until ", " case ", " select ", " function "] {
        if lower.contains(kw) { return nil }
    }
    // Bare background `&` that is not `&&` or `2>&1`-style.
    if hasBareAmpersand(script) { return nil }
    // Parenthesized subshells: `( cmd )` at statement level.
    if hasBareSubshellParens(script) { return nil }

    var segments: [[String]] = []
    var current = ""
    var inSingle = false
    var inDouble = false
    var escape = false
    var i = script.startIndex

    func flush() {
        let words = tokenizeWords(current)
        if !words.isEmpty { segments.append(words) }
        current = ""
    }

    while i < script.endIndex {
        let ch = script[i]
        if escape {
            current.append(ch)
            escape = false
            i = script.index(after: i)
            continue
        }
        if ch == "\\" && !inSingle {
            escape = true
            current.append(ch)
            i = script.index(after: i)
            continue
        }
        if ch == "'" && !inDouble {
            inSingle.toggle()
            current.append(ch)
            i = script.index(after: i)
            continue
        }
        if ch == "\"" && !inSingle {
            inDouble.toggle()
            current.append(ch)
            i = script.index(after: i)
            continue
        }
        if !inSingle && !inDouble {
            // Operators
            if ch == "&" {
                let next = script.index(after: i)
                if next < script.endIndex && script[next] == "&" {
                    flush()
                    i = script.index(after: next)
                    continue
                }
            }
            if ch == "|" {
                let next = script.index(after: i)
                if next < script.endIndex && script[next] == "|" {
                    flush()
                    i = script.index(after: next)
                    continue
                }
                flush()
                i = script.index(after: i)
                continue
            }
            if ch == ";" || ch == "\n" {
                flush()
                i = script.index(after: i)
                continue
            }
        }
        current.append(ch)
        i = script.index(after: i)
    }
    flush()
    return segments
}

/// Detect `( … )` subshells outside quotes (fail closed).
private func hasBareSubshellParens(_ script: String) -> Bool {
    var inSingle = false
    var inDouble = false
    var escape = false
    for ch in script {
        if escape { escape = false; continue }
        if ch == "\\" && !inSingle { escape = true; continue }
        if ch == "'" && !inDouble { inSingle.toggle(); continue }
        if ch == "\"" && !inSingle { inDouble.toggle(); continue }
        if !inSingle && !inDouble && (ch == "(" || ch == ")") {
            return true
        }
    }
    return false
}

private func hasBareAmpersand(_ script: String) -> Bool {
    var inSingle = false
    var inDouble = false
    var escape = false
    var i = script.startIndex
    while i < script.endIndex {
        let ch = script[i]
        if escape { escape = false; i = script.index(after: i); continue }
        if ch == "\\" && !inSingle { escape = true; i = script.index(after: i); continue }
        if ch == "'" && !inDouble { inSingle.toggle(); i = script.index(after: i); continue }
        if ch == "\"" && !inSingle { inDouble.toggle(); i = script.index(after: i); continue }
        if !inSingle && !inDouble && ch == "&" {
            let prevOK: Bool = {
                if i == script.startIndex { return true }
                let p = script[script.index(before: i)]
                return p != "&" && p != ">"
            }()
            let next = script.index(after: i)
            let nextOK = next >= script.endIndex || script[next] != "&"
            if prevOK && nextOK { return true }
        }
        i = script.index(after: i)
    }
    return false
}

func tokenizeWords(_ segment: String) -> [String] {
    var words: [String] = []
    var current = ""
    var inSingle = false
    var inDouble = false
    var escape = false
    for ch in segment {
        if escape {
            current.append(ch)
            escape = false
            continue
        }
        if ch == "\\" && !inSingle {
            escape = true
            continue
        }
        if ch == "'" && !inDouble {
            inSingle.toggle()
            continue
        }
        if ch == "\"" && !inSingle {
            inDouble.toggle()
            continue
        }
        if !inSingle && !inDouble && ch.isWhitespace {
            if !current.isEmpty {
                // Strip leading env assignments for classification of primary.
                words.append(current)
                current = ""
            }
            continue
        }
        current.append(ch)
    }
    if !current.isEmpty { words.append(current) }
    // Drop leading VAR=value prefixes for primary word extraction.
    return stripLeadingEnvAssignments(words)
}

/// Whether a token looks like a shell `NAME=VALUE` assignment.
public func isEnvAssignment(_ tok: String) -> Bool {
    guard let eq = tok.firstIndex(of: "=") else { return false }
    let name = tok[..<eq]
    guard !name.isEmpty else { return false }
    let first = name.unicodeScalars.first!
    guard first == "_" || CharacterSet.letters.contains(first) else { return false }
    return name.unicodeScalars.allSatisfy {
        $0 == "_" || CharacterSet.alphanumerics.contains($0)
    }
}

func stripLeadingEnvAssignments(_ words: [String]) -> [String] {
    var w = words
    while let first = w.first, isEnvAssignment(first) {
        w.removeFirst()
    }
    return w
}

/// Peel peelable wrappers (`timeout`, `env`, …). Does NOT peel sudo/xargs/nohup.
public func unwrapWrappers(_ words: [String]) -> [String] {
    var w = words
    while let first = w.first {
        let base = (first as NSString).lastPathComponent
        if base == "env" {
            w.removeFirst()
            while let f = w.first, f.contains("=") || f.hasPrefix("-") {
                w.removeFirst()
            }
            continue
        }
        if base == "timeout" {
            w.removeFirst()
            while let option = w.first, option.hasPrefix("-") {
                w.removeFirst()
                if option == "--" {
                    break
                }
                if ["-k", "--kill-after", "-s", "--signal"].contains(option), !w.isEmpty {
                    w.removeFirst()
                }
            }
            if !w.isEmpty {
                w.removeFirst()
            }
            continue
        }
        if peelableWrappers.contains(base) {
            // Drop the wrapper and its common option args heuristically.
            w.removeFirst()
            while let f = w.first, f.hasPrefix("-") {
                // Options that take a value: -s, -t, etc. Drop one more token.
                if f == "--" {
                    w.removeFirst()
                    break
                }
                w.removeFirst()
                if !f.hasPrefix("--") && f.count == 2,
                   let next = w.first, !next.hasPrefix("-")
                {
                    // single-letter option with value
                    w.removeFirst()
                }
            }
            continue
        }
        break
    }
    return w
}

/// Inner script of `bash|sh|dash|zsh|ksh -c '…'`.
public func shellDashCScript(_ words: [String]) -> String? {
    guard let program = words.first else { return nil }
    let base = (program as NSString).lastPathComponent
    guard ["bash", "sh", "dash", "zsh", "ksh"].contains(base) else { return nil }
    guard let flagOffset = words.dropFirst().firstIndex(where: {
        $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c")
    }) else { return nil }
    // `flagOffset` is an index into the original array (ArraySlice shares indices).
    var i = words.index(after: flagOffset)
    while i < words.endIndex {
        let word = words[i]
        if word == "--" || word == "-" {
            let next = words.index(after: i)
            return next < words.endIndex ? words[next] : nil
        }
        if !word.hasPrefix("-") {
            return word
        }
        i = words.index(after: i)
    }
    return nil
}

/// Evaluate bash segments for dangerous/safe classification (prompt path).
public struct BashSegmentEvaluation: Sendable, Equatable {
    public var needsPrompt: Bool
    public var autoAllow: Bool
    public var reason: String?
}

private let sandboxWriteCommands: Set<String> = [
    "rm", "rmdir", "touch", "mkdir", "chmod", "chown", "chgrp", "cp", "mv",
    "ln", "install", "rsync", "dd", "tee", "truncate",
]

private let sandboxExecRiskCommands: Set<String> = [
    "xargs", "eval", "exec", "source", ".", "command", "builtin",
]

private func hasShellRedirectWrite(_ command: String) -> Bool {
    var inSingle = false
    var inDouble = false
    var escaped = false
    var index = command.startIndex
    while index < command.endIndex {
        let character = command[index]
        if escaped {
            escaped = false
        } else if character == "\\" && !inSingle {
            escaped = true
        } else if character == "'" && !inDouble {
            inSingle.toggle()
        } else if character == "\"" && !inSingle {
            inDouble.toggle()
        } else if character == ">" && !inSingle && !inDouble {
            let next = command.index(after: index)
            if next >= command.endIndex || command[next] != "&" {
                return true
            }
        }
        index = command.index(after: index)
    }
    return false
}

private func hasEnvironmentAssignment(_ command: String) -> Bool {
    command
        .split(whereSeparator: { $0.isWhitespace || $0 == ";" || $0 == "|" })
        .contains { isEnvAssignment(String($0)) }
}

/// Whether Bash can use the active OS sandbox as its authorization boundary.
///
/// This is deliberately stricter than the ordinary safe-command list: an
/// unknown but parseable command may run in the sandbox, while floors that can
/// write real files, alter execution environment, or invoke opaque/indirect
/// programs remain prompt-required.
public func bashSandboxAutoAllow(
    _ command: String,
    exactGrants: [String] = []
) -> Bool {
    guard let segments = allCommandsFromScript(command) else { return false }
    let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
    let exactGrant = exactGrants.contains {
        $0.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
    }
    if hasEnvironmentAssignment(command) && !exactGrant { return false }
    if hasShellRedirectWrite(command) && !exactGrant { return false }

    for words in segments {
        let unwrapped = unwrapWrappers(words)
        guard let first = unwrapped.first else { continue }
        let base = (first as NSString).lastPathComponent.lowercased()
        if isDangerousCommandWords(unwrapped) { return false }
        if sandboxExecRiskCommands.contains(base) { return false }
        if base == "rg" && rgHasPreFlag(unwrapped) { return false }
        if sandboxWriteCommands.contains(base) && !exactGrant { return false }
        if base == "sed",
           unwrapped.contains(where: { $0 == "-i" || $0.hasPrefix("-i") }),
           !exactGrant {
            return false
        }
    }
    return true
}

public func evaluateBashSegments(
    _ cmd: String,
    grants: [String],
    disallows: [String]
) -> BashSegmentEvaluation {
    guard let segments = allCommandsFromScript(cmd) else {
        return BashSegmentEvaluation(needsPrompt: true, autoAllow: false, reason: "unparseable")
    }
    var allSafe = true
    var anyDangerous = false
    for words in segments {
        let unwrapped = unwrapWrappers(words)
        guard let first = unwrapped.first else { continue }
        let base = (first as NSString).lastPathComponent
        if setupCommands.contains(base) { continue }
        let joined = unwrapped.joined(separator: " ")
        // CWE-183: word-boundary on disallow / grant prefixes.
        if disallows.contains(where: { matchesCommandPrefix(joined, pattern: $0) }) {
            return BashSegmentEvaluation(needsPrompt: false, autoAllow: false, reason: "disallow")
        }
        if isDangerousCommandWords(unwrapped) {
            anyDangerous = true
            allSafe = false
            continue
        }
        let granted = grants.contains(where: { matchesCommandPrefix(joined, pattern: $0) })
        if granted || isAlwaysSafeCommandWords(unwrapped) || safeCommands.contains(base) {
            continue
        }
        allSafe = false
    }
    if anyDangerous {
        return BashSegmentEvaluation(needsPrompt: true, autoAllow: false, reason: "dangerous")
    }
    if allSafe {
        return BashSegmentEvaluation(needsPrompt: false, autoAllow: true, reason: "safe")
    }
    return BashSegmentEvaluation(needsPrompt: true, autoAllow: false, reason: "needs_prompt")
}
