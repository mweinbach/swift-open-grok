// Chunks.swift
//
// Streaming response chunk types. Ported from
// crates/codegen/xai-grok-workspace-types/src/chunks/*.
//
// Each transport call returns a stream of chunks. The chunk type is
// domain-specific:
//   * `ToolChunk` — streaming output / progress / final result for a tool
//     invocation (or the response to `ToolRequest.definitions`). Tools that
//     need user approval or input also yield `needPermission` /
//     `needUserAnswer` chunks; the sampler answers them by sending
//     `ToolResponse` values back on the paired bidi response sender.
//   * `OpsChunk` — one or more chunks for a workspace ops call (most are
//     unary; ripgrep / fuzzy_search are streaming).
//   * `SessionChunk` — one or more chunks for a session lifecycle call.
//
// Every chunk variant maps to a static `ChunkKind` discriminator so the
// typed-trait layer can produce a clear `WorkspaceError.protocolMismatch`
// when an unexpected chunk arrives on the wrong stream.

import Foundation
import OpenGrokShared

// MARK: - ToolChunk

/// Streaming chunk for a tool call.
///
/// Stream contract:
/// * For tool invocations, the stream emits zero or more `output` /
///   `progress` chunks then **exactly one** `final` chunk and closes.
/// * A tool may additionally yield zero or more `needPermission` /
///   `needUserAnswer` / `needPlanModeChange` chunks before its `final`.
///   Each blocks the tool until the sampler replies with the matching
///   `ToolResponse` on the paired response sender (correlated by `reqId`).
///   The sampler is the unique consumer of the stream, so exhaustive
///   matching forces it to handle every variant — this is how the
///   "must respond" property is enforced at the type level.
/// * For `ToolRequest.definitions`, the stream emits exactly one
///   `definitions` chunk and closes.
public enum ToolChunk: Hashable, Sendable, Codable, Equatable {
    /// Incremental tool output (e.g. bash stdout). Zero or more.
    case output(ToolOutputChunk)
    /// Tool-emitted progress / lifecycle event.
    case progress(ToolProgress)
    /// Terminal result. Exactly one, last. Stream closes after this.
    case final(ToolCallResult)
    /// Tool definitions response. Single chunk.
    case definitions([ToolDef])
    /// Tool needs the sampler to make a permission decision before continuing.
    case needPermission(reqId: String, request: PermissionRequest)
    /// Tool needs the sampler to collect answers from the user.
    case needUserAnswer(reqId: String, questions: [UserQuestion])
    /// Tool needs the sampler to approve a plan-mode transition (entering
    /// or exiting plan mode).
    ///
    /// Plan mode transitions are deliberately *not* broadcast on the
    /// EventBus: sampler-caused state flows back via the call's stream
    /// chunks (here) and the resulting `final` payload, never via EventBus.
    case needPlanModeChange(reqId: String, transition: PlanModeTransition)

    /// Discriminator for the current variant.
    public var kind: ChunkKind {
        switch self {
        case .output: return .toolOutput
        case .progress: return .toolProgress
        case .final: return .toolFinal
        case .definitions: return .toolDefinitions
        case .needPermission: return .needPermission
        case .needUserAnswer: return .needUserAnswer
        case .needPlanModeChange: return .needPlanModeChange
        }
    }

    // MARK: Codable — adjacent `type`/`data` tagging, snake_case variants

    private enum Tag: String, Codable {
        case output, progress, final, definitions
        case needPermission = "need_permission"
        case needUserAnswer = "need_user_answer"
        case needPlanModeChange = "need_plan_mode_change"
    }
    private enum CodingKeys: String, CodingKey {
        case type, data
        case reqId = "req_id"
        case request
        case questions
        case transition
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        switch tag {
        case .output:
            self = .output(try c.decode(ToolOutputChunk.self, forKey: .data))
        case .progress:
            self = .progress(try c.decode(ToolProgress.self, forKey: .data))
        case .final:
            self = .final(try c.decode(ToolCallResult.self, forKey: .data))
        case .definitions:
            self = .definitions(try c.decode([ToolDef].self, forKey: .data))
        case .needPermission:
            let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            self = .needPermission(
                reqId: try inner.decode(String.self, forKey: .reqId),
                request: try inner.decode(PermissionRequest.self, forKey: .request)
            )
        case .needUserAnswer:
            let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            self = .needUserAnswer(
                reqId: try inner.decode(String.self, forKey: .reqId),
                questions: try inner.decode([UserQuestion].self, forKey: .questions)
            )
        case .needPlanModeChange:
            let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            self = .needPlanModeChange(
                reqId: try inner.decode(String.self, forKey: .reqId),
                transition: try inner.decode(PlanModeTransition.self, forKey: .transition)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .output(let v):
            try c.encode(Tag.output, forKey: .type)
            try c.encode(v, forKey: .data)
        case .progress(let v):
            try c.encode(Tag.progress, forKey: .type)
            try c.encode(v, forKey: .data)
        case .final(let v):
            try c.encode(Tag.final, forKey: .type)
            try c.encode(v, forKey: .data)
        case .definitions(let v):
            try c.encode(Tag.definitions, forKey: .type)
            try c.encode(v, forKey: .data)
        case .needPermission(let reqId, let request):
            try c.encode(Tag.needPermission, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(reqId, forKey: .reqId)
            try inner.encode(request, forKey: .request)
        case .needUserAnswer(let reqId, let questions):
            try c.encode(Tag.needUserAnswer, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(reqId, forKey: .reqId)
            try inner.encode(questions, forKey: .questions)
        case .needPlanModeChange(let reqId, let transition):
            try c.encode(Tag.needPlanModeChange, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(reqId, forKey: .reqId)
            try inner.encode(transition, forKey: .transition)
        }
    }
}

// MARK: - ToolResponse

/// Sampler-to-workspace message sent on the tool's bidi response sender to
/// satisfy a `ToolChunk.needPermission`, `ToolChunk.needUserAnswer`, or
/// `ToolChunk.needPlanModeChange`.
///
/// One `ToolResponse` per `Need*` chunk; correlated by `reqId` (echoed back
/// from the corresponding `Need*` chunk).
public enum ToolResponse: Hashable, Sendable, Codable, Equatable {
    case permission(reqId: String, decision: PermissionDecision)
    case userAnswer(reqId: String, answers: [UserAnswer])
    case planModeChange(reqId: String, decision: PlanModeDecision)

    private enum Tag: String, Codable {
        case permission, userAnswer = "user_answer", planModeChange = "plan_mode_change"
    }
    private enum CodingKeys: String, CodingKey {
        case type, data
        case reqId = "req_id"
        case decision
        case answers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
        let reqId = try inner.decode(String.self, forKey: .reqId)
        switch tag {
        case .permission:
            self = .permission(reqId: reqId, decision: try inner.decode(PermissionDecision.self, forKey: .decision))
        case .userAnswer:
            self = .userAnswer(reqId: reqId, answers: try inner.decode([UserAnswer].self, forKey: .answers))
        case .planModeChange:
            self = .planModeChange(reqId: reqId, decision: try inner.decode(PlanModeDecision.self, forKey: .decision))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .permission(let reqId, let decision):
            try c.encode(Tag.permission, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(reqId, forKey: .reqId)
            try inner.encode(decision, forKey: .decision)
        case .userAnswer(let reqId, let answers):
            try c.encode(Tag.userAnswer, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(reqId, forKey: .reqId)
            try inner.encode(answers, forKey: .answers)
        case .planModeChange(let reqId, let decision):
            try c.encode(Tag.planModeChange, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(reqId, forKey: .reqId)
            try inner.encode(decision, forKey: .decision)
        }
    }
}

// MARK: - OpsChunk

/// Streaming chunk for an ops call.
///
/// Most variants are unary (one chunk then close); `fuzzyMatch` and
/// `ripgrepHit` stream zero-or-more times. `ripgrepHit` is followed by a
/// single explicit `ripgrepDone` terminator.
public enum OpsChunk: Hashable, Sendable, Codable, Equatable {
    // Unary VCS responses
    case gitStatus(GitStatus)
    case gitDiff(GitDiff)
    case gitBranchInfo(GitBranchInfo)
    case gitMetadata(GitMetadata?)
    // Unary discovery / read responses
    case hunks([Hunk])
    case skills([SkillInfo])
    case plugins([PluginInfo])
    case projectConfig(ProjectConfig)
    case permissions(PermissionPolicy)
    case envrc([String: String])
    case resolvedFiles([ResolvedFile])
    case memoryChunks([MemoryChunk])
    case plugin(PluginInfo)
    /// Acknowledgement for void ops (`actOnHunk`, `memoryWrite`,
    /// `refreshPlugins` accepted, ...).
    case ack
    // Streaming responses
    case fuzzyMatch(FuzzyMatch)
    case ripgrepHit(ContentMatch)
    case ripgrepDone(RipgrepStats)

    /// Discriminator for the current variant.
    public var kind: ChunkKind {
        switch self {
        case .gitStatus: return .gitStatus
        case .gitDiff: return .gitDiff
        case .gitBranchInfo: return .gitBranchInfo
        case .gitMetadata: return .gitMetadata
        case .hunks: return .hunks
        case .skills: return .skills
        case .plugins: return .plugins
        case .projectConfig: return .projectConfig
        case .permissions: return .permissions
        case .envrc: return .envrc
        case .resolvedFiles: return .resolvedFiles
        case .memoryChunks: return .memoryChunks
        case .plugin: return .plugin
        case .ack: return .ack
        case .fuzzyMatch: return .fuzzyMatch
        case .ripgrepHit: return .ripgrepHit
        case .ripgrepDone: return .ripgrepDone
        }
    }

    // MARK: Codable

    private enum Tag: String, Codable {
        case gitStatus = "git_status"
        case gitDiff = "git_diff"
        case gitBranchInfo = "git_branch_info"
        case gitMetadata = "git_metadata"
        case hunks, skills, plugins
        case projectConfig = "project_config"
        case permissions, envrc
        case resolvedFiles = "resolved_files"
        case memoryChunks = "memory_chunks"
        case plugin, ack
        case fuzzyMatch = "fuzzy_match"
        case ripgrepHit = "ripgrep_hit"
        case ripgrepDone = "ripgrep_done"
    }
    private enum CodingKeys: String, CodingKey { case type, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        switch tag {
        case .gitStatus:
            self = .gitStatus(try c.decode(GitStatus.self, forKey: .data))
        case .gitDiff:
            self = .gitDiff(try c.decode(GitDiff.self, forKey: .data))
        case .gitBranchInfo:
            self = .gitBranchInfo(try c.decode(GitBranchInfo.self, forKey: .data))
        case .gitMetadata:
            // `Option<GitMetadata>` on the wire — `null` decodes to `nil`.
            if c.contains(.data) {
                let value = try c.decodeIfPresent(GitMetadata.self, forKey: .data)
                self = .gitMetadata(value)
            } else {
                self = .gitMetadata(nil)
            }
        case .hunks:
            self = .hunks(try c.decode([Hunk].self, forKey: .data))
        case .skills:
            self = .skills(try c.decode([SkillInfo].self, forKey: .data))
        case .plugins:
            self = .plugins(try c.decode([PluginInfo].self, forKey: .data))
        case .projectConfig:
            self = .projectConfig(try c.decode(ProjectConfig.self, forKey: .data))
        case .permissions:
            self = .permissions(try c.decode(PermissionPolicy.self, forKey: .data))
        case .envrc:
            self = .envrc(try c.decode([String: String].self, forKey: .data))
        case .resolvedFiles:
            self = .resolvedFiles(try c.decode([ResolvedFile].self, forKey: .data))
        case .memoryChunks:
            self = .memoryChunks(try c.decode([MemoryChunk].self, forKey: .data))
        case .plugin:
            self = .plugin(try c.decode(PluginInfo.self, forKey: .data))
        case .ack:
            // Unit variant — `data` may be absent or null.
            if c.contains(.data) { _ = try? c.decode(JSONValue?.self, forKey: .data) }
            self = .ack
        case .fuzzyMatch:
            self = .fuzzyMatch(try c.decode(FuzzyMatch.self, forKey: .data))
        case .ripgrepHit:
            self = .ripgrepHit(try c.decode(ContentMatch.self, forKey: .data))
        case .ripgrepDone:
            self = .ripgrepDone(try c.decode(RipgrepStats.self, forKey: .data))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .gitStatus(let v):
            try c.encode(Tag.gitStatus, forKey: .type)
            try c.encode(v, forKey: .data)
        case .gitDiff(let v):
            try c.encode(Tag.gitDiff, forKey: .type)
            try c.encode(v, forKey: .data)
        case .gitBranchInfo(let v):
            try c.encode(Tag.gitBranchInfo, forKey: .type)
            try c.encode(v, forKey: .data)
        case .gitMetadata(let v):
            try c.encode(Tag.gitMetadata, forKey: .type)
            try c.encodeIfPresent(v, forKey: .data)
        case .hunks(let v):
            try c.encode(Tag.hunks, forKey: .type)
            try c.encode(v, forKey: .data)
        case .skills(let v):
            try c.encode(Tag.skills, forKey: .type)
            try c.encode(v, forKey: .data)
        case .plugins(let v):
            try c.encode(Tag.plugins, forKey: .type)
            try c.encode(v, forKey: .data)
        case .projectConfig(let v):
            try c.encode(Tag.projectConfig, forKey: .type)
            try c.encode(v, forKey: .data)
        case .permissions(let v):
            try c.encode(Tag.permissions, forKey: .type)
            try c.encode(v, forKey: .data)
        case .envrc(let v):
            try c.encode(Tag.envrc, forKey: .type)
            try c.encode(v, forKey: .data)
        case .resolvedFiles(let v):
            try c.encode(Tag.resolvedFiles, forKey: .type)
            try c.encode(v, forKey: .data)
        case .memoryChunks(let v):
            try c.encode(Tag.memoryChunks, forKey: .type)
            try c.encode(v, forKey: .data)
        case .plugin(let v):
            try c.encode(Tag.plugin, forKey: .type)
            try c.encode(v, forKey: .data)
        case .ack:
            try c.encode(Tag.ack, forKey: .type)
            // Unit variant: omit `data`.
        case .fuzzyMatch(let v):
            try c.encode(Tag.fuzzyMatch, forKey: .type)
            try c.encode(v, forKey: .data)
        case .ripgrepHit(let v):
            try c.encode(Tag.ripgrepHit, forKey: .type)
            try c.encode(v, forKey: .data)
        case .ripgrepDone(let v):
            try c.encode(Tag.ripgrepDone, forKey: .type)
            try c.encode(v, forKey: .data)
        }
    }
}

// MARK: - SessionChunk

/// Streaming chunk for a session-lifecycle call.
///
/// Most variants are unary; `sessionInfo` is streamed by
/// `SessionLifecycleRequest.list` (one chunk per session).
public enum SessionChunk: Hashable, Sendable, Codable, Equatable {
    /// Response to `SessionLifecycleRequest.fork` — the new session id.
    case sessionId(SessionId)
    /// One session metadata snapshot, streamed by
    /// `SessionLifecycleRequest.list`.
    case sessionInfo(AgentSessionInfo)
    /// Response to `SessionLifecycleRequest.rewind`.
    case rewindResult(RewindResult)
    /// Response to `SessionLifecycleRequest.getRewindPoints`.
    case rewindPoints([RewindPoint])
    /// Acknowledgement for void session ops (`destroy`, `applyWorktree`,
    /// `beginPrompt`, `endPrompt`).
    case ack

    /// Discriminator for the current variant.
    public var kind: ChunkKind {
        switch self {
        case .sessionId: return .sessionId
        case .sessionInfo: return .sessionInfo
        case .rewindResult: return .rewindResult
        case .rewindPoints: return .rewindPoints
        case .ack: return .sessionAck
        }
    }

    // MARK: Codable

    private enum Tag: String, Codable {
        case sessionId = "session_id"
        case sessionInfo = "session_info"
        case rewindResult = "rewind_result"
        case rewindPoints = "rewind_points"
        case ack
    }
    private enum CodingKeys: String, CodingKey { case type, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        switch tag {
        case .sessionId:
            self = .sessionId(try c.decode(SessionId.self, forKey: .data))
        case .sessionInfo:
            self = .sessionInfo(try c.decode(AgentSessionInfo.self, forKey: .data))
        case .rewindResult:
            self = .rewindResult(try c.decode(RewindResult.self, forKey: .data))
        case .rewindPoints:
            self = .rewindPoints(try c.decode([RewindPoint].self, forKey: .data))
        case .ack:
            if c.contains(.data) { _ = try? c.decode(JSONValue?.self, forKey: .data) }
            self = .ack
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sessionId(let v):
            try c.encode(Tag.sessionId, forKey: .type)
            try c.encode(v, forKey: .data)
        case .sessionInfo(let v):
            try c.encode(Tag.sessionInfo, forKey: .type)
            try c.encode(v, forKey: .data)
        case .rewindResult(let v):
            try c.encode(Tag.rewindResult, forKey: .type)
            try c.encode(v, forKey: .data)
        case .rewindPoints(let v):
            try c.encode(Tag.rewindPoints, forKey: .type)
            try c.encode(v, forKey: .data)
        case .ack:
            try c.encode(Tag.ack, forKey: .type)
        }
    }
}
