// LiveModelPickerTests.swift
//
// Derived from the `/model` suite in
// `crates/codegen/xai-grok-pager/src/slash/commands/model.rs` at upstream
// 9ed09e2a — notably `duplicate_model_names_are_sorted_and_selected_by_provider`
// and the row-shape assertions in `model_picker_rows_carry_provider_metadata`.

import Foundation
import Testing
@testable import OpenGrokCLI
import OpenGrokModels
import OpenGrokSamplingTypes

private func entry(
    id: String,
    provider: String,
    name: String,
    description: String? = "Model description",
    contextWindow: UInt64? = nil,
    supportsReasoningEffort: Bool = false
) -> LiveModelPickerEntry {
    LiveModelPickerEntry(
        id: id,
        providerID: provider,
        name: name,
        description: description,
        contextWindow: contextWindow,
        supportsReasoningEffort: supportsReasoningEffort
    )
}

/// The two same-named models upstream's regression test pins.
private let duplicateNameCatalog: [LiveModelPickerEntry] = [
    entry(id: "xai:gpt-5.6-sol", provider: "xai", name: "GPT-5.6 Sol", contextWindow: 353_000),
    entry(id: "gpt-5.6-sol", provider: "codex", name: "GPT-5.6 Sol", contextWindow: 353_000),
]

@Suite("Model picker labels")
struct LiveModelPickerLabelTests {
    @Test("provider labels cover every built-in provider and its aliases")
    func providerLabels() {
        #expect(LiveModelPicker.providerLabel(forProviderID: "codex") == "OpenAI Codex")
        #expect(LiveModelPicker.providerLabel(forProviderID: "openai") == "OpenAI Codex")
        #expect(LiveModelPicker.providerLabel(forProviderID: "openai_codex") == "OpenAI Codex")
        #expect(LiveModelPicker.providerLabel(forProviderID: "xai") == "xAI")
        #expect(LiveModelPicker.providerLabel(forProviderID: "kimi") == "Kimi")
        #expect(LiveModelPicker.providerLabel(forProviderID: "moonshot_ai") == "Kimi")
        #expect(LiveModelPicker.providerLabel(forProviderID: "fireworks") == "Fireworks AI")
        #expect(LiveModelPicker.providerLabel(forProviderID: "deepseek") == "DeepSeek")
        #expect(LiveModelPicker.providerLabel(forProviderID: "deep_seek") == "DeepSeek")
        #expect(LiveModelPicker.providerLabel(forProviderID: "opencode_go") == "OpenCode Go")
        #expect(LiveModelPicker.providerLabel(forProviderID: "opencode-go") == "OpenCode Go")
        #expect(LiveModelPicker.providerLabel(forProviderID: "wafer") == "Wafer AI")
        #expect(LiveModelPicker.providerLabel(forProviderID: "wafer_ai") == "Wafer AI")
    }

    /// An unknown provider stays selectable and still says where it came from,
    /// rather than losing its attribution.
    @Test("an unrecognized provider falls back to its own id")
    func unknownProviderLabel() {
        #expect(LiveModelPicker.providerLabel(forProviderID: "some-new-provider")
            == "some-new-provider")
        #expect(LiveModelPicker.providerLabel(forProviderID: "") == nil)
        #expect(LiveModelPicker.providerLabel(forProviderID: "   ") == nil)
    }

    /// A catalog key that is already provider-qualified must not double up.
    @Test("the catalog slug strips a matching provider prefix exactly once")
    func catalogSlug() {
        #expect(LiveModelPicker.catalogSlug(id: "wafer:wafer-large", providerID: "wafer")
            == "wafer-large")
        #expect(LiveModelPicker.catalogSlug(id: "gpt-5.6-sol", providerID: "codex")
            == "gpt-5.6-sol")
        // A different provider's prefix is part of the id, not a qualifier.
        #expect(LiveModelPicker.catalogSlug(id: "xai:grok-build", providerID: "codex")
            == "xai:grok-build")
        #expect(LiveModelPicker.catalogSlug(id: "bare", providerID: "") == "bare")
    }

    @Test("selectors are provider-qualified")
    func selectors() {
        #expect(LiveModelPicker.selector(for: duplicateNameCatalog[0]) == "xai:gpt-5.6-sol")
        #expect(LiveModelPicker.selector(for: duplicateNameCatalog[1]) == "codex:gpt-5.6-sol")
        #expect(
            LiveModelPicker.selector(
                for: entry(id: "solo", provider: "", name: "Solo")
            ) == "Solo"
        )
    }

    /// Provenance: Rust `format_context_window`.
    @Test("context windows format to one decimal without a trailing .0")
    func contextWindowFormatting() {
        #expect(LiveModelPicker.formatContextWindow(353_400) == "353.4K context")
        #expect(LiveModelPicker.formatContextWindow(500_000) == "500K context")
        #expect(LiveModelPicker.formatContextWindow(1_000_000) == "1M context")
        #expect(LiveModelPicker.formatContextWindow(1_040_000) == "1M context")
        #expect(LiveModelPicker.formatContextWindow(1_250_000) == "1.3M context")
        #expect(LiveModelPicker.formatContextWindow(999) == "999 context")
    }
}

@Suite("Model picker rows")
struct LiveModelPickerRowTests {
    /// Provenance: Rust `model_picker_rows_carry_provider_metadata`.
    @Test("rows read Provider · Name with a slug-led sub-line")
    func rowShape() throws {
        let entries = [
            entry(
                id: "gpt-5.6-sol",
                provider: "codex",
                name: "GPT-5.6 Sol",
                contextWindow: 353_400
            ),
            entry(
                id: "grok-build",
                provider: "xai",
                name: "Grok Build",
                contextWindow: 500_000
            ),
        ]
        let rows = LiveModelPicker.rows(entries: entries)

        let codex = try #require(rows.first { $0.id == "gpt-5.6-sol" })
        #expect(codex.label == "OpenAI Codex · GPT-5.6 Sol")
        #expect(codex.selector == "codex:gpt-5.6-sol")
        #expect(codex.summary == "gpt-5.6-sol · 353.4K context · Model description")
        #expect(codex.matchText.contains("gpt-5.6-sol"))
        #expect(codex.matchText.contains("OpenAI Codex"))
        #expect(codex.insertText == "codex:gpt-5.6-sol")

        let xai = try #require(rows.first { $0.id == "grok-build" })
        #expect(xai.label == "xAI · Grok Build")
        #expect(xai.summary == "grok-build · 500K context · Model description")
    }

    /// Provenance: Rust `duplicate_model_names_are_sorted_and_selected_by_provider`.
    /// Provider-then-name ordering puts the two identically named rows adjacent
    /// with the thing that distinguishes them leading.
    @Test("rows sort by provider then name")
    func sorting() {
        let rows = LiveModelPicker.rows(entries: duplicateNameCatalog)
        #expect(rows.count == 2)
        #expect(rows[0].label == "OpenAI Codex · GPT-5.6 Sol")
        #expect(rows[0].insertText == "codex:gpt-5.6-sol")
        #expect(rows[1].label == "xAI · GPT-5.6 Sol")
        #expect(rows[1].insertText == "xai:gpt-5.6-sol")
    }

    @Test("name is the tiebreak within one provider")
    func sortingWithinProvider() {
        let entries = [
            entry(id: "b", provider: "xai", name: "Zeta"),
            entry(id: "a", provider: "xai", name: "Alpha"),
        ]
        #expect(LiveModelPicker.rows(entries: entries).map(\.id) == ["a", "b"])
    }

    /// A trailing space signals "more input expected" so Enter advances to the
    /// effort sub-menu instead of submitting.
    @Test("reasoning models insert a trailing space")
    func reasoningTrailingSpace() throws {
        let entries = [
            entry(id: "r", provider: "xai", name: "Reasoner", supportsReasoningEffort: true),
            entry(id: "p", provider: "xai", name: "Plain", supportsReasoningEffort: false),
        ]
        let rows = LiveModelPicker.rows(entries: entries)
        let reasoning = try #require(rows.first { $0.id == "r" })
        let plain = try #require(rows.first { $0.id == "p" })
        #expect(reasoning.insertText == "xai:r ")
        #expect(plain.insertText == "xai:p")
    }

    @Test("the current model is marked and pre-selected")
    func currentModel() throws {
        let rows = LiveModelPicker.rows(
            entries: duplicateNameCatalog,
            currentModelID: "xai:gpt-5.6-sol"
        )
        let current = try #require(rows.first { $0.isCurrent })
        #expect(current.id == "xai:gpt-5.6-sol")
        #expect(current.label == "xAI · GPT-5.6 Sol (current)")
        #expect(rows.filter(\.isCurrent).count == 1)
    }

    @Test("missing catalog metadata drops its part of the sub-line")
    func sparseMetadata() throws {
        let rows = LiveModelPicker.rows(entries: [
            entry(id: "m", provider: "wafer", name: "M", description: nil, contextWindow: nil),
            entry(id: "n", provider: "wafer", name: "N", description: "   ", contextWindow: 8_000),
        ])
        #expect(try #require(rows.first { $0.id == "m" }).summary == "m")
        #expect(try #require(rows.first { $0.id == "n" }).summary == "n · 8K context")
    }

    /// The overlay carries the catalog key as the row id, because that is what
    /// the selection handler switches to.
    @Test("the overlay preserves catalog keys and pre-selects the current row")
    func overlayShape() throws {
        let overlay = LiveModelPicker.overlay(
            entries: duplicateNameCatalog,
            currentModelID: "xai:gpt-5.6-sol"
        )
        #expect(overlay.id == "model")
        guard case .list(let list) = overlay.content else {
            Issue.record("expected a list overlay")
            return
        }
        #expect(list.rows.map(\.id) == ["gpt-5.6-sol", "xai:gpt-5.6-sol"])
        #expect(list.selectedIndex == 1)
        #expect(list.rows[1].detail?.contains("✓") == true)
        #expect(list.rows[0].detail == "codex:gpt-5.6-sol")
    }
}

@Suite("Model picker resolution")
struct LiveModelPickerResolutionTests {
    /// Provenance: Rust `duplicate_model_names_are_sorted_and_selected_by_provider`.
    /// The bare name is ambiguous and must be refused rather than resolved to
    /// whichever entry happens to come first.
    @Test("a provider-qualified selector picks its own model; the bare name is refused")
    func providerQualifiedSelection() {
        #expect(
            LiveModelPicker.resolve(query: "codex:gpt-5.6-sol", entries: duplicateNameCatalog)
                == "gpt-5.6-sol"
        )
        #expect(
            LiveModelPicker.resolve(query: "xai:gpt-5.6-sol", entries: duplicateNameCatalog)
                == "xai:gpt-5.6-sol"
        )
        #expect(LiveModelPicker.resolve(query: "GPT-5.6 Sol", entries: duplicateNameCatalog) == nil)
    }

    /// The two entries share a display name but not a catalog id — one is
    /// `gpt-5.6-sol`, the other `xai:gpt-5.6-sol`. The raw-id tier therefore
    /// still has exactly one match and resolves, while the display name stays
    /// ambiguous. Ambiguity is per tier, not per model.
    @Test("a raw catalog id resolves even when its display name is ambiguous")
    func rawIDTierIsUnambiguous() {
        #expect(
            LiveModelPicker.resolve(query: "gpt-5.6-sol", entries: duplicateNameCatalog)
                == "gpt-5.6-sol"
        )
    }

    /// When two entries genuinely share a catalog id, that tier goes ambiguous
    /// too and the qualified selector is the only way in.
    @Test("a genuinely shared id is refused at every unqualified tier")
    func sharedIDIsRefused() {
        let entries = [
            entry(id: "shared", provider: "xai", name: "One"),
            entry(id: "shared", provider: "codex", name: "Two"),
        ]
        #expect(LiveModelPicker.resolve(query: "shared", entries: entries) == nil)
        #expect(LiveModelPicker.resolve(query: "xai:shared", entries: entries) == "shared")
    }

    @Test("an unambiguous bare name or slug still resolves")
    func unambiguousFallback() {
        let entries = [
            entry(id: "grok-build", provider: "xai", name: "Grok Build"),
            entry(id: "gpt-5.6-sol", provider: "codex", name: "GPT-5.6 Sol"),
        ]
        #expect(LiveModelPicker.resolve(query: "Grok Build", entries: entries) == "grok-build")
        #expect(LiveModelPicker.resolve(query: "grok-build", entries: entries) == "grok-build")
        #expect(LiveModelPicker.resolve(query: "xai:grok-build", entries: entries) == "grok-build")
    }

    @Test("resolution is case-insensitive and ignores surrounding whitespace")
    func caseAndWhitespace() {
        let entries = [entry(id: "grok-build", provider: "xai", name: "Grok Build")]
        #expect(LiveModelPicker.resolve(query: "  XAI:GROK-BUILD  ", entries: entries)
            == "grok-build")
        #expect(LiveModelPicker.resolve(query: "grok build", entries: entries) == "grok-build")
    }

    /// A qualified selector must win even when a *different* model's bare name
    /// would also have matched, so tier order is load-bearing.
    @Test("the qualified tier wins before the bare-name tier is consulted")
    func tierOrdering() {
        let entries = [
            entry(id: "alpha", provider: "xai", name: "xai:beta"),
            entry(id: "beta", provider: "xai", name: "Beta"),
        ]
        #expect(LiveModelPicker.resolve(query: "xai:beta", entries: entries) == "beta")
    }

    @Test("an empty or unknown query resolves to nothing")
    func emptyAndUnknown() {
        #expect(LiveModelPicker.resolve(query: "", entries: duplicateNameCatalog) == nil)
        #expect(LiveModelPicker.resolve(query: "   ", entries: duplicateNameCatalog) == nil)
        #expect(LiveModelPicker.resolve(query: "nope", entries: duplicateNameCatalog) == nil)
        #expect(LiveModelPicker.resolve(query: "x", entries: []) == nil)
    }

    /// Provenance: Rust `CommandResult::Error(format!("Unknown model: {trimmed}"))`.
    @Test("the refusal message names the trimmed query")
    func unknownMessage() {
        #expect(LiveModelPicker.unknownModelMessage("  GPT-5.6 Sol  ")
            == "Unknown model: GPT-5.6 Sol")
    }
}

/// Provenance: Rust `ModelCommand::suggest_args` → `build_model_items`, and
/// `empty_query_returns_one_row_per_logical_model`.
@Suite("Model picker completions")
struct LiveModelPickerCompletionTests {
    private let entries = [
        entry(id: "gpt-5.6-sol", provider: "codex", name: "GPT-5.6 Sol"),
        entry(id: "grok-build", provider: "xai", name: "Grok Build"),
        entry(id: "r", provider: "xai", name: "Reasoner", supportsReasoningEffort: true),
    ]

    /// An empty query lists the whole catalog, one row per logical model.
    @Test("an empty query offers every model in picker order")
    func emptyQueryListsEverything() {
        let rows = LiveModelPicker.completions(query: "", entries: entries)
        #expect(rows.map(\.selector) == ["codex:gpt-5.6-sol", "xai:grok-build", "xai:r"])
        #expect(LiveModelPicker.completions(query: "   ", entries: entries).count == 3)
    }

    /// The query narrows on the same text upstream fuzzy-matches — provider
    /// label, display name and slug — plus the selector.
    @Test("a query narrows on provider, name, slug or selector")
    func queryNarrows() {
        func selectors(_ query: String) -> [String] {
            LiveModelPicker.completions(query: query, entries: entries).map(\.selector)
        }
        #expect(selectors("codex:") == ["codex:gpt-5.6-sol"])
        // Provider label, not wire id.
        #expect(selectors("OpenAI") == ["codex:gpt-5.6-sol"])
        #expect(selectors("grok") == ["xai:grok-build"])
        #expect(selectors("reason") == ["xai:r"])
        #expect(selectors("xai") == ["xai:grok-build", "xai:r"])
        #expect(selectors("nothing-matches").isEmpty)
    }

    /// Accepting a row replaces the whole composer, so the row has to carry the
    /// command back with it — a bare selector would submit as a prompt.
    @Test("suggestions insert a complete command, not a bare selector")
    func suggestionsCarryTheCommand() throws {
        let suggestions = LiveModelPicker.suggestions(
            query: "codex:",
            entries: entries,
            currentModelID: "gpt-5.6-sol"
        )
        let codex = try #require(suggestions.first)
        #expect(codex.name == "OpenAI Codex · GPT-5.6 Sol (current)")
        #expect(codex.summary == "gpt-5.6-sol · Model description")
        #expect(codex.insertText == "/model codex:gpt-5.6-sol")
    }

    /// The trailing space that says "an effort level may follow" survives into
    /// the inserted command.
    @Test("a reasoning model's row keeps its trailing space")
    func reasoningRowKeepsTrailingSpace() throws {
        let suggestion = try #require(
            LiveModelPicker.suggestions(query: "reason", entries: entries).first
        )
        #expect(suggestion.insertText == "/model xai:r ")
    }

    /// Every offered row must round-trip: what it inserts has to be exactly
    /// what the resolver accepts, or the dropdown would hand the user a
    /// command that then fails as `Unknown model`.
    @Test("every offered row inserts a command the resolver resolves")
    func offeredRowsRoundTripThroughTheResolver() {
        let catalog = LiveModelCatalogResolver.catalog()
        for suggestion in LiveModelPicker.suggestions(query: "", entries: catalog) {
            let selector = suggestion.insertText.dropFirst("/model ".count)
            #expect(
                LiveModelPicker.resolve(query: String(selector), entries: catalog) != nil,
                "\(suggestion.insertText) must resolve"
            )
        }
    }
}

@Suite("Embedded catalog picker entries")
struct LiveModelCatalogEntryTests {
    /// The picker must see real names and context windows, not bare ids —
    /// otherwise every row would read `id · <nothing>`.
    @Test("the embedded catalog supplies display metadata")
    func embeddedCatalogCarriesMetadata() throws {
        let entries = LiveModelCatalogResolver.catalog()
        #expect(!entries.isEmpty)
        for entry in entries {
            #expect(!entry.id.isEmpty)
            #expect(!entry.providerID.isEmpty)
            #expect(!entry.name.isEmpty)
        }
        #expect(entries.contains { $0.contextWindow != nil })
        // Every entry must be reachable by its own qualified selector.
        for entry in entries {
            let selector = LiveModelPicker.selector(for: entry)
            #expect(
                LiveModelPicker.resolve(query: selector, entries: entries) == entry.id,
                "\(selector) must resolve to \(entry.id)"
            )
        }
    }
}

@Suite("Live OpenCode Go catalog")
struct LiveOpenCodeGoCatalogTests {
    @Test("picker entries come from the filtered shared catalog snapshot")
    func filteredSnapshotFeedsPicker() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-picker-opencode-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            OpenCodeGoModels.apiKeyEnv: "fixture-opencode-key",
        ]

        var info = ModelInfo.fallback(slug: "opencode-go:gpt-ish")
        info.id = "opencode-go:gpt-ish"
        info.model = "gpt-ish"
        info.name = "GPT-ish"
        info.provider = .openCodeGo
        info.baseURL = OpenCodeGoModels.apiBaseURLDefault
        info.apiBackend = .chatCompletions

        let remote = OpenCodeGoModelsCatalog(
            entries: OrderedModelMap([
                ("opencode-go:gpt-ish", ModelEntry(
                    info: info,
                    envKey: .single(OpenCodeGoModels.apiKeyEnv)
                ))
            ]),
            descriptors: [],
            warnings: [],
            credentialFingerprint: "6016a36c568a0296"
        )
        let store = LiveModelCatalogStore(
            input: CatalogResolutionInput(),
            environment: environment,
            openGrokHome: home
        )
        store.applyOpenCodeGoCatalog(remote)

        let resolver = LiveModelCatalogResolver(
            environment: environment,
            openGrokHome: home,
            sessionID: "fixture",
            workingDirectory: home,
            catalogSource: { store.snapshot() }
        )
        #expect(!resolver.catalogEntries().contains { $0.id == "opencode-go:gpt-ish" })

        store.updateInput(CatalogResolutionInput(
            models: ModelsSectionConfig(opencodeGoEnabledModels: ["gpt-ish"])
        ))
        #expect(
            resolver.catalogEntries().filter { $0.id == "opencode-go:gpt-ish" }.map(\.id)
                == ["opencode-go:gpt-ish"]
        )
    }
}
