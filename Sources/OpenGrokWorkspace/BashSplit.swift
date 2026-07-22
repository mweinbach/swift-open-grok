// BashSplit.swift
//
// Lightweight bash command segmentation without tree-sitter.
// Fail-closed: unparseable / high-risk constructs return nil → Ask.

import Foundation

/// Wrappers peeled for deny/ask/grants/safe lists. `sudo` / `xargs` / `nohup`
/// are intentionally NOT peeled.
private let peelableWrappers: Set<String> = [
    "timeout", "nice", "ionice", "chrt", "stdbuf", "env",
]

/// Setup commands skipped for "primary" classification.
public let setupCommands: Set<String> = [
    "cd", "export", "sleep", "true", ":", "shift", "umask", "ulimit",
]

/// Dangerous commands that always need a prompt even with remembered grants.
public let dangerousCommands: Set<String> = [
    "rm", "rmdir", "dd", "mkfs", "shutdown", "reboot", "halt", "poweroff",
    "kill", "killall", "pkill", "chmod", "chown", "chgrp", "sudo", "su",
    "mount", "umount", "mkfs.ext4", "mkfs.xfs", "userdel", "passwd",
    "curl", "wget", "nc", "ncat", "bash", "sh", "zsh", "python", "python3",
    "perl", "ruby", "node", "osascript",
]

/// Built-in safe commands for auto-allow when no deny/ask matches.
public let safeCommands: Set<String> = [
    "ls", "pwd", "echo", "cat", "head", "tail", "wc", "true", "false",
    "date", "whoami", "hostname", "uname", "which", "type", "git",
    "rg", "grep", "find", "fd", "bat", "less", "more", "file", "stat",
    "diff", "sort", "uniq", "tr", "cut", "awk", "sed", "jq",
]

/// Split a script on `&&`, `||`, `;`, `|`, newlines into word-only segments.
/// Returns `nil` when high-risk constructs are detected (fail closed).
public func allCommandsFromScript(_ script: String) -> [[String]]? {
    // Fail closed on common high-risk constructs.
    let hostile = ["$(", "`", "${", "<(", ">(", "\n(", " monads"]
    // Subshells / substitutions / control flow heuristics.
    if script.contains("$(") || script.contains("`") || script.contains("${") {
        return nil
    }
    if script.contains(" while ") || script.contains(" for ") || script.contains(" if ") {
        return nil
    }
    // Bare background `&` that is not `&&` or `2>&1`-style.
    if hasBareAmpersand(script) { return nil }

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
        _ = hostile
    }
    flush()
    return segments
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
    // Drop VAR=value prefixes for primary word extraction.
    return words
}

/// Peel peelable wrappers (`timeout`, `env`, …). Does NOT peel sudo/xargs/nohup.
public func unwrapWrappers(_ words: [String]) -> [String] {
    var w = words
    while let first = w.first {
        let base = (first as NSString).lastPathComponent
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
        // env VAR=val cmd
        if base == "env" {
            w.removeFirst()
            while let f = w.first, f.contains("=") || f.hasPrefix("-") {
                w.removeFirst()
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

public func evaluateBashSegments(
    _ cmd: String,
    grants: [String],
    disallows: [String]
) -> BashSegmentEvaluation {
    guard let segments = allCommandsFromScript(cmd) else {
        return BashSegmentEvaluation(needsPrompt: true, autoAllow: false, reason: "unparseable")
    }
    var allSafe = true
    for words in segments {
        let unwrapped = unwrapWrappers(words)
        guard let first = unwrapped.first else { continue }
        let base = (first as NSString).lastPathComponent
        if setupCommands.contains(base) { continue }
        let joined = unwrapped.joined(separator: " ")
        if disallows.contains(where: { joined.hasPrefix($0) }) {
            return BashSegmentEvaluation(needsPrompt: false, autoAllow: false, reason: "disallow")
        }
        if dangerousCommands.contains(base) {
            return BashSegmentEvaluation(needsPrompt: true, autoAllow: false, reason: "dangerous:\(base)")
        }
        let granted = grants.contains(where: { joined.hasPrefix($0) })
        if !(granted || safeCommands.contains(base)) {
            allSafe = false
        }
    }
    if allSafe {
        return BashSegmentEvaluation(needsPrompt: false, autoAllow: true, reason: "safe")
    }
    return BashSegmentEvaluation(needsPrompt: true, autoAllow: false, reason: "needs_prompt")
}
