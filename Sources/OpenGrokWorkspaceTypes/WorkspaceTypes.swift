// WorkspaceTypes.swift
//
// Supporting structs/enums referenced from requests, chunks, and events.
// Ported from `crates/codegen/xai-grok-workspace-types/src/types/*`.
//
// These are the **canonical wire-format contracts** for the workspace
// stream / ops surface. Runtime crates (`OpenGrokHunkTracker`,
// `OpenGrokWorkspace`, `OpenGrokShell`, …) may hold richer domain models
// and convert to/from these DTOs at the boundary; the JSON shapes defined
// here are the source of truth for encode/decode parity with Rust.

import Foundation
import OpenGrokShared

// MARK: - config.rs

/// Filesystem isolation strategy for a forked session.
///
/// `none` is the default and is appropriate for the root session (which
/// shares the workspace's working tree). Subagent forks should explicitly
/// opt into a more restrictive mode (`.worktree`); relying on the default
/// for a subagent gives it shared-tree access, which is rarely the right
/// default for an exploratory child agent.
public enum IsolationMode: String, Hashable, Sendable, Codable, Equatable, CaseIterable {
    case none
    case worktree
    case sandbox

    public static let validValues = allCases.map(\.rawValue)
}

extension IsolationMode: CustomStringConvertible {
    public var description: String { rawValue }
}

/// Capability mode applied to a forked session.
///
/// `readWrite` is the default and is appropriate for the root session.
/// Subagents should explicitly opt into a more restrictive mode (typically
/// `.readOnly`); relying on the default for a subagent gives it read+write
/// access, which is rarely the right default for an exploratory child agent.
public enum CapabilityMode: Hashable, Sendable, Codable, Equatable {
    case readWrite
    case readOnly
    case none

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        switch raw {
        case "read_write": self = .readWrite
        case "read_only": self = .readOnly
        case "none": self = .none
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown CapabilityMode: \(raw)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .readWrite: try c.encode("read_write")
        case .readOnly: try c.encode("read_only")
        case .none: try c.encode("none")
        }
    }
}

/// Per-tool-server configuration knob.
public struct ToolServerConfig: Hashable, Sendable, Codable, Equatable {
    public var id: String
    public var enabled: Bool
    public var command: String?
    public var args: [String: String]

    public init(
        id: String,
        enabled: Bool = false,
        command: String? = nil,
        args: [String: String] = [:]
    ) {
        self.id = id
        self.enabled = enabled
        self.command = command
        self.args = args
    }

    enum CodingKeys: String, CodingKey {
        case id, enabled, command, args
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        command = try c.decodeIfPresent(String.self, forKey: .command)
        args = try c.decodeIfPresent([String: String].self, forKey: .args) ?? [:]
    }
}

/// Configuration applied when forking a session via
/// `SessionLifecycleRequest.fork`.
///
/// The default is `.none` isolation and `.readWrite` capability — oriented
/// at the root session, not subagents. Construct subagent configs by fully
/// naming the relevant fields rather than relying on memberwise defaults.
public struct AgentSessionConfig: Hashable, Sendable, Codable, Equatable {
    public var agentId: String
    public var isolation: IsolationMode
    public var capabilityMode: CapabilityMode
    public var toolConfig: [ToolServerConfig]
    public var maxDepth: UInt32
    public var cwdOverride: String?
    public var extraEnv: [String: String]

    public init(
        agentId: String = "",
        isolation: IsolationMode = .none,
        capabilityMode: CapabilityMode = .readWrite,
        toolConfig: [ToolServerConfig] = [],
        maxDepth: UInt32 = 0,
        cwdOverride: String? = nil,
        extraEnv: [String: String] = [:]
    ) {
        self.agentId = agentId
        self.isolation = isolation
        self.capabilityMode = capabilityMode
        self.toolConfig = toolConfig
        self.maxDepth = maxDepth
        self.cwdOverride = cwdOverride
        self.extraEnv = extraEnv
    }

    enum CodingKeys: String, CodingKey {
        case agentId = "agent_id"
        case isolation
        case capabilityMode = "capability_mode"
        case toolConfig = "tool_config"
        case maxDepth = "max_depth"
        case cwdOverride = "cwd_override"
        case extraEnv = "extra_env"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentId = try c.decodeIfPresent(String.self, forKey: .agentId) ?? ""
        isolation = try c.decodeIfPresent(IsolationMode.self, forKey: .isolation) ?? .none
        capabilityMode = try c.decodeIfPresent(CapabilityMode.self, forKey: .capabilityMode) ?? .readWrite
        toolConfig = try c.decodeIfPresent([ToolServerConfig].self, forKey: .toolConfig) ?? []
        maxDepth = try c.decodeIfPresent(UInt32.self, forKey: .maxDepth) ?? 0
        cwdOverride = try c.decodeIfPresent(String.self, forKey: .cwdOverride)
        extraEnv = try c.decodeIfPresent([String: String].self, forKey: .extraEnv) ?? [:]
    }
}

/// Project configuration returned by `OpsChunk.projectConfig`.
public struct ProjectConfig: Hashable, Sendable, Codable, Equatable {
    public var values: [String: String]
    public var trusted: Bool

    public init(values: [String: String] = [:], trusted: Bool = false) {
        self.values = values
        self.trusted = trusted
    }

    enum CodingKeys: String, CodingKey {
        case values, trusted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        values = try c.decodeIfPresent([String: String].self, forKey: .values) ?? [:]
        trusted = try c.decodeIfPresent(Bool.self, forKey: .trusted) ?? false
    }
}

/// Permission policy returned by `OpsChunk.permissions`.
///
/// The three lists correspond to the three policy decisions a tool can
/// receive: `allow` (no prompt, always allow), `deny` (always deny), and
/// `ask` (always prompt the user). Together with `PermissionDecision`'s
/// per-invocation decisions (`allowOnce`, `allowSession`, `allowProject`,
/// `deny`), this is the complete permission vocabulary required by the
/// W1-S4 acceptance criterion: "allow, deny, ask, allow-once, allow-session,
/// rule source, and audit context without losing order."
///
/// "Rule source" is encoded by which list a tool pattern appears in
/// (`allow`/`deny`/`ask`); "audit context" is carried by the
/// `PermissionRequest` payload (`tool_name`, `summary`, `input_json`,
/// `destructive`) that the workspace emits to the sampler before each
/// decision, and by the `requires_reload` / `requires_restart` flags on
/// hook/plugin action outcomes. Order within each list is preserved by
/// `Array` (vs `Set`) so precedence rules can be evaluated deterministically.
public struct PermissionPolicy: Hashable, Sendable, Codable, Equatable {
    public var allow: [String]
    public var deny: [String]
    public var ask: [String]

    public init(allow: [String] = [], deny: [String] = [], ask: [String] = []) {
        self.allow = allow
        self.deny = deny
        self.ask = ask
    }

    enum CodingKeys: String, CodingKey {
        case allow, deny, ask
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allow = try c.decodeIfPresent([String].self, forKey: .allow) ?? []
        deny = try c.decodeIfPresent([String].self, forKey: .deny) ?? []
        ask = try c.decodeIfPresent([String].self, forKey: .ask) ?? []
    }
}

// MARK: - files.rs

/// A reference (input) to be resolved by the `@file` provider.
public struct FileReference: Hashable, Sendable, Codable, Equatable {
    public var raw: String
    public var absolutePath: String?

    public init(raw: String, absolutePath: String? = nil) {
        self.raw = raw
        self.absolutePath = absolutePath
    }

    enum CodingKeys: String, CodingKey {
        case raw
        case absolutePath = "absolute_path"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        raw = try c.decode(String.self, forKey: .raw)
        absolutePath = try c.decodeIfPresent(String.self, forKey: .absolutePath)
    }
}

/// A resolved file returned in `OpsChunk.resolvedFiles`.
public struct ResolvedFile: Hashable, Sendable, Codable, Equatable {
    public var reference: String
    public var path: String
    public var resolved: Bool
    public var preview: String?
    public var error: String?

    public init(
        reference: String,
        path: String = "",
        resolved: Bool = false,
        preview: String? = nil,
        error: String? = nil
    ) {
        self.reference = reference
        self.path = path
        self.resolved = resolved
        self.preview = preview
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case reference, path, resolved, preview, error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reference = try c.decode(String.self, forKey: .reference)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        resolved = try c.decodeIfPresent(Bool.self, forKey: .resolved) ?? false
        preview = try c.decodeIfPresent(String.self, forKey: .preview)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

// MARK: - git.rs

/// VCS kind.
public enum VcsKind: Hashable, Sendable, Codable, Equatable {
    case git
    case jj

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        switch raw {
        case "git": self = .git
        case "jj": self = .jj
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown VcsKind: \(raw)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .git: try c.encode("git")
        case .jj: try c.encode("jj")
        }
    }
}

/// Options controlling a `gitStatus` request.
public struct GitStatusOpts: Hashable, Sendable, Codable, Equatable {
    public var includeUntracked: Bool
    public var includeIgnored: Bool

    public init(includeUntracked: Bool = false, includeIgnored: Bool = false) {
        self.includeUntracked = includeUntracked
        self.includeIgnored = includeIgnored
    }

    enum CodingKeys: String, CodingKey {
        case includeUntracked = "include_untracked"
        case includeIgnored = "include_ignored"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        includeUntracked = try c.decodeIfPresent(Bool.self, forKey: .includeUntracked) ?? false
        includeIgnored = try c.decodeIfPresent(Bool.self, forKey: .includeIgnored) ?? false
    }
}

/// Status snapshot returned by `OpsChunk.gitStatus`.
public struct GitStatus: Hashable, Sendable, Codable, Equatable {
    public var branch: String
    public var headCommit: String
    public var root: String
    public var staged: [String]
    public var unstaged: [String]
    public var untracked: [String]
    public var clean: Bool
    public var vcs: VcsKind

    public init(
        branch: String = "",
        headCommit: String = "",
        root: String = "",
        staged: [String] = [],
        unstaged: [String] = [],
        untracked: [String] = [],
        clean: Bool = false,
        vcs: VcsKind = .git
    ) {
        self.branch = branch
        self.headCommit = headCommit
        self.root = root
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.clean = clean
        self.vcs = vcs
    }

    enum CodingKeys: String, CodingKey {
        case branch
        case headCommit = "head_commit"
        case root
        case staged, unstaged, untracked, clean, vcs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        headCommit = try c.decodeIfPresent(String.self, forKey: .headCommit) ?? ""
        root = try c.decodeIfPresent(String.self, forKey: .root) ?? ""
        staged = try c.decodeIfPresent([String].self, forKey: .staged) ?? []
        unstaged = try c.decodeIfPresent([String].self, forKey: .unstaged) ?? []
        untracked = try c.decodeIfPresent([String].self, forKey: .untracked) ?? []
        clean = try c.decodeIfPresent(Bool.self, forKey: .clean) ?? false
        vcs = try c.decodeIfPresent(VcsKind.self, forKey: .vcs) ?? .git
    }
}

/// Arguments for a `gitDiff` request.
public struct GitDiffArgs: Hashable, Sendable, Codable, Equatable {
    public var range: String?
    public var paths: [String]
    public var staged: Bool

    public init(range: String? = nil, paths: [String] = [], staged: Bool = false) {
        self.range = range
        self.paths = paths
        self.staged = staged
    }

    enum CodingKeys: String, CodingKey {
        case range, paths, staged
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        range = try c.decodeIfPresent(String.self, forKey: .range)
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        staged = try c.decodeIfPresent(Bool.self, forKey: .staged) ?? false
    }
}

/// Diff returned by `OpsChunk.gitDiff`.
public struct GitDiff: Hashable, Sendable, Codable, Equatable {
    public var patch: String
    public var files: [String]

    public init(patch: String = "", files: [String] = []) {
        self.patch = patch
        self.files = files
    }

    enum CodingKeys: String, CodingKey {
        case patch, files
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        patch = try c.decodeIfPresent(String.self, forKey: .patch) ?? ""
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
    }
}

/// Branch information returned by `OpsChunk.gitBranchInfo`.
public struct GitBranchInfo: Hashable, Sendable, Codable, Equatable {
    public var current: String?
    public var local: [String]
    public var upstream: String?

    public init(current: String? = nil, local: [String] = [], upstream: String? = nil) {
        self.current = current
        self.local = local
        self.upstream = upstream
    }

    enum CodingKeys: String, CodingKey {
        case current, local, upstream
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        current = try c.decodeIfPresent(String.self, forKey: .current)
        local = try c.decodeIfPresent([String].self, forKey: .local) ?? []
        upstream = try c.decodeIfPresent(String.self, forKey: .upstream)
    }
}

/// Repository metadata returned by `OpsChunk.gitMetadata`.
public struct GitMetadata: Hashable, Sendable, Codable, Equatable {
    public var originUrl: String?
    public var root: String
    public var defaultBranch: String?
    public var vcs: VcsKind

    public init(
        originUrl: String? = nil,
        root: String = "",
        defaultBranch: String? = nil,
        vcs: VcsKind = .git
    ) {
        self.originUrl = originUrl
        self.root = root
        self.defaultBranch = defaultBranch
        self.vcs = vcs
    }

    enum CodingKeys: String, CodingKey {
        case originUrl = "origin_url"
        case root
        case defaultBranch = "default_branch"
        case vcs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        originUrl = try c.decodeIfPresent(String.self, forKey: .originUrl)
        root = try c.decodeIfPresent(String.self, forKey: .root) ?? ""
        defaultBranch = try c.decodeIfPresent(String.self, forKey: .defaultBranch)
        vcs = try c.decodeIfPresent(VcsKind.self, forKey: .vcs) ?? .git
    }
}

// MARK: - hunk.rs

/// A single tracked hunk in a file.
public struct Hunk: Hashable, Sendable, Codable, Equatable {
    public var id: HunkId
    public var path: String
    public var added: UInt32
    public var removed: UInt32
    public var startLine: UInt32
    public var summary: String

    public init(
        id: HunkId,
        path: String = "",
        added: UInt32 = 0,
        removed: UInt32 = 0,
        startLine: UInt32 = 0,
        summary: String = ""
    ) {
        self.id = id
        self.path = path
        self.added = added
        self.removed = removed
        self.startLine = startLine
        self.summary = summary
    }

    enum CodingKeys: String, CodingKey {
        case id, path
        case added, removed
        case startLine = "start_line"
        case summary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(HunkId.self, forKey: .id)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        added = try c.decodeIfPresent(UInt32.self, forKey: .added) ?? 0
        removed = try c.decodeIfPresent(UInt32.self, forKey: .removed) ?? 0
        startLine = try c.decodeIfPresent(UInt32.self, forKey: .startLine) ?? 0
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
    }
}

/// Action applied to a hunk by `WorkspaceOpsRequest.actOnHunk`.
public enum HunkAction: Hashable, Sendable, Codable, Equatable {
    case accept(hunkId: HunkId)
    case reject(hunkId: HunkId)
    case revert(hunkId: HunkId)

    private enum Tag: String, Codable {
        case accept, reject, revert
    }
    private enum CodingKeys: String, CodingKey { case type, data, hunkId = "hunk_id" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
        let id = try inner.decode(HunkId.self, forKey: .hunkId)
        switch tag {
        case .accept: self = .accept(hunkId: id)
        case .reject: self = .reject(hunkId: id)
        case .revert: self = .revert(hunkId: id)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .accept(let id):
            try c.encode(Tag.accept, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(id, forKey: .hunkId)
        case .reject(let id):
            try c.encode(Tag.reject, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(id, forKey: .hunkId)
        case .revert(let id):
            try c.encode(Tag.revert, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(id, forKey: .hunkId)
        }
    }
}

// MARK: - interaction.rs

/// A single question in an `ask_user_question` invocation.
public struct UserQuestion: Hashable, Sendable, Codable, Equatable {
    public var question: String
    public var options: [UserQuestionOption]
    public var multiSelect: Bool

    public init(question: String, options: [UserQuestionOption] = [], multiSelect: Bool = false) {
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
    }

    enum CodingKeys: String, CodingKey {
        case question, options
        case multiSelect = "multi_select"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = try c.decode(String.self, forKey: .question)
        options = try c.decodeIfPresent([UserQuestionOption].self, forKey: .options) ?? []
        multiSelect = try c.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
    }
}

/// One choice within a `UserQuestion`.
public struct UserQuestionOption: Hashable, Sendable, Codable, Equatable {
    public var label: String
    public var description: String
    public var preview: String?

    public init(label: String, description: String = "", preview: String? = nil) {
        self.label = label
        self.description = description
        self.preview = preview
    }

    enum CodingKeys: String, CodingKey {
        case label, description, preview
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        preview = try c.decodeIfPresent(String.self, forKey: .preview)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encode(description, forKey: .description)
        // `skip_serializing_if = "Option::is_none"` — only emit when set.
        if let preview = preview {
            try c.encode(preview, forKey: .preview)
        }
    }
}

/// The user's answer to a single `UserQuestion`.
public enum UserAnswer: Hashable, Sendable, Codable, Equatable {
    case selected(String)
    case other(String)
    case multiple([String])

    private enum Tag: String, Codable {
        case selected, other, multiple
    }
    private enum CodingKeys: String, CodingKey { case type, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        switch tag {
        case .selected:
            self = .selected(try c.decode(String.self, forKey: .data))
        case .other:
            self = .other(try c.decode(String.self, forKey: .data))
        case .multiple:
            self = .multiple(try c.decode([String].self, forKey: .data))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .selected(let s):
            try c.encode(Tag.selected, forKey: .type)
            try c.encode(s, forKey: .data)
        case .other(let s):
            try c.encode(Tag.other, forKey: .type)
            try c.encode(s, forKey: .data)
        case .multiple(let arr):
            try c.encode(Tag.multiple, forKey: .type)
            try c.encode(arr, forKey: .data)
        }
    }
}

// MARK: - memory.rs

/// One entry returned from a memory search.
public struct MemoryChunk: Hashable, Sendable, Codable, Equatable {
    public var id: String
    public var content: String
    public var source: String?
    /// Optional relevance score from the search backend.
    ///
    /// Stored as `Float?` (not `Double`) to match the Rust `f32` field;
    /// `Float`-to-JSON round-trip is exact for typical score magnitudes.
    /// `Equatable`/`Hashable` conformance uses Swift's `Float` semantics.
    public var score: Float?

    public init(id: String, content: String = "", source: String? = nil, score: Float? = nil) {
        self.id = id
        self.content = content
        self.source = source
        self.score = score
    }

    enum CodingKeys: String, CodingKey {
        case id, content, source, score
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source)
        score = try c.decodeIfPresent(Float.self, forKey: .score)
    }
}

// MARK: - permission.rs

/// A pending permission request emitted to the sampler via
/// `ToolChunk.needPermission`.
public struct PermissionRequest: Hashable, Sendable, Codable, Equatable {
    public var toolName: String
    public var summary: String
    public var inputJson: String
    public var destructive: Bool

    public init(toolName: String, summary: String = "", inputJson: String = "", destructive: Bool = false) {
        self.toolName = toolName
        self.summary = summary
        self.inputJson = inputJson
        self.destructive = destructive
    }

    enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case summary
        case inputJson = "input_json"
        case destructive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolName = try c.decode(String.self, forKey: .toolName)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        inputJson = try c.decodeIfPresent(String.self, forKey: .inputJson) ?? ""
        destructive = try c.decodeIfPresent(Bool.self, forKey: .destructive) ?? false
    }
}

/// User decision delivered to the workspace via
/// `ToolResponse.permission` on the tool's bidi response sender.
///
/// The four cases — `allowOnce`, `allowSession`, `allowProject`, and
/// `deny` — together with `PermissionPolicy`'s `allow` / `deny` / `ask`
/// lists form the complete permission vocabulary required by the W1-S4
/// acceptance criterion: "allow, deny, ask, allow-once, allow-session,
/// rule source, and audit context without losing order."
public enum PermissionDecision: Hashable, Sendable, Codable, Equatable {
    /// Allow this single invocation.
    case allowOnce
    /// Allow and remember the decision for the rest of the session.
    case allowSession
    /// Allow and persist the decision to the project's permission policy.
    case allowProject
    /// Deny this invocation.
    case deny(reason: String)

    private enum Tag: String, Codable {
        case allowOnce = "allow_once"
        case allowSession = "allow_session"
        case allowProject = "allow_project"
        case deny
    }
    private enum CodingKeys: String, CodingKey { case type, data, reason }
    private enum DenyPayload: Codable {
        case deny(reason: String)
        enum CodingKeys: String, CodingKey { case reason }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .deny(reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .deny(let r):
                // `#[serde(default)]` always emits the field (empty string
                // when absent at construction time).
                try c.encode(r, forKey: .reason)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        switch tag {
        case .allowOnce:
            // Unit variant — `data` may be `null` or absent.
            if c.contains(.data) { _ = try? c.decode(JSONValue?.self, forKey: .data) }
            self = .allowOnce
        case .allowSession:
            if c.contains(.data) { _ = try? c.decode(JSONValue?.self, forKey: .data) }
            self = .allowSession
        case .allowProject:
            if c.contains(.data) { _ = try? c.decode(JSONValue?.self, forKey: .data) }
            self = .allowProject
        case .deny:
            let p = try c.decodeIfPresent(DenyPayload.self, forKey: .data)
            if case .deny(let r) = p {
                self = .deny(reason: r)
            } else {
                self = .deny(reason: "")
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allowOnce:
            try c.encode(Tag.allowOnce, forKey: .type)
            // Unit variant: omit `data` (matches serde's adjacent-tagging
            // behavior for unit variants — `{"type":"allow_once"}`).
        case .allowSession:
            try c.encode(Tag.allowSession, forKey: .type)
        case .allowProject:
            try c.encode(Tag.allowProject, forKey: .type)
        case .deny(let r):
            try c.encode(Tag.deny, forKey: .type)
            try c.encode(DenyPayload.deny(reason: r), forKey: .data)
        }
    }
}

// MARK: - plan_mode.rs

/// Direction of a plan-mode transition the tool wants to make.
public enum PlanModeTransition: Hashable, Sendable, Codable, Equatable {
    /// Tool wants to enter plan mode. `plan` is the proposed plan content
    /// (`nil` at the moment of entry; populated later in the same session
    /// as the plan develops).
    case enter(plan: String?)
    /// Tool wants to exit plan mode and resume normal operation.
    /// `finalPlan` is what the model will execute; the UI may render it
    /// for review.
    case exit(finalPlan: String?)

    private enum Tag: String, Codable { case enter, exit }
    private enum CodingKeys: String, CodingKey { case type, data, plan, finalPlan = "final_plan" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
        switch tag {
        case .enter:
            self = .enter(plan: try inner.decodeIfPresent(String.self, forKey: .plan))
        case .exit:
            self = .exit(finalPlan: try inner.decodeIfPresent(String.self, forKey: .finalPlan))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .enter(let p):
            try c.encode(Tag.enter, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            // `#[serde(default)]` — always emit `plan` (null when nil).
            try inner.encode(p, forKey: .plan)
        case .exit(let p):
            try c.encode(Tag.exit, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(p, forKey: .finalPlan)
        }
    }
}

/// User's decision on a proposed plan-mode transition.
///
/// `defer` is distinct from `reject`: it means "not right now" rather than
/// "no". Useful when the user wants to gather more context before approving
/// (e.g. read additional files first); the model may re-propose later.
public enum PlanModeDecision: Hashable, Sendable, Codable, Equatable {
    case approve
    case reject(feedback: String?)
    case `defer`

    private enum Tag: String, Codable { case approve, reject, `defer` }
    private enum CodingKeys: String, CodingKey { case type, data, feedback }
    private enum RejectPayload: Codable {
        case reject(feedback: String?)
        enum CodingKeys: String, CodingKey { case feedback }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .reject(feedback: try c.decodeIfPresent(String.self, forKey: .feedback))
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .reject(let f):
                // `#[serde(default)]` always emits the field (null when nil).
                try c.encode(f, forKey: .feedback)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        switch tag {
        case .approve:
            if c.contains(.data) { _ = try? c.decode(JSONValue?.self, forKey: .data) }
            self = .approve
        case .reject:
            let p = try c.decodeIfPresent(RejectPayload.self, forKey: .data)
            if case .reject(let f) = p {
                self = .reject(feedback: f)
            } else {
                self = .reject(feedback: nil)
            }
        case .`defer`:
            if c.contains(.data) { _ = try? c.decode(JSONValue?.self, forKey: .data) }
            self = .`defer`
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .approve:
            try c.encode(Tag.approve, forKey: .type)
        case .reject(let f):
            try c.encode(Tag.reject, forKey: .type)
            try c.encode(RejectPayload.reject(feedback: f), forKey: .data)
        case .`defer`:
            try c.encode(Tag.`defer`, forKey: .type)
        }
    }
}

// MARK: - plugins.rs (workspace stream DTOs — distinct from
// OpenGrokHooksPluginTypes ACP extension DTOs).

/// Plugin metadata surfaced by `OpsChunk.plugins`.
///
/// NOTE: this `source`-keyed `PluginInfo` is the workspace stream DTO,
/// distinct from `OpenGrokHooksPluginTypes.PluginInfo` (the richer
/// pager-facing ACP extension DTO keyed by `scope`). The two are
/// intentionally separate types — the wire shapes diverge.
public struct PluginInfo: Hashable, Sendable, Codable, Equatable {
    public var id: String
    public var name: String
    public var version: String
    public var path: String
    public var source: String
    public var enabled: Bool

    public init(
        id: String,
        name: String = "",
        version: String = "",
        path: String = "",
        source: String = "",
        enabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.path = path
        self.source = source
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case id, name, version, path, source, enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }
}

/// Hook metadata surfaced by `OpsChunk.hooks` / `WorkspaceEvent.hooksChanged`.
///
/// NOTE: workspace stream DTO, distinct from
/// `OpenGrokHooksPluginTypes.HookInfo` (the richer ACP extension DTO).
public struct HookInfo: Hashable, Sendable, Codable, Equatable {
    public var id: String
    public var name: String
    public var event: String
    public var pluginId: String?
    public var enabled: Bool

    public init(
        id: String,
        name: String = "",
        event: String = "",
        pluginId: String? = nil,
        enabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.event = event
        self.pluginId = pluginId
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case id, name, event
        case pluginId = "plugin_id"
        case enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        event = try c.decodeIfPresent(String.self, forKey: .event) ?? ""
        pluginId = try c.decodeIfPresent(String.self, forKey: .pluginId)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }
}

// MARK: - search.rs

/// Arguments for a `ripgrep` request.
public struct RipgrepArgs: Hashable, Sendable, Codable, Equatable {
    public var pattern: String
    public var cwd: String?
    public var globs: [String]
    public var caseInsensitive: Bool
    public var maxMatches: UInt32?

    public init(
        pattern: String,
        cwd: String? = nil,
        globs: [String] = [],
        caseInsensitive: Bool = false,
        maxMatches: UInt32? = nil
    ) {
        self.pattern = pattern
        self.cwd = cwd
        self.globs = globs
        self.caseInsensitive = caseInsensitive
        self.maxMatches = maxMatches
    }

    enum CodingKeys: String, CodingKey {
        case pattern, cwd, globs
        case caseInsensitive = "case_insensitive"
        case maxMatches = "max_matches"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pattern = try c.decode(String.self, forKey: .pattern)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        globs = try c.decodeIfPresent([String].self, forKey: .globs) ?? []
        caseInsensitive = try c.decodeIfPresent(Bool.self, forKey: .caseInsensitive) ?? false
        maxMatches = try c.decodeIfPresent(UInt32.self, forKey: .maxMatches)
    }
}

/// One match emitted as `OpsChunk.ripgrepHit`.
public struct ContentMatch: Hashable, Sendable, Codable, Equatable {
    public var path: String
    public var lineNumber: UInt32
    public var line: String
    public var spans: [MatchSpan]

    public init(path: String, lineNumber: UInt32 = 0, line: String = "", spans: [MatchSpan] = []) {
        self.path = path
        self.lineNumber = lineNumber
        self.line = line
        self.spans = spans
    }

    enum CodingKeys: String, CodingKey {
        case path
        case lineNumber = "line_number"
        case line, spans
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        lineNumber = try c.decodeIfPresent(UInt32.self, forKey: .lineNumber) ?? 0
        line = try c.decodeIfPresent(String.self, forKey: .line) ?? ""
        spans = try c.decodeIfPresent([MatchSpan].self, forKey: .spans) ?? []
    }
}

/// Byte span within a `ContentMatch.line`.
public struct MatchSpan: Hashable, Sendable, Codable, Equatable {
    public var start: UInt32
    public var end: UInt32

    public init(start: UInt32 = 0, end: UInt32 = 0) {
        self.start = start
        self.end = end
    }
}

/// Statistics emitted as `OpsChunk.ripgrepDone`.
public struct RipgrepStats: Hashable, Sendable, Codable, Equatable {
    public var filesMatched: UInt32
    public var linesMatched: UInt32
    public var truncated: Bool

    public init(filesMatched: UInt32 = 0, linesMatched: UInt32 = 0, truncated: Bool = false) {
        self.filesMatched = filesMatched
        self.linesMatched = linesMatched
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey {
        case filesMatched = "files_matched"
        case linesMatched = "lines_matched"
        case truncated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filesMatched = try c.decodeIfPresent(UInt32.self, forKey: .filesMatched) ?? 0
        linesMatched = try c.decodeIfPresent(UInt32.self, forKey: .linesMatched) ?? 0
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

/// Arguments for a `fuzzySearch` request.
public struct FuzzySearchArgs: Hashable, Sendable, Codable, Equatable {
    public var query: String
    public var cwd: String?
    public var limit: UInt32?

    public init(query: String, cwd: String? = nil, limit: UInt32? = nil) {
        self.query = query
        self.cwd = cwd
        self.limit = limit
    }

    enum CodingKeys: String, CodingKey {
        case query, cwd, limit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        query = try c.decode(String.self, forKey: .query)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        limit = try c.decodeIfPresent(UInt32.self, forKey: .limit)
    }
}

/// One match emitted as `OpsChunk.fuzzyMatch`.
public struct FuzzyMatch: Hashable, Sendable, Codable, Equatable {
    public var path: String
    public var score: Int32
    public var matchedIndices: [UInt32]

    public init(path: String, score: Int32 = 0, matchedIndices: [UInt32] = []) {
        self.path = path
        self.score = score
        self.matchedIndices = matchedIndices
    }

    enum CodingKeys: String, CodingKey {
        case path, score
        case matchedIndices = "matched_indices"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        score = try c.decodeIfPresent(Int32.self, forKey: .score) ?? 0
        matchedIndices = try c.decodeIfPresent([UInt32].self, forKey: .matchedIndices) ?? []
    }
}

// MARK: - session.rs

/// Snapshot of a session emitted by `SessionChunk.sessionInfo` (one per
/// session in the response stream of `SessionLifecycleRequest.list`).
public struct AgentSessionInfo: Hashable, Sendable, Codable, Equatable {
    public var id: SessionId
    public var parent: SessionId?
    public var agentId: String
    public var isolation: IsolationMode
    /// Wall-clock creation time. Defaults to `Date(timeIntervalSince1970: 0)`
    /// (Unix epoch) rather than `Date()` so a missing field does not
    /// silently impersonate the receiver's wall clock.
    public var createdAt: Date

    public init(
        id: SessionId,
        parent: SessionId? = nil,
        agentId: String = "",
        isolation: IsolationMode = .none,
        createdAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.id = id
        self.parent = parent
        self.agentId = agentId
        self.isolation = isolation
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, parent
        case agentId = "agent_id"
        case isolation
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(SessionId.self, forKey: .id)
        parent = try c.decodeIfPresent(SessionId.self, forKey: .parent)
        agentId = try c.decodeIfPresent(String.self, forKey: .agentId) ?? ""
        isolation = try c.decodeIfPresent(IsolationMode.self, forKey: .isolation) ?? .none
        // Default to epoch when absent.
        if let date = try c.decodeIfPresent(Date.self, forKey: .createdAt) {
            createdAt = date
        } else {
            createdAt = Date(timeIntervalSince1970: 0)
        }
    }
}

/// Result of a `SessionLifecycleRequest.rewind`.
public struct RewindResult: Hashable, Sendable, Codable, Equatable {
    public var session: SessionId
    public var headPromptIndex: UInt64
    public var promptsDropped: UInt64

    public init(
        session: SessionId,
        headPromptIndex: UInt64 = 0,
        promptsDropped: UInt64 = 0
    ) {
        self.session = session
        self.headPromptIndex = headPromptIndex
        self.promptsDropped = promptsDropped
    }

    enum CodingKeys: String, CodingKey {
        case session
        case headPromptIndex = "head_prompt_index"
        case promptsDropped = "prompts_dropped"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = try c.decode(SessionId.self, forKey: .session)
        headPromptIndex = try c.decodeIfPresent(UInt64.self, forKey: .headPromptIndex) ?? 0
        promptsDropped = try c.decodeIfPresent(UInt64.self, forKey: .promptsDropped) ?? 0
    }
}

/// One rewind point returned in `SessionChunk.rewindPoints`.
public struct RewindPoint: Hashable, Sendable, Codable, Equatable {
    public var promptIndex: UInt64
    /// Wall-clock time the prompt was started. Defaults to Unix epoch
    /// rather than the receiver's wall clock when absent.
    public var at: Date
    public var summary: String

    public init(
        promptIndex: UInt64,
        at: Date = Date(timeIntervalSince1970: 0),
        summary: String = ""
    ) {
        self.promptIndex = promptIndex
        self.at = at
        self.summary = summary
    }

    enum CodingKeys: String, CodingKey {
        case promptIndex = "prompt_index"
        case at
        case summary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        promptIndex = try c.decode(UInt64.self, forKey: .promptIndex)
        if let date = try c.decodeIfPresent(Date.self, forKey: .at) {
            at = date
        } else {
            at = Date(timeIntervalSince1970: 0)
        }
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
    }
}

/// Filesystem event kind reported by `WorkspaceEvent.fsChanged`.
public enum FsEventKind: Hashable, Sendable, Codable, Equatable {
    case created
    case modified
    case removed
    case renamed

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        switch raw {
        case "created": self = .created
        case "modified": self = .modified
        case "removed": self = .removed
        case "renamed": self = .renamed
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown FsEventKind: \(raw)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .created: try c.encode("created")
        case .modified: try c.encode("modified")
        case .removed: try c.encode("removed")
        case .renamed: try c.encode("renamed")
        }
    }
}

/// Generic server-status enum used for both MCP and LSP servers.
public enum ServerStatus: Hashable, Sendable, Codable, Equatable {
    case starting
    case running
    case stopped
    case failed

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        switch raw {
        case "starting": self = .starting
        case "running": self = .running
        case "stopped": self = .stopped
        case "failed": self = .failed
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown ServerStatus: \(raw)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .starting: try c.encode("starting")
        case .running: try c.encode("running")
        case .stopped: try c.encode("stopped")
        case .failed: try c.encode("failed")
        }
    }
}

/// MCP server status reported by `WorkspaceEvent.mcpServerStateChanged`.
public typealias McpServerStatus = ServerStatus

/// LSP server status reported by `WorkspaceEvent.lspServerStateChanged`.
public typealias LspServerStatus = ServerStatus

// MARK: - skills.rs

/// Discovered skill metadata surfaced by `OpsChunk.skills`.
///
/// NOTE: this `source`-keyed `SkillInfo` is **not** the wire shape of the
/// `workspace.discover_skills` RPC — that is `RPCSkills.SkillInfo`
/// (`scope`-keyed), defined in `RpcMethods.swift`.
public struct SkillInfo: Hashable, Sendable, Codable, Equatable {
    public var id: String
    public var displayName: String
    public var description: String
    public var path: String
    public var source: String

    public init(
        id: String,
        displayName: String = "",
        description: String = "",
        path: String = "",
        source: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.path = path
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case description, path, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
    }
}

// MARK: - tools.rs

/// One incremental tool output frame (e.g. bash stdout).
public struct ToolOutputChunk: Hashable, Sendable, Codable, Equatable {
    public var callId: ToolCallId
    public var stream: String
    /// Raw bytes from the tool. Encoded as a standard (RFC 4648) base64
    /// string in JSON; the underlying bytes go over as length-prefixed
    /// bytes in binary serializers.
    public var bytes: Data
    /// Wall-clock timestamp the chunk was emitted (UTC). Defaults to Unix
    /// epoch when absent (rather than `Date()` — the receiver's wall clock
    /// must not impersonate the originator's).
    public var at: Date

    public init(
        callId: ToolCallId,
        stream: String = "",
        bytes: Data = Data(),
        at: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.callId = callId
        self.stream = stream
        self.bytes = bytes
        self.at = at
    }

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case stream
        case bytes
        case at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        callId = try c.decode(ToolCallId.self, forKey: .callId)
        stream = try c.decodeIfPresent(String.self, forKey: .stream) ?? ""
        // `#[serde(with = "bytes_as_base64")]` — bytes are a base64 string
        // on the wire.
        if let b64 = try c.decodeIfPresent(String.self, forKey: .bytes) {
            bytes = Data(base64Encoded: b64) ?? Data()
        } else {
            bytes = Data()
        }
        if let date = try c.decodeIfPresent(Date.self, forKey: .at) {
            at = date
        } else {
            at = Date(timeIntervalSince1970: 0)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(callId, forKey: .callId)
        try c.encode(stream, forKey: .stream)
        try c.encode(bytes.base64EncodedString(), forKey: .bytes)
        try c.encode(at, forKey: .at)
    }
}

/// Lifecycle / progress event emitted by a tool.
public enum ToolProgress: Hashable, Sendable, Codable, Equatable {
    case started(callId: ToolCallId)
    case status(callId: ToolCallId, message: String)
    case percent(callId: ToolCallId, fraction: Float)

    private enum Tag: String, Codable {
        case started, status, percent
    }
    private enum CodingKeys: String, CodingKey {
        case type, data
        case callId = "call_id"
        case message
        case fraction
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
        let callId = try inner.decode(ToolCallId.self, forKey: .callId)
        switch tag {
        case .started:
            self = .started(callId: callId)
        case .status:
            let message = try inner.decode(String.self, forKey: .message)
            self = .status(callId: callId, message: message)
        case .percent:
            let fraction = try inner.decode(Float.self, forKey: .fraction)
            self = .percent(callId: callId, fraction: fraction)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .started(let id):
            try c.encode(Tag.started, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(id, forKey: .callId)
        case .status(let id, let message):
            try c.encode(Tag.status, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(id, forKey: .callId)
            try inner.encode(message, forKey: .message)
        case .percent(let id, let fraction):
            try c.encode(Tag.percent, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(id, forKey: .callId)
            try inner.encode(fraction, forKey: .fraction)
        }
    }
}

/// Terminal result emitted as exactly one `ToolChunk.final` per call.
public struct ToolCallResult: Hashable, Sendable, Codable, Equatable {
    public var callId: ToolCallId
    public var exitCode: Int32
    public var summary: String
    public var outputJson: String
    public var cancelled: Bool

    public init(
        callId: ToolCallId,
        exitCode: Int32 = 0,
        summary: String = "",
        outputJson: String = "",
        cancelled: Bool = false
    ) {
        self.callId = callId
        self.exitCode = exitCode
        self.summary = summary
        self.outputJson = outputJson
        self.cancelled = cancelled
    }

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case exitCode = "exit_code"
        case summary
        case outputJson = "output_json"
        case cancelled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        callId = try c.decode(ToolCallId.self, forKey: .callId)
        exitCode = try c.decodeIfPresent(Int32.self, forKey: .exitCode) ?? 0
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        outputJson = try c.decodeIfPresent(String.self, forKey: .outputJson) ?? ""
        cancelled = try c.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
    }
}

/// Tool definition surfaced via `ToolChunk.definitions`.
public struct ToolDef: Hashable, Sendable, Codable, Equatable {
    public var name: String
    public var description: String
    public var inputSchemaJson: String
    public var requiresPermission: Bool

    public init(
        name: String,
        description: String = "",
        inputSchemaJson: String = "",
        requiresPermission: Bool = false
    ) {
        self.name = name
        self.description = description
        self.inputSchemaJson = inputSchemaJson
        self.requiresPermission = requiresPermission
    }

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchemaJson = "input_schema_json"
        case requiresPermission = "requires_permission"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        inputSchemaJson = try c.decodeIfPresent(String.self, forKey: .inputSchemaJson) ?? ""
        requiresPermission = try c.decodeIfPresent(Bool.self, forKey: .requiresPermission) ?? false
    }
}
