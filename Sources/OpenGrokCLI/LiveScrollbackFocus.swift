import Foundation
import OpenGrokCompaction
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokShared

/// The scrollback's selection cursor and every effect the `ScrollbackFocused`
/// bindings have on the transcript.
///
/// The reference keeps this in `scrollback/state/` and reaches it from
/// `When::ScrollbackFocused` (`actions/defaults.rs:84-460`). Here the
/// controller owns the focus and the key mapping and the render layer owns the
/// blocks, so the whole effect surface lives on this one value: it is handed
/// the item array, mutates it in place, and reports what the user should be
/// told. Keeping it out of the frame renderer is deliberate — it is pure and
/// testable, and the renderer only has to hold an index.
struct LiveScrollbackSelection: Sendable {
    /// Index into the conversation, or nil while the composer holds focus.
    private(set) var index: Int?

    /// Markdown renderings stashed by `toggleRaw`, keyed by block index, so
    /// toggling back restores the exact styling instead of needing the markdown
    /// renderer a second time.
    private var stashedStyledLines: [Int: [PagerStyledLine]] = [:]

    init() {}

    var isFocused: Bool { index != nil }

    /// Take focus, landing on the newest block — which is where the user is
    /// looking when they press Tab.
    mutating func focus(itemCount: Int) {
        guard itemCount > 0 else {
            index = 0
            return
        }
        index = min(index ?? itemCount - 1, itemCount - 1)
    }

    /// Click-to-select: focus a specific block, clamped into the conversation.
    /// Unlike `focus`, this always lands on `index` (when the transcript is
    /// non-empty) rather than preserving a prior cursor — the mouse hit is
    /// authoritative. Empty transcripts still park at 0 so the focus flag
    /// stays meaningful for the composer unfocus paint path.
    mutating func select(at index: Int, itemCount: Int) {
        guard itemCount > 0 else {
            self.index = 0
            return
        }
        self.index = min(max(0, index), itemCount - 1)
    }

    mutating func unfocus() {
        index = nil
    }

    /// Keep the cursor inside the array as the transcript grows or a block is
    /// removed underneath it.
    mutating func clamp(itemCount: Int) {
        guard let current = index else { return }
        guard itemCount > 0 else {
            index = 0
            return
        }
        index = min(current, itemCount - 1)
    }

    /// What the caller should do after applying a command.
    struct Outcome: Sendable, Equatable {
        /// A line for the transcript, or nil when the movement speaks for
        /// itself.
        var notice: String?
        /// Text the caller should put on the clipboard.
        var clipboard: String?
        /// A URL the caller should hand to the platform opener.
        var url: String?
        /// Whether the viewport should be pulled to the selection.
        var revealsSelection: Bool

        init(
            notice: String? = nil,
            clipboard: String? = nil,
            url: String? = nil,
            revealsSelection: Bool = true
        ) {
            self.notice = notice
            self.clipboard = clipboard
            self.url = url
            self.revealsSelection = revealsSelection
        }
    }

    mutating func apply(
        _ command: OpenGrokPagerScrollbackCommand,
        items: inout [PagerConversationItem]
    ) -> Outcome {
        guard !items.isEmpty else { return Outcome(revealsSelection: false) }
        let current = index ?? items.count - 1

        switch command {
        case .selectNext:
            index = min(current + 1, items.count - 1)
            return Outcome()
        case .selectPrevious:
            index = max(current - 1, 0)
            return Outcome()
        case .selectFirst:
            index = 0
            return Outcome()
        case .selectLast:
            index = items.count - 1
            return Outcome()
        case .nextTurn:
            index = Self.step(from: current, in: items, forward: true) { $0.isTurnBoundary }
            return Outcome()
        case .previousTurn:
            index = Self.step(from: current, in: items, forward: false) { $0.isTurnBoundary }
            return Outcome()
        case .nextResponse:
            index = Self.step(from: current, in: items, forward: true) { $0.isAssistantResponse }
            return Outcome()
        case .previousResponse:
            index = Self.step(from: current, in: items, forward: false) { $0.isAssistantResponse }
            return Outcome()

        case .collapse:
            setFold(collapsed: true, at: current, items: &items)
            return Outcome()
        case .expand:
            setFold(collapsed: false, at: current, items: &items)
            return Outcome()
        case .toggleFold:
            setFold(collapsed: !items[current].isFolded, at: current, items: &items)
            return Outcome()
        case .toggleExpandAll:
            // `E` collapses everything when anything is open, and opens
            // everything otherwise (`defaults.rs:313`).
            let shouldCollapse = items.contains { $0.isFoldable && !$0.isFolded }
            for position in items.indices where items[position].isFoldable {
                setFold(collapsed: shouldCollapse, at: position, items: &items)
            }
            return Outcome(notice: shouldCollapse ? "Collapsed every block." : "Expanded every block.")
        case .expandAllThinking:
            var anyClosed = false
            for position in items.indices {
                guard case .message(let message) = items[position],
                      message.role == .reasoning else { continue }
                if message.isCollapsed { anyClosed = true }
            }
            for position in items.indices {
                guard case .message(var message) = items[position],
                      message.role == .reasoning else { continue }
                message.isCollapsed = !anyClosed
                items[position] = .message(message)
            }
            return Outcome(notice: anyClosed ? "Expanded all thinking." : "Collapsed all thinking.")

        case .toggleRaw:
            return toggleRaw(at: current, items: &items)

        case .copyBlockContent:
            let text = Self.content(of: items[current])
            guard !text.isEmpty else {
                return Outcome(notice: "Nothing to copy in that block.")
            }
            return Outcome(notice: "Copied \(text.count) characters.", clipboard: text)
        case .copyBlockMetadata:
            guard let meta = Self.metadata(of: items[current]) else {
                return Outcome(notice: "That block has no command or path to copy.")
            }
            return Outcome(notice: "Copied \(meta)", clipboard: meta)

        case .openBlockViewer:
            // The viewer is the text modal the overlay layer already builds;
            // the caller pushes it, because only it owns the overlay stack.
            return Outcome()

        case .openNextLink, .openPreviousLink:
            let links = Self.links(in: items[current])
            guard !links.isEmpty else {
                return Outcome(notice: "No links in that block.")
            }
            let target = command == .openNextLink ? links[0] : links[links.count - 1]
            return Outcome(notice: "Opening \(target)", url: target)

        case .killBackgroundTask:
            guard case .tool(let tool) = items[current], tool.state == .running else {
                return Outcome(notice: "That block is not a running task.")
            }
            return Outcome(notice: "No background-task registry in this build — \(tool.name) is running in the turn.")
        }
    }

    // MARK: - Fold

    private mutating func setFold(
        collapsed: Bool,
        at position: Int,
        items: inout [PagerConversationItem]
    ) {
        guard items.indices.contains(position) else { return }
        switch items[position] {
        case .tool(var tool):
            tool.isExpanded = !collapsed
            items[position] = .tool(tool)
        case .message(var message):
            guard message.role == .reasoning || message.role == .system else { return }
            message.isCollapsed = collapsed
            items[position] = .message(message)
        case .separator:
            break
        }
    }

    /// `r` — show the block's source instead of its rendering.
    ///
    /// The frame painter already falls back to `text` when `styledLines` is
    /// empty, so raw mode is exactly "drop the styling". The stash is what
    /// makes it a toggle rather than a one-way door.
    private mutating func toggleRaw(
        at position: Int,
        items: inout [PagerConversationItem]
    ) -> Outcome {
        guard case .message(var message) = items[position] else {
            return Outcome(notice: "Only messages have a rendered and a raw form.")
        }
        if let stashed = stashedStyledLines.removeValue(forKey: position) {
            message.styledLines = stashed
            items[position] = .message(message)
            return Outcome(notice: "Rendered.")
        }
        guard !message.styledLines.isEmpty else {
            return Outcome(notice: "That block has no rendering to strip.")
        }
        stashedStyledLines[position] = message.styledLines
        message.styledLines = []
        items[position] = .message(message)
        return Outcome(notice: "Raw.")
    }

    // MARK: - Traversal

    /// The next index in `direction` whose item satisfies `predicate`, or the
    /// current one when there is none — movement clamps, it does not wrap.
    private static func step(
        from current: Int,
        in items: [PagerConversationItem],
        forward: Bool,
        where predicate: (PagerConversationItem) -> Bool
    ) -> Int {
        let candidates = forward
            ? Array((current + 1)..<items.count)
            : Array((0..<current).reversed())
        return candidates.first { predicate(items[$0]) } ?? current
    }

    // MARK: - Extraction

    static func content(of item: PagerConversationItem) -> String {
        switch item {
        case .message(let message):
            return message.text
        case .tool(let tool):
            return tool.output ?? tool.input
        case .separator(let text):
            return text
        }
    }

    /// `Y` copies the command or path a block was *about*, not its body —
    /// upstream's "copy command / path" (`defaults.rs:373`).
    static func metadata(of item: PagerConversationItem) -> String? {
        switch item {
        case .tool(let tool):
            return tool.input.isEmpty ? nil : tool.input
        case .message, .separator:
            return nil
        }
    }

    /// Bare `http`/`https` URLs in reading order.
    static func links(in item: PagerConversationItem) -> [String] {
        let text = content(of: item)
        guard !text.isEmpty else { return [] }
        var found: [String] = []
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]{}\"'`,.;:"))
            guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { continue }
            found.append(trimmed)
        }
        return found
    }

    /// The first block whose text contains `query`, case-insensitively — what
    /// `/find` selects.
    static func firstMatch(for query: String, in items: [PagerConversationItem]) -> Int? {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return nil }
        return items.firstIndex { content(of: $0).lowercased().contains(needle) }
    }
}

private extension PagerConversationItem {
    /// A turn begins at a user prompt.
    var isTurnBoundary: Bool {
        if case .message(let message) = self { return message.role == .user }
        return false
    }

    var isAssistantResponse: Bool {
        if case .message(let message) = self { return message.role == .assistant }
        return false
    }

    /// Whether `h`/`l`/`e` have anything to act on.
    var isFoldable: Bool {
        switch self {
        case .tool: return true
        case .message(let message): return message.role == .reasoning || message.role == .system
        case .separator: return false
        }
    }

    var isFolded: Bool {
        switch self {
        case .tool(let tool): return !tool.isExpanded
        case .message(let message): return message.isCollapsed
        case .separator: return true
        }
    }
}

// MARK: - Context report

/// `/context` — the session's real token accounting, laid out as text.
///
/// Separate from the renderer so it is pure and testable: it takes the same
/// `ContextUsage` auto-compaction decides on and formats it, with no I/O and no
/// actor isolation.
enum LivePagerContextReport {
    static func lines(usage: ContextUsage, itemCount: Int) -> [PagerStyledLine] {
        let used = usage.usedTokens
        let window = usage.contextWindow
        // `percentUsed` rather than a local computation: it truncates on
        // purpose, so a readout never rounds 99.6% up to a reassuring 100.
        // Two places computing this differently is how they drift apart.
        let percent = usage.percentUsed

        var rows = [
            "Model              \(usage.modelID)",
            "Blocks             \(itemCount)",
            "",
            "Used               \(format(used)) of \(format(window)) tokens (\(percent)%)",
            bar(used: used, of: window),
            "",
            "Compacts at        \(format(usage.triggerTokenLimit)) tokens (\(usage.budgetSource))",
            "Compacts down to   \(format(usage.targetTokenLimit)) tokens",
            "Compacted so far   \(usage.compactionCount)\(usage.compactionCount == 1 ? " time" : " times")"
        ]
        if let remaining = usage.compactionsRemaining {
            rows.append("Compactions left   \(remaining)")
        }
        if usage.willCompactOnNextTurn {
            rows.append("")
            rows.append("Over budget — the next turn will compact first.")
        }
        return rows.map { PagerStyledLine(text: $0) }
    }

    /// Thousands separators, because a bare `184320` is hard to compare
    /// against a window at a glance.
    private static func format(_ value: UInt64) -> String {
        let digits = String(value)
        guard digits.count > 3 else { return digits }
        var out: [Character] = []
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return String(out.reversed())
    }

    private static func bar(used: UInt64, of window: UInt64, width: Int = 40) -> String {
        guard window > 0 else { return "" }
        let ratio = min(1.0, Double(used) / Double(window))
        let filled = Int((ratio * Double(width)).rounded())
        return "  [" + String(repeating: "█", count: filled)
            + String(repeating: "·", count: max(0, width - filled)) + "]"
    }
}

// MARK: - Clipboard

/// Put text on the user's clipboard from inside the alt screen.
///
/// OSC 52 rather than a subprocess: it is the only mechanism that also works
/// over SSH and inside tmux, which is exactly where a TUI's copy is most
/// needed, and it costs one write to the sink already in hand.
enum LivePagerClipboard {
    static func copy(
        _ text: String,
        to write: (Data) throws -> Void,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let insideTmux = environment["TMUX"] != nil
        try write(osc52Sequence(text: text, tmuxPassthrough: insideTmux))
    }

    /// A `/copy` or `/export` destination, relative to the session's directory.
    static func resolve(_ path: String, relativeTo workingDirectory: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .appendingPathComponent(expanded)
            .standardizedFileURL
    }
}
