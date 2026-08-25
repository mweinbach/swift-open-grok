// ActiveAgentReminder.swift
//
// Provider-neutral rendering for the active work that must survive compaction.
// Rust reference: crates/common/xai-grok-compaction/src/reminder.rs.

import Foundation

public enum ActiveAgentTodoStatus: String, Sendable, Equatable, Hashable {
    case pending
    case inProgress = "in_progress"
    case completed
    case cancelled

    public var isActionable: Bool {
        switch self {
        case .pending, .inProgress: true
        case .completed, .cancelled: false
        }
    }

    public var tag: String { "[\(rawValue)]" }
}

public struct ActiveAgentTodoItem: Sendable, Equatable, Hashable {
    public var id: String
    public var content: String
    public var status: ActiveAgentTodoStatus

    public init(id: String, content: String, status: ActiveAgentTodoStatus) {
        self.id = id
        self.content = content
        self.status = status
    }
}

public struct ActiveAgentBackgroundTask: Sendable, Equatable, Hashable {
    public var taskID: String
    public var command: String
    public var status: String
    public var toolName: String?

    public init(
        taskID: String,
        command: String,
        status: String = "running",
        toolName: String? = nil
    ) {
        self.taskID = taskID
        self.command = command
        self.status = status
        self.toolName = toolName
    }
}

public struct ActiveAgentRunningSubagent: Sendable, Equatable, Hashable {
    public var subagentID: String
    public var subagentType: String?
    public var description: String?
    public var elapsedSeconds: UInt64

    public init(
        subagentID: String,
        subagentType: String? = nil,
        description: String? = nil,
        elapsedSeconds: UInt64 = 0
    ) {
        self.subagentID = subagentID
        self.subagentType = subagentType
        self.description = description
        self.elapsedSeconds = elapsedSeconds
    }
}

public struct ActiveAgentSubagentToolNames: Sendable, Equatable, Hashable {
    public var poll: String
    public var cancel: String

    public init(poll: String, cancel: String) {
        self.poll = poll
        self.cancel = cancel
    }
}

public struct ActiveAgentReminderState: Sendable, Equatable, Hashable {
    public var runningCommands: [ActiveAgentBackgroundTask]
    public var todos: [ActiveAgentTodoItem]
    public var runningSubagents: [ActiveAgentRunningSubagent]

    public init(
        runningCommands: [ActiveAgentBackgroundTask] = [],
        todos: [ActiveAgentTodoItem] = [],
        runningSubagents: [ActiveAgentRunningSubagent] = []
    ) {
        self.runningCommands = runningCommands
        self.todos = todos
        self.runningSubagents = runningSubagents
    }

    public var hasActionableTodos: Bool {
        todos.contains { $0.status.isActionable }
    }

    public var isEmpty: Bool {
        runningCommands.isEmpty && runningSubagents.isEmpty && !hasActionableTodos
    }
}

public enum ActiveAgentReminderFormatter {
    public static func backgroundTasksSection(
        _ tasks: [ActiveAgentBackgroundTask]
    ) -> String? {
        guard !tasks.isEmpty else { return nil }
        let lines = tasks.map { task in
            if let toolName = task.toolName {
                return "- \"\(task.taskID)\": `\(task.command)` (\(task.status), \(toolName))"
            }
            return "- \"\(task.taskID)\": `\(task.command)` (\(task.status))"
        }.joined(separator: "\n")
        return "## Running Background Tasks\nThese tasks are still running:\n\(lines)"
    }

    public static func todoListSection(_ todos: [ActiveAgentTodoItem]) -> String? {
        let actionable = todos.filter { $0.status.isActionable }
        guard !actionable.isEmpty else { return nil }

        let lines = actionable.map {
            "- \($0.status.tag) \($0.id): \($0.content)"
        }.joined(separator: "\n")
        let completed = todos.filter { $0.status == .completed }.count
        let cancelled = todos.filter { $0.status == .cancelled }.count
        let trailer: String
        switch (completed, cancelled) {
        case (0, 0): trailer = ""
        case (let count, 0): trailer = "\n(\(count) completed)"
        case (0, let count): trailer = "\n(\(count) cancelled)"
        case (let done, let dropped):
            trailer = "\n(\(done) completed, \(dropped) cancelled)"
        }

        return "## TODO List\n"
            + "This is your task list from before the conversation was compacted — it is still "
            + "active. Keep working through the items below and update their status as you make "
            + "progress:\n\(lines)\(trailer)"
    }

    public static func runningSubagentsSection(
        _ subagents: [ActiveAgentRunningSubagent],
        tools: ActiveAgentSubagentToolNames
    ) -> String? {
        guard !subagents.isEmpty else { return nil }
        let lines = subagents.map { subagent in
            var head = "subagent_id: `\(subagent.subagentID)`"
            if let type = subagent.subagentType {
                head += ", type: `\(type)`"
            }
            if let description = subagent.description {
                head += ", task: \"\(description)\""
            }
            return "- \(head) (running for \(subagent.elapsedSeconds)s)"
        }.joined(separator: "\n")

        return "## Running Subagents\n"
            + "These subagents were launched before this compaction and are still running. "
            + "Use `\(tools.poll)` with the subagent_id to check their status or retrieve results. "
            + "Use `\(tools.cancel)` with the subagent_id to cancel a subagent.\n\(lines)"
    }

    public static func formatSections(
        state: ActiveAgentReminderState,
        subagentTools: ActiveAgentSubagentToolNames? = nil
    ) -> [String] {
        var sections: [String] = []
        if let background = backgroundTasksSection(state.runningCommands) {
            sections.append(background)
        }
        if let todos = todoListSection(state.todos) {
            sections.append(todos)
        }
        if let subagentTools,
           let subagents = runningSubagentsSection(state.runningSubagents, tools: subagentTools)
        {
            sections.append(subagents)
        }
        return sections
    }

    public static func wrapSystemReminder(_ sections: [String]) -> String? {
        let body = sections.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.joined(separator: "\n\n")
        guard !body.isEmpty else { return nil }
        return "<system-reminder>\n\(body)\n</system-reminder>"
    }

    public static func formatReminder(
        state: ActiveAgentReminderState,
        subagentTools: ActiveAgentSubagentToolNames? = nil
    ) -> String? {
        wrapSystemReminder(formatSections(state: state, subagentTools: subagentTools))
    }

    public static func appendReminderBlock(_ summary: String, reminder: String?) -> String {
        guard let reminder,
              !reminder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return summary }
        return "\(summary)\n\n\(reminder)"
    }
}
