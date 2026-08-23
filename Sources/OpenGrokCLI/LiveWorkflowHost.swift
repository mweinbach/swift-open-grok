// LiveWorkflowHost.swift
//
// The embedder's half of the workflow seam (`RhaiWorkflowHost`, RhaiHost.swift).
//
// The engine decides *when* to ask for an agent, how many slots to reserve
// first, and how to journal the answer. This actor decides what an agent
// actually is: a genuine root-owned child session, with independently resolved
// provider credentials, the parent's sandbox/tool policy as its ceiling, and
// a real isolated checkout whenever the workflow requests one.
//
// Budget arithmetic lives here rather than in the engine on purpose. The engine
// distinguishes a quota refusal at *reservation* time (terminal and
// non-catchable — the run ends `budget_exceeded` so it can resume against a
// raised cap) from the same error out of a *spawn* (catchable by the script),
// and that distinction is only meaningful if one component owns the counter.

import Foundation
import OpenGrokSessionRuntime
import OpenGrokShared
import OpenGrokToolRegistry
import OpenGrokWorkflow

actor LiveWorkflowHost: RhaiWorkflowHost {
    private let context: RhaiWorkflowRunContext
    private let environment: LiveWorkflowAgentEnvironment
    private let scratchRoot: URL
    private let templates: LiveWorkflowTemplates
    private let gitDiff: @Sendable (String, URL) async throws -> String
    private let concurrency: Int

    /// Slots handed out but not yet returned, plus slots already spent. Both
    /// count against `agentBudget`; `reserved` is what makes a `parallel()`
    /// fan-out fail *before* any agent runs rather than half way through.
    private var spent: UInt64
    private var reserved: UInt64 = 0
    private var tokensUsed: UInt64 = 0
    private var agentSequence: UInt64 = 0

    /// One tool surface per distinct clamped capability mode. Building one
    /// connects MCP servers and loads hooks, so it is done at most four times
    /// per run rather than once per agent.
    private var invokers: [ToolCapabilityMode: any LiveWorkflowToolInvoker] = [:]
    private var pendingInvokers: [ToolCapabilityMode: Task<any LiveWorkflowToolInvoker, Error>] = [:]

    nonisolated let maxConcurrentAgents: Int

    init(
        context: RhaiWorkflowRunContext,
        environment: LiveWorkflowAgentEnvironment,
        scratchRoot: URL,
        maxConcurrentAgents: Int = 8,
        templates: LiveWorkflowTemplates = .empty,
        gitDiff: @escaping @Sendable (String, URL) async throws -> String = LiveWorkflowGitDiff.run
    ) {
        self.context = context
        self.environment = environment
        self.scratchRoot = scratchRoot
        self.templates = templates
        self.concurrency = max(1, maxConcurrentAgents)
        self.maxConcurrentAgents = max(1, maxConcurrentAgents)
        self.gitDiff = gitDiff
        self.spent = context.priorAgentsUsed
    }

    // MARK: - Budget

    func reserveAgentCalls(_ count: UInt64) throws {
        let requested = spent.saturatingAdd(reserved).saturatingAdd(count)
        guard requested <= context.agentBudget else {
            throw RhaiHostError.agentCallQuotaExceeded(
                requested: requested,
                maximum: context.agentBudget
            )
        }
        reserved = reserved.saturatingAdd(count)
    }

    func releaseAgentCalls(_ count: UInt64) {
        reserved = reserved >= count ? reserved - count : 0
    }

    func budgetState() -> RhaiBudgetState {
        let used = spent.saturatingAdd(reserved)
        return RhaiBudgetState(
            total: context.agentBudget,
            spent: spent,
            reserved: reserved,
            remaining: context.agentBudget >= used ? context.agentBudget - used : 0
        )
    }

    /// Convert one reserved slot into a spent one. Called on every path a spawn
    /// can take, including failure: a child that ran and failed still consumed
    /// a provider call, and charging it is what stops a script from retrying
    /// forever inside its own budget.
    private func commitReservation() {
        reserved = reserved > 0 ? reserved - 1 : 0
        spent = spent.saturatingAdd(1)
    }

    // MARK: - Agents

    func spawnAgent(_ options: RhaiAgentOptions) async throws -> RhaiAgentResult {
        if context.cancellation.isCancelled { throw RhaiHostError.cancelled }
        let agentID = nextAgentID(label: options.label)
        let board = context.progress
        let child = LiveWorkflowChildAgent(
            runID: context.runID,
            environment: childEnvironment,
            cancellation: context.cancellation
        )
        do {
            let result = try await child.run(agentID: agentID, options: options) { event in
                await Self.publish(event, to: board)
            }
            commitReservation()
            tokensUsed = tokensUsed.saturatingAdd(result.tokensUsed)
            await board.agentFinished(
                agentID: agentID,
                state: result.cancelled ? .cancelled : result.success ? .succeeded : .failed,
                tokensUsed: result.tokensUsed
            )
            return result
        } catch let error as RhaiHostError {
            switch error {
            case .cancelled:
                // Nothing is journaled for a cancelled spawn, and the engine
                // gives the slot back, so the reservation is released rather
                // than spent: a resume must be able to re-run this agent.
                await board.agentFinished(agentID: agentID, state: .cancelled, tokensUsed: 0)
            case .budgetExceeded, .agentCallQuotaExceeded:
                await board.agentFinished(agentID: agentID, state: .cancelled, tokensUsed: 0)
            case .failed, .unsupported:
                commitReservation()
                await board.agentFinished(agentID: agentID, state: .failed, tokensUsed: 0)
            }
            throw error
        }
    }

    /// The engine journals each `parallel()` sibling by position, so results
    /// must come back in input order regardless of completion order. The
    /// default implementation on `RhaiWorkflowHost` already does this; it is
    /// restated here only to bind the cap to the host's own configured value
    /// and to check cancellation once before the batch rather than per sibling.
    func spawnAgents(
        _ batch: [RhaiAgentOptions]
    ) async -> [Result<RhaiAgentResult, RhaiHostError>] {
        guard !batch.isEmpty else { return [] }
        if context.cancellation.isCancelled {
            return batch.map { _ in .failure(.cancelled) }
        }
        var results = [Result<RhaiAgentResult, RhaiHostError>?](repeating: nil, count: batch.count)
        await withTaskGroup(of: (Int, Result<RhaiAgentResult, RhaiHostError>).self) { group in
            var next = 0
            var running = 0
            while next < batch.count, running < concurrency {
                let index = next
                group.addTask { [self] in (index, await attempt(batch[index])) }
                next += 1
                running += 1
            }
            while let (index, result) = await group.next() {
                results[index] = result
                if next < batch.count {
                    let index = next
                    group.addTask { [self] in (index, await attempt(batch[index])) }
                    next += 1
                }
            }
        }
        return results.map { $0 ?? .failure(.failed("agent produced no result")) }
    }

    private func attempt(_ options: RhaiAgentOptions) async -> Result<RhaiAgentResult, RhaiHostError> {
        do {
            return .success(try await spawnAgent(options))
        } catch let error as RhaiHostError {
            return .failure(error)
        } catch {
            return .failure(.failed(String(describing: error)))
        }
    }

    private func nextAgentID(label: String?) -> String {
        agentSequence += 1
        let slug = label.map { Self.slug($0) } ?? "agent"
        return "\(slug)-\(agentSequence)"
    }

    private static func slug(_ text: String) -> String {
        let mapped = text.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed.isEmpty ? "agent" : String(collapsed.prefix(24))
    }

    private static func publish(
        _ event: LiveWorkflowAgentEvent,
        to board: RhaiWorkflowProgressBoard
    ) async {
        switch event {
        case .started(let agentID, let label, let phase):
            await board.agentStarted(agentID: agentID, label: label, phase: phase)
        case .toolCall(let agentID, let name):
            await board.log("\(agentID): \(name)")
        case .status, .finished:
            // `finished` is published by the spawn path, which knows the
            // outcome; the child only knows that it stopped.
            break
        }
    }

    // MARK: - Notifications

    func phase(title: String, replayed: Bool) async {
        await context.progress.enterPhase(title, replayed: replayed)
    }

    func log(message: String, replayed: Bool) async {
        guard !replayed else { return }
        await context.progress.log(message)
    }

    func telemetry(name: String, fields: JSONValue, replayed: Bool) async {
        guard !replayed else { return }
        await context.progress.log("telemetry: \(name)")
    }

    // MARK: - Scratch files

    func writeScratchFile(name: String, content: String) throws -> String {
        try LiveWorkflowScratchSecurity.write(name: name, content: content, root: scratchRoot)
    }

    func readScratchFile(name: String) throws -> String {
        try LiveWorkflowScratchSecurity.read(name: name, root: scratchRoot)
    }

    // MARK: - Other host calls

    func renderTemplate(name: String, variables: JSONValue) throws -> String {
        try templates.render(name: name, variables: variables)
    }

    func gitDiffSince(commit: String) async throws -> String {
        try await gitDiff(commit, environment.workspaceRoot)
    }

    // MARK: - Tool surfaces

    /// Hand out (and cache) the tool surface for one clamped capability mode.
    func invoker(for mode: ToolCapabilityMode) async throws -> any LiveWorkflowToolInvoker {
        if let cached = invokers[mode] { return cached }
        if let pending = pendingInvokers[mode] {
            return try await pending.value
        }

        let factory = environment.makeInvoker
        let pending = Task<any LiveWorkflowToolInvoker, Error> {
            try await factory(mode)
        }
        pendingInvokers[mode] = pending
        defer { pendingInvokers[mode] = nil }
        let built = try await pending.value
        invokers[mode] = built
        return built
    }

    /// The environment children actually get: the configured one with its
    /// `makeInvoker` routed through this actor's cache.
    ///
    /// Without this every agent would build its own tool surface, and building
    /// one starts the session's MCP servers — a ten-agent fan-out would spawn
    /// ten copies of every configured server.
    private var childEnvironment: LiveWorkflowAgentEnvironment {
        LiveWorkflowAgentEnvironment(
            sampler: environment.sampler,
            model: environment.model,
            workspaceRoot: environment.workspaceRoot,
            systemPrompt: environment.systemPrompt,
            parentCapabilityMode: environment.parentCapabilityMode,
            supportsReasoningEffort: environment.supportsReasoningEffort,
            subagentBridge: environment.subagentBridge,
            requiresSubagentBridge: environment.requiresSubagentBridge,
            maxToolRounds: environment.maxToolRounds,
            makeInvoker: { [self] mode in try await invoker(for: mode) }
        )
    }
}

extension UInt64 {
    fileprivate func saturatingAdd(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? UInt64.max : sum
    }
}
