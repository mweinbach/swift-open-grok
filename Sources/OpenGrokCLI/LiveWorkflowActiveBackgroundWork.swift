// LiveWorkflowActiveBackgroundWork.swift
//
// Status-chip push for active workflow runs. The live registry used by
// `/tasks` workflow rows is `RhaiWorkflowRunRegistry` (created via
// `LiveWorkflowLaunch.makeRegistry`); this file is the CLI-typed install
// seam that maps registry membership events onto
// `LiveActiveBackgroundWorkSink` / `.workflow` keys.
//
// Count definition matches Rust `TasksPane::running_count` workflow half
// (`tasks_pane.rs:1132-1149` @ `650c1db7`): every run whose status is
// `active` (`WorkflowRunSnapshot::is_active`, views/workflows.rs:55-57).
// Paused / budget_exceeded / cancelled / failed / completed / interrupted
// are not active — remove fires when status leaves `.active`.
//
// Workflow child agents are NOT counted here. Marker capability today:
// structural exclusion only — children run through `LiveWorkflowChildAgent`
// and never enter `LiveSubagentHost` (`LivePagerForkTasksCommands` notes the
// same divergence from upstream's `workflow_run_id.is_none()` filter).
// `LiveSubagentHost.countsTowardActiveBackgroundWork` also recognizes
// `workflowRunID` / `owner == .workflow` markers, but the workflow path does
// not set them because it never registers through that host. This sink emits
// only `.workflow` run ids.

import Foundation
import OpenGrokSessionRuntime

enum LiveWorkflowActiveBackgroundWork {
    /// Install (or clear) a `LiveActiveBackgroundWorkSink` on the live
    /// workflow run registry. A non-nil install republishes every currently
    /// `.active` run id so a late-attached renderer seeds its cache without
    /// polling. Replacement/clear is generation-safe inside the registry.
    static func setActiveBackgroundWorkSink(
        on registry: RhaiWorkflowRunRegistry,
        _ sink: LiveActiveBackgroundWorkSink?
    ) async {
        guard let sink else {
            await registry.setActiveBackgroundWorkSink(nil)
            return
        }
        await registry.setActiveBackgroundWorkSink { event in
            switch event {
            case .upsert(let runID):
                if let mapped = LiveActiveBackgroundWorkEvent.upsert(
                    kind: .workflow,
                    id: runID
                ) {
                    await sink(mapped)
                }
            case .remove(let runID):
                if let mapped = LiveActiveBackgroundWorkEvent.remove(
                    kind: .workflow,
                    id: runID
                ) {
                    await sink(mapped)
                }
            }
        }
    }

    /// Drop every still-published `.workflow` id and clear the sink. Session
    /// teardown calls this so a lost terminal status cannot leave the chip
    /// armed after the registry is abandoned.
    static func shutdownActiveBackgroundWork(
        on registry: RhaiWorkflowRunRegistry
    ) async {
        await registry.shutdownActiveBackgroundWork()
    }
}
