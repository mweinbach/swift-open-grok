// LiveModelPicker.swift
//
// Provider-qualified `/model` selection.
// Port of `crates/codegen/xai-grok-pager/src/slash/commands/model.rs` at
// upstream 9ed09e2a.
//
// Two model catalogs can legitimately serve the same model under the same
// display name — DeepSeek V4 Pro is reachable both directly and through
// Fireworks, and upstream's own test pins `GPT-5.6 Sol` appearing under both
// Codex and xAI. Selecting by bare name is therefore ambiguous, and upstream's
// answer is not "pick the first": every lookup tier must match **exactly one**
// model or it is refused. That is the rule this file exists to enforce.
//
// A selector is `provider:slug` (`codex:gpt-5.6-sol`). Rows read
// `Provider · Name` and sort by provider then name, so the two same-named rows
// sit next to each other with the thing that distinguishes them leading.

import Foundation
import OpenGrokModels
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes

// MARK: - Entry

/// One selectable model, carrying the fields the picker renders and matches on.
struct LiveModelPickerEntry: Sendable, Equatable {
    /// Catalog key. This is what a selection resolves to and what the model
    /// switch is driven with.
    var id: String
    /// Provider wire id (`codex`, `xai`, `deepseek`, …).
    var providerID: String
    var name: String
    var description: String?
    var contextWindow: UInt64?
    var supportsReasoningEffort: Bool
    /// The catalog entry's scalar reasoning-effort default. This is the value
    /// `reasoning_effort_for_model(entry, None)` returns in upstream when no
    /// override is given (acp/model_state.rs:14-23). Populated from
    /// `ModelInfo.reasoningEffort` after `deriveReasoningEffortFields`.
    var defaultReasoningEffort: ReasoningEffort?
    /// The model's declared effort menu; empty falls back to the built-in
    /// legacy menu when `supportsReasoningEffort` is set.
    var reasoningEfforts: [ReasoningEffortOption]
    /// The model's declared service tiers (`/fast` reads the fast id here).
    var serviceTiers: [ModelServiceTier]

    init(
        id: String,
        providerID: String,
        name: String,
        description: String? = nil,
        contextWindow: UInt64? = nil,
        supportsReasoningEffort: Bool = false,
        defaultReasoningEffort: ReasoningEffort? = nil,
        reasoningEfforts: [ReasoningEffortOption] = [],
        serviceTiers: [ModelServiceTier] = []
    ) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.description = description
        self.contextWindow = contextWindow
        self.supportsReasoningEffort = supportsReasoningEffort
        self.defaultReasoningEffort = defaultReasoningEffort
        self.reasoningEfforts = reasoningEfforts
        self.serviceTiers = serviceTiers
    }

    /// The fast tier id when this model advertises one
    /// (`current_fast_service_tier_id`, acp/model_state.rs:224-230).
    var fastServiceTierID: String? {
        serviceTiers.first(where: \.isFast)?.id
    }
}

// MARK: - Reasoning effort

/// Why an effort token could not be applied to a model. Port of
/// `EffortTokenError` (xai-grok-pager acp/model_state.rs:29-60) with
/// upstream's exact message copy, shared by `/model <name> <effort>` and the
/// `--reasoning-effort` startup flag so both surfaces classify identically.
enum LiveEffortTokenError: Error, Equatable {
    /// The target model does not advertise reasoning-effort support.
    case unsupported
    /// The token is neither a menu id nor a canonical value the model's menu
    /// offers. `offered` lists only this model's option ids — never a
    /// hardcoded global set, so blocked levels (`none`/`minimal`) are not
    /// advertised.
    case unknownToken(token: String, offered: [String])

    var message: String {
        switch self {
        case .unsupported:
            return "current model does not support reasoning effort"
        case .unknownToken(let token, let offered):
            if offered.isEmpty {
                return "unknown effort level '\(token)'; "
                    + "this model has no selectable effort levels"
            }
            return "unknown effort level '\(token)'; use one of: "
                + offered.joined(separator: ", ")
        }
    }
}

/// The shared effort-token policy: gate on the model's support flag first,
/// then resolve the token against the model's menu. Port of
/// `resolve_effort_for_model` / `reasoning_effort_options_for`
/// (acp/model_state.rs:288-364) over the catalog's option lists.
enum LiveModelEffort {
    /// Built-in fallback menu when a reasoning model pins no menu, strongest
    /// first (`EFFORT_LEVELS`, slash/commands/effort_levels.rs:9-14).
    /// `none`/`minimal` stay reachable for power users via the canonical
    /// parse, matching upstream's `ReasoningEffort::from_str` note.
    static let legacyLevels: [ReasoningEffort] = [.xhigh, .high, .medium, .low]

    /// `effort_description` (effort_levels.rs:16-27).
    static func description(for level: ReasoningEffort) -> String {
        switch level {
        case .none: return "No reasoning"
        case .minimal: return "Minimal reasoning"
        case .low: return "Faster, lighter reasoning"
        case .medium: return "Balanced reasoning"
        case .high: return "Heavy reasoning"
        case .xhigh: return "Extra-high reasoning"
        case .max: return "Maximum reasoning"
        case .ultra: return "Maximum reasoning with automatic task delegation"
        }
    }

    /// `legacy_effort_options` (effort_levels.rs:33-45): lowercase level as
    /// id and label, `default` unset.
    static func legacyOptions() -> [ReasoningEffortOption] {
        legacyLevels.map { level in
            ReasoningEffortOption(
                id: level.asString,
                value: level,
                label: level.asString,
                description: description(for: level),
                isDefault: false
            )
        }
    }

    /// The menu offered for a model: its declared options, else the built-in
    /// fallback; nothing for a model with no effort support
    /// (`reasoning_effort_options_for`, acp/model_state.rs:288-299).
    static func options(
        supportsReasoningEffort: Bool,
        declaredEfforts: [ReasoningEffortOption]
    ) -> [ReasoningEffortOption] {
        guard supportsReasoningEffort else { return [] }
        return declaredEfforts.isEmpty ? legacyOptions() : declaredEfforts
    }

    /// `resolve_effort_for_model` (acp/model_state.rs:339-364): a menu option
    /// id (case-insensitive) or a canonical level that appears as a value in
    /// the menu. Levels the model does not offer are rejected here so they
    /// fail in the TUI instead of 400ing on the API.
    static func resolve(
        token: String,
        supportsReasoningEffort: Bool,
        declaredEfforts: [ReasoningEffortOption]
    ) -> Result<ReasoningEffort, LiveEffortTokenError> {
        guard supportsReasoningEffort else { return .failure(.unsupported) }
        let menu = options(
            supportsReasoningEffort: supportsReasoningEffort,
            declaredEfforts: declaredEfforts
        )
        if let option = menu.first(where: {
            $0.id.caseInsensitiveCompare(token) == .orderedSame
        }) {
            return .success(option.value)
        }
        if let parsed = parseCanonicalEffortToken(token),
           let option = menu.first(where: { $0.value == parsed }) {
            return .success(option.value)
        }
        return .failure(.unknownToken(token: token, offered: menu.map(\.id)))
    }
}

/// A built picker row. `id` is the catalog key the selection handler receives;
/// `insertText` is what typing the row into the prompt should produce.
struct LiveModelPickerRow: Sendable, Equatable {
    var id: String
    var label: String
    /// `provider:slug` — what the user types to name this model unambiguously.
    var selector: String
    /// Sub-line under the label: slug, context window, catalog description.
    var summary: String
    var matchText: String
    var insertText: String
    var isCurrent: Bool
}

// MARK: - Picker

enum LiveModelPicker {
    /// Human-facing provider name.
    ///
    /// An unrecognized provider falls back to its own wire id rather than being
    /// hidden: a model from a provider this build does not know about should
    /// still be selectable and still say where it came from.
    static func providerLabel(forProviderID providerID: String) -> String? {
        let id = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return nil }
        switch id {
        case "codex", "openai", "openai_codex": return "OpenAI Codex"
        case "xai": return "xAI"
        case "kimi", "moonshot", "moonshot_ai": return "Kimi"
        case "fireworks", "fireworks_ai": return "Fireworks AI"
        case "deepseek", "deep_seek", "deepseek_api": return "DeepSeek"
        case "meta", "meta_ai", "meta_api": return "Meta API"
        case "opencode_go", "opencode-go": return "OpenCode Go"
        case "wafer", "wafer_ai": return "Wafer AI"
        default: return providerID
        }
    }

    /// The catalog id with its own `provider:` prefix removed, so a key that is
    /// already qualified does not render as `wafer:wafer:model`.
    static func catalogSlug(id: String, providerID: String) -> String {
        guard !providerID.isEmpty else { return id }
        let prefix = providerID + ":"
        guard id.hasPrefix(prefix) else { return id }
        return String(id.dropFirst(prefix.count))
    }

    /// The unambiguous way to name this model on the prompt: `provider:slug`.
    static func selector(for entry: LiveModelPickerEntry) -> String {
        guard !entry.providerID.isEmpty else { return entry.name }
        return "\(entry.providerID):\(catalogSlug(id: entry.id, providerID: entry.providerID))"
    }

    // MARK: Resolution

    /// Resolve a typed `/model` argument to a catalog id.
    ///
    /// Three tiers, each **unique-match-only**: a provider-qualified selector,
    /// then the raw catalog id, then an unqualified display name or slug. A
    /// tier that matches more than one model yields nothing and falls through,
    /// so an ambiguous bare name ends as "unknown" rather than silently
    /// selecting whichever entry happened to be first.
    static func resolve(query: String, entries: [LiveModelPickerEntry]) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let match = uniqueMatch(entries, where: {
            selector(for: $0).caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return match
        }
        if let match = uniqueMatch(entries, where: {
            $0.id.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return match
        }
        return uniqueMatch(entries, where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
                || catalogSlug(id: $0.id, providerID: $0.providerID)
                    .caseInsensitiveCompare(trimmed) == .orderedSame
        })
    }

    /// The catalog id of the sole entry satisfying `predicate`, or nil when
    /// zero or more than one does.
    private static func uniqueMatch(
        _ entries: [LiveModelPickerEntry],
        where predicate: (LiveModelPickerEntry) -> Bool
    ) -> String? {
        var found: String?
        for entry in entries where predicate(entry) {
            if found != nil { return nil }
            found = entry.id
        }
        return found
    }

    /// Error text for a `/model` argument that named no single model.
    static func unknownModelMessage(_ query: String) -> String {
        "Unknown model: \(query.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// Split `args` into `(prefix, lastToken)` on the final whitespace run,
    /// or `nil` when there is no interior whitespace to split on. Port of
    /// `split_trailing_token` (upstream model.rs:223-231); the caller resolves
    /// the token to an effort against the picked model's options.
    static func splitTrailingToken(_ args: String) -> (prefix: String, token: String)? {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let splitIndex = trimmed.lastIndex(where: \.isWhitespace) else { return nil }
        let prefix = String(trimmed[..<splitIndex])
            .trimmingCharacters(in: .whitespaces)
        let token = String(trimmed[trimmed.index(after: splitIndex)...])
        guard !prefix.isEmpty, !token.isEmpty else { return nil }
        return (prefix, token)
    }

    // MARK: Rows

    /// Provider-then-name ordering, with the catalog slug as the final
    /// tiebreak so two identically named models from one provider stay stable.
    static func sorted(_ entries: [LiveModelPickerEntry]) -> [LiveModelPickerEntry] {
        entries.sorted { left, right in
            let leftProvider = (providerLabel(forProviderID: left.providerID) ?? "").lowercased()
            let rightProvider = (providerLabel(forProviderID: right.providerID) ?? "").lowercased()
            if leftProvider != rightProvider { return leftProvider < rightProvider }
            let leftName = left.name.lowercased()
            let rightName = right.name.lowercased()
            if leftName != rightName { return leftName < rightName }
            return catalogSlug(id: left.id, providerID: left.providerID)
                < catalogSlug(id: right.id, providerID: right.providerID)
        }
    }

    static func rows(
        entries: [LiveModelPickerEntry],
        currentModelID: String? = nil
    ) -> [LiveModelPickerRow] {
        sorted(entries).map { entry in
            let providerLabel = providerLabel(forProviderID: entry.providerID)
            let rowLabel = providerLabel.map { "\($0) · \(entry.name)" } ?? entry.name
            let isCurrent = entry.id == currentModelID
            let selector = selector(for: entry)
            return LiveModelPickerRow(
                id: entry.id,
                label: isCurrent ? "\(rowLabel) (current)" : rowLabel,
                selector: selector,
                summary: description(for: entry),
                matchText: "\(entry.name) "
                    + "\(catalogSlug(id: entry.id, providerID: entry.providerID)) "
                    + (providerLabel ?? ""),
                // A trailing space on reasoning models keeps the composer in
                // the argument phase, and `completions` answers a query that
                // already names a reasoning model with the effort sub-menu —
                // upstream's chained autocomplete (model.rs:60-65).
                insertText: entry.supportsReasoningEffort ? "\(selector) " : selector,
                isCurrent: isCurrent
            )
        }
    }

    /// Build the `/model` overlay.
    ///
    /// The render layer deliberately does not know what a model is, so all
    /// labelling happens here and it receives finished rows. Row ids stay the
    /// catalog key, which is what the selection handler switches to.
    static func overlay(
        entries: [LiveModelPickerEntry],
        currentModelID: String? = nil,
        id: String = "model",
        title: String = "Select model"
    ) -> PagerOverlay {
        let built = rows(entries: entries, currentModelID: currentModelID)
        let listRows = built.map { row in
            PagerListRow(
                id: row.id,
                label: row.label,
                detail: row.isCurrent ? "\(row.selector)  ✓" : row.selector,
                summary: row.summary
            )
        }
        var overlay = PagerOverlay.list(id: id, title: title, rows: listRows)
        if case .list(var list) = overlay.content,
           let index = built.firstIndex(where: { $0.isCurrent }) {
            list.selectedIndex = index
            overlay.content = .list(list)
        }
        return overlay
    }

    // MARK: Completions

    /// Dropdown rows for a partially typed `/model` argument, mirroring
    /// upstream's `ModelCommand::suggest_args` → `build_model_items`.
    ///
    /// Upstream's prompt widget fuzzy-matches `ArgItem.match_text`. This port
    /// has no fuzzy matcher, so it filters on a case-insensitive substring of
    /// the same text plus the selector. That is narrower, never wider: every
    /// row offered is one the query could have meant, and an empty query still
    /// lists the whole catalog the way upstream's does.
    static func completions(
        query: String,
        entries: [LiveModelPickerEntry],
        currentModelID: String? = nil
    ) -> [LiveModelPickerRow] {
        let all = rows(entries: entries, currentModelID: currentModelID)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.matchText.lowercased().contains(needle)
                || $0.selector.lowercased().contains(needle)
        }
    }

    /// The effort phase of `/model`'s chained autocomplete: when the query
    /// already names a reasoning model, suggest that model's effort levels
    /// instead of the model list (`detect_effort_phase` + `build_effort_items`,
    /// upstream model.rs:60-65, :234-260).
    ///
    /// Upstream detects the phase by a trailing space after the model name.
    /// This port's controller trims the argument query before handing it
    /// over, so the space is unrecoverable here; instead the phase opens when
    /// the query is exactly a reasoning model's selector (what accepting a
    /// model row leaves behind, minus its trailing space) or that selector
    /// plus a partial effort token. Longest-selector-first disambiguates
    /// selectors that share a prefix, as upstream sorts by name length.
    static func effortPhase(
        query: String,
        entries: [LiveModelPickerEntry]
    ) -> (entry: LiveModelPickerEntry, effortQuery: String)? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidates = entries
            .filter(\.supportsReasoningEffort)
            .map { (entry: $0, selector: selector(for: $0)) }
            .sorted { $0.selector.count > $1.selector.count }
        for (entry, selector) in candidates {
            if selector.caseInsensitiveCompare(trimmed) == .orderedSame {
                return (entry, "")
            }
            if trimmed.count > selector.count,
               trimmed.lowercased().hasPrefix(selector.lowercased()),
               let boundary = trimmed.index(
                   trimmed.startIndex,
                   offsetBy: selector.count,
                   limitedBy: trimmed.endIndex
               ),
               trimmed[boundary].isWhitespace {
                let rest = trimmed[boundary...]
                    .trimmingCharacters(in: .whitespaces)
                return (entry, rest)
            }
        }
        return nil
    }

    /// Effort rows for the chained `/model` dropdown. `insertText` carries
    /// the full command back (`/model <selector> <effort-id>`) because the
    /// composer replaces its whole text on accept.
    static func effortSuggestions(
        entry: LiveModelPickerEntry,
        effortQuery: String,
        command: String = "model"
    ) -> [OpenGrokPagerCommandSuggestion] {
        let menu = LiveModelEffort.options(
            supportsReasoningEffort: entry.supportsReasoningEffort,
            declaredEfforts: entry.reasoningEfforts
        )
        let selector = selector(for: entry)
        let needle = effortQuery.lowercased()
        return menu
            .filter { needle.isEmpty || $0.id.lowercased().contains(needle) }
            .map { option in
                OpenGrokPagerCommandSuggestion(
                    name: option.label,
                    summary: option.description ?? "",
                    insertText: "/\(command) \(selector) \(option.id)"
                )
            }
    }

    /// The same rows as dropdown suggestions.
    ///
    /// `insertText` carries the command back with the selector because the
    /// composer replaces its whole text on accept — a bare `codex:gpt-5.6-sol`
    /// left behind would submit as a prompt, not as a model switch.
    static func suggestions(
        query: String,
        entries: [LiveModelPickerEntry],
        currentModelID: String? = nil,
        command: String = "model"
    ) -> [OpenGrokPagerCommandSuggestion] {
        // A query that already names a reasoning model chains into that
        // model's effort sub-menu instead of re-listing the catalog
        // (upstream model.rs:60-65).
        if let (entry, effortQuery) = effortPhase(query: query, entries: entries) {
            let effortRows = effortSuggestions(
                entry: entry,
                effortQuery: effortQuery,
                command: command
            )
            if !effortRows.isEmpty { return effortRows }
        }
        return completions(query: query, entries: entries, currentModelID: currentModelID)
            .map { row in
                OpenGrokPagerCommandSuggestion(
                    name: row.label,
                    summary: row.summary,
                    // `insertText` already carries the trailing space that says
                    // "an effort level may follow" for reasoning models.
                    insertText: "/\(command) \(row.insertText)"
                )
            }
    }

    /// `slug · context · description`, omitting parts the catalog does not
    /// carry. The provider is not repeated here — it already leads the label.
    static func description(for entry: LiveModelPickerEntry) -> String {
        var parts = [catalogSlug(id: entry.id, providerID: entry.providerID)]
        if let tokens = entry.contextWindow {
            parts.append(formatContextWindow(tokens))
        }
        if let description = entry.description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            parts.append(description)
        }
        return parts.joined(separator: " · ")
    }

    /// `353400` → `353.4K context`, `1000000` → `1M context`. One decimal
    /// place, and a whole number never renders a trailing `.0`.
    static func formatContextWindow(_ tokens: UInt64) -> String {
        func compact(_ divisor: UInt64, _ suffix: String) -> String {
            let tenths = (UInt64(tokens) * 10 + divisor / 2) / divisor
            if tenths % 10 == 0 {
                return "\(tenths / 10)\(suffix) context"
            }
            return "\(tenths / 10).\(tenths % 10)\(suffix) context"
        }
        if tokens >= 1_000_000 { return compact(1_000_000, "M") }
        if tokens >= 1_000 { return compact(1_000, "K") }
        return "\(tokens) context"
    }
}
