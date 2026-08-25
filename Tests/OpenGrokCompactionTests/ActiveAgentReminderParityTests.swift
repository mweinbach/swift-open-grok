import OpenGrokCompaction
import Testing

@Suite("Active-agent compaction reminder parity")
struct ActiveAgentReminderParityTests {
    @Test("background tasks preserve upstream wording and resolved tool names")
    func backgroundTasksMatchRust() {
        let rendered = ActiveAgentReminderFormatter.backgroundTasksSection([
            ActiveAgentBackgroundTask(
                taskID: "task-1",
                command: "swift test",
                toolName: "run_terminal_cmd"
            ),
            ActiveAgentBackgroundTask(taskID: "task-2", command: "npm run dev"),
        ])

        #expect(rendered == """
        ## Running Background Tasks
        These tasks are still running:
        - "task-1": `swift test` (running, run_terminal_cmd)
        - "task-2": `npm run dev` (running)
        """)
    }

    @Test("only actionable todos render while terminal states become count trailers")
    func actionableTodosMatchRust() {
        let rendered = ActiveAgentReminderFormatter.todoListSection([
            ActiveAgentTodoItem(id: "one", content: "Inspect upstream", status: .pending),
            ActiveAgentTodoItem(id: "two", content: "Ship the port", status: .inProgress),
            ActiveAgentTodoItem(id: "three", content: "hidden completed text", status: .completed),
            ActiveAgentTodoItem(id: "four", content: "hidden cancelled text", status: .cancelled),
        ])

        #expect(rendered == """
        ## TODO List
        This is your task list from before the conversation was compacted — it is still active. Keep working through the items below and update their status as you make progress:
        - [pending] one: Inspect upstream
        - [in_progress] two: Ship the port
        (1 completed, 1 cancelled)
        """)
        #expect(rendered?.contains("hidden completed text") == false)
        #expect(rendered?.contains("hidden cancelled text") == false)
    }

    @Test("completed-only or cancelled-only state never fabricates a TODO section")
    func nonActionableTodosAreSilent() {
        let state = ActiveAgentReminderState(todos: [
            ActiveAgentTodoItem(id: "done", content: "already complete", status: .completed),
            ActiveAgentTodoItem(id: "cancelled", content: "discarded", status: .cancelled),
        ])

        #expect(state.isEmpty)
        #expect(!state.hasActionableTodos)
        #expect(ActiveAgentReminderFormatter.todoListSection(state.todos) == nil)
        #expect(ActiveAgentReminderFormatter.formatReminder(state: state) == nil)
    }

    @Test("running subagents require actually resolved poll and cancel tool names")
    func subagentsRequireResolvedTools() {
        let state = ActiveAgentReminderState(runningSubagents: [
            ActiveAgentRunningSubagent(
                subagentID: "agent-4",
                subagentType: "explore",
                description: "find files",
                elapsedSeconds: 5
            ),
        ])

        #expect(ActiveAgentReminderFormatter.formatReminder(state: state) == nil)
        #expect(ActiveAgentReminderFormatter.formatReminder(
            state: state,
            subagentTools: ActiveAgentSubagentToolNames(
                poll: "get_command_or_subagent_output",
                cancel: "kill_command_or_subagent"
            )
        ) == """
        <system-reminder>
        ## Running Subagents
        These subagents were launched before this compaction and are still running. Use `get_command_or_subagent_output` with the subagent_id to check their status or retrieve results. Use `kill_command_or_subagent` with the subagent_id to cancel a subagent.
        - subagent_id: `agent-4`, type: `explore`, task: "find files" (running for 5s)
        </system-reminder>
        """)
    }

    @Test("sections remain ordered background tasks then todos then subagents")
    func sectionOrderingAndWrapperMatchRust() {
        let state = ActiveAgentReminderState(
            runningCommands: [ActiveAgentBackgroundTask(taskID: "job", command: "build")],
            todos: [ActiveAgentTodoItem(id: "todo", content: "ship", status: .pending)],
            runningSubagents: [ActiveAgentRunningSubagent(subagentID: "child")]
        )
        let rendered = ActiveAgentReminderFormatter.formatReminder(
            state: state,
            subagentTools: ActiveAgentSubagentToolNames(poll: "poll", cancel: "cancel")
        )
        let background = rendered?.range(of: "## Running Background Tasks")?.lowerBound
        let todos = rendered?.range(of: "## TODO List")?.lowerBound
        let subagents = rendered?.range(of: "## Running Subagents")?.lowerBound

        #expect(background != nil)
        #expect(todos != nil)
        #expect(subagents != nil)
        if let background, let todos, let subagents {
            #expect(background < todos)
            #expect(todos < subagents)
        }
        #expect(rendered?.hasPrefix("<system-reminder>\n") == true)
        #expect(rendered?.hasSuffix("\n</system-reminder>") == true)
    }

    @Test("empty wrapper and blank append blocks are omitted")
    func emptyBlocksStayEmpty() {
        #expect(ActiveAgentReminderFormatter.wrapSystemReminder(["", " \n "]) == nil)
        #expect(ActiveAgentReminderFormatter.appendReminderBlock("summary", reminder: nil)
            == "summary")
        #expect(ActiveAgentReminderFormatter.appendReminderBlock("summary", reminder: " \n ")
            == "summary")
        #expect(ActiveAgentReminderFormatter.appendReminderBlock("summary", reminder: "active")
            == "summary\n\nactive")
    }
}
