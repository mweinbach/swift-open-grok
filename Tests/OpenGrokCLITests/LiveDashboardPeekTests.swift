// LiveDashboardPeekTests.swift
//
// Wave 18 B1-p: the composition half of the dashboard peek — which SOURCE a
// roster row's peek reads, the status vocabulary
// (`views/dashboard/peek.rs:948-1039` at pin 650c1db7), and the
// build-once/read-never cache discipline the port's disk-backed background
// rows force.
//
// The pin that matters most here is the last one: upstream re-reads a live
// in-memory scrollback every frame, which is free. This port's background
// rows are session JSON on disk, so a per-arrow read would be N decodes per
// keystroke. The cache test proves arrowing touches no disk by DELETING the
// session files and resolving peeks anyway.

import Foundation
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokCLI

private func userItem(_ text: String, synthetic: SyntheticReason? = nil) -> ConversationItem {
    .user(UserItem(content: [.text(text: text)], syntheticReason: synthetic))
}

private func assistantItem(_ text: String, toolCalls: [ToolCall] = []) -> ConversationItem {
    .assistant(AssistantItem(content: text, toolCalls: toolCalls))
}

private func record(
    _ sessionID: String,
    items: [ConversationItem],
    updatedAt: Date = Date(timeIntervalSince1970: 1_000)
) -> LiveConversationRecord {
    LiveConversationRecord(
        sessionID: sessionID,
        workingDirectory: "/tmp",
        parentSessionID: nil,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: updatedAt,
        items: items
    )
}

private func row(_ sessionID: String) -> String {
    LiveDashboardOverlay.attachPrefix + sessionID
}

private func liveUser(_ text: String) -> PagerConversationItem {
    .message(PagerMessage(role: .user, text: text))
}

private func liveAssistant(_ text: String) -> PagerConversationItem {
    .message(PagerMessage(role: .assistant, text: text))
}

private func liveTool(_ name: String) -> PagerConversationItem {
    .tool(PagerToolCard(name: name, input: "x", state: .running))
}

@Suite("Dashboard peek source")
struct LiveDashboardPeekSourceTests {
    @Test("the active row reads memory, a background row reads the cache, anything else is nil")
    func sourcePerRowKind() {
        let cache = LiveDashboardPeekCache.build(from: [
            record("bg-1", items: [userItem("disk ask"), assistantItem("disk answer")]),
            // The active session's own file is stale by construction — the
            // live items must win for its row.
            record("active-1", items: [userItem("stale disk copy")]),
        ])
        let activeItems = [liveUser("live ask"), liveAssistant("live answer")]

        let active = LiveDashboardPeek.peek(
            forRowID: row("active-1"),
            cache: cache,
            activeSessionID: "active-1",
            activeItems: activeItems,
            turnActivity: nil
        )
        #expect(active?.items == activeItems, "the active row is served from memory")

        let background = LiveDashboardPeek.peek(
            forRowID: row("bg-1"),
            cache: cache,
            activeSessionID: "active-1",
            activeItems: activeItems,
            turnActivity: nil
        )
        #expect(
            background?.items == [liveUser("disk ask"), liveAssistant("disk answer")],
            "a background row is served from the decoded record"
        )

        // A subagent child row: peek-onto-a-subagent lands with subagent
        // attach (B1 ruling §5.3), so it must resolve to nothing rather than
        // silently showing the parent's transcript.
        #expect(LiveDashboardPeek.peek(
            forRowID: "subagent:sub-1",
            cache: cache,
            activeSessionID: "active-1",
            activeItems: activeItems,
            turnActivity: nil
        ) == nil)

        // A session id the cache never saw — what a row for a session deleted
        // underneath the open modal looks like.
        #expect(LiveDashboardPeek.peek(
            forRowID: row("ghost"),
            cache: cache,
            activeSessionID: "active-1",
            activeItems: activeItems,
            turnActivity: nil
        ) == nil)
    }

    @Test("a background row is ALWAYS Idle, whatever the active turn is doing")
    func backgroundRowsAreAlwaysIdle() {
        let cache = LiveDashboardPeekCache.build(from: [
            record("bg-1", items: [userItem("ask"), assistantItem("answer")], updatedAt: Date(timeIntervalSince1970: 900)),
        ])
        let peek = LiveDashboardPeek.peek(
            forRowID: row("bg-1"),
            cache: cache,
            activeSessionID: "active-1",
            activeItems: [liveUser("busy")],
            // The ACTIVE session is mid-turn; that must not leak onto a
            // background row, which has no runtime attached at all.
            turnActivity: "Thinking\u{2026}",
            now: Date(timeIntervalSince1970: 960)
        )
        #expect(peek?.statusLabel == LiveDashboardPeek.idleStatus)
        #expect(peek?.timeAgo == LivePagerTasksBlock.formatDuration(60))
    }

    @Test("synthetic user turns are never pinned as prompts the user never typed")
    func syntheticUserTurnsAreDropped() {
        let cache = LiveDashboardPeekCache.build(from: [
            record("bg-1", items: [
                userItem("real ask"),
                userItem("<system-reminder>", synthetic: .systemReminder),
                assistantItem("answer"),
            ]),
        ])
        let items = cache.items["bg-1"] ?? []
        #expect(items == [liveUser("real ask"), liveAssistant("answer")])
    }

    @Test("an assistant turn's tool calls become cards with their results attached")
    func toolCallsPairWithResults() {
        let cache = LiveDashboardPeekCache.build(from: [
            record("bg-1", items: [
                userItem("ask"),
                assistantItem("", toolCalls: [
                    ToolCall(id: "call-1", name: "bash", arguments: "ls"),
                ]),
                .toolResult(ToolResultItem(toolCallId: "call-1", content: "a\nb")),
            ]),
        ])
        let items = cache.items["bg-1"] ?? []
        #expect(items.count == 2, "an empty assistant body contributes no message block")
        guard case .tool(let card) = items[1] else {
            Issue.record("expected a tool card, got \(items[1])")
            return
        }
        #expect(card.name == "bash")
        #expect(card.output == "a\nb")
    }
}

@Suite("Dashboard peek status vocabulary")
struct LiveDashboardPeekStatusTests {
    @Test("an idle transcript names its newest agent block")
    func idleVocabulary() {
        #expect(LiveDashboardPeek.status(
            items: [liveUser("ask"), liveAssistant("answer")],
            turnActivity: nil
        ) == "Response")

        #expect(LiveDashboardPeek.status(
            items: [liveUser("ask"), .tool(PagerToolCard(name: "bash", state: .succeeded))],
            turnActivity: nil
        ) == "Bash")

        #expect(LiveDashboardPeek.status(
            items: [liveUser("ask"), .tool(PagerToolCard(name: "read", state: .succeeded))],
            turnActivity: nil
        ) == "Read")

        #expect(LiveDashboardPeek.status(
            items: [liveUser("ask"), .message(PagerMessage(role: .reasoning, text: "hmm"))],
            turnActivity: nil
        ) == "Thought", "a finished thinking block reads `Thought`")

        // The user's latest prompt is the turn boundary: nothing before it
        // belongs to this turn (`peek.rs:1029-1031`).
        #expect(LiveDashboardPeek.status(
            items: [liveAssistant("previous answer"), liveUser("brand new ask")],
            turnActivity: nil
        ) == "Idle")

        #expect(LiveDashboardPeek.status(items: [], turnActivity: nil) == "Idle")
    }

    @Test("a running turn takes the live activity as ground truth")
    func runningVocabulary() {
        #expect(LiveDashboardPeek.status(
            items: [liveUser("ask")],
            turnActivity: "Thinking\u{2026}"
        ) == "Thinking")

        #expect(LiveDashboardPeek.status(
            items: [liveUser("ask")],
            turnActivity: "Responding\u{2026}"
        ) == "Response")

        // A tool name (LiveComposition's `turnActivity = tool.name`) is
        // upstream's `ToolRunning`: fall through to the scan and recover the
        // specific label.
        #expect(LiveDashboardPeek.status(
            items: [liveUser("ask"), liveTool("bash")],
            turnActivity: "bash"
        ) == "Bash")

        // A pending permission is not its own status here (question mode is
        // deferred); it falls through the same way and the running tool wins.
        #expect(LiveDashboardPeek.status(
            items: [liveUser("ask"), liveTool("bash")],
            turnActivity: "Permission required: run ls"
        ) == "Bash")
    }

    /// THE reason the running arm exists (`peek.rs:960-968`): once the agent
    /// has moved past its last message into tool execution, a scrollback scan
    /// alone would keep reporting the stale `Response` — the peek would claim
    /// the agent had answered while it was still working.
    @Test("a running turn never dwells on a stale Response")
    func runningNeverShowsStaleResponse() {
        let items = [liveUser("ask"), liveAssistant("an answer from earlier in the turn")]
        #expect(
            LiveDashboardPeek.status(items: items, turnActivity: "bash") == "Working",
            "a stale message must not outrank the live activity"
        )
        #expect(
            LiveDashboardPeek.status(items: items, turnActivity: nil) == "Response",
            "the same transcript IS a Response once the turn ends"
        )
    }
}

@Suite("Dashboard peek cache")
struct LiveDashboardPeekCacheTests {
    /// The cache is built ONCE, at `/dashboard` time, from a single
    /// `catalog.records()` pass. Arrowing the roster must not read disk: the
    /// proof here is that the files are gone by the time the peeks resolve.
    @Test("built once from one records() pass; arrowing reads no disk")
    func builtOnceAndReadNever() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peek-cache-\(UUID().uuidString)", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let encoder = JSONEncoder()
        let ids = ["s-1", "s-2", "s-3"]
        for id in ids {
            let data = try encoder.encode(record(id, items: [
                userItem("ask in \(id)"),
                assistantItem("answer in \(id)"),
            ]))
            try data.write(to: sessions.appendingPathComponent("\(id).json"))
        }

        let catalog = LiveSessionCatalog(openGrokHome: home)
        let cache = LiveDashboardPeekCache.build(from: try catalog.records())
        #expect(cache.items.count == ids.count, "one decode per session file, no more")

        // Everything the cursor could reach is now resolvable WITHOUT the
        // store that produced it.
        try FileManager.default.removeItem(at: sessions)
        for id in ids {
            let peek = LiveDashboardPeek.peek(
                forRowID: row(id),
                cache: cache,
                activeSessionID: "not-a-tab",
                activeItems: [],
                turnActivity: nil
            )
            #expect(peek != nil, "\(id) still resolves with the store gone")
            #expect(peek?.items.first == liveUser("ask in \(id)"))
            #expect(peek?.statusLabel == LiveDashboardPeek.idleStatus)
        }
    }

    @Test("an unreadable session file is skipped, not fatal")
    func undecodableFilesAreSkipped() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peek-cache-\(UUID().uuidString)", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try JSONEncoder()
            .encode(record("good", items: [userItem("ask")]))
            .write(to: sessions.appendingPathComponent("good.json"))
        try Data("{ not json".utf8)
            .write(to: sessions.appendingPathComponent("broken.json"))

        let catalog = LiveSessionCatalog(openGrokHome: home)
        let cache = LiveDashboardPeekCache.build(from: try catalog.records())
        #expect(cache.items.keys.sorted() == ["good"])
    }
}
