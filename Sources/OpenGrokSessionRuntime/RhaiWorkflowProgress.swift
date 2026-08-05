// RhaiWorkflowProgress.swift
//
// Live progress for a background workflow run.
//
// The journal is the durable record, but it deliberately does not contain
// everything the `/workflows` dashboard shows. `phase()`, `log()` and
// `telemetry_event()` are fire-and-forget in the engine — they consume no
// sequence number and are never journaled (engine.rs:342 `host_emit`) — and an
// agent that is still running has no journal entry yet, because the entry is
// written when the spawn *returns*.
//
// So the dashboard reads two sources and they answer different questions:
//
//   the journal  — what this run durably did, survives a restart, replays
//   this board   — what it is doing right now, in this process, lost on exit
//
// Nothing here is authoritative. A restarted session shows a run's agent roster
// from the journal with no current phase, which is correct: the phase belonged
// to a process that is gone.

import Foundation

public struct RhaiWorkflowAgentProgress: Sendable, Hashable {
    public enum State: String, Sendable, Hashable {
        case running
        case succeeded
        case failed
        case cancelled
    }

    public var agentID: String
    public var label: String?
    public var phase: String?
    public var state: State
    public var tokensUsed: UInt64
    public var startedAtMS: UInt64
    public var finishedAtMS: UInt64?

    public init(
        agentID: String,
        label: String? = nil,
        phase: String? = nil,
        state: State = .running,
        tokensUsed: UInt64 = 0,
        startedAtMS: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000),
        finishedAtMS: UInt64? = nil
    ) {
        self.agentID = agentID
        self.label = label
        self.phase = phase
        self.state = state
        self.tokensUsed = tokensUsed
        self.startedAtMS = startedAtMS
        self.finishedAtMS = finishedAtMS
    }
}

public struct RhaiWorkflowProgress: Sendable, Hashable {
    /// Phase titles in the order the run announced them.
    public var phases: [String]
    /// The most recent `log()` line, which is what the dashboard row shows as
    /// the run's activity when it is between phases.
    public var lastLog: String?
    /// Agents in spawn order — the roster, including ones still running.
    public var agents: [RhaiWorkflowAgentProgress]
    public var tokensUsed: UInt64

    public init(
        phases: [String] = [],
        lastLog: String? = nil,
        agents: [RhaiWorkflowAgentProgress] = [],
        tokensUsed: UInt64 = 0
    ) {
        self.phases = phases
        self.lastLog = lastLog
        self.agents = agents
        self.tokensUsed = tokensUsed
    }

    public var currentPhase: String? { phases.last }
    public var runningAgentCount: Int { agents.filter { $0.state == .running }.count }
    public var finishedAgentCount: Int { agents.filter { $0.state != .running }.count }
}

/// The mutable side of `RhaiWorkflowProgress`, written by the host and read by
/// the dashboard.
public actor RhaiWorkflowProgressBoard {
    private var progress = RhaiWorkflowProgress()

    public init() {}

    public func snapshot() -> RhaiWorkflowProgress { progress }

    /// A replayed phase is history being redrawn, not new activity, so it is
    /// recorded once rather than appended a second time on resume.
    public func enterPhase(_ title: String, replayed: Bool) {
        if replayed, progress.phases.contains(title) { return }
        progress.phases.append(title)
    }

    public func log(_ message: String) {
        progress.lastLog = message
    }

    public func agentStarted(agentID: String, label: String?, phase: String?) {
        progress.agents.append(RhaiWorkflowAgentProgress(
            agentID: agentID,
            label: label,
            phase: phase ?? progress.currentPhase
        ))
    }

    public func agentFinished(
        agentID: String,
        state: RhaiWorkflowAgentProgress.State,
        tokensUsed: UInt64
    ) {
        guard let index = progress.agents.lastIndex(where: { $0.agentID == agentID }) else { return }
        progress.agents[index].state = state
        progress.agents[index].tokensUsed = tokensUsed
        progress.agents[index].finishedAtMS = UInt64(Date().timeIntervalSince1970 * 1000)
        progress.tokensUsed &+= tokensUsed
    }
}
