// LiveWorkflowOverlay.swift
//
// Maps the background registry's run views onto the `/workflows` overlay's row
// model, and interprets the control keys the overlay reports back.
//
// The render layer has no way to reach a run and should not be given one, so
// `p`/`r`/`x` come back as row ids of the form `"<key>:<run-id>"` and are turned
// into registry calls here.

import Foundation
import OpenGrokPagerRender
import OpenGrokSessionRuntime
import OpenGrokWorkflow

enum LiveWorkflowOverlayBuilder {
    /// Newest run first — the dashboard is read top-down and the run a user
    /// just launched is the one they are looking for.
    static func rows(from views: [RhaiWorkflowRunView]) -> [PagerWorkflowRow] {
        views.reversed().map(row(from:))
    }

    static func row(from view: RhaiWorkflowRunView) -> PagerWorkflowRow {
        let record = view.record
        let agents = view.agents
        return PagerWorkflowRow(
            runID: record.runID,
            name: record.workflowName,
            status: record.status.rawValue,
            phase: view.currentPhase,
            agentsFinished: agents.filter { $0.state != .running }.count,
            agentBudget: record.agentBudget,
            tokensUsed: view.progress.tokensUsed,
            message: record.message,
            result: record.result.map(RhaiCanonicalJSON.string),
            agents: agents.map { agent in
                PagerWorkflowAgent(
                    name: agent.label ?? agent.agentID ?? "seq \(agent.seq)",
                    state: agent.state.label,
                    phase: nil,
                    tokensUsed: agent.tokensUsed
                )
            }
        )
    }

    /// What the overlay asked for. `nil` when the row id is a plain selection
    /// rather than a control key.
    enum Command: Equatable {
        case pause(runID: String)
        case resume(runID: String)
        case stop(runID: String)
    }

    static func command(forRowID rowID: String) -> Command? {
        let parts = rowID.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        let runID = String(parts[1])
        switch parts[0] {
        case "p": return .pause(runID: runID)
        case "r": return .resume(runID: runID)
        case "x": return .stop(runID: runID)
        default: return nil
        }
    }

    /// Perform a dashboard control key.
    ///
    /// Pause and stop are both cancellation here. The engine has no "suspend
    /// and keep the task parked" state — a run stops at a terminal outcome and
    /// resumes by replaying its journal — so pausing is stopping plus the
    /// knowledge that the journal is a resumable prefix. Resume needs the
    /// original script, which the dashboard does not hold; upstream is explicit
    /// that a bare resume cannot raise a budget cap either, so it reports what
    /// the user has to do instead of half-doing it.
    static func apply(
        _ command: Command,
        registry: RhaiWorkflowRunRegistry
    ) async -> String {
        switch command {
        case .pause(let runID), .stop(let runID):
            do {
                try await registry.cancel(runID: runID)
                return "workflow \(runID) stopped"
            } catch {
                return "cannot stop \(runID): \(error)"
            }
        case .resume(let runID):
            let record = try? await registry.record(runID: runID)
            guard let record, record.status.isResumable else {
                return "workflow \(runID) is not resumable"
            }
            return "resume \(runID) with `open-grok --workflow <the same script>`; "
                + "a budget-limited run needs a higher agent_budget to make progress"
        }
    }
}
