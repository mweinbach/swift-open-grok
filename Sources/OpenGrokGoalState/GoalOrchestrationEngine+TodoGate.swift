import Foundation

public struct GoalTodoGateInput: Sendable, Hashable {
    public var pending: [GoalTodoSnapshot]
    public var inProgressBacked: [GoalTodoSnapshot]
    public var inProgressUnbacked: [GoalTodoSnapshot]
    public var backingTaskCount: Int

    public init(todos: [GoalTodoSnapshot], backingTaskCount: Int) {
        let backing = max(0, backingTaskCount)
        pending = todos.filter { $0.status == "pending" }
        let inProgress = todos.filter { $0.status == "in_progress" }
        let backedCount = min(backing, inProgress.count)
        inProgressBacked = Array(inProgress.prefix(backedCount))
        inProgressUnbacked = Array(inProgress.dropFirst(backedCount))
        self.backingTaskCount = backing
    }
}

public enum GoalTodoGateDecision: Sendable, Hashable {
    case continueTurn
    case nudge(reminder: String, reason: String)
}

public enum GoalTodoGate {
    public static func evaluate(_ input: GoalTodoGateInput) -> GoalTodoGateDecision {
        guard !input.pending.isEmpty || !input.inProgressUnbacked.isEmpty else {
            return .continueTurn
        }
        return .nudge(
            reminder: reminder(
                pending: input.pending,
                unbackedInProgress: input.inProgressUnbacked
            ),
            reason: "in_flight"
        )
    }

    /// Rust `acp_session_impl/reminders.rs:103-129`; the plan template is
    /// already resolved to the actual tool name because Swift has no renderer.
    public static func reminder(
        pending: [GoalTodoSnapshot],
        unbackedInProgress: [GoalTodoSnapshot]
    ) -> String {
        var output = "You have outstanding todos but ended your turn without a tool call.\n\n"
        if !unbackedInProgress.isEmpty {
            output += "In-progress (no backing background task):\n"
            for item in unbackedInProgress {
                output += "- \(item.content)\n"
            }
            output += "\n"
        }
        if !pending.isEmpty {
            output += "Pending:\n"
            for item in pending {
                output += "- \(item.content)\n"
            }
            output += "\n"
        }
        output += "Per <task_completion_discipline>, advance the next pending todo "
            + "with the appropriate tool call NOW. If you have a genuine external "
            + "blocker (missing credential, denied permission, network unreachable), "
            + "state it explicitly AND mark the affected todos `cancelled` via "
            + "todo_write with a reason in the same turn."
        return output
    }
}
