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
    /// (`build_recap_items`, `session_recap.rs:62-91`):
    ///
    /// 1. Optionally strip reasoning items (`stripReasoning`) — only needed on
    ///    the Anthropic Messages backend, which rejects thinking blocks sent
    ///    without a `thinking` config. Every other backend keeps reasoning
    ///    VERBATIM so the prefix KV cache stays warm
    ///    (`compaction_utils.rs:88-93` for the strip itself).
    /// 2. Truncate a trailing incomplete assistant/tool-result run — a recap
    ///    can fire mid-turn, and the appended instruction must never follow a
    ///    dangling tool call or output.
    /// 3. Append the recap instruction as a final REAL user turn
    ///    (`ConversationItem::user`, synthetic reason nil — session_recap.rs:89).
    ///
    /// The over-budget front-trim of `budget_recap_items`
    /// (`session_recap.rs:127-164`) is deliberately not ported: this port's
    /// sessions auto-compact at the same 85% threshold before every sample, so
    /// the snapshot a recap reads is already held under the wall; a degenerate
    /// overflow fails the side-call and paints the failure copy instead.
    static func buildItems(
        conversation: [ConversationItem],
        tag: String,
        stripReasoning: Bool
    ) -> [ConversationItem] {
        var items = stripReasoning
            ? conversation.filter { if case .reasoning = $0 { return false } else { return true } }
            : conversation
        popTrailingToolRun(&items)
        items.append(.user(instruction(tag: tag)))
        return items
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
