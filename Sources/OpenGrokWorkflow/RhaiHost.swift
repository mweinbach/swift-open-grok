// RhaiHost.swift
//
// Port of crates/codegen/xai-workflow/src/host.rs — the boundary between a
// workflow script and the thing that actually runs agents.
//
// Upstream models this as an mpsc channel of `WorkflowHostRequest` values, each
// carrying a oneshot reply sender; the script thread blocks on the reply. Swift
// expresses the same shape as an async protocol: one method per request, each
// suspending until the host answers. The engine never spawns agents itself —
// `spawnAgent` is the seam an embedder fills in.

import Foundation
import OpenGrokShared

/// host.rs:5 — options for one agent spawn.
///
/// Every field is serialized even when nil: the JSON form is hashed into the
/// journal's `req_hash`, and Rust's serde emits `null` for `None`. Omitting nil
/// keys the way Swift's synthesized encoder would produces a different hash and
/// would make every Rust-written journal look like divergence.
public struct RhaiAgentOptions: Sendable, Hashable {
    public var prompt: String
    public var label: String?
    public var model: String?
    public var reasoningEffort: String?
    public var maxOutputTokens: UInt64?
    public var agentType: String?
    public var capabilityMode: String?
    public var isolationWorktree: Bool
    public var forkContext: Bool
    public var resumeFrom: String?
    public var outputSchema: JSONValue?
    public var phase: String?

    public init(
        prompt: String = "",
        label: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        maxOutputTokens: UInt64? = nil,
        agentType: String? = nil,
        capabilityMode: String? = nil,
        isolationWorktree: Bool = false,
        forkContext: Bool = false,
        resumeFrom: String? = nil,
        outputSchema: JSONValue? = nil,
        phase: String? = nil
    ) {
        self.prompt = prompt
        self.label = label
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.maxOutputTokens = maxOutputTokens
        self.agentType = agentType
        self.capabilityMode = capabilityMode
        self.isolationWorktree = isolationWorktree
        self.forkContext = forkContext
        self.resumeFrom = resumeFrom
        self.outputSchema = outputSchema
        self.phase = phase
    }

    /// The exact JSON serde produces for `AgentOpts`, nulls included.
    public var json: JSONValue {
        .object([
            "prompt": .string(prompt),
            "label": label.map(JSONValue.string) ?? .null,
            "model": model.map(JSONValue.string) ?? .null,
            "reasoning_effort": reasoningEffort.map(JSONValue.string) ?? .null,
            "max_output_tokens": maxOutputTokens.map { .number(.uint64($0)) } ?? .null,
            "agent_type": agentType.map(JSONValue.string) ?? .null,
            "capability_mode": capabilityMode.map(JSONValue.string) ?? .null,
            "isolation_worktree": .bool(isolationWorktree),
            "fork_context": .bool(forkContext),
            "resume_from": resumeFrom.map(JSONValue.string) ?? .null,
            "output_schema": outputSchema ?? .null,
            "phase": phase.map(JSONValue.string) ?? .null,
        ])
    }

    /// engine.rs:446 `agent_opts_from_map` — serde `#[serde(default)]` on every
    /// field, and no `deny_unknown_fields`, so absent keys take defaults and
    /// unrecognized keys are ignored rather than rejected.
    public static func fromJSON(_ value: JSONValue) throws -> RhaiAgentOptions {
        guard let map = value.objectValue else {
            throw RhaiHostError.failed("invalid agent options: expected a map")
        }
        func string(_ key: String) throws -> String? {
            switch map[key] {
            case .none, .some(.null): return nil
            case .some(.string(let text)): return text
            default: throw RhaiHostError.failed("invalid agent options: \(key) must be a string")
            }
        }
        func flag(_ key: String) throws -> Bool {
            switch map[key] {
            case .none, .some(.null): return false
            case .some(.bool(let value)): return value
            default: throw RhaiHostError.failed("invalid agent options: \(key) must be a boolean")
            }
        }
        var options = RhaiAgentOptions()
        options.prompt = try string("prompt") ?? ""
        options.label = try string("label")
        options.model = try string("model")
        options.reasoningEffort = try string("reasoning_effort")
        if case .some(.number(let number)) = map["max_output_tokens"] {
            options.maxOutputTokens = number.uint64Value
        }
        options.agentType = try string("agent_type")
        options.capabilityMode = try string("capability_mode")
        options.isolationWorktree = try flag("isolation_worktree")
        options.forkContext = try flag("fork_context")
        options.resumeFrom = try string("resume_from")
        if let schema = map["output_schema"], !schema.isNull { options.outputSchema = schema }
        options.phase = try string("phase")
        return options
    }
}

/// host.rs:33 — what one finished agent reports back.
public struct RhaiAgentResult: Sendable, Hashable {
    public var agentID: String
    public var success: Bool
    public var output: JSONValue
    public var cancelled: Bool
    public var tokensUsed: UInt64
    public var durationMS: UInt64

    public init(
        agentID: String,
        success: Bool,
        output: JSONValue,
        cancelled: Bool = false,
        tokensUsed: UInt64 = 0,
        durationMS: UInt64 = 0
    ) {
        self.agentID = agentID
        self.success = success
        self.output = output
        self.cancelled = cancelled
        self.tokensUsed = tokensUsed
        self.durationMS = durationMS
    }

    /// The journaled form — this is what `agent()` hands back to the script, so
    /// the key spelling is part of the script-facing contract (`r.output`,
    /// `r.success`, `r.tokens_used`).
    public var json: JSONValue {
        .object([
            "agent_id": .string(agentID),
            "success": .bool(success),
            "output": output,
            "cancelled": .bool(cancelled),
            "tokens_used": .number(.uint64(tokensUsed)),
            "duration_ms": .number(.uint64(durationMS)),
        ])
    }
}

/// host.rs:43 — the run's agent budget as the script sees it via `budget()`.
public struct RhaiBudgetState: Sendable, Hashable {
    public var total: UInt64?
    public var spent: UInt64
    public var reserved: UInt64
    public var remaining: UInt64?

    public init(total: UInt64? = nil, spent: UInt64 = 0, reserved: UInt64 = 0, remaining: UInt64? = nil) {
        self.total = total
        self.spent = spent
        self.reserved = reserved
        self.remaining = remaining
    }

    public var json: JSONValue {
        .object([
            "total": total.map { .number(.uint64($0)) } ?? .null,
            "spent": .number(.uint64(spent)),
            "reserved": .number(.uint64(reserved)),
            "remaining": remaining.map { .number(.uint64($0)) } ?? .null,
        ])
    }
}

/// host.rs:51 — the five failure modes a host call can report, which the engine
/// treats very differently: quota and budget end the run resumably, cancellation
/// ends it, and `unsupported`/`failed` are *catchable* by the script.
public enum RhaiHostError: Error, Sendable, Hashable, CustomStringConvertible {
    case agentCallQuotaExceeded(requested: UInt64, maximum: UInt64)
    case budgetExceeded
    case cancelled
    case unsupported(String)
    case failed(String)

    public var description: String {
        switch self {
        case .agentCallQuotaExceeded(let requested, let maximum):
            return "workflow agent-call quota exceeded: requested \(requested), maximum \(maximum)"
        case .budgetExceeded:
            return "workflow token budget exceeded"
        case .cancelled:
            return "workflow cancelled"
        case .unsupported(let message):
            return "unsupported in this context: \(message)"
        case .failed(let message):
            return "host failure: \(message)"
        }
    }

    /// The message the script sees when it catches this error. Upstream raises
    /// the bare host message, not the `Display` form (engine.rs:292).
    var scriptMessage: String {
        switch self {
        case .unsupported(let message), .failed(let message): return message
        default: return description
        }
    }
}

// MARK: - The seam

/// The host side of the workflow boundary — the agent-execution seam.
///
/// This port deliberately does **not** implement agent spawning. An embedder
/// (the session runtime) conforms to this and connects `spawnAgent` to real
/// subagent execution; the engine only decides *when* to call it, how many
/// slots to reserve first, and how to journal the answer.
///
/// The fire-and-forget notifications (`phase`, `log`, `telemetry`) carry a
/// `replayed` flag so a resumed run can redraw its history without re-emitting
/// it as if it were new (engine.rs:342 `host_emit`).
public protocol RhaiWorkflowHost: Sendable {
    /// Claim `count` agent slots up front. Throwing
    /// `.agentCallQuotaExceeded` here stops the fan-out *before* any agent runs.
    func reserveAgentCalls(_ count: UInt64) async throws
    /// Give slots back when a reserved spawn ended in a terminal-but-resumable
    /// state, so the resumed run is not charged twice.
    func releaseAgentCalls(_ count: UInt64) async
    func spawnAgent(_ options: RhaiAgentOptions) async throws -> RhaiAgentResult
    func phase(title: String, replayed: Bool) async
    func log(message: String, replayed: Bool) async
    func telemetry(name: String, fields: JSONValue, replayed: Bool) async
    func budgetState() async throws -> RhaiBudgetState
    func renderTemplate(name: String, variables: JSONValue) async throws -> String
    func writeScratchFile(name: String, content: String) async throws -> String
    func readScratchFile(name: String) async throws -> String
    func gitDiffSince(commit: String) async throws -> String

    /// How many agents may run at once inside one `parallel()` barrier.
    ///
    /// Upstream has no cap in this crate — it hands every request to the host
    /// at once and the shell's host service decides. Exposing it here keeps the
    /// decision with the host while giving the engine a bound to honor.
    var maxConcurrentAgents: Int { get }

    /// Run a whole `parallel()` batch. The default implementation fans out with
    /// `maxConcurrentAgents` in flight and returns results **in input order**,
    /// which the engine relies on to journal each sibling under its own
    /// sequence number.
    func spawnAgents(_ batch: [RhaiAgentOptions]) async -> [Result<RhaiAgentResult, RhaiHostError>]
}

extension RhaiWorkflowHost {
    public var maxConcurrentAgents: Int { 8 }

    public func spawnAgents(
        _ batch: [RhaiAgentOptions]
    ) async -> [Result<RhaiAgentResult, RhaiHostError>] {
        guard !batch.isEmpty else { return [] }
        let limit = max(1, maxConcurrentAgents)
        var results = [Result<RhaiAgentResult, RhaiHostError>?](repeating: nil, count: batch.count)
        await withTaskGroup(of: (Int, Result<RhaiAgentResult, RhaiHostError>).self) { group in
            var next = 0
            var running = 0
            while next < batch.count, running < limit {
                let index = next
                let options = batch[index]
                group.addTask { (index, await Self.attempt(self, options)) }
                next += 1
                running += 1
            }
            while let (index, result) = await group.next() {
                results[index] = result
                if next < batch.count {
                    let index = next
                    let options = batch[index]
                    group.addTask { (index, await Self.attempt(self, options)) }
                    next += 1
                }
            }
        }
        return results.map { $0 ?? .failure(.failed("agent produced no result")) }
    }

    private static func attempt(
        _ host: Self,
        _ options: RhaiAgentOptions
    ) async -> Result<RhaiAgentResult, RhaiHostError> {
        do {
            return .success(try await host.spawnAgent(options))
        } catch let error as RhaiHostError {
            return .failure(error)
        } catch {
            return .failure(.failed(String(describing: error)))
        }
    }
}

// MARK: - Probe host

/// validate.rs:50 — the stub host a dry run validates against. Every call
/// succeeds with a shape-complete stub so a script's branches are exercised
/// without any agent actually running.
public actor RhaiProbeHost: RhaiWorkflowHost {
    private let agentBudget: UInt64
    private var agentCalls: UInt64 = 0
    public private(set) var spawnCount = 0

    public init(agentBudget: UInt64 = rhaiDefaultAgentBudget) {
        self.agentBudget = agentBudget
    }

    public nonisolated var maxConcurrentAgents: Int { 8 }

    public func reserveAgentCalls(_ count: UInt64) throws {
        let requested = agentCalls.rhaiSaturatingAdd(count)
        guard requested <= agentBudget else {
            throw RhaiHostError.agentCallQuotaExceeded(requested: requested, maximum: agentBudget)
        }
        agentCalls = requested
    }

    public func releaseAgentCalls(_ count: UInt64) {
        agentCalls = agentCalls >= count ? agentCalls - count : 0
    }

    public func spawnAgent(_ options: RhaiAgentOptions) throws -> RhaiAgentResult {
        spawnCount += 1
        return RhaiAgentResult(
            agentID: "stub",
            success: true,
            output: .object([
                "achieved": .bool(true),
                "gaps": .string(""),
                "evidence": .string("stub evidence"),
                "questions": .array([.string("q1"), .string("q2")]),
                "claims": .array([]),
                "uncertainties": .array([]),
                "verdicts": .array([]),
                "failures": .array([.string("test_a")]),
                "issues": .string("none"),
                "stub": .bool(true),
            ]),
            cancelled: false,
            tokensUsed: 1,
            durationMS: 1
        )
    }

    public func phase(title: String, replayed: Bool) {}
    public func log(message: String, replayed: Bool) {}
    public func telemetry(name: String, fields: JSONValue, replayed: Bool) {}

    public func budgetState() -> RhaiBudgetState {
        RhaiBudgetState(total: nil, spent: 0, reserved: 0, remaining: nil)
    }

    public func renderTemplate(name: String, variables: JSONValue) -> String { "stub template" }
    public func writeScratchFile(name: String, content: String) -> String { "scratch/\(name)" }
    public func readScratchFile(name: String) -> String { "stub content" }
    public func gitDiffSince(commit: String) -> String { "" }
}

extension UInt64 {
    func rhaiSaturatingAdd(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? UInt64.max : sum
    }
}
