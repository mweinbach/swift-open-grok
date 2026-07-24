// ShellAccess.swift
//
// Heuristic shell file-access escalation so managed Read/Edit deny/ask
// cannot be bypassed via shell readers/writers/redirects.
// Tree-sitter AST path is unavailable in Swift; this fail-closed scanner
// covers redirections, common readers/writers, and path movers.

import Foundation
import OpenGrokPaths

public enum ShellFileMode: Sendable, Equatable {
    case read
    case write
}

private let shellReaders: Set<String> = [
    "cat", "tac", "nl", "head", "tail", "grep", "egrep", "fgrep", "rg", "sed",
    "awk", "less", "more", "bat", "strings", "xxd", "od", "hexdump", "base64",
    "cut", "sort", "uniq", "wc", "diff", "jq", "yq", "ag", "ack", "zcat",
]

private let shellWriters: Set<String> = [
    "tee", "truncate",
]

private let pathMovers: Set<String> = [
    "cp", "mv", "ln", "install", "rsync", "rm", "rmdir", "touch", "mkdir",
    "chmod", "chown", "chgrp",
]

extension CompiledPolicy {
    /// Escalation-only shell file-access gate. Returns reject/ask, never allow.
    public func evaluateShellFileAccess(_ cmd: String, cwd: String) -> PermissionDecision? {
        guard hasFileRestrictions else { return nil }

        // Unparseable / high-risk constructs → ask (fail closed).
        guard let segments = allCommandsFromScript(cmd) else {
            return .ask
        }

        var decision: PermissionDecision?
        var forcedAsk = false

        // Redirection targets: `> file`, `>> file`, `< file`.
        for (path, mode) in redirectTargets(cmd) {
            if path.contains("$") || path.contains("*") || path.contains("?") {
                forcedAsk = true
            }
            decision = combineDecisions(
                decision,
                escalateShellPath(path, cwd: cwd, mode: mode)
            )
        }

        for words in segments {
            let unwrapped = unwrapWrappers(words)
            guard let first = unwrapped.first else { continue }
            let program = (first as NSString).lastPathComponent.lowercased()

            if program == "cd" || program == "pushd" {
                // Relative operands after cd are unpinnable → ask.
                forcedAsk = true
                continue
            }

            if program == "dd" {
                for word in unwrapped.dropFirst() {
                    if word.hasPrefix("if=") {
                        let p = String(word.dropFirst(3))
                        decision = combineDecisions(
                            decision,
                            escalateShellPath(p, cwd: cwd, mode: .read)
                        )
                    } else if word.hasPrefix("of=") {
                        let p = String(word.dropFirst(3))
                        decision = combineDecisions(
                            decision,
                            escalateShellPath(p, cwd: cwd, mode: .write)
                        )
                    }
                }
                continue
            }

            let modes: [ShellFileMode]
            if shellReaders.contains(program) {
                if program == "sed", unwrapped.contains(where: { $0 == "-i" || $0.hasPrefix("-i") }) {
                    modes = [.read, .write]
                } else {
                    modes = [.read]
                }
            } else if shellWriters.contains(program) {
                modes = [.write]
            } else if pathMovers.contains(program) {
                modes = pathMoverModes(program)
            } else {
                continue
            }

            let operands = pathOperands(unwrapped)
            if operands.isEmpty {
                // Known reader/writer without a clear path operand → ask when restricted.
                forcedAsk = true
                continue
            }
            for op in operands {
                if op.contains("$") || op.contains("*") {
                    forcedAsk = true
                }
                for mode in modes {
                    decision = combineDecisions(
                        decision,
                        escalateShellPath(op, cwd: cwd, mode: mode)
                    )
                }
            }
        }

        if forcedAsk {
            decision = combineDecisions(decision, .ask)
        }
        return decision
    }

    private func pathMoverModes(_ program: String) -> [ShellFileMode] {
        switch program {
        case "rm", "rmdir", "touch", "mkdir", "chmod", "chown", "chgrp":
            return [.write]
        case "cp", "mv", "ln", "install", "rsync":
            return [.read, .write]
        default:
            return [.write]
        }
    }

    private func pathOperands(_ words: [String]) -> [String] {
        var out: [String] = []
        var i = 1
        while i < words.count {
            let w = words[i]
            if w == "--" {
                out.append(contentsOf: words[(i + 1)...])
                break
            }
            if w.hasPrefix("-") {
                // Options that take a value: drop next token heuristically.
                if ["-o", "--output", "-C", "--chdir"].contains(w), i + 1 < words.count {
                    i += 2
                    continue
                }
                i += 1
                continue
            }
            if w.contains("="), !w.hasPrefix("/") {
                i += 1
                continue
            }
            out.append(w)
            i += 1
        }
        return out
    }

    private func escalateShellPath(
        _ token: String,
        cwd: String,
        mode: ShellFileMode
    ) -> PermissionDecision? {
        if isSafeWriteSink(token) { return nil }
        let absolute: String
        if token.hasPrefix("/") {
            absolute = normalizeLexically(token)
        } else {
            absolute = normalizeLexically((cwd as NSString).appendingPathComponent(token))
        }
        let access: AccessKind
        switch mode {
        case .read: access = .read(absolute)
        case .write: access = .edit(absolute)
        }
        // Escalation only: drop Allow so a file allow-rule can't auto-approve here.
        switch evaluate(access) {
        case .some(.allow), .none: return nil
        case .some(let other): return other
        }
    }
}

func isSafeWriteSink(_ path: String) -> Bool {
    path == "/dev/null" || path == "/dev/stdout" || path == "/dev/stderr"
}

/// Collect `>`, `>>`, `<` targets outside quotes.
func redirectTargets(_ script: String) -> [(String, ShellFileMode)] {
    var results: [(String, ShellFileMode)] = []
    var inSingle = false
    var inDouble = false
    var escape = false
    var i = script.startIndex

    func skipSpaces(_ idx: String.Index) -> String.Index {
        var j = idx
        while j < script.endIndex, script[j].isWhitespace { j = script.index(after: j) }
        return j
    }

    func readToken(_ idx: String.Index) -> (String, String.Index)? {
        var j = idx
        if j >= script.endIndex { return nil }
        var token = ""
        var sq = false
        var dq = false
        var esc = false
        while j < script.endIndex {
            let ch = script[j]
            if esc {
                token.append(ch)
                esc = false
                j = script.index(after: j)
                continue
            }
            if ch == "\\" && !sq {
                esc = true
                j = script.index(after: j)
                continue
            }
            if ch == "'" && !dq { sq.toggle(); j = script.index(after: j); continue }
            if ch == "\"" && !sq { dq.toggle(); j = script.index(after: j); continue }
            if !sq && !dq && (ch.isWhitespace || "&|;<>".contains(ch)) {
                break
            }
            token.append(ch)
            j = script.index(after: j)
        }
        return token.isEmpty ? nil : (token, j)
    }

    while i < script.endIndex {
        let ch = script[i]
        if escape { escape = false; i = script.index(after: i); continue }
        if ch == "\\" && !inSingle { escape = true; i = script.index(after: i); continue }
        if ch == "'" && !inDouble { inSingle.toggle(); i = script.index(after: i); continue }
        if ch == "\"" && !inSingle { inDouble.toggle(); i = script.index(after: i); continue }
        if !inSingle && !inDouble {
            if ch == ">" {
                var next = script.index(after: i)
                if next < script.endIndex, script[next] == ">" {
                    next = script.index(after: next)
                }
                // Skip optional `&` in `>&` fd dups without path.
                if next < script.endIndex, script[next] == "&" {
                    i = script.index(after: next)
                    continue
                }
                next = skipSpaces(next)
                if let (tok, end) = readToken(next) {
                    results.append((tok, .write))
                    i = end
                    continue
                }
            } else if ch == "<" {
                var next = script.index(after: i)
                if next < script.endIndex, script[next] == "<" {
                    // Heredoc — fail closed at script level already; skip.
                    i = script.index(after: next)
                    continue
                }
                if next < script.endIndex, script[next] == "&" {
                    i = script.index(after: next)
                    continue
                }
                next = skipSpaces(next)
                if let (tok, end) = readToken(next) {
                    results.append((tok, .read))
                    i = end
                    continue
                }
            }
        }
        i = script.index(after: i)
    }
    return results
}

/// Whether an absolute edit path should always prompt (startup files, ssh, hooks).
public func protectedEditPath(_ path: String) -> Bool {
    let lexical = normalizeLexically(path)
    let parts = lexical.split(separator: "/").map { $0.lowercased() }
    let file = parts.last.map(String.init) ?? ""
    let startup: Set<String> = [
        ".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".profile",
        ".zshrc", ".zshenv", ".zprofile", ".zlogin", ".zlogout",
        ".kshrc", ".cshrc", ".tcshrc", ".login", ".logout", ".inputrc",
    ]
    if startup.contains(file) { return true }
    if parts.contains(".ssh") { return true }
    if parts.contains(".git") {
        if let gitIdx = parts.firstIndex(of: ".git"),
           gitIdx + 1 < parts.count,
           parts[gitIdx + 1] == "hooks"
        {
            return true
        }
    }
    if parts.count >= 2,
       parts[parts.count - 2] == ".opengrok",
       parts[parts.count - 1] == "config.toml"
    {
        return true
    }
    if lexical == "/etc" || lexical.hasPrefix("/etc/") { return true }
    return false
}
