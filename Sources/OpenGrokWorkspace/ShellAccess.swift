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

// MARK: - Protected edit targets

/// Why an edit must still prompt even under `acceptEdits`. Ported from
/// `ProtectedEditReason` (`shell_access.rs:327-341`).
///
/// Every variant is a code-execution-on-next-session vector: writing one of
/// these files installs something that runs later without a separate execution
/// approval, so the edit approval has to carry that warning.
public enum ProtectedEditReason: String, Sendable, Equatable, Hashable, Codable {
    case hookRoot = "hook_root"
    case gitHooks = "git_hooks"
    case ssh
    case startupFile = "startup_file"
    case etc
    case grokConfig = "grok_config"
    case grokSandbox = "grok_sandbox"
    case claudeSettings = "claude_settings"
    case cursorHooks = "cursor_hooks"
    /// Fail-closed / unclassified sensitive path; no user copy (shell_access.rs:389).
    case sensitive

    /// Wire discriminator for the ACP `ProtectedEditPermission` payload.
    public var kind: String { rawValue }

    /// User-facing explanation, verbatim from `description()`
    /// (`shell_access.rs:359-390`).
    public var explanation: String? {
        switch self {
        case .hookRoot:
            return "Note: This edit contains changes to hooks, which can be executed as code on later sessions without a separate execution approval."
        case .gitHooks:
            return "Note: This edit contains changes to Git hooks, which can run automatically on commit, push, or other Git actions without a separate execution approval."
        case .ssh:
            return "Note: This edit contains changes under `.ssh`, which can affect credentials and authentication for future sessions."
        case .startupFile:
            return "Note: This edit contains changes to a shell startup file, which can run automatically in future terminals without a separate execution approval."
        case .etc:
            return "Note: This edit contains changes under `/etc`, which is system configuration and can affect this machine beyond the current project."
        case .grokConfig:
            return "Note: This edit contains changes to Open Grok config, which can alter permissions, tools, and other behavior in later sessions."
        case .grokSandbox:
            return "Note: This edit contains changes to the Open Grok sandbox config, which can loosen filesystem and network restrictions on commands."
        case .claudeSettings:
            return "Note: This edit contains changes to Claude-compatible settings, which can install hooks or change permission mode without a separate execution approval."
        case .cursorHooks:
            return "Note: This edit contains changes to Cursor hooks, which can run automatically in later sessions without a separate execution approval."
        case .sensitive:
            return nil
        }
    }
}

/// Shell startup files (`STARTUP_FILES`, shell_access.rs:444-462).
private let protectedStartupFiles: Set<String> = [
    ".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".profile",
    ".zshrc", ".zshenv", ".zprofile", ".zlogin", ".zlogout",
    ".kshrc", ".cshrc", ".tcshrc", ".login", ".logout", ".inputrc", ".xprofile",
]

/// Config filenames that are protected when they sit directly inside a
/// `.opengrok` directory or directly inside the user grok home
/// (`protected_grok_config_file_with_home`, shell_access.rs:504-529).
private let protectedGrokConfigFiles: Set<String> = [
    "config.toml", "managed_config.toml", "requirements.toml",
]

/// Full protection classification for an edit target.
///
/// Mirrors `edit_target_protection` (shell_access.rs:416-432): a relative path
/// is `.sensitive` (unclassifiable, fail closed), otherwise the lexical form is
/// checked, then the symlink-resolved form, then `/etc` containment.
public func editTargetProtection(
    _ path: String,
    userGrokHome: String? = nil
) -> ProtectedEditReason? {
    guard path.hasPrefix("/") else { return .sensitive }
    let lexical = normalizeLexically(path)
    if let reason = protectedEditReason(lexical, userGrokHome: userGrokHome) {
        return reason
    }
    let resolved = URL(fileURLWithPath: lexical).resolvingSymlinksInPath().path
    if resolved != lexical,
       let reason = protectedEditReason(normalizeLexically(resolved), userGrokHome: userGrokHome) {
        return reason
    }
    if resolved == "/etc" || resolved.hasPrefix("/etc/") { return .sensitive }
    return nil
}

/// Classify one already-normalized absolute path. Check order is Rust's
/// (`protected_edit_reason`, shell_access.rs:434-496); first match wins.
public func protectedEditReason(
    _ path: String,
    userGrokHome: String? = nil
) -> ProtectedEditReason? {
    let lexical = normalizeLexically(path)
    let parts = lexical.split(separator: "/").map { $0.lowercased() }
    let file = parts.last ?? ""

    // 1. `.opengrok/hooks/**`, `.opengrok/hooks-paths`, `$OPENGROK_HOME/hooks`.
    if adjacentPair(parts, ".opengrok", "hooks") { return .hookRoot }
    if parts.count >= 2,
       parts[parts.count - 2] == ".opengrok",
       parts[parts.count - 1] == "hooks-paths" {
        return .hookRoot
    }
    if let home = userGrokHome {
        let normalizedHome = normalizeLexically(home)
        let hookRoot = (normalizedHome as NSString).appendingPathComponent("hooks")
        if lexical == hookRoot || lexical.hasPrefix(hookRoot + "/") { return .hookRoot }
        if lexical == (normalizedHome as NSString).appendingPathComponent("hooks-paths") {
            return .hookRoot
        }
    }

    // 2/3. Claude-compatible settings and Cursor hooks.
    if parts.count >= 2, parts[parts.count - 2] == ".claude",
       file == "settings.json" || file == "settings.local.json" {
        return .claudeSettings
    }
    if parts.count >= 2, parts[parts.count - 2] == ".cursor", file == "hooks.json" {
        return .cursorHooks
    }

    // 4. `.git/hooks/**` and the `.git/modules/**/hooks` submodule form.
    if adjacentPair(parts, ".git", "hooks") { return .gitHooks }
    if let gitIndex = parts.firstIndex(of: ".git"),
       gitIndex + 1 < parts.count,
       parts[gitIndex + 1] == "modules",
       parts[(gitIndex + 2)...].dropFirst().contains("hooks") {
        return .gitHooks
    }

    // 5/6. Credentials and shell startup files.
    if parts.contains(".ssh") { return .ssh }
    if protectedStartupFiles.contains(file) { return .startupFile }

    // 7. Grok config / sandbox config, in `.opengrok/` or the user grok home.
    let configReason: ProtectedEditReason?
    if protectedGrokConfigFiles.contains(file) {
        configReason = .grokConfig
    } else if file == "sandbox.toml" {
        configReason = .grokSandbox
    } else {
        configReason = nil
    }
    if let configReason {
        let inDotGrok = parts.count >= 2 && parts[parts.count - 2] == ".opengrok"
        var inGrokHome = false
        if let home = userGrokHome {
            let parent = (lexical as NSString).deletingLastPathComponent
            let normalizedHome = normalizeLexically(home)
            inGrokHome = parent == normalizedHome
                || parent == URL(fileURLWithPath: normalizedHome).resolvingSymlinksInPath().path
        }
        if inDotGrok || inGrokHome { return configReason }
    }

    // 8. System configuration.
    if lexical == "/etc" || lexical.hasPrefix("/etc/") { return .etc }
    return nil
}

/// Whether `parts` contains `first` immediately followed by `second`.
private func adjacentPair(_ parts: [String], _ first: String, _ second: String) -> Bool {
    guard parts.count >= 2 else { return false }
    for index in 0..<(parts.count - 1) where parts[index] == first && parts[index + 1] == second {
        return true
    }
    return false
}

/// Whether an absolute edit path should always prompt. Boolean façade over
/// `protectedEditReason` for the call sites that only branch on it.
public func protectedEditPath(_ path: String, userGrokHome: String? = nil) -> Bool {
    protectedEditReason(path, userGrokHome: userGrokHome) != nil
}
