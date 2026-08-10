// LiveRecap.swift
//
// `/recap` — the session recap side-call, manual arm.
//
// A recap NEVER mutates the conversation: it samples a read-only snapshot of
// the live conversation and surfaces display-only text
// (`session/helpers/session_recap.rs:1-12`). Generation reuses the session's
// conversation prefix verbatim — so the provider prompt cache stays warm —
// and appends ONE user instruction turn wrapped in the reminder tag
// (`session_recap.rs:23-33`, `:76-91`).
//
// The pure helpers live here; the actor half (model choice, the one-shot
// sample, failure copy) is `performRecap` in `LiveComposition.swift`, ported
// from `handle_recap` (`acp_session_impl/recap.rs:250-507`) and
// `prepare_auxiliary_sampling` (`acp_session_impl/sampler_turn.rs:1100-1197`).

import Foundation
import OpenGrokConfig
import OpenGrokSamplingTypes

enum LiveRecap {
    // MARK: - Constants

    /// Hard cap on the recap text length (bytes, like Rust `String::len`).
    /// Generous headroom: the instruction targets ~25–40 words, so this only
    /// guards against runaway model output (`session_recap.rs:18-21`).
    static let maxChars = 1200

    /// The one provider with an Automatic helper model: Codex sessions prefer
    /// `gpt-5.6-terra`; every other provider keeps its active session model
    /// (`sampler_turn.rs:25-31`). This table is deliberately one row — do not
    /// grow it without an upstream citation.
    static let automaticCodexAuxModel = "gpt-5.6-terra"

    /// Recap budgeting is capped at the verified product-backend input window.
    /// Smaller explicit windows still win (`session_recap.rs:93-107`).
    static let contextWindowCap: UInt64 = 500_000
    static let budgetThresholdPercent: UInt64 = 85
    static let budgetHeadroomTokens: UInt64 = 4_000

    private static let bytesPerToken: UInt64 = 4
    private static let imageTokenEstimate: UInt64 = 765
    private static let truncationMarkerReserve = 64

    // MARK: - Instruction

    /// The instruction turn appended to the conversation snapshot. BYTE-EXACT
    /// port of `recap_instruction` (`session_recap.rs:37-60`), few-shot
    /// examples included; the examples are synthetic upstream and must stay
    /// synthetic here. All recap directions live in this single user message
    /// (wrapped in the reminder tag) rather than a separate system prompt, so
    /// the conversation prefix is reused verbatim and the prompt cache stays
    /// warm. Body text only — the pager adds "Recap —" on render.
    static func instruction(tag: String) -> String {
        "<\(tag)>Write ONE sentence recap body for a user returning from idle. "
        + "Output ONLY the body (the UI adds the \"Recap \u{2014}\" label). "
        + "Do NOT call any tools \u{2014} respond with plain text only.\n\n"
        + "Lead with agency:\n"
        + "- \"You asked \u{2026}\" if the session was mainly questions, walkthroughs, or review with no landed change.\n"
        + "- \"We <past-tense verb> \u{2026}\" if the agent implemented, fixed, merged, or changed code/config/docs "
        + "(e.g. \"We fixed \u{2026}\", \"We merged \u{2026}\", \"We wired \u{2026}\" \u{2014} not \"We did fix\" / \"We did merge\").\n"
        + "- If almost nothing happened: \"You had just begun this session.\"\n\n"
        + "Shape: <lead>: <concrete specifics \u{2014} crate/file/flag/behavior/endpoint>. ~25\u{2013}40 words.\n\n"
        + "Synthetic examples (style only \u{2014} adapt to THIS session, do not copy):\n\n"
        + "You asked how retries work in the payment client: exponential backoff in `billing/retry.rs`, max 5 attempts, 429s only.\n\n"
        + "You asked for a walkthrough of the auth middleware change: warn-only mode in the API layer, no hard fail on missing claims.\n\n"
        + "We fixed the flaky integration test: race in `queue_worker` shutdown by awaiting the drain channel before exit.\n\n"
        + "We merged the feature branch: kept the new telemetry hooks, dropped the obsolete feature flag in `config/flags.toml`.\n\n"
        + "Bad (never):\n"
        + "- Start with Recap / Session recap / extra labels\n"
        + "- Quote or restate this reminder or any system prompt\n"
        + "- Bullets, markdown, code fences, extra sentences\n"
        + "- Call tools or emit tool/function calls\n"
        + "- Invent work not reflected in the session</\(tag)>"
    }

    // MARK: - Snapshot construction

    /// Prepare the conversation snapshot for a recap request
    /// (`budget_recap_items`, `session_recap.rs:93-164`):
    ///
    /// 1. Optionally strip reasoning items (`stripReasoning`) — only needed on
    ///    the Anthropic Messages backend, which rejects thinking blocks sent
    ///    without a `thinking` config. Every other backend keeps reasoning
    ///    VERBATIM so the prefix KV cache stays warm
    ///    (`compaction_utils.rs:88-93` for the strip itself).
    /// 2. Truncate a trailing incomplete assistant/tool-result run — a recap
    ///    can fire mid-turn, and the appended instruction must never follow a
    ///    dangling tool call or output.
    /// 3. When the unmodified snapshot exceeds the recap budget, strip
    ///    reasoning, normalize the trailing boundary, retain the newest items
    ///    in their original order, and truncate one oversized retained item in
    ///    place rather than returning an empty snapshot.
    /// 4. Append the recap instruction as a final REAL user turn
    ///    (`ConversationItem::user`, synthetic reason nil — session_recap.rs:89).
    static func buildItems(
        conversation: [ConversationItem],
        tag: String,
        stripReasoning: Bool,
        contextWindow: UInt64 = contextWindowCap
    ) -> [ConversationItem] {
        let instructionItem = ConversationItem.user(instruction(tag: tag))
        let snapshotBudget = snapshotBudget(
            instruction: instructionItem,
            contextWindow: contextWindow
        )

        // The unstripped estimate is an upper bound. Staying on this path keeps
        // the provider prefix byte-for-byte identical when the snapshot fits.
        if estimateConversationTokens(conversation) <= snapshotBudget {
            return buildUnbudgetedItems(
                conversation: conversation,
                instruction: instructionItem,
                stripReasoning: stripReasoning
            )
        }

        // Once front-trimming loses prefix-cache identity, reasoning is always
        // removed, including on providers that accept it (`session_recap.rs:120-123`).
        var snapshot = conversation.filter {
            if case .reasoning = $0 { return false }
            return true
        }
        popTrailingToolRun(&snapshot)
        var items = fitConversationToBudget(snapshot, maxTokens: snapshotBudget)
        items.append(instructionItem)
        return items
    }

    private static func buildUnbudgetedItems(
        conversation: [ConversationItem],
        instruction: ConversationItem,
        stripReasoning: Bool
    ) -> [ConversationItem] {
        var items = stripReasoning
            ? conversation.filter { if case .reasoning = $0 { return false } else { return true } }
            : conversation
        popTrailingToolRun(&items)
        items.append(instruction)
        return items
    }

    static func promptBudget(contextWindow: UInt64) -> UInt64 {
        let effectiveWindow = min(contextWindow, contextWindowCap)
        let threshold = effectiveWindow * budgetThresholdPercent / 100
        return threshold >= budgetHeadroomTokens ? threshold - budgetHeadroomTokens : 0
    }

    static func snapshotBudget(tag: String, contextWindow: UInt64) -> UInt64 {
        snapshotBudget(
            instruction: .user(instruction(tag: tag)),
            contextWindow: contextWindow
        )
    }

    private static func snapshotBudget(
        instruction: ConversationItem,
        contextWindow: UInt64
    ) -> UInt64 {
        let promptBudget = promptBudget(contextWindow: contextWindow)
        let instructionTokens = estimateItemTokens(instruction)
        return promptBudget >= instructionTokens ? promptBudget - instructionTokens : 0
    }

    static func estimateConversationTokens(_ items: [ConversationItem]) -> UInt64 {
        items.reduce(0) { $0 + estimateItemTokens($1) }
    }

    private static func estimateItemTokens(_ item: ConversationItem) -> UInt64 {
        switch item {
        case .system(let system):
            return UInt64(system.content.utf8.count) / bytesPerToken
        case .user(let user):
            return estimateContentParts(user.content)
        case .assistant(let assistant):
            let bytes = assistant.content.utf8.count
                + assistant.toolCalls.reduce(0) { $0 + $1.arguments.utf8.count }
            return UInt64(bytes) / bytesPerToken
        case .toolResult(let result):
            if result.orderedContent.isEmpty {
                return UInt64(result.content.utf8.count) / bytesPerToken
            }
            return estimateOrderedContent(result.orderedContent)
        case .customToolOutput(let output):
            return estimateOrderedContent(output.content)
        case .backendToolCall(let call):
            return UInt64(call.estimatedContentLen()) / bytesPerToken
        case .reasoning(let reasoning):
            let bytes = reasoningItemText(reasoning).utf8.count
                + (reasoning.encryptedContent?.utf8.count ?? 0)
            return UInt64(bytes) / bytesPerToken
        }
    }

    private static func estimateContentParts(_ parts: [ContentPart]) -> UInt64 {
        var bytes = 0
        var images: UInt64 = 0
        for part in parts {
            switch part {
            case .text(let text): bytes += text.utf8.count
            case .image: images += 1
            }
        }
        return UInt64(bytes) / bytesPerToken + images * imageTokenEstimate
    }

    private static func estimateOrderedContent(
        _ content: [CustomToolOutputContent]
    ) -> UInt64 {
        var bytes = 0
        var images: UInt64 = 0
        for part in content {
            switch part {
            case .text(let text): bytes += text.utf8.count
            case .image: images += 1
            }
        }
        return UInt64(bytes) / bytesPerToken + images * imageTokenEstimate
    }

    private static func fitConversationToBudget(
        _ conversation: [ConversationItem],
        maxTokens: UInt64
    ) -> [ConversationItem] {
        guard estimateConversationTokens(conversation) > maxTokens else { return conversation }

        var head: [ConversationItem] = []
        var body = conversation
        if let first = body.first, case .system = first {
            head.append(body.removeFirst())
        }

        let headTokens = estimateConversationTokens(head)
        let budget = maxTokens >= headTokens ? maxTokens - headTokens : 0
        var remaining = budget
        var start = body.count
        if !body.isEmpty {
            for index in stride(from: body.count - 1, through: 0, by: -1) {
                let cost = estimateItemTokens(body[index])
                guard cost <= remaining else { break }
                remaining -= cost
                start = index
            }
        }

        while start < body.count, isToolOutput(body[start]) {
            start += 1
        }
        if start < body.count {
            head.append(contentsOf: body[start...])
        } else {
            head.append(contentsOf: recoverTruncatedTailUnit(body, budget: budget))
        }
        return head
    }

    private static func isToolOutput(_ item: ConversationItem) -> Bool {
        switch item {
        case .toolResult, .customToolOutput: true
        default: false
        }
    }

    private static func recoverTruncatedTailUnit(
        _ input: [ConversationItem],
        budget: UInt64
    ) -> [ConversationItem] {
        var body = input
        var results: [ConversationItem] = []
        while let last = body.last, isToolOutput(last) {
            results.append(body.removeLast())
        }
        results.reverse()

        guard !results.isEmpty else {
            guard let item = body.popLast() else { return [] }
            return [truncateItem(item, maxTokens: budget)]
        }

        let owner: ConversationItem?
        if let last = body.last,
           case .assistant(let assistant) = last,
           !assistant.toolCalls.isEmpty {
            owner = body.removeLast()
        } else {
            owner = nil
        }
        let ownerCost = owner.map(estimateItemTokens) ?? 0
        let resultBudget = budget >= ownerCost ? budget - ownerCost : 0
        let perResult = max(resultBudget / UInt64(results.count), 1)
        var unit = owner.map { [$0] } ?? []
        unit.append(contentsOf: results.map { truncateItem($0, maxTokens: perResult) })
        return unit
    }

    private static func truncateItem(
        _ item: ConversationItem,
        maxTokens: UInt64
    ) -> ConversationItem {
        let maxBytes = Int(clamping: maxTokens * bytesPerToken)
        switch item {
        case .toolResult(var result):
            if result.orderedContent.isEmpty {
                if let truncated = truncateText(result.content, maxBytes: maxBytes) {
                    result.content = truncated
                }
            } else {
                result.orderedContent = truncateOrderedContent(
                    result.orderedContent,
                    maxTokens: maxTokens
                )
                result.content = result.orderedContent.compactMap { part in
                    if case .text(let text) = part { return text }
                    return nil
                }.joined()
            }
            return .toolResult(result)
        case .customToolOutput(var output):
            output.content = truncateOrderedContent(output.content, maxTokens: maxTokens)
            return .customToolOutput(output)
        case .assistant(var assistant):
            if let truncated = truncateText(assistant.content, maxBytes: maxBytes) {
                assistant.content = truncated
            }
            return .assistant(assistant)
        case .user(var user):
            user.content = user.content.map { part in
                guard case .text(let text) = part,
                      let truncated = truncateText(text, maxBytes: maxBytes)
                else { return part }
                return .text(text: truncated)
            }
            return .user(user)
        default:
            return item
        }
    }

    private static func truncateOrderedContent(
        _ content: [CustomToolOutputContent],
        maxTokens: UInt64
    ) -> [CustomToolOutputContent] {
        var remainingUnits = maxTokens * bytesPerToken
        let imageUnits = imageTokenEstimate * bytesPerToken
        var retained: [CustomToolOutputContent] = []

        for part in content {
            switch part {
            case .text(let text):
                let textUnits = UInt64(text.utf8.count)
                if textUnits <= remainingUnits {
                    remainingUnits -= textUnits
                    retained.append(part)
                    continue
                }
                let availableBytes = Int(clamping: remainingUnits)
                if availableBytes > 0 {
                    retained.append(.text(text: truncateText(
                        text,
                        maxBytes: availableBytes
                    ) ?? text))
                }
                return retained
            case .image:
                guard imageUnits <= remainingUnits else { return retained }
                remainingUnits -= imageUnits
                retained.append(part)
            }
        }
        return retained
    }

    private static func truncateText(_ text: String, maxBytes: Int) -> String? {
        let bytes = Array(text.utf8)
        guard bytes.count > maxBytes else { return nil }

        let keep = max(0, maxBytes - truncationMarkerReserve)
        let prefix = floorToScalarBoundary(text, maxBytes: keep)
        let dropped = bytes.count - prefix.utf8.count
        let withMarker = prefix
            + "\n[... truncated \(dropped) bytes to fit the compaction window ...]"
        if withMarker.utf8.count <= maxBytes {
            return withMarker
        }
        return floorToScalarBoundary(text, maxBytes: maxBytes)
    }

    /// Pop a trailing tool run — trailing `toolResult`s, native
    /// `customToolOutput`s and any trailing assistant with tool calls
    /// (complete runs included) — so the snapshot ends on a clean boundary.
    /// Trailing `reasoning` goes too: it precedes its owner, which the pop
    /// just removed (`pop_trailing_tool_run`, `session_recap.rs:166-186`).
    static func popTrailingToolRun(_ items: inout [ConversationItem]) {
        while let last = items.last {
            switch last {
            case .assistant(let assistant) where !assistant.toolCalls.isEmpty:
                items.removeLast()
            case .toolResult, .customToolOutput, .reasoning:
                items.removeLast()
            default:
                return
            }
        }
    }

    /// Real user prompts (`syntheticReason == nil`), not assistant/tool items
    /// (`main_turn_count`, `session_recap.rs:191-202`).
    static func mainTurnCount(_ conversation: [ConversationItem]) -> Int {
        conversation.reduce(into: 0) { count, item in
            if case .user(let user) = item, user.syntheticReason == nil {
                count += 1
            }
        }
    }

    // MARK: - Output tidy pass

    /// Clean the model's raw recap output into a readable one-liner body
    /// (`clean_recap_text`, `session_recap.rs:267-312`): collapse whitespace,
    /// strip a stray leading label or symmetric wrapping quotes the model
    /// added anyway, and cap at `maxChars` bytes on a scalar boundary with an
    /// ellipsis. Does not prepend "Recap —" — the render layer adds the label.
    static func cleanText(_ raw: String) -> String {
        // Collapse runs of whitespace/newlines into single spaces.
        var out = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        // Strip a stray leading label if the model added one anyway.
        for label in [
            "Recap \u{2014}",
            "Recap\u{2014}",
            "Recap -",
            "Recap:",
            "recap:",
            "Session recap:",
            "Summary:",
        ] where out.hasPrefix(label) {
            out = String(out.dropFirst(label.count).drop(while: \.isWhitespace))
            break
        }

        // Strip symmetric wrapping quotes around the whole string. Byte-level
        // like upstream (`out.as_bytes()`, session_recap.rs:294-302).
        let bytes = Array(out.utf8)
        if bytes.count >= 2 {
            let first = bytes[0]
            let last = bytes[bytes.count - 1]
            if (first == UInt8(ascii: "\"") && last == UInt8(ascii: "\""))
                || (first == UInt8(ascii: "'") && last == UInt8(ascii: "'")) {
                out = String(decoding: bytes[1..<(bytes.count - 1)], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if out.utf8.count > maxChars {
            out = floorToScalarBoundary(out, maxBytes: maxChars)
            while let last = out.last, last.isWhitespace {
                out.removeLast()
            }
            out.append("\u{2026}")
        }

        return out
    }

    /// Rust `floor_char_boundary` + truncate: cut at the largest byte index
    /// ≤ `maxBytes` that is a UTF-8 scalar boundary, so a multi-byte character
    /// straddling the cap is dropped whole rather than torn.
    private static func floorToScalarBoundary(_ s: String, maxBytes: Int) -> String {
        let bytes = Array(s.utf8)
        guard bytes.count > maxBytes else { return s }
        var cut = maxBytes
        while cut > 0, bytes[cut] & 0b1100_0000 == 0b1000_0000 {
            cut -= 1
        }
        return String(decoding: bytes[0..<cut], as: UTF8.self)
    }

    // MARK: - Failure copy

    /// Toast when a manual `/recap` produces no summary. Empty sessions get a
    /// clear empty-state message; anything else (model failure, empty summary)
    /// keeps the generic failure copy (`recap_unavailable_toast`,
    /// pager `app/dispatch/notes.rs:331-340`).
    static func unavailableToast(hasUserMessages: Bool) -> String {
        hasUserMessages ? "Couldn't generate recap" : "No messages yet"
    }

    // MARK: - Model choice

    /// The helper model the recap should try to resolve, before falling back
    /// to the active session model. Explicit `[models] recap` wins; Automatic
    /// picks the economical model for the active provider — Codex only
    /// (`prepare_auxiliary_sampling`, `sampler_turn.rs:1106-1118`, and
    /// `automatic_auxiliary_model`, `sampler_turn.rs:27-31`).
    static func desiredModel(
        configured: String?,
        activeProvider: ModelProvider
    ) -> (modelID: String, explicit: Bool)? {
        if let configured = configured?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return (configured, true)
        }
        if activeProvider == .codex {
            return (automaticCodexAuxModel, false)
        }
        return nil
    }

    /// Reasoning effort for an auxiliary call (`auxiliary_reasoning_effort`,
    /// `sampler_turn.rs:33-47`): Codex helpers run at medium, xAI at low,
    /// anything else at the model's own default (low when it has none) — and
    /// only on models that declare effort support at all.
    static func auxiliaryReasoningEffort(
        provider: ModelProvider,
        supported: Bool,
        modelDefault: ReasoningEffort?
    ) -> ReasoningEffort? {
        guard supported else { return nil }
        if provider == .codex { return .medium }
        if provider == .xai { return .low }
        return modelDefault ?? .low
    }

    // MARK: - Config reads

    /// The explicit `[models] recap` pin, or `nil` for provider-aware
    /// Automatic. Read fresh at `/recap` time from the project-then-user
    /// config ladder (the `LiveImageTools` flag precedent), mirroring
    /// upstream's live read through `models_manager.recap_model()`
    /// (`agent/models.rs:1176-1179`). This is the consumer that makes the
    /// parsed key honest — before this, `models.recap` parsed and nothing
    /// read it.
    static func configuredModel(
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String]
    ) -> String? {
        for table in configTables(
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment
        ) {
            guard case .string(let raw)? = table[path: ["models", "recap"]] else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Session recap gate. Default ON — disable via the `GROK_SESSION_RECAP`
    /// env or the `[features] session_recap` config key
    /// (`resolve_session_recap`, `agent/config.rs:2657-2667`). The remote
    /// settings leg is not ported: this composition has no live
    /// remote-settings surface at this seam (recorded divergence).
    static func enabled(
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String]
    ) -> Bool {
        if let fromEnv = boolFromEnv(environment["GROK_SESSION_RECAP"]) {
            return fromEnv
        }
        for table in configTables(
            workingDirectory: workingDirectory,
            openGrokHome: openGrokHome,
            environment: environment
        ) {
            if case .boolean(let value)? = table[path: ["features", "session_recap"]] {
                return value
            }
        }
        return true
    }

    private static func configTables(
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String]
    ) -> [TOMLValue] {
        var tables = [loadMergedProjectConfig(cwd: workingDirectory, environment: environment)]
        if let user = try? loadConfigFile(
            at: openGrokHome.appendingPathComponent("config.toml")
        ) {
            tables.append(user)
        }
        return tables
    }

    private static func boolFromEnv(_ raw: String?) -> Bool? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty
        else { return nil }
        switch raw {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }
}
