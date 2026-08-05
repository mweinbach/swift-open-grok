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

    init(
        id: String,
        providerID: String,
        name: String,
        description: String? = nil,
        contextWindow: UInt64? = nil,
        supportsReasoningEffort: Bool = false
    ) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.description = description
        self.contextWindow = contextWindow
        self.supportsReasoningEffort = supportsReasoningEffort
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
                // A trailing space on reasoning models signals "more input
                // expected", so Enter advances to the effort sub-menu instead
                // of submitting.
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
