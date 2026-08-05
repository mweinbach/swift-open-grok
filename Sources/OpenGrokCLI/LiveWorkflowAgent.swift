// LiveWorkflowAgent.swift
//
// The child-agent side of the workflow seam: what actually happens when a
// workflow script calls `agent(prompt, opts)`.
//
// A child agent is a real headless session against the configured provider —
// the same sampler, the same tool executor, the same turn loop shape as the
// interactive session in `LiveShellSamplingDriver` — with three things removed
// and two added.
//
// Removed: no conversation persistence (a child's transcript is not a resumable
// user session; the durable record of what it did is the workflow journal), no
// Code Mode (it is a session-wide decision the parent already made, and a
// child inheriting a half-built cell runtime would be able to `wait` on cells
// it never created), and no pager surface.
//
// Added: schema-forced output when the script asked for one, and a capability
// clamp that makes it structurally impossible for a child to hold a tool the
// parent session does not.

import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokToolRegistry
import OpenGrokWorkflow

/// The tool surface a child agent may reach.
///
/// `LiveToolExecutor` is the only production conformer. The protocol exists so
/// the turn loop can be exercised without standing up hooks, MCP connections,
/// and a process backend — not to admit a second real implementation.
protocol LiveWorkflowToolInvoker: Sendable {
    var tools: [ToolSpec] { get }
    var workingDirectory: URL { get }
    func invoke(
        sessionID: String,
        workingDirectory: URL,
        call: ToolCall
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError>
}

extension LiveToolExecutor: LiveWorkflowToolInvoker {}

// MARK: - Capability clamp

enum LiveWorkflowCapability {
    /// The mode a child actually gets, given what the script asked for and what
    /// the parent session holds.
    ///
    /// The parent is a ceiling, never a floor. A script asking for `all` inside
    /// a `read_only` session gets `read_only`; a script asking for `read_only`
    /// inside a `read_write` session gets `read_only`, because narrowing is the
    /// script's to do. An unparseable or non-subset request falls back to the
    /// parent rather than erroring: the script is data, and a workflow should
    /// not be able to fail a run by naming a capability it cannot have.
    static func clamp(requested: String?, parent: ToolCapabilityMode) -> ToolCapabilityMode {
        guard let requested,
              let mode = parse(requested),
              mode.isSubset(of: parent)
        else { return parent }
        return mode
    }

    static func parse(_ raw: String) -> ToolCapabilityMode? {
        switch raw {
        case "read_only", "read-only", "readonly": return .readOnly
        case "read_write", "read-write", "readwrite": return .readWrite
        case "execute": return .execute
        case "all": return .all
        default: return nil
        }
    }
}

// MARK: - Environment

/// Everything a child agent needs that is fixed for the whole workflow run.
struct LiveWorkflowAgentEnvironment: Sendable {
    let sampler: OpenGrokLiveSampler
    let model: String
    /// The parent session's workspace root. Child tool executors are built with
    /// this as their only allowed root, so a child cannot read or write outside
    /// the workspace even if its prompt tells it to.
    let workspaceRoot: URL
    /// The parent session's system prompt, if it has one (an agent profile).
    let systemPrompt: String?
    /// The ceiling for every child's capability mode.
    let parentCapabilityMode: ToolCapabilityMode
    /// Builds the tool surface for one clamped capability mode. Called at most
    /// once per distinct mode per run; the host caches the results.
    let makeInvoker: @Sendable (ToolCapabilityMode) async throws -> any LiveWorkflowToolInvoker
    /// Matches the interactive session's own ceiling (`LiveComposition.swift`
    /// `runTurn`): a child that has not converged in this many tool rounds is
    /// looping, and the workflow gets a soft failure it can branch on.
    let maxToolRounds: Int

    init(
        sampler: OpenGrokLiveSampler,
        model: String,
        workspaceRoot: URL,
        systemPrompt: String? = nil,
        parentCapabilityMode: ToolCapabilityMode = .readWrite,
        maxToolRounds: Int = 16,
        makeInvoker: @escaping @Sendable (ToolCapabilityMode) async throws -> any LiveWorkflowToolInvoker
    ) {
        self.sampler = sampler
        self.model = model
        self.workspaceRoot = workspaceRoot
        self.systemPrompt = systemPrompt
        self.parentCapabilityMode = parentCapabilityMode
        self.maxToolRounds = maxToolRounds
        self.makeInvoker = makeInvoker
    }
}

/// What a running child reports as it goes, so the dashboard can show it.
enum LiveWorkflowAgentEvent: Sendable {
    case started(agentID: String, label: String?, phase: String?)
    case status(agentID: String, String)
    case toolCall(agentID: String, name: String)
    case finished(agentID: String, tokensUsed: UInt64)
}

// MARK: - The runner

struct LiveWorkflowChildAgent: Sendable {
    let runID: String
    let environment: LiveWorkflowAgentEnvironment
    let cancellation: RhaiCancellationToken

    /// Run one child agent to completion.
    ///
    /// Throws `RhaiHostError` and nothing else, because the engine's handling
    /// of the five cases is the whole contract: `.cancelled` and
    /// `.budgetExceeded` end the run resumably and journal nothing, while
    /// `.failed` is soft — the script catches it, or a `parallel()` sibling
    /// becomes `()` — and *is* journaled, so a resume takes the same branch.
    func run(
        agentID: String,
        options: RhaiAgentOptions,
        emit: @Sendable @escaping (LiveWorkflowAgentEvent) async -> Void
    ) async throws -> RhaiAgentResult {
        let startedAt = Date()
        await emit(.started(agentID: agentID, label: options.label, phase: options.phase))

        do {
            let output = try await turnLoop(agentID: agentID, options: options, emit: emit)
            let tokens = output.tokensUsed
            await emit(.finished(agentID: agentID, tokensUsed: tokens))
            return RhaiAgentResult(
                agentID: agentID,
                success: true,
                output: output.value,
                cancelled: false,
                tokensUsed: tokens,
                durationMS: UInt64(max(0, Date().timeIntervalSince(startedAt)) * 1000)
            )
        } catch let error as RhaiHostError {
            await emit(.finished(agentID: agentID, tokensUsed: 0))
            throw error
        } catch is CancellationError {
            await emit(.finished(agentID: agentID, tokensUsed: 0))
            throw RhaiHostError.cancelled
        } catch {
            await emit(.finished(agentID: agentID, tokensUsed: 0))
            throw RhaiHostError.failed("agent \(options.label ?? agentID) failed: \(error)")
        }
    }

    private struct Output {
        let value: JSONValue
        let tokensUsed: UInt64
    }

    private func turnLoop(
        agentID: String,
        options: RhaiAgentOptions,
        emit: @Sendable @escaping (LiveWorkflowAgentEvent) async -> Void
    ) async throws -> Output {
        let mode = LiveWorkflowCapability.clamp(
            requested: options.capabilityMode,
            parent: environment.parentCapabilityMode
        )
        let invoker: any LiveWorkflowToolInvoker
        do {
            invoker = try await environment.makeInvoker(mode)
        } catch {
            throw RhaiHostError.failed("child agent tool surface unavailable: \(error)")
        }

        let sessionID = "\(runID)-\(agentID)"
        var items: [ConversationItem] = []
        if let system = systemPrompt(for: options) {
            items.append(.system(system))
        }
        items.append(.user(options.prompt))

        var round = 0
        var characters = options.prompt.count
        while true {
            try checkCancelled()
            await emit(.status(agentID: agentID, "sampling"))
            let response = try await environment.sampler.sample(OpenGrokLiveSamplingRequest(
                sessionID: sessionID,
                turnID: "\(agentID)-\(round)",
                model: options.model ?? environment.model,
                prompt: options.prompt,
                items: items,
                tools: invoker.tools,
                jsonSchema: options.outputSchema
            )) { _ in
                // A child agent's tokens do not stream anywhere: the workflow,
                // not a pane, is the consumer, and it reads the finished value.
            }
            characters += response.output.count
            items.append(contentsOf: response.items)

            guard !response.toolCalls.isEmpty else {
                return Output(
                    value: decodeOutput(response.output, schema: options.outputSchema),
                    tokensUsed: estimateTokens(characters: characters)
                )
            }
            guard round < environment.maxToolRounds else {
                throw RhaiHostError.failed(
                    "agent \(options.label ?? agentID) exceeded \(environment.maxToolRounds) tool rounds"
                )
            }
            round += 1
            items.append(contentsOf: try await execute(
                response.toolCalls,
                agentID: agentID,
                sessionID: sessionID,
                invoker: invoker,
                emit: emit
            ))
        }
    }

    /// A child's system prompt is the parent's, plus the run framing the script
    /// controls. `label` and `phase` are the script's way of telling an agent
    /// what job it holds inside a fan-out, so they belong in the prompt rather
    /// than only in the dashboard.
    private func systemPrompt(for options: RhaiAgentOptions) -> String? {
        var parts: [String] = []
        if let base = environment.systemPrompt { parts.append(base) }
        var framing = "You are a workflow subagent."
        if let label = options.label { framing += " Your assigned role is \"\(label)\"." }
        if let phase = options.phase { framing += " You are working in phase \"\(phase)\"." }
        framing += " Complete only the task you are given and report the result."
        if options.outputSchema != nil {
            framing += " Respond with a single JSON object matching the required schema and nothing else."
        }
        parts.append(framing)
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private func execute(
        _ calls: [ToolCall],
        agentID: String,
        sessionID: String,
        invoker: any LiveWorkflowToolInvoker,
        emit: @Sendable @escaping (LiveWorkflowAgentEvent) async -> Void
    ) async throws -> [ConversationItem] {
        var results = [ConversationItem?](repeating: nil, count: calls.count)
        try await withThrowingTaskGroup(of: (Int, ToolResultItem).self) { group in
            for (index, call) in calls.enumerated() {
                await emit(.toolCall(agentID: agentID, name: call.name))
                group.addTask {
                    let outcome = await invoker.invoke(
                        sessionID: sessionID,
                        workingDirectory: invoker.workingDirectory,
                        call: call
                    )
                    let content: String
                    switch outcome {
                    case .success(let value):
                        content = value.promptText
                    case .failure(.cancelled):
                        throw CancellationError()
                    case .failure(let error):
                        // A failed tool is the model's problem to route around,
                        // not the run's: the child sees the failure text and
                        // gets another round.
                        content = "Tool \(call.name) failed: \(error.description)"
                    }
                    return (index, ToolResultItem(toolCallId: call.callId, content: content))
                }
            }
            for try await (index, result) in group {
                results[index] = .toolResult(result)
            }
        }
        try checkCancelled()
        return results.compactMap { $0 }
    }

    /// The script indexes into `r.output`, so a schema-forced answer is decoded
    /// into a real object. Without a schema the output stays a string, which is
    /// what the built-ins expect from a prose agent.
    private func decodeOutput(_ text: String, schema: JSONValue?) -> JSONValue {
        guard schema != nil else { return .string(text) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Models fenced into JSON still sometimes wrap it; strip one fence
        // rather than handing the script a string it will index into and get
        // `()` from.
        let unfenced = Self.stripCodeFence(trimmed)
        guard let data = unfenced.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return .string(text)
        }
        return value
    }

    static func stripCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```") else { return text }
        var body = text.dropFirst(3)
        if let newline = body.firstIndex(of: "\n") {
            let tag = body[body.startIndex..<newline]
            if !tag.contains(where: { $0 == "{" || $0 == "[" }) {
                body = body[body.index(after: newline)...]
            }
        }
        return String(body.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Neither the sampler nor `ConversationResponse` surfaces provider usage
    /// through this seam, so the figure the dashboard and `budget()` show is an
    /// estimate over the characters that crossed the boundary. It is used for
    /// display and for the script's own pacing decisions; the *enforced* budget
    /// is the agent-call count, which is exact.
    private func estimateTokens(characters: Int) -> UInt64 {
        UInt64(max(0, characters) / 4)
    }

    private func checkCancelled() throws {
        if cancellation.isCancelled { throw RhaiHostError.cancelled }
        if Task.isCancelled { throw RhaiHostError.cancelled }
    }
}
