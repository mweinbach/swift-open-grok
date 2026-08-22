// LiveWorkflowHost.swift
//
// The embedder's half of the workflow seam (`RhaiWorkflowHost`, RhaiHost.swift).
//
// The engine decides *when* to ask for an agent, how many slots to reserve
// first, and how to journal the answer. This actor decides what an agent
// actually is: a headless child session against the parent's provider, with the
// parent's tool policy as a ceiling and the parent's workspace as its only root.
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
    private let gitDiff: @Sendable (String, URL) async -> String
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

    nonisolated let maxConcurrentAgents: Int

    init(
        context: RhaiWorkflowRunContext,
        environment: LiveWorkflowAgentEnvironment,
        scratchRoot: URL,
        maxConcurrentAgents: Int = 8,
        gitDiff: @escaping @Sendable (String, URL) async -> String = LiveWorkflowHost.runGitDiff
    ) {
        self.context = context
        self.environment = environment
        self.scratchRoot = scratchRoot
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
                state: .succeeded,
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

    /// Scratch files are the workflow's own storage, not the workspace's: a
    /// script writing a report must not be able to drop it into the user's
    /// repository. They live under the run's own directory, and the name is
    /// reduced to a single path component so `../` cannot escape it.
    func writeScratchFile(name: String, content: String) throws -> String {
        let url = try scratchURL(for: name)
        do {
            try FileManager.default.createDirectory(
                at: scratchRoot,
                withIntermediateDirectories: true
            )
            try Data(content.utf8).write(to: url, options: .atomic)
        } catch {
            throw RhaiHostError.failed("cannot write scratch file \(name): \(error)")
        }
        return url.path
    }

    func readScratchFile(name: String) throws -> String {
        let url = try scratchURL(for: name)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw RhaiHostError.failed("cannot read scratch file \(name): \(error)")
        }
    }

    private func scratchURL(for name: String) throws -> URL {
        let component = (name as NSString).lastPathComponent
        guard !component.isEmpty, component != ".", component != ".." else {
            throw RhaiHostError.failed("invalid scratch file name: \(name)")
        }
        return scratchRoot.appendingPathComponent(component)
    }

    // MARK: - Other host calls

    func renderTemplate(name: String, variables: JSONValue) throws -> String {
        // Upstream resolves named prompt templates from the shell's registry,
        // which this composition does not have. Reporting it as unsupported
        // rather than returning a stub is deliberate: `unsupported` is
        // catchable, so a script can fall back, whereas a stub would silently
        // send an agent a meaningless prompt.
        throw RhaiHostError.unsupported("render_template is not available in this session: \(name)")
    }

    func gitDiffSince(commit: String) async -> String {
        await gitDiff(commit, environment.workspaceRoot)
    }

    static let runGitDiff: @Sendable (String, URL) async -> String = { commit, root in
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "diff", "\(commit)...HEAD"]
            process.currentDirectoryURL = root
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            let box = LiveWorkflowContinuationBox(continuation)
            // Never `waitUntilExit` — it blocks a cooperative thread and has
            // deadlocked this codebase before (PORT_STATUS, wave 4).
            process.terminationHandler = { _ in
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                box.resume(String(data: data, encoding: .utf8) ?? "")
            }
            do {
                try process.run()
            } catch {
                box.resume("")
            }
        }
    }

    // MARK: - Tool surfaces

    /// Hand out (and cache) the tool surface for one clamped capability mode.
    func invoker(for mode: ToolCapabilityMode) async throws -> any LiveWorkflowToolInvoker {
        if let cached = invokers[mode] { return cached }
        let built = try await environment.makeInvoker(mode)
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
            maxToolRounds: environment.maxToolRounds,
            makeInvoker: { [self] mode in try await invoker(for: mode) }
        )
    }
}

/// `terminationHandler` can fire once, but the compiler cannot see that, so the
/// continuation needs a resume-once guard to stay `Sendable`.
private final class LiveWorkflowContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?

    init(_ continuation: CheckedContinuation<String, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: String) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

extension UInt64 {
    fileprivate func saturatingAdd(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? UInt64.max : sum
    }
}
