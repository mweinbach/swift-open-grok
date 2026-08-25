// LiveCompactionStateReminder.swift
//
// Snapshot session-owned live state immediately before replacing conversation
// history. Rust reference: shell/session/compaction.rs:1970-2055,2197-2208 and
// shell/session/helpers/compaction_context.rs:115-237 at 00e176c8.

import Foundation
import OpenGrokCompaction
import OpenGrokShellBase
import OpenGrokToolRegistry

struct LiveCompactionMCPServerSnapshot: Sendable, Equatable {
    var name: String
    var toolCount: Int
    var description: String?

    init(name: String, toolCount: Int, description: String? = nil) {
        self.name = name
        self.toolCount = toolCount
        self.description = description
    }
}

struct LiveCompactionMCPToolNames: Sendable, Equatable {
    var search: String
    var call: String
}

struct LiveCompactionStateSnapshot: Sendable, Equatable {
    var editedFiles: [String] = []
    var activeAgentState = ActiveAgentReminderState()
    var connectedMCPServers: [LiveCompactionMCPServerSnapshot] = []
    var memoryContext: String?
    var subagentToolNames: ActiveAgentSubagentToolNames?
    var mcpToolNames: LiveCompactionMCPToolNames?
}

typealias LiveCompactionStateSnapshotProvider = @Sendable (
    _ sessionID: String,
    _ lastUserQuery: String?
) async -> LiveCompactionStateSnapshot

struct LiveCompactionStateSnapshotInputs: Sendable {
    var sessionID: String
    var workingDirectory: URL
    var todoStore: LiveTodoStore?
    var subagentHost: (any LiveSubagentQuerying)?
    var activeSubagentIDs: [String] = []
    var backgroundTasks: [ShellTaskSnapshot] = []
    var connectedMCPServers: [LiveCompactionMCPServerSnapshot] = []
    var editedFiles: [String] = []
    var memoryContext: String?
    var advertisedToolNames: Set<String> = []
    var subagentToolNames: ActiveAgentSubagentToolNames?
    var mcpToolNames: LiveCompactionMCPToolNames?
    var now: Date = Date()
}

enum LiveCompactionStateReminder {
    static let maximumEntriesPerSection = 32
    static let maximumLineCharacters = 512
    static let maximumSectionCharacters = 6_000
    static let maximumReminderCharacters = 16_384

    static func snapshot(
        sessionID: String,
        lastUserQuery: String?,
        toolExecutor: LiveToolExecutor
    ) async -> LiveCompactionStateSnapshot {
        let toolset = toolExecutor.mcpToolset
        // `/new` and `/resume` can retain an executor while changing the
        // conversation. Its original todo, MCP, hunk and memory resources
        // must never be copied across that ownership boundary.
        guard toolset.resources.sessionId == sessionID else {
            return LiveCompactionStateSnapshot()
        }

        let workingDirectory = toolExecutor.workingDirectory
        let advertised = Set(await toolExecutor.currentActiveToolSpecs().map(\.name))
        let activeSubagentIDs: [String]
        let host: (any LiveSubagentQuerying)?
        if let candidate = toolExecutor.subagentHost,
           await candidate.context.sessionID == sessionID
        {
            activeSubagentIDs = await candidate.coordinator
                .listActive(parentSessionID: sessionID)
                .map { $0.request.id }
            host = candidate
        } else {
            activeSubagentIDs = []
            host = nil
        }

        let backgroundTasks = await toolExecutor.backgroundTaskSnapshots(
            sessionID: sessionID,
            workingDirectory: workingDirectory
        )
        let connectedNames = await toolExecutor.mcpSessionConnections.names()
        let mcpServers = connectedNames.map { serverName in
            let toolCount = advertised.filter { name in
                guard name.hasPrefix(mcpToolNamePrefix(serverName)),
                      let tool = toolset.tool(named: name)
                else { return false }
                return tool.namespace == .mcp
            }.count
            return LiveCompactionMCPServerSnapshot(name: serverName, toolCount: toolCount)
        }

        let editedFiles: [String]
        if let tracker = toolset.resources.hunkTracker {
            let hunks = await tracker.getAllHunks()
            editedFiles = Array(Set(hunks.compactMap { hunk in
                guard hunk.source.isAgentEdit,
                      hunk.source.sessionId == sessionID,
                      isWithinWorkspace(hunk.path, workingDirectory: workingDirectory)
                else { return nil }
                return hunk.path
            })).sorted()
        } else {
            editedFiles = []
        }

        let recoveredMemory: String?
        if let services = toolExecutor.sessionServices,
           services.owningSessionID == nil || services.owningSessionID == sessionID,
           let memory = services.memory,
           await memory.workspacePath.standardizedFileURL == workingDirectory.standardizedFileURL
        {
            let query = lastUserQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
            let results = await memory.search(
                query: query.flatMap { $0.isEmpty ? nil : $0 } ?? "project context",
                maxResults: 3,
                minScore: 0
            )
            recoveredMemory = LiveMemoryFormatting.memoryContext(results)
        } else {
            recoveredMemory = nil
        }

        let poll = resolveTool(
            kind: .backgroundTaskAction,
            fallbackNames: ["get_task_output", "get_command_or_subagent_output"],
            advertised: advertised,
            toolset: toolset
        )
        let cancel = resolveTool(
            kind: .killTaskAction,
            fallbackNames: ["kill_task", "kill_command_or_subagent"],
            advertised: advertised,
            toolset: toolset
        )
        let subagentTools: ActiveAgentSubagentToolNames?
        if let poll, let cancel {
            subagentTools = ActiveAgentSubagentToolNames(poll: poll, cancel: cancel)
        } else {
            subagentTools = nil
        }

        let search = resolveTool(
            kind: .searchTool,
            fallbackNames: ["search_tool"],
            advertised: advertised,
            toolset: toolset
        )
        let use = resolveTool(
            kind: .useTool,
            fallbackNames: ["use_tool"],
            advertised: advertised,
            toolset: toolset
        )
        let mcpTools: LiveCompactionMCPToolNames?
        if let search, let use {
            mcpTools = LiveCompactionMCPToolNames(search: search, call: use)
        } else {
            mcpTools = nil
        }

        return await snapshot(inputs: LiveCompactionStateSnapshotInputs(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            todoStore: toolExecutor.todoStore,
            subagentHost: host,
            activeSubagentIDs: activeSubagentIDs,
            backgroundTasks: backgroundTasks,
            connectedMCPServers: mcpServers,
            editedFiles: editedFiles,
            memoryContext: recoveredMemory,
            advertisedToolNames: advertised,
            subagentToolNames: subagentTools,
            mcpToolNames: mcpTools
        ))
    }

    static func snapshot(
        inputs: LiveCompactionStateSnapshotInputs
    ) async -> LiveCompactionStateSnapshot {
        let liveTodos = await inputs.todoStore?.todos ?? []
        let todos = liveTodos.prefix(maximumEntriesPerSection).compactMap { item in
            ActiveAgentTodoStatus(rawValue: item.status.rawValue).map { status in
                ActiveAgentTodoItem(id: item.id, content: item.content, status: status)
            }
        }

        let tasks = inputs.backgroundTasks
            .filter { task in
                !task.completed
                    && (task.ownerSessionID == nil || task.ownerSessionID == inputs.sessionID)
            }
            .sorted { $0.taskID < $1.taskID }
            .prefix(maximumEntriesPerSection)
            .map { task in
                let candidate = task.kind == .monitor ? "monitor" : "run_terminal_cmd"
                let toolName = inputs.advertisedToolNames.contains(candidate) ? candidate : nil
                return ActiveAgentBackgroundTask(
                    taskID: task.taskID,
                    command: task.displayCommand ?? task.command,
                    status: "running",
                    toolName: toolName
                )
            }

        var subagents: [ActiveAgentRunningSubagent] = []
        if let host = inputs.subagentHost {
            for id in inputs.activeSubagentIDs.sorted().prefix(maximumEntriesPerSection) {
                guard let current = await host.subagentSnapshot(id: id),
                      !current.completed,
                      current.subagentID == id
                else { continue }
                subagents.append(ActiveAgentRunningSubagent(
                    subagentID: current.subagentID,
                    subagentType: current.subagentType.isEmpty ? nil : current.subagentType,
                    description: current.description.isEmpty ? nil : current.description,
                    elapsedSeconds: UInt64(max(0, inputs.now.timeIntervalSince(current.startedAt)))
                ))
            }
        }

        return LiveCompactionStateSnapshot(
            editedFiles: Array(Set(inputs.editedFiles.filter {
                isWithinWorkspace($0, workingDirectory: inputs.workingDirectory)
            })).sorted(),
            activeAgentState: ActiveAgentReminderState(
                runningCommands: Array(tasks),
                todos: Array(todos),
                runningSubagents: subagents
            ),
            connectedMCPServers: inputs.connectedMCPServers.sorted { $0.name < $1.name },
            memoryContext: inputs.memoryContext,
            subagentToolNames: inputs.subagentToolNames,
            mcpToolNames: inputs.mcpToolNames
        )
    }

    static func render(_ snapshot: LiveCompactionStateSnapshot) -> String? {
        var sections: [String] = []

        let editedFiles = snapshot.editedFiles.prefix(maximumEntriesPerSection).compactMap {
            nonemptyLine($0)
        }
        if !editedFiles.isEmpty {
            let lines = editedFiles.map { "- \($0)" }.joined(separator: "\n")
            sections.append("## Files Edited This Session\n"
                + "These files were modified by you during this session:\n\(lines)")
        }

        let active = sanitizedActiveState(snapshot.activeAgentState)
        let safeTools = snapshot.subagentToolNames.flatMap { tools -> ActiveAgentSubagentToolNames? in
            guard let poll = nonemptyLine(tools.poll),
                  let cancel = nonemptyLine(tools.cancel)
            else { return nil }
            return ActiveAgentSubagentToolNames(poll: poll, cancel: cancel)
        }
        sections.append(contentsOf: ActiveAgentReminderFormatter.formatSections(
            state: active,
            subagentTools: safeTools
        ))

        let serverLines = snapshot.connectedMCPServers
            .prefix(maximumEntriesPerSection)
            .compactMap { server -> String? in
                guard let name = nonemptyLine(server.name) else { return nil }
                let count = max(0, server.toolCount)
                let toolWord = count == 1 ? "tool" : "tools"
                if let description = server.description.flatMap(nonemptyLine) {
                    return "- \(name) (\(count) \(toolWord)): \(description)"
                }
                return "- \(name) (\(count) \(toolWord))"
            }
        if !serverLines.isEmpty {
            var section = "## Connected MCP Servers\n" + serverLines.joined(separator: "\n")
            if let tools = snapshot.mcpToolNames,
               let search = nonemptyLine(tools.search),
               let call = nonemptyLine(tools.call)
            {
                section += "\nTo use MCP tools, you MUST call `\(search)` first to retrieve "
                    + "the tool's input schema before calling `\(call)`. NEVER guess parameter "
                    + "names — always use the exact schema returned by `\(search)`."
            }
            sections.append(section)
        }

        if let memory = snapshot.memoryContext,
           !memory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            sections.append(sanitizeMultiline(memory))
        }

        var bounded: [String] = []
        var used = "<system-reminder>\n\n</system-reminder>".count
        for section in sections {
            let trimmed = limit(section, to: maximumSectionCharacters)
            let separatorCost = bounded.isEmpty ? 0 : 2
            guard used + separatorCost + trimmed.count <= maximumReminderCharacters else {
                continue
            }
            bounded.append(trimmed)
            used += separatorCost + trimmed.count
        }
        return ActiveAgentReminderFormatter.wrapSystemReminder(bounded)
    }

    private static func sanitizedActiveState(
        _ state: ActiveAgentReminderState
    ) -> ActiveAgentReminderState {
        let commands = state.runningCommands.prefix(maximumEntriesPerSection).compactMap {
            task -> ActiveAgentBackgroundTask? in
            guard let id = nonemptyLine(task.taskID),
                  let command = nonemptyLine(task.command),
                  let status = nonemptyLine(task.status)
            else { return nil }
            return ActiveAgentBackgroundTask(
                taskID: id,
                command: command,
                status: status,
                toolName: task.toolName.flatMap(nonemptyLine)
            )
        }
        let todos = state.todos.prefix(maximumEntriesPerSection).compactMap {
            todo -> ActiveAgentTodoItem? in
            guard let id = nonemptyLine(todo.id),
                  let content = nonemptyLine(todo.content)
            else { return nil }
            return ActiveAgentTodoItem(id: id, content: content, status: todo.status)
        }
        let subagents = state.runningSubagents.prefix(maximumEntriesPerSection).compactMap {
            subagent -> ActiveAgentRunningSubagent? in
            guard let id = nonemptyLine(subagent.subagentID) else { return nil }
            return ActiveAgentRunningSubagent(
                subagentID: id,
                subagentType: subagent.subagentType.flatMap(nonemptyLine),
                description: subagent.description.flatMap(nonemptyLine),
                elapsedSeconds: subagent.elapsedSeconds
            )
        }
        return ActiveAgentReminderState(
            runningCommands: Array(commands),
            todos: Array(todos),
            runningSubagents: Array(subagents)
        )
    }

    private static func resolveTool(
        kind: ProductToolKind,
        fallbackNames: [String],
        advertised: Set<String>,
        toolset: FinalizedToolset
    ) -> String? {
        if let byKind = advertised.sorted().first(where: {
            toolset.toolKind(for: $0) == kind
        }) {
            return byKind
        }
        return fallbackNames.first { advertised.contains($0) }
    }

    private static func isWithinWorkspace(_ path: String, workingDirectory: URL) -> Bool {
        let root = workingDirectory.standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    private static func nonemptyLine(_ value: String) -> String? {
        let collapsed = value.split(whereSeparator: { $0.isNewline || $0.isWhitespace })
            .joined(separator: " ")
            .replacingOccurrences(of: "<", with: "‹")
            .replacingOccurrences(of: ">", with: "›")
            .replacingOccurrences(of: "`", with: "'")
        let safe = limit(redactSecrets(collapsed), to: maximumLineCharacters)
        return safe.isEmpty ? nil : safe
    }

    private static func sanitizeMultiline(_ value: String) -> String {
        let escaped = value.replacingOccurrences(
            of: "(?i)</?system-reminder\\s*>",
            with: "[removed reminder tag]",
            options: .regularExpression
        )
        return limit(redactSecrets(escaped), to: maximumSectionCharacters)
    }

    private static func redactSecrets(_ value: String) -> String {
        var redacted = value.replacingOccurrences(
            of: "(?i)(\\bbearer\\s+)[A-Za-z0-9._~+/=-]+",
            with: "$1[REDACTED]",
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: "(?i)(\\b(?:authorization|x-api-key|api[_-]?key|access[_-]?token|refresh[_-]?token|password|passwd|secret)\\b\\s*[:=]\\s*)(?:\\\"[^\\\"]*\\\"|'[^']*'|[^\\s,;]+)",
            with: "$1[REDACTED]",
            options: .regularExpression
        )
        return redacted.replacingOccurrences(
            of: "\\b(?:sk|xai|ghp|gho|github_pat|AIza)[-_][A-Za-z0-9_-]{8,}\\b",
            with: "[REDACTED]",
            options: .regularExpression
        )
    }

    private static func limit(_ value: String, to maximumCharacters: Int) -> String {
        guard value.count > maximumCharacters else { return value }
        return String(value.prefix(maximumCharacters - 1)) + "…"
    }
}
