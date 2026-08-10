// LiveDashboardPeek.swift
//
// Wave 18 B1-p: the composition half of the dashboard peek — what fills
// `PagerDashboardPeek` for whichever roster row the cursor is on. Upstream
// counterpart at pin 650c1db7: `views/dashboard/peek.rs`
// (`compute_peek_fields` :238-377, `extract_last_response_type` :948-1039)
// reading a leased in-memory `ScrollbackState`.
//
// THE DIVERGENCE THAT SHAPES THIS FILE: upstream runs N live agents, so
// every peeked row has an in-memory scrollback and a live turn activity.
// This port runs ONE agent stack; a background roster row is a session FILE
// (`$OPENGROK_HOME/sessions/<id>.json`), idle by construction. So there are
// exactly two sources:
//
//   * the ACTIVE row  → the live `items` + the live `turnActivity`, full
//     ground truth, recomputed on every refresh;
//   * a BACKGROUND row → its decoded transcript, status always `"Idle"` —
//     not a guess but a fact of the single-runtime architecture;
//   * anything else (a subagent child row, an id the cache never saw) → nil,
//     no peek. The subagent peek lands with subagent attach (B1 ruling §5.3):
//     peeking a row Enter cannot open is a dead end.
//
// The disk pass happens ONCE, when the dashboard opens. Upstream can afford
// a per-frame read because its source is memory; here a per-arrow read would
// be N JSON decodes per keystroke. Background tabs are idle, so a snapshot
// taken at open cannot go stale while the modal is up.

import Foundation
import OpenGrokPagerRender
import OpenGrokSamplingTypes

/// Every background session's transcript, decoded once at `/dashboard` time.
///
/// A value type on purpose: the composition hands it to the resolver by
/// copy, so no arrow key can accidentally trigger I/O through it.
struct LiveDashboardPeekCache: Sendable, Equatable {
    /// Session id → its transcript, projected into render items.
    private(set) var items: [String: [PagerConversationItem]]
    /// Session id → the record's `updatedAt`, the peek's time-ago source.
    private(set) var lastActivity: [String: Date]

    init(
        items: [String: [PagerConversationItem]] = [:],
        lastActivity: [String: Date] = [:]
    ) {
        self.items = items
        self.lastActivity = lastActivity
    }

    /// Build from one `catalog.records()` pass
    /// (`LiveSessionsComposition.swift:135-153`).
    static func build(from records: [LiveConversationRecord]) -> LiveDashboardPeekCache {
        var items: [String: [PagerConversationItem]] = [:]
        var lastActivity: [String: Date] = [:]
        items.reserveCapacity(records.count)
        lastActivity.reserveCapacity(records.count)
        for record in records {
            items[record.sessionID] = peekItems(from: record.items)
            lastActivity[record.sessionID] = record.updatedAt
        }
        return LiveDashboardPeekCache(items: items, lastActivity: lastActivity)
    }

    /// Project a persisted transcript into render items.
    ///
    /// This mirrors `LivePagerConversationState.seed(from:)`
    /// (`LiveComposition.swift:7412-7477`) — the same projection `/resume`
    /// paints — rather than calling it: that type is file-private to
    /// `LiveComposition.swift` and its `seed` is a mutating method on a live
    /// streaming state (tool-call indices, an active assistant cursor) this
    /// read-only path has no business constructing.
    ///
    /// Deliberately NOT carried over: markdown styling. `seed` renders
    /// assistant prose through `PagerMarkdownRenderer` for the full
    /// transcript; the peek is a dense tail whose blocks are one line each,
    /// and paying a markdown parse per background session at open time would
    /// put the whole roster's transcripts through the renderer to show a
    /// handful of rows. Plain text degrades exactly the way `PagerMessage`
    /// documents (empty `styledLines` → paint `text` verbatim).
    static func peekItems(from conversationItems: [ConversationItem]) -> [PagerConversationItem] {
        var resultsByCallID: [String: String] = [:]
        for item in conversationItems {
            if case .toolResult(let result) = item {
                resultsByCallID[result.toolCallId] = result.content
            }
        }
        var items: [PagerConversationItem] = []
        for item in conversationItems {
            switch item {
            case .user(let user):
                // Synthetic turn-starters (scheduler fires, queue drains) are
                // provider plumbing and are not painted live either — a peek
                // that pinned one would show the user a prompt they never
                // typed.
                guard user.syntheticReason == nil else { continue }
                let text = user.content.compactMap { part -> String? in
                    if case .text(let value) = part { return value }
                    return nil
                }.joined(separator: "\n")
                guard !text.isEmpty else { continue }
                items.append(.message(PagerMessage(role: .user, text: text)))
            case .assistant(let assistant):
                if !assistant.content.isEmpty {
                    items.append(.message(PagerMessage(
                        role: .assistant,
                        text: assistant.content
                    )))
                }
                for call in assistant.toolCalls {
                    items.append(.tool(PagerToolCard(
                        name: call.name,
                        input: call.arguments,
                        output: resultsByCallID[call.id],
                        state: .succeeded
                    )))
                }
            case .system, .toolResult, .customToolOutput, .backendToolCall, .reasoning:
                continue
            }
        }
        return items
    }
}

enum LiveDashboardPeek {
    /// The status a background row always shows. Upstream would compute this
    /// from the row's live agent; here a non-active tab has no runtime
    /// attached, so `"Idle"` is `extract_last_response_type`'s own
    /// not-running fallback (`peek.rs:1035-1038`) reached the honest way.
    static let idleStatus = "Idle"

    /// Resolve the peek for one roster row, or nil when the row has none.
    ///
    /// `rowID` is the roster's own id (`LiveDashboardOverlay.attachPrefix +
    /// sessionID` for a session, `subagent:<id>` for a child row). Anything
    /// that is not an attachable session resolves to nil — including a
    /// session id the cache never saw, which is what a row for a session
    /// deleted underneath the open modal looks like.
    ///
    /// DIVERGENCE from the research contract's signature: no `width`/`height`
    /// parameters. `PagerDashboardPeek` carries ITEMS, and the dense tail is
    /// laid out at paint width inside the band, so geometry here would be a
    /// second, staler copy of the modal's — the exact drift the render side's
    /// measure/paint pairing exists to prevent.
    static func peek(
        forRowID rowID: String,
        cache: LiveDashboardPeekCache,
        activeSessionID: String,
        activeItems: [PagerConversationItem],
        activeLastActivity: Date? = nil,
        turnActivity: String?,
        now: Date = Date()
    ) -> PagerDashboardPeek? {
        guard rowID.hasPrefix(LiveDashboardOverlay.attachPrefix) else { return nil }
        let sessionID = String(rowID.dropFirst(LiveDashboardOverlay.attachPrefix.count))
        guard !sessionID.isEmpty else { return nil }

        if sessionID == activeSessionID {
            return PagerDashboardPeek(
                statusLabel: status(items: activeItems, turnActivity: turnActivity),
                timeAgo: timeAgo(
                    from: activeLastActivity ?? cache.lastActivity[sessionID],
                    now: now
                ),
                items: activeItems
            )
        }
        guard let items = cache.items[sessionID] else { return nil }
        return PagerDashboardPeek(
            statusLabel: idleStatus,
            timeAgo: timeAgo(from: cache.lastActivity[sessionID], now: now),
            items: items
        )
    }

    /// `format_duration` (`util.rs:81-97`) against the row's last change —
    /// the same elapsed formatter the tasks pane and the roster's detail
    /// column already use, so the three read as one vocabulary. An unknown
    /// instant paints nothing: the status row drops the time column rather
    /// than showing an age it does not know.
    static func timeAgo(from date: Date?, now: Date) -> String {
        guard let date else { return "" }
        return LivePagerTasksBlock.formatDuration(max(0, now.timeIntervalSince(date)))
    }

    /// `extract_last_response_type` (`peek.rs:948-1039`).
    ///
    /// While a turn RUNS the live activity is ground truth for what the agent
    /// is doing right now. Driving the label from it — instead of only from a
    /// scrollback scan — is what stops the peek dwelling on the previous,
    /// now-stale `Response` after the agent has moved into tool execution
    /// (`peek.rs:960-968`).
    ///
    /// This port's `turnActivity` is the composition's status STRING
    /// (`LiveComposition.swift:9176,9388,9396-9430`), not upstream's
    /// `TurnActivity` enum, so the arms match on its prefixes. A tool name or
    /// a `Permission required: …` string falls through to the scan exactly as
    /// upstream's `ToolRunning` arm does, recovering the specific tool label;
    /// a missing or stale block yields the generic `"Working"`.
    static func status(items: [PagerConversationItem], turnActivity: String?) -> String {
        let running = turnActivity != nil
        if let activity = turnActivity {
            if activity.hasPrefix("Thinking") { return "Thinking" }
            if activity.hasPrefix("Responding") { return "Response" }
            if activity.hasPrefix("Compacting") { return "Compacting" }
            if activity.hasPrefix("Retrying") { return "Retrying" }
            // else: ToolRunning — fall through to the scan.
        }
        for item in items.reversed() {
            switch item {
            case .message(let message):
                switch message.role {
                case .assistant:
                    // Idle → the newest message IS the result. While running
                    // we only reach here in the tool arm, where a message is
                    // stale: skip it and let a newer tool label or the
                    // "Working" fallback win (`peek.rs:975-985`).
                    if running { return workingOrIdle(running) }
                    return "Response"
                case .reasoning:
                    return running ? "Thinking" : "Thought"
                case .user:
                    // The user's latest input marks the turn boundary — there
                    // is no agent response after it yet (`peek.rs:1029-1031`).
                    return workingOrIdle(running)
                case .system, .error:
                    // Structural blocks carry no response type; keep scanning.
                    continue
                }
            case .tool(let tool):
                return label(for: tool.kind)
            case .separator:
                continue
            }
        }
        return workingOrIdle(running)
    }

    private static func workingOrIdle(_ running: Bool) -> String {
        running ? "Working" : idleStatus
    }

    /// The tool-label table (`peek.rs:995-1012`), mapped onto the port's
    /// `PagerToolKind`. `.create` folds into `Edit`: upstream has no separate
    /// create block — a file write is an `Edit` there.
    private static func label(for kind: PagerToolKind) -> String {
        switch kind {
        case .execute: return "Bash"
        case .read: return "Read"
        case .edit, .create: return "Edit"
        case .list: return "List"
        case .search: return "Search"
        case .fetch: return "Fetch"
        case .webSearch: return "Web search"
        case .generic: return "Tool"
        }
    }
}
