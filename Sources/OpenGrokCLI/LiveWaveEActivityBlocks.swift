import Foundation
import OpenGrokPagerRender
import OpenGrokScheduler
import OpenGrokSessionRuntime
import OpenGrokShellBase

private struct LiveWaveEActivitySnapshots {
    var workflows: [RhaiWorkflowRunView] = []
    var subagents: [LiveSubagentSnapshot] = []
    var swarms: [LiveSwarmTranscriptSnapshot] = []
    var tasks: [ShellTaskSnapshot] = []
    var scheduled: [ScheduledTaskInfo] = []
}

extension LiveInteractiveControllerRenderer {
    func refreshActivityBlocks() async {
        guard !sessionID.isEmpty else { return }
        let now = Date()
        let snapshots = await waveEActivitySnapshots()

        for task in snapshots.tasks where task.isBackgrounded || task.kind == .monitor {
            let state: PagerActivityState
            if !task.completed {
                state = .running
            } else if task.explicitlyKilled {
                state = .cancelled
            } else if task.exitCode == 0 {
                state = .succeeded
            } else {
                state = .failed
            }
            let description = task.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayCommand = task.displayCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title: String
            if let description, !description.isEmpty {
                title = description
            } else if let displayCommand, !displayCommand.isEmpty {
                title = displayCommand
            } else {
                title = task.command
            }
            conversation.upsertBlock(.backgroundTask(PagerBackgroundTaskBlock(
                id: "background-task-\(task.taskID)",
                kind: task.kind == .monitor ? .monitor : .process,
                title: title,
                state: state,
                outputTail: task.output.isEmpty ? nil : task.output,
                exitCode: task.exitCode.map { Int($0) },
                duration: task.duration(at: now)
            )))
            refreshWaveEBackgroundTaskViewer(task: task, title: title)
        }

        for scheduled in snapshots.scheduled {
            conversation.upsertBlock(.backgroundTask(PagerBackgroundTaskBlock(
                id: "scheduled-task-\(scheduled.taskId)",
                kind: .scheduled,
                title: "\(scheduled.tag) · \(scheduled.humanSchedule)",
                state: .waiting,
                outputTail: scheduled.prompt
            )))
        }

        for subagent in snapshots.subagents {
            conversation.upsertBlock(.subagent(Self.waveESubagentBlock(subagent, now: now)))
        }

        let subagentsByID = Dictionary(
            uniqueKeysWithValues: snapshots.subagents.map { ($0.subagentID, $0) }
        )
        for swarm in snapshots.swarms {
            let members = swarm.slots.enumerated().map { index, result in
                guard let result else {
                    return PagerSwarmMember(
                        id: "\(swarm.swarmID)-member-\(index)",
                        label: "Member \(index + 1)",
                        state: swarm.isActive ? .queued : .cancelled,
                        activity: swarm.isActive ? "Waiting to finish" : nil
                    )
                }
                let subagent = subagentsByID[result.agentID]
                return PagerSwarmMember(
                    id: result.agentID.isEmpty
                        ? "\(swarm.swarmID)-member-\(index)"
                        : result.agentID,
                    label: result.item ?? subagent?.description ?? "Member \(index + 1)",
                    state: Self.waveESwarmMemberState(result.outcome),
                    activity: subagent?.status == "running" ? "Running" : nil,
                    turnCount: Int(subagent?.turnCount ?? 0),
                    toolCount: Int(subagent?.toolCallCount ?? 0),
                    duration: subagent.map {
                        $0.completed
                            ? TimeInterval($0.durationMS) / 1_000
                            : max(0, now.timeIntervalSince($0.startedAt))
                    },
                    outcome: result.body.isEmpty ? subagent?.output : result.body
                )
            }
            let completed = swarm.slots.compactMap { $0 }
            let state: PagerActivityState
            if swarm.isActive && !swarm.isFinished {
                state = .running
            } else if completed.contains(where: { $0.outcome == .failed }) {
                state = .failed
            } else if completed.contains(where: { $0.outcome == .aborted })
                || completed.count < swarm.expectedMembers
            {
                state = .cancelled
            } else {
                state = .succeeded
            }
            let summary = [
                "completed \(completed.filter { $0.outcome == .completed }.count)",
                "failed \(completed.filter { $0.outcome == .failed }.count)",
                "cancelled \(completed.filter { $0.outcome == .aborted }.count)",
            ].joined(separator: " · ")
            conversation.upsertBlock(.swarm(PagerSwarmBlock(
                id: "swarm-\(swarm.swarmID)",
                objective: swarm.description,
                state: state,
                members: members,
                outcome: swarm.isActive ? nil : summary,
                isExpanded: true
            )))
        }

        for view in snapshots.workflows {
            let phases = view.phases.map { phase in
                PagerWorkflowPhase(
                    label: phase,
                    state: phase == view.currentPhase && view.record.status == .active
                        ? .running
                        : .succeeded
                )
            }
            conversation.upsertBlock(.workflow(PagerWorkflowBlock(
                id: "workflow-\(view.record.runID)",
                name: view.record.workflowName,
                objective: view.record.message ?? view.record.workflowName,
                state: Self.waveEActivityState(view.record.status.rawValue),
                phases: phases,
                agentCount: Int(view.record.agentsUsed),
                outcome: view.record.message
                    ?? view.record.result.map { String(describing: $0) }
            )))
        }
    }

    private func waveEActivitySnapshots() async -> LiveWaveEActivitySnapshots {
        var snapshots = LiveWaveEActivitySnapshots()
        if let workflowRegistry {
            snapshots.workflows = (try? await workflowRegistry.views()) ?? []
        }
        if let host = toolExecutor?.subagentHost {
            for id in await host.knownSubagentIDs() {
                if let snapshot = await host.subagentSnapshot(id: id) {
                    snapshots.subagents.append(snapshot)
                }
            }
            snapshots.swarms = host.swarmRegistry.transcriptSnapshots(
                parentSessionID: sessionID
            )
        }
        snapshots.tasks = await toolExecutor?.backgroundTaskSnapshots(
            sessionID: sessionID,
            workingDirectory: URL(fileURLWithPath: workingDirectory, isDirectory: true)
        ) ?? []
        if let schedulerHost = toolExecutor?.schedulerHost {
            snapshots.scheduled = await schedulerHost.displayInfos()
        }
        return snapshots
    }

    static func waveESubagentBlock(
        _ subagent: LiveSubagentSnapshot,
        now: Date
    ) -> PagerSubagentBlock {
        PagerSubagentBlock(
            id: "subagent-\(subagent.subagentID)",
            label: subagent.description.isEmpty
                ? subagent.subagentType
                : "\(subagent.subagentType) · \(subagent.description)",
            state: waveEActivityState(subagent.status),
            activity: subagent.status == "running" ? "Running" : nil,
            turnCount: Int(subagent.turnCount),
            toolCount: Int(subagent.toolCallCount),
            duration: subagent.completed
                ? TimeInterval(subagent.durationMS) / 1_000
                : max(0, now.timeIntervalSince(subagent.startedAt)),
            outcome: subagent.output.isEmpty ? nil : subagent.output
        )
    }

    private static func waveEActivityState(_ status: String) -> PagerActivityState {
        switch status {
        case "running", "active": return .running
        case "queued": return .queued
        case "waiting", "paused", "budget_exceeded": return .waiting
        case "completed", "succeeded", "ok": return .succeeded
        case "cancelled", "canceled", "interrupted": return .cancelled
        default: return .failed
        }
    }

    private static func waveESwarmMemberState(_ outcome: SwarmMemberOutcome) -> PagerActivityState {
        switch outcome {
        case .completed: return .succeeded
        case .failed: return .failed
        case .aborted: return .cancelled
        }
    }

    func openWaveEBackgroundTaskViewer(for item: PagerConversationItem) -> Bool {
        guard case .block(.backgroundTask(let block)) = item,
              block.id.hasPrefix("background-task-") else { return false }
        overlays.push(.sessionInfo(
            id: "block-viewer:\(block.id)",
            title: block.title,
            lines: waveEBackgroundTaskViewerLines(block.outputTail),
            followsTail: true
        ))
        return true
    }

    private func refreshWaveEBackgroundTaskViewer(task: ShellTaskSnapshot, title: String) {
        let id = "block-viewer:background-task-\(task.taskID)"
        guard overlays.updateText(id: id, { text in
            text.lines = waveEBackgroundTaskViewerLines(task.output)
        }) else { return }
        overlays.retitle(id: id, title: title)
    }

    private func waveEBackgroundTaskViewerLines(_ output: String?) -> [PagerStyledLine] {
        guard let output, !output.isEmpty else {
            return [PagerStyledLine(text: "(no output yet)")]
        }
        return output
            .split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            .map { PagerStyledLine(text: String($0)) }
    }
}
