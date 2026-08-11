// HeuristicPermissionClassifier.swift
//
// Deterministic auto-mode classifier (no network). Ported from
// `xai-grok-workspace/src/permission/auto_mode/mod.rs` HeuristicPermissionClassifier
// and `classify_bash`, using the lightweight BashSplit helpers.

import Foundation

/// Deterministic auto-mode classifier: blocks known-dangerous patterns and
/// allows routine local-dev commands without a network call.
public struct HeuristicPermissionClassifier: PermissionClassifier, Sendable {
    public init() {}

    public func classify(access: AccessKind, toolName: String) async -> PermissionDecision {
        await classify(
            access: access,
            toolName: toolName,
            accessDetail: access.detail,
            transcript: ""
        )
    }

    public func classify(
        access: AccessKind,
        toolName: String,
        accessDetail: String?,
        transcript: String
    ) async -> PermissionDecision {
        Self.classifySync(
            toolName: toolName,
            access: access,
            accessDetail: accessDetail,
            transcript: transcript
        )
    }

    public static func classifySync(
        toolName: String,
        access: AccessKind,
        accessDetail: String?,
        transcript: String
    ) -> PermissionDecision {
        let detail = (accessDetail ?? "").lowercased()
        let tool = toolName.lowercased()
        let transcriptLower = transcript.lowercased()
        let blob = "\(tool) \(detail) \(transcriptLower)"

        if tool.contains("ask_user") || tool.contains("askuserquestion") {
            return .policyDeny("auto mode: interactive tool blocked")
        }

        for pat in Self.dangerousPatterns where blob.contains(pat) {
            return .policyDeny("auto mode: dangerous pattern")
        }

        if (blob.contains("curl") || blob.contains("wget") || blob.contains("fetch"))
            && (blob.contains("| sh")
                || blob.contains("|sh")
                || blob.contains("| bash")
                || blob.contains("|bash")
                || blob.contains("| zsh")
                || blob.contains("|zsh"))
        {
            return .policyDeny("auto mode: pipe-to-shell")
        }

        for pat in Self.hostileIntent where transcriptLower.contains(pat) {
            return .policyDeny("auto mode: hostile intent")
        }

        switch access {
        case .bash(let cmd):
            return classifyBash(cmd)
        case .webFetch(let url):
            let u = url.lowercased()
            if u.contains("localhost") || u.contains("127.0.0.1") || u.hasPrefix("file:") {
                return .policyDeny("auto mode: local web fetch blocked")
            }
            return .policyDeny("auto mode: web fetch blocked")
        case .edit, .mcpTool:
            return .policyDeny("auto mode: side-effect access blocked")
        case .read, .grep, .webSearch:
            return .allow
        }
    }
}

// MARK: - Pre-check lists (Rust auto_mode.rs ~397-463)

private extension HeuristicPermissionClassifier {
    static let dangerousPatterns: [String] = [
        "rm -rf /",
        "rm -rf /*",
        "mkfs",
        "dd if=",
        ":(){ :|:& };:",
        "curl | sh",
        "curl|sh",
        "curl | bash",
        "curl|bash",
        "wget | sh",
        "wget|sh",
        "wget | bash",
        "wget|bash",
        "chmod 777",
        "chmod -r 777",
        "chmod +x /tmp",
        "base64 -d",
        "base64 --decode",
        "nc -e",
        "ncat -e",
        "/dev/tcp/",
        "shutdown",
        "reboot",
        "useradd",
        "userdel",
        "passwd ",
        "chown -r /",
        "iptables -f",
        "kill -9 1",
        "sudo rm",
        "sudo dd",
        "sudo mkfs",
        "exfiltrat",
        "steal credential",
        "send secrets",
    ]

    static let hostileIntent: [String] = [
        "delete all files",
        "wipe the disk",
        "exfiltrate",
        "steal secrets",
        "send my credentials",
        "ignore safety",
        "bypass permission",
    ]
}

// MARK: - Bash classification (Rust classify_bash ~619-656)

private func classifyBash(_ cmd: String) -> PermissionDecision {
    guard let segments = allCommandsFromScript(cmd) else {
        return .policyDeny("auto mode: unparseable bash")
    }
    if scriptEnvRisk(cmd, segments: segments) != .safe {
        return .policyDeny("auto mode: env risk")
    }
    if heuristicHasShellRedirectWrite(cmd) {
        return .policyDeny("auto mode: shell redirect write")
    }
    guard !segments.isEmpty else {
        return .policyDeny("auto mode: empty bash")
    }
    for words in segments {
        let unwrapped = unwrapWrappers(words)
        guard let first = unwrapped.first else { continue }
        let base = (first as NSString).lastPathComponent
        if setupCommands.contains(base) { continue }
        if !bashCommandIsRoutine(unwrapped) {
            return .policyDeny("auto mode: non-routine bash")
        }
    }
    return .allow
}

// MARK: - Routine command matching (Rust bash_command_is_routine ~666-740)

/// Routine local-dev command prefixes (word-boundary matched). Mirrors Rust
/// `ROUTINE_PREFIXES` (auto_mode.rs ~499-573).
private let routinePrefixes: [String] = [
    "cargo ",
    "git add",
    "git commit",
    "git checkout",
    "git switch",
    "git stash",
    "git pull",
    "git fetch",
    "git worktree list",
    "pytest",
    "python ",
    "python3 ",
    "node ",
    "rustc ",
    "rustfmt",
    "clippy",
    "make ",
    "cmake ",
    "cd",
    "pushd",
    "popd",
    "ls",
    "pwd",
    "echo ",
    "printf ",
    "cat ",
    "head ",
    "tail ",
    "wc ",
    "rg ",
    "grep ",
    "which ",
    "type ",
    "true",
    "false",
    "test ",
    "sort ",
    "uniq ",
    "tr ",
    "cut ",
    "diff ",
    "jq ",
    "date",
    "whoami",
    "hostname",
    "uname",
    "nproc",
    "printenv",
    "stat ",
    "file ",
    "tree",
    "basename ",
    "dirname ",
    "realpath ",
    "readlink ",
    "strings ",
    "sleep ",
    "df ",
    "du ",
    "ps ",
    "top",
    "htop",
    "bazel ",
    "just ",
    "go ",
    "kubectl get",
    "kubectl logs",
    "kubectl describe",
    "set",
]

private let kubectlUnsafeFlags: Set<String> = [
    "--kubeconfig",
    "--context",
    "--cluster",
    "--server",
    "-s",
    "--token",
    "--user",
    "--as",
    "--as-group",
    "--as-uid",
    "--as-user-extra",
    "--username",
    "--password",
    "--client-certificate",
    "--client-key",
    "--certificate-authority",
]

private let safeEnvKeys: Set<String> = [
    "CARGO_TERM_COLOR",
    "CARGO_TERM_PROGRESS_WHEN",
    "RUST_LOG",
    "RUST_LOG_STYLE",
    "RUST_BACKTRACE",
    "RUST_TEST_THREADS",
    "RUST_MIN_STACK",
    "NO_COLOR",
    "CLICOLOR",
    "CLICOLOR_FORCE",
    "FORCE_COLOR",
    "COLORTERM",
]

private let injectionEnvKeys: Set<String> = [
    "LD_PRELOAD",
    "LD_AUDIT",
    "BASH_ENV",
    "ENV",
    "IFS",
    "PATH",
    "GIT_EXTERNAL_DIFF",
    "GIT_PROXY_COMMAND",
    "PROMPT_COMMAND",
]

private let injectionEnvKeyPrefixes: [String] = ["DYLD_", "GIT_CONFIG"]

private let findMutatingActions: Set<String> = [
    "-delete", "-exec", "-execdir", "-ok", "-okdir",
    "-fprint", "-fprint0", "-fprintf", "-fls",
]

private let npmSafeSubcommands: Set<String> = [
    "install", "i", "ci", "add", "remove", "rm", "uninstall", "update", "up", "upgrade",
    "test", "t", "run", "run-script", "start", "build", "audit", "list", "ls", "ll",
    "outdated", "why", "view", "info", "dedupe", "prune", "version", "pack", "config",
    "link", "unlink", "rebuild", "store", "fetch", "import",
]

private let uvSafeSubcommands: Set<String> = [
    "sync", "pip", "lock", "venv", "add", "remove", "tree", "export", "build", "version",
    "python", "cache", "init", "self", "help",
]

private let rustupSafeSubcommands: Set<String> = [
    "show", "toolchain", "component", "target", "default", "update", "which", "doc",
    "self", "completions", "set", "override",
]

private enum EnvRisk: Comparable {
    case safe
    case unvetted
    case injection

    private var rank: Int {
        switch self {
        case .safe: return 0
        case .unvetted: return 1
        case .injection: return 2
        }
    }

    static func < (lhs: EnvRisk, rhs: EnvRisk) -> Bool {
        lhs.rank < rhs.rank
    }
}

private func bashCommandIsRoutine(_ words: [String]) -> Bool {
    let inner = unwrapWrappers(words)
    if inner.isEmpty || isLoneWrapper(inner) {
        return true
    }
    guard let first = inner.first else { return false }
    let head = (first as NSString).lastPathComponent.lowercased()

    if let pmRoutine = packageManagerSubcommandIsRoutine(head: head, inner: inner) {
        return pmRoutine
    }

    if head == "find" {
        return findIsReadOnly(inner)
    }

    if head == "git" {
        if isAlwaysSafeCommandWords(inner) {
            return true
        }
        if gitWordsHaveUnsafeQueryOption(inner) {
            return false
        }
    }

    if head == "tree",
       inner.contains(where: {
           ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("o"))
               || $0.hasPrefix("--output")
       })
    {
        return false
    }

    if head == "rg", rgHasPreFlag(inner) {
        return false
    }

    if head == "kubectl" {
        for flag in inner.dropFirst() {
            let name = flag.split(separator: "=", maxSplits: 1).first.map(String.init) ?? flag
            if kubectlUnsafeFlags.contains(name) {
                return false
            }
        }
    }

    if head == "gh" {
        return ghSubcommandIsReadOnly(inner)
    }

    if isDangerousCommandWords(inner) {
        return false
    }

    let joined = inner.joined(separator: " ").lowercased()
    return routinePrefixes.contains { prefix in
        let base = prefix.trimmingCharacters(in: .whitespaces)
        return matchesCommandPrefix(joined, pattern: base)
    }
}

private func isLoneWrapper(_ words: [String]) -> Bool {
    guard words.count == 1, let first = words.first else { return false }
    let base = (first as NSString).lastPathComponent
    return ["env", "timeout", "nice", "ionice", "chrt", "stdbuf"].contains(base)
}

private func findIsReadOnly(_ words: [String]) -> Bool {
    !words.contains { findMutatingActions.contains($0) }
}

private func gitWordsHaveUnsafeQueryOption(_ words: [String]) -> Bool {
    words.contains { word in
        word == "--output" || word.hasPrefix("--output=")
            || word == "--ext-diff"
            || (word.hasPrefix("-") && !word.hasPrefix("--") && word.contains("O"))
    }
}

private func ghSubcommandIsReadOnly(_ inner: [String]) -> Bool {
    var toks: [String] = []
    if inner.count > 1 {
        for word in inner[1...] where !word.hasPrefix("-") {
            toks.append(word)
            if toks.count == 2 { break }
        }
    }
    switch toks.count {
    case 2:
        let group = toks[0]
        let sub = toks[1]
        let readGroups = ["pr", "issue", "release", "run", "workflow", "repo", "gist"]
        let readSubs = ["view", "list", "status", "checks", "diff"]
        if readGroups.contains(group), readSubs.contains(sub) { return true }
        if group == "auth", sub == "status" { return true }
        return false
    case 1:
        return toks[0] == "status"
    default:
        return false
    }
}

// MARK: - Package manager allowlist (Rust package_manager_subcommand_is_routine)

private enum LaunchTarget {
    case notLauncher
    case inner([String])
    case unresolved
}

private func packageManagerSubcommandIsRoutine(head: String, inner: [String]) -> Bool? {
    guard ["uv", "uvx", "npm", "npx", "pnpm", "yarn", "rustup"].contains(head) else {
        return nil
    }
    if isRemoteLauncher(head: head, inner: inner) {
        return false
    }
    switch explicitLaunchTarget(head: head, inner: inner) {
    case .unresolved:
        return false
    case .inner(let launched):
        return commandEnvRisk(launched) == .safe
            && !heuristicHasShellRedirectWrite(launched.joined(separator: " "))
            && bashCommandIsRoutine(launched)
    case .notLauncher:
        break
    }
    guard let sub = launcherSubcommand(head: head, inner: inner) else {
        return false
    }
    switch head {
    case "npm", "pnpm", "yarn":
        return npmSafeSubcommands.contains(sub)
    case "uv":
        return uvSafeSubcommands.contains(sub)
    case "rustup":
        return rustupSafeSubcommands.contains(sub)
    default:
        return false
    }
}

private func launcherSubcommand(head: String, inner: [String]) -> String? {
    guard inner.count > 1 else { return nil }
    let sub = inner[1]
    switch (head, sub) {
    case ("npm", "x"), ("pnpm", "x"), ("yarn", "x"):
        return "exec"
    case ("npm", "innit"), ("pnpm", "innit"), ("yarn", "innit"):
        return "init"
    default:
        return sub
    }
}

private func isRemoteLauncher(head: String, inner: [String]) -> Bool {
    if head == "npx" || head == "uvx" { return true }
    if head == "uv",
       inner.count > 2,
       inner[1] == "tool",
       inner[2] == "run"
    {
        return true
    }
    guard let sub = launcherSubcommand(head: head, inner: inner) else { return false }
    switch head {
    case "npm", "pnpm", "yarn":
        if ["dlx", "create", "explore"].contains(sub) { return true }
        if sub == "init", inner.count > 2, !inner[2].hasPrefix("-") { return true }
        return false
    default:
        return false
    }
}

private func explicitLaunchTarget(head: String, inner: [String]) -> LaunchTarget {
    guard let sub = launcherSubcommand(head: head, inner: inner) else {
        return .notLauncher
    }
    let start: Int
    switch (head, sub) {
    case ("uv", "run"):
        start = 2
    case ("rustup", "run"):
        guard inner.count > 2, !inner[2].hasPrefix("-") else { return .unresolved }
        start = 3
    case ("npm", "exec"), ("pnpm", "exec"), ("yarn", "exec"):
        start = inner.count > 2 && inner[2] == "--" ? 3 : 2
    default:
        return .notLauncher
    }
    guard start < inner.count else { return .unresolved }
    let tok = inner[start]
    guard !tok.hasPrefix("-") else { return .unresolved }
    return .inner(Array(inner[start...]))
}

// MARK: - Env risk (Rust script_env_risk / command_env_risk)

private func scriptEnvRisk(_ cmd: String, segments: [[String]]) -> EnvRisk {
    var risk: EnvRisk = .safe
    for token in cmd.split(whereSeparator: { $0.isWhitespace || $0 == ";" || $0 == "|" || $0 == "&" }) {
        let tok = String(token)
        if isEnvAssignment(tok), let eq = tok.firstIndex(of: "=") {
            risk = max(risk, envKeyRisk(String(tok[..<eq])))
        }
    }
    for words in segments {
        risk = max(risk, commandEnvRisk(words))
    }
    return risk
}

private func commandEnvRisk(_ words: [String]) -> EnvRisk {
    var risk: EnvRisk = .safe
    var current = words
    for _ in 0..<8 {
        guard let first = current.first else { break }
        let base = (first as NSString).lastPathComponent
        if base == "env" {
            var optionsDone = false
            for arg in current.dropFirst() {
                if arg == "--" {
                    optionsDone = true
                    continue
                }
                if !optionsDone, arg.hasPrefix("-") {
                    return .injection
                }
                if let eq = arg.firstIndex(of: "=") {
                    let key = String(arg[..<eq])
                    risk = max(risk, envKeyRisk(key))
                } else {
                    break
                }
            }
        }
        let peeled = unwrapWrappers(current)
        if peeled == current { break }
        current = peeled
    }
    return risk
}

private func envKeyRisk(_ key: String) -> EnvRisk {
    if safeEnvKeys.contains(key) { return .safe }
    if injectionEnvKeys.contains(key) { return .injection }
    if injectionEnvKeyPrefixes.contains(where: { key.hasPrefix($0) }) { return .injection }
    return .unvetted
}

private func heuristicHasShellRedirectWrite(_ command: String) -> Bool {
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
