import Foundation
import OpenGrokPager
import OpenGrokPagerRender

/// Content builders for the overlays the live renderer presents.
///
/// Kept apart from `LiveComposition` so the renderer actor stays a dispatcher:
/// every function here is pure, which is also what makes them testable without
/// standing up a terminal.
enum LivePagerOverlayText {
    /// Collapse a prompt to one row, since list rows are single-line.
    static func singleLine(_ text: String) -> String {
        let flattened = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flattened.isEmpty ? text.trimmingCharacters(in: .whitespaces) : flattened
    }

    /// The command palette's fallback rows, parsed out of the controller's own
    /// help text so the palette cannot drift from `/help`.
    static func commandRows() -> [PagerListRow] {
        OpenGrokPagerInteractiveController.helpText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("/") else { return nil }
                // `  /model [name]  /m         Switch the active model`
                // Columns are separated by runs of two-or-more spaces. The
                // leading `/`-prefixed columns are the command and its aliases;
                // whatever follows is the description.
                let parts = trimmed.components(separatedBy: "  ")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                guard let head = parts.first else { return nil }
                let aliases = parts.dropFirst().prefix { $0.hasPrefix("/") }
                let summary = parts.dropFirst(1 + aliases.count).joined(separator: " ")
                let label = ([head] + aliases).joined(separator: "  ")
                let name = head.split(separator: " ").first.map(String.init) ?? head
                return PagerListRow(
                    id: name,
                    label: label,
                    summary: summary.isEmpty ? nil : summary
                )
            }
    }

    static func sessionInfoLines(
        workingDirectory: String,
        modelName: String,
        itemCount: Int,
        queuedPromptCount: Int,
        modes: OpenGrokPagerInputModes
    ) -> [PagerStyledLine] {
        var modeFlags: [String] = []
        if modes.isMultiline { modeFlags.append("multiline") }
        if modes.isVimMode { modeFlags.append("vim") }
        if modes.enterSteers { modeFlags.append("enter-steers") }
        if modes.combineQueuedPrompts { modeFlags.append("combine-queued") }

        return [
            field("Model", modelName),
            field("Directory", workingDirectory),
            field("Transcript", "\(itemCount) block\(itemCount == 1 ? "" : "s")"),
            field("Queued", "\(queuedPromptCount)"),
            field("Modes", modeFlags.isEmpty ? "default" : modeFlags.joined(separator: ", "))
        ]
    }

    /// What the renderer can actually observe. It is not told the sampler's
    /// token accounting, so this reports transcript size rather than inventing
    /// a context percentage.
    static func contextLines(
        modelName: String,
        itemCount: Int,
        transcriptCharacters: Int
    ) -> [PagerStyledLine] {
        [
            field("Model", modelName),
            field("Blocks", "\(itemCount)"),
            field("Transcript", "\(transcriptCharacters) characters"),
            PagerStyledLine(text: ""),
            PagerStyledLine(
                text: "Token accounting is not reported to the renderer yet, so this",
                foreground: nil
            ),
            PagerStyledLine(text: "shows transcript size rather than context usage.")
        ]
    }

    /// The `index`-th assistant response counting back from the end, 1-based —
    /// `/copy 2` is "the one before last", matching upstream.
    static func assistantResponse(
        fromLast index: Int,
        in items: [PagerConversationItem]
    ) -> String? {
        guard index >= 1 else { return nil }
        var seen = 0
        for item in items.reversed() {
            guard case .message(let message) = item, message.role == .assistant else { continue }
            seen += 1
            if seen == index { return message.text }
        }
        return nil
    }

    /// Transcript lines containing `query`, case-insensitively, as list rows.
    static func search(_ query: String, in items: [PagerConversationItem]) -> [PagerListRow] {
        let needle = query.lowercased()
        var rows: [PagerListRow] = []
        for (index, item) in items.enumerated() {
            guard case .message(let message) = item else { continue }
            for (lineIndex, line) in message.text.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).enumerated() {
                guard line.lowercased().contains(needle) else { continue }
                rows.append(PagerListRow(
                    id: "match-\(index)-\(lineIndex)",
                    label: singleLine(String(line)),
                    detail: roleLabel(message.role)
                ))
            }
        }
        return rows
    }

    static func shortcutsLines() -> [PagerStyledLine] {
        section("Composer", [
            ("Enter", "send, or queue while a turn runs"),
            ("Shift+Enter", "newline in multiline mode"),
            ("Tab", "focus the transcript"),
            ("Esc", "cancel a turn, or clear the draft"),
            ("Ctrl+C", "cancel, then quit"),
            ("Ctrl+M", "toggle multiline")
        ]) + [PagerStyledLine(text: "")] + section("Transcript", [
            ("↑ / ↓", "scroll a line"),
            ("PgUp / PgDn", "scroll a page"),
            ("Ctrl+U / Ctrl+D", "scroll a half page"),
            ("g / G", "top / bottom")
        ]) + [PagerStyledLine(text: "")] + section("Overlays", [
            ("Ctrl+P", "command palette"),
            ("Ctrl+.", "this cheatsheet"),
            ("↑ / ↓", "move the selection"),
            ("Enter", "choose"),
            ("Esc", "dismiss")
        ])
    }

    static func tutorialLines() -> [PagerStyledLine] {
        [
            PagerStyledLine(text: "Getting started", style: [.bold]),
            PagerStyledLine(text: ""),
            PagerStyledLine(text: "1. Type a request and press Enter."),
            PagerStyledLine(text: "2. While a turn runs, Enter queues a follow-up."),
            PagerStyledLine(text: "3. Esc cancels the turn; Esc again clears the draft."),
            PagerStyledLine(text: "4. Tab moves focus to the transcript to scroll it."),
            PagerStyledLine(text: ""),
            PagerStyledLine(text: "Useful commands", style: [.bold]),
            PagerStyledLine(text: "  /model     switch the active model"),
            PagerStyledLine(text: "  /find      search the transcript"),
            PagerStyledLine(text: "  /copy      copy the last response"),
            PagerStyledLine(text: "  /export    write the conversation to a file"),
            PagerStyledLine(text: "  /help      browse every command")
        ]
    }

    static let easterEgg = """
        ⠀⠀⠀⠀⠀⠀⣀⣀⡀⠀⠀⠀⢀⠄
        ⠀⠀⠀⣠⣾⠿⠛⠛⠛⠛⢀⡴⠁⠀
        ⠀⠀⣼⡟⠁⠀⠀⠀⢀⡴⠻⣿⡀⠀   gboom.
        """

    // MARK: - Line helpers

    private static func field(_ label: String, _ value: String) -> PagerStyledLine {
        PagerStyledLine(spans: [
            PagerStyledSpan(text: label.padding(toLength: 12, withPad: " ", startingAt: 0)),
            PagerStyledSpan(text: value, style: [.bold])
        ])
    }

    private static func section(
        _ title: String,
        _ rows: [(String, String)]
    ) -> [PagerStyledLine] {
        [PagerStyledLine(text: title, style: [.bold])] + rows.map { key, label in
            PagerStyledLine(spans: [
                PagerStyledSpan(
                    text: "  " + key.padding(toLength: 18, withPad: " ", startingAt: 0),
                    style: [.bold]
                ),
                PagerStyledSpan(text: label)
            ])
        }
    }

    private static func roleLabel(_ role: PagerMessageRole) -> String {
        switch role {
        case .user: return "you"
        case .assistant: return "grok"
        case .system: return "system"
        case .reasoning: return "thinking"
        case .error: return "error"
        }
    }
}
