// RhaiWorkflowRunRegistry.swift
//
// The background run registry for the Rhai workflow engine.
//
// Upstream never runs a workflow in the foreground: `workflow_run` returns a
// run id immediately and the run proceeds on its own task, with `/workflows`
// and the workflow tool reading its state back out of the persisted manifest
// and journal. This actor is that behaviour — it owns the detached task, the
// cancellation token, and the two durable artifacts:
//
//   <OPENGROK_HOME>/workflow-runs.json                the manifest
//   <OPENGROK_HOME>/workflow-journals/<run-id>.jsonl  the per-run journal
//
// Both already existed (`WorkflowSessionStore`, wave 3); nothing about their
// format is invented here. Resume is the engine's own cached-prefix semantics:
// a run resumes by being started again over the journal it left behind, so
// `resume` reloads that file and hands it to a fresh engine run rather than
// keeping any in-memory continuation.

import Foundation
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokWorkflow

/// Everything a host needs to know about the run it is being built for.
///
/// The host is constructed per run rather than shared, because agent budget,
/// scratch-file root, and cancellation are all run-scoped.
public struct RhaiWorkflowRunContext: Sendable {
    public let runID: String
    public let workflowName: String
    public let arguments: JSONValue
    public let agentBudget: UInt64
    /// Where the journal for this run lives, or `nil` for an in-memory store.
    public let journalURL: URL?
    /// Flipped by `cancel(runID:)`. The engine polls it between operations and
    /// the host is expected to propagate it into any child agent in flight.
    public let cancellation: RhaiCancellationToken
    /// Where the host publishes what the run is doing right now. Everything on
    /// it is process-local; see `RhaiWorkflowProgress`.
    public let progress: RhaiWorkflowProgressBoard

    public init(
        runID: String,
        workflowName: String,
        arguments: JSONValue,
        agentBudget: UInt64,
        journalURL: URL?,
        cancellation: RhaiCancellationToken,
        progress: RhaiWorkflowProgressBoard = RhaiWorkflowProgressBoard()
    ) {
        self.runID = runID
        self.workflowName = workflowName
        self.arguments = arguments
        self.agentBudget = agentBudget
        self.journalURL = journalURL
        self.cancellation = cancellation
        self.progress = progress
    }
}

/// How the registry obtains a host for a run.
///
/// The registry deliberately knows nothing about agents: it lives below the CLI
/// in the dependency graph, and the thing that can actually run a child agent
/// (`LiveWorkflowHost`) lives above it. This closure is the join.
public struct RhaiWorkflowHostFactory: Sendable {
    private let make: @Sendable (RhaiWorkflowRunContext) async throws -> any RhaiWorkflowHost
    private let finish: @Sendable (RhaiWorkflowRunContext) async -> Void

    public init(
        make: @escaping @Sendable (RhaiWorkflowRunContext) async throws -> any RhaiWorkflowHost,
        finish: @escaping @Sendable (RhaiWorkflowRunContext) async -> Void = { _ in }
    ) {
        self.make = make
        self.finish = finish
    }

    public func makeHost(for context: RhaiWorkflowRunContext) async throws -> any RhaiWorkflowHost {
        try await make(context)
    }

    /// Called once the run reaches a terminal outcome, so a host holding
    /// process-backed resources (tool runtimes, MCP connections) can release
    /// them. Always called, including on cancellation and failure.
    public func finishHost(for context: RhaiWorkflowRunContext) async {
        await finish(context)
    }
}

public enum RhaiWorkflowRegistryError: Error, Sendable, Hashable, CustomStringConvertible {
    case missingRun(String)
    case notResumable(String)
    case scriptMismatch(String)
    case persistence(String)
    case journal(String)

    public var description: String {
        switch self {
        case .missingRun(let id): return "workflow run does not exist: \(id)"
        case .notResumable(let status): return "workflow run is not resumable (status \(status))"
        case .scriptMismatch(let id): return "workflow run \(id) was started from a different script"
        case .persistence(let message): return "workflow persistence failed: \(message)"
        case .journal(let message): return "workflow journal failed: \(message)"
        }
    }
}

/// One run's live state, as the `/workflows` overlay and `workflow show` read it.
public struct RhaiWorkflowRunView: Sendable, Hashable {
    public let record: WorkflowRunRecord
    /// Journal entries in sequence order — the durable record of what the run
    /// did. Survives a restart and is what a resume replays.
    public let entries: [RhaiJournalEntry]
    /// What the run is doing right now, from the in-process board. Empty for a
    /// run this process did not start.
    public let progress: RhaiWorkflowProgress

    public init(
        record: WorkflowRunRecord,
        entries: [RhaiJournalEntry],
        progress: RhaiWorkflowProgress = RhaiWorkflowProgress()
    ) {
        self.record = record
        self.entries = entries
        self.progress = progress
    }

    /// Phase titles. Live phases come from the board; a run from an earlier
    /// process has none, because `phase()` is never journaled.
    public var phases: [String] { progress.phases }

    public var currentPhase: String? { progress.currentPhase }

    /// The agent roster: every completed agent from the journal, plus any that
    /// is still in flight from the board.
    ///
    /// The journal is preferred for finished agents because it is what a resume
    /// will replay; the board contributes the labels the journal does not carry
    /// and the rows that have no journal entry yet.
    public var agents: [Agent] {
        var rows: [Agent] = []
        for entry in entries where entry.kind == "spawn_agent" {
            if let terminal = entry.result[rhaiHostTerminalKey]?.stringValue {
                rows.append(Agent(seq: entry.seq, agentID: nil, label: nil, state: .terminal(terminal), tokensUsed: 0))
                continue
            }
            if let message = entry.result[rhaiHostErrorKey]?.stringValue {
                rows.append(Agent(seq: entry.seq, agentID: nil, label: nil, state: .failed(message), tokensUsed: 0))
                continue
            }
            let agentID = entry.result["agent_id"]?.stringValue
            let success = entry.result["success"]?.boolValue ?? false
            let cancelled = entry.result["cancelled"]?.boolValue ?? false
            let live = agentID.flatMap { id in progress.agents.first { $0.agentID == id } }
            rows.append(Agent(
                seq: entry.seq,
                agentID: agentID,
                label: live?.label,
                state: cancelled ? .cancelled : (success ? .succeeded : .failed("agent reported failure")),
                tokensUsed: entry.result["tokens_used"]?.uint64Value ?? live?.tokensUsed ?? 0
            ))
        }
        let journaled = Set(rows.compactMap(\.agentID))
        for running in progress.agents where running.state == .running && !journaled.contains(running.agentID) {
            rows.append(Agent(
                seq: UInt64(rows.count),
                agentID: running.agentID,
                label: running.label,
                state: .running,
                tokensUsed: running.tokensUsed
            ))
        }
        return rows
    }

    public struct Agent: Sendable, Hashable {
        public enum State: Sendable, Hashable {
            case running
            case succeeded
            case failed(String)
            case cancelled
            /// A `parallel()` sibling the engine never got an answer for
            /// (budget, cancellation, dropped reply).
            case terminal(String)

            public var label: String {
                switch self {
                case .running: return "running"
                case .succeeded: return "ok"
                case .failed: return "failed"
                case .cancelled: return "cancelled"
                case .terminal(let kind): return kind
                }
            }
        }

        public let seq: UInt64
        public let agentID: String?
        public let label: String?
        public let state: State
        public let tokensUsed: UInt64
    }
}

public actor RhaiWorkflowRunRegistry {
    private struct Live {
        let context: RhaiWorkflowRunContext
        let task: Task<Void, Never>
    }

    public let store: WorkflowSessionStore
    private var live: [String: Live] = [:]
    /// Retained so `journal(runID:)` can answer for an in-memory registry, where
    /// there is no file to read back.
    private var journals: [String: RhaiJournal] = [:]
    /// Boards outlive their run so a finished run's roster stays visible in the
    /// dashboard for the life of the session, matching upstream's "active and
    /// retained runs" dashboard rather than an active-only list.
    private var boards: [String: RhaiWorkflowProgressBoard] = [:]
    private let makeRunID: @Sendable () -> String

    public init(
        store: WorkflowSessionStore,
        makeRunID: @escaping @Sendable () -> String = { RhaiWorkflowRunRegistry.freshRunID() }
    ) {
        self.store = store
        self.makeRunID = makeRunID
    }

    /// Run ids are path components of the journal file, so the alphabet is the
    /// one `WorkflowSessionStore.journalURL(for:)` will accept.
    public static func freshRunID() -> String {
        let millis = UInt64(Date().timeIntervalSince1970 * 1000)
        let suffix = UInt32.random(in: 0..<0xFFFF_FFFF)
        return String(format: "wf_%llu_%08x", millis, suffix)
    }

    /// Mark runs that were active when the process died as interrupted, so a
    /// restarted session never shows a run as still progressing when no task
    /// is behind it.
    @discardableResult
    public func restore() async throws -> [WorkflowRunRecord] {
        do {
            return try await store.restore()
        } catch {
            throw RhaiWorkflowRegistryError.persistence(String(describing: error))
        }
    }

    // MARK: - Starting

    /// Start a run in the background and return its record immediately.
    ///
    /// The record is inserted *before* the task starts, so `list()` never has a
    /// window where a run exists but is invisible.
    @discardableResult
    public func start(
        script: String,
        workflowName: String? = nil,
        arguments: JSONValue = .object([:]),
        agentBudget: UInt64 = rhaiDefaultAgentBudget,
        hostFactory: RhaiWorkflowHostFactory,
        limits: RhaiInterpreterLimits = RhaiInterpreterLimits()
    ) async throws -> WorkflowRunRecord {
        let name = try workflowName ?? Self.inferName(from: script)
        let runID = makeRunID()
        let journalURL: URL?
        do {
            journalURL = try await store.journalURL(for: runID)
        } catch {
            throw RhaiWorkflowRegistryError.persistence(String(describing: error))
        }
        let journal = RhaiJournal(path: journalURL)
        let record = WorkflowRunRecord(
            runID: runID,
            workflowName: name,
            scriptHash: rhaiRequestHash(kind: "script", payload: .string(script)),
            argumentsHash: rhaiRequestHash(kind: "arguments", payload: arguments),
            status: .active,
            journalPath: journalURL?.path,
            agentBudget: agentBudget
        )
        do {
            try await store.insert(record)
        } catch {
            throw RhaiWorkflowRegistryError.persistence(String(describing: error))
        }
        launch(
            record: record,
            script: script,
            arguments: arguments,
            journal: journal,
            journalURL: journalURL,
            hostFactory: hostFactory,
            limits: limits
        )
        return record
    }

    /// Resume a paused or budget-exceeded run over the journal it left behind.
    ///
    /// This is the engine's cached-prefix resume, not a checkpoint restore: the
    /// script runs from the top and every host call it repeats is answered from
    /// the journal until the run catches up with itself. That is why the script
    /// must be byte-identical — a different script would take a different path
    /// and the journal would report divergence rather than silently diverging.
    @discardableResult
    public func resume(
        runID: String,
        script: String,
        arguments: JSONValue = .object([:]),
        hostFactory: RhaiWorkflowHostFactory,
        limits: RhaiInterpreterLimits = RhaiInterpreterLimits()
    ) async throws -> WorkflowRunRecord {
        var record: WorkflowRunRecord
        do {
            record = try await store.record(runID)
        } catch {
            throw RhaiWorkflowRegistryError.missingRun(runID)
        }
        guard record.status.isResumable else {
            throw RhaiWorkflowRegistryError.notResumable(record.status.rawValue)
        }
        guard record.scriptHash == rhaiRequestHash(kind: "script", payload: .string(script)) else {
            throw RhaiWorkflowRegistryError.scriptMismatch(runID)
        }
        let journalURL = record.journalPath.map { URL(fileURLWithPath: $0) }
        let journal: RhaiJournal
        if let journalURL {
            do {
                journal = try RhaiJournal.load(path: journalURL)
            } catch {
                throw RhaiWorkflowRegistryError.journal(String(describing: error))
            }
        } else {
            journal = journals[runID] ?? RhaiJournal()
        }
        record.status = .active
        record.message = nil
        record.revision = record.revision.saturatingAdd(1)
        record.completionDelivered = false
        do {
            try await store.update(record)
        } catch {
            throw RhaiWorkflowRegistryError.persistence(String(describing: error))
        }
        launch(
            record: record,
            script: script,
            arguments: arguments,
            journal: journal,
            journalURL: journalURL,
            hostFactory: hostFactory,
            limits: limits
        )
        return record
    }

    private func launch(
        record: WorkflowRunRecord,
        script: String,
        arguments: JSONValue,
        journal: RhaiJournal,
        journalURL: URL?,
        hostFactory: RhaiWorkflowHostFactory,
        limits: RhaiInterpreterLimits
    ) {
        let cancellation = RhaiCancellationToken()
        let board = boards[record.runID] ?? RhaiWorkflowProgressBoard()
        let context = RhaiWorkflowRunContext(
            runID: record.runID,
            workflowName: record.workflowName,
            arguments: arguments,
            agentBudget: record.agentBudget,
            journalURL: journalURL,
            cancellation: cancellation,
            progress: board
        )
        journals[record.runID] = journal
        boards[record.runID] = board
        let task = Task { [weak self] in
            let outcome: RhaiWorkflowOutcome
            do {
                let host = try await hostFactory.makeHost(for: context)
                outcome = await RhaiWorkflowEngine.run(RhaiWorkflowRunParameters(
                    script: script,
                    arguments: arguments,
                    journal: journal,
                    host: host,
                    cancellation: cancellation,
                    limits: limits
                ))
            } catch {
                outcome = .failed(error: "workflow host unavailable: \(error)")
            }
            await hostFactory.finishHost(for: context)
            await self?.finish(runID: context.runID, outcome: outcome, journal: journal)
        }
        live[record.runID] = Live(context: context, task: task)
    }

    private func finish(runID: String, outcome: RhaiWorkflowOutcome, journal: RhaiJournal) async {
        live[runID] = nil
        guard var record = try? await store.record(runID) else { return }
        switch outcome {
        case .completed(let result):
            record.status = .completed
            record.result = result
            record.message = nil
        case .paused(let kind, let message):
            record.status = .paused
            record.message = "\(kind.rawValue): \(message)"
        case .budgetExceeded(let message):
            record.status = .budgetExceeded
            record.message = message
        case .cancelled:
            record.status = .cancelled
            record.message = "cancelled"
        case .failed(let error):
            record.status = .failed
            record.message = error
        }
        // Agent accounting comes from the journal rather than from the host:
        // it is the artifact that survives a restart, and it is what a resumed
        // run will replay, so it is the number a raised budget must be compared
        // against.
        record.agentsUsed = journal.agentReservationCount
        record.revision = record.revision.saturatingAdd(1)
        record.completionDelivered = false
        try? await store.update(record)
    }

    // MARK: - Control

    /// Ask a run to stop. Cancellation is cooperative in both directions: the
    /// token stops the engine between operations, and the Swift task
    /// cancellation reaches any child agent currently awaiting a provider.
    public func cancel(runID: String) async throws {
        guard let entry = live[runID] else {
            guard (try? await store.record(runID)) != nil else {
                throw RhaiWorkflowRegistryError.missingRun(runID)
            }
            return
        }
        entry.context.cancellation.cancel()
        entry.task.cancel()
    }

    /// Wait for a run to leave `.active`. Returns the terminal record.
    @discardableResult
    public func awaitCompletion(runID: String, timeoutMS: UInt64? = nil) async throws -> WorkflowRunRecord {
        if let entry = live[runID] {
            if let timeoutMS {
                let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000)
                while live[runID] != nil, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
            } else {
                await entry.task.value
            }
        }
        do {
            return try await store.record(runID)
        } catch {
            throw RhaiWorkflowRegistryError.missingRun(runID)
        }
    }

    public func isRunning(_ runID: String) -> Bool { live[runID] != nil }

    // MARK: - Reading

    public func list() async throws -> [WorkflowRunRecord] {
        do {
            return try await store.list()
        } catch {
            throw RhaiWorkflowRegistryError.persistence(String(describing: error))
        }
    }

    public func record(runID: String) async throws -> WorkflowRunRecord {
        do {
            return try await store.record(runID)
        } catch {
            throw RhaiWorkflowRegistryError.missingRun(runID)
        }
    }

    /// The journal as it stands right now, read from disk when there is a file
    /// and from the retained in-memory journal otherwise.
    public func journalEntries(runID: String) async throws -> [RhaiJournalEntry] {
        if let journal = journals[runID] { return journal.snapshot }
        let record = try await self.record(runID: runID)
        guard let path = record.journalPath else { return [] }
        do {
            return try RhaiJournal.load(path: URL(fileURLWithPath: path)).snapshot
        } catch {
            throw RhaiWorkflowRegistryError.journal(String(describing: error))
        }
    }

    public func progress(runID: String) async -> RhaiWorkflowProgress {
        guard let board = boards[runID] else { return RhaiWorkflowProgress() }
        return await board.snapshot()
    }

    public func view(runID: String) async throws -> RhaiWorkflowRunView {
        RhaiWorkflowRunView(
            record: try await record(runID: runID),
            entries: try await journalEntries(runID: runID),
            progress: await progress(runID: runID)
        )
    }

    /// Every run, newest last, each with its journal and live progress. This is
    /// what the `/workflows` overlay renders.
    public func views() async throws -> [RhaiWorkflowRunView] {
        var out: [RhaiWorkflowRunView] = []
        for record in try await list() {
            let entries = (try? await journalEntries(runID: record.runID)) ?? []
            out.append(RhaiWorkflowRunView(
                record: record,
                entries: entries,
                progress: await progress(runID: record.runID)
            ))
        }
        return out
    }

    // MARK: - Naming

    /// A run's display name comes from the script's `meta` block when it has
    /// one. A script without usable metadata still runs — the name falls back
    /// to `inline` rather than the run being rejected — because `--workflow`
    /// points at an arbitrary file the user wrote.
    static func inferName(from script: String) throws -> String {
        (try? RhaiMeta.extract(from: script).name) ?? "inline"
    }
}

private extension UInt64 {
    /// A local copy: the engine target's own saturating add is internal to it.
    func workflowSaturatingAdd(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? UInt64.max : sum
    }
}
