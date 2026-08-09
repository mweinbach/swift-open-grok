// LiveAgentsComposition.swift
//
// Builds the agents/personas modal's row snapshots from the LIVE sources —
// the same loaders the running session uses, never parallel
// re-implementations:
//
//   * Agents:   `AgentDefinitionDiscovery.discover` — the discovery the
//               subagent host resolves spawn names against.
//   * Toggles:  a fresh effective-config read of `[subagents.toggle]`
//               (`load_agent_toggle`, `agents_modal.rs:569-587` at
//               upstream 650c1db7). READ-ONLY: the `t` writer is B9-b2.
//   * Default:  the startup-agent resolution chain
//               (`resolve_default_agent_name`, `agents_modal.rs:712-722` →
//               `MvpAgent::resolve_agent_definition`,
//               `xai-grok-shell/src/agent/mvp_agent/agent_ops.rs:3882-4010`).
//   * Personas: `SubagentPersonaLoader` — the B9-b0 loader that feeds
//               `resolveRuntimeConfig`, so the tab lists exactly the names
//               a live spawn can resolve. The port has no bundle-catalog
//               client (`x.ai/bundle/status` — recorded B9 deferral), so
//               upstream's bundle-catalog column (`agents_modal.rs:451-469`)
//               is absent and inline `[subagents.personas]` entries — which
//               upstream's modal MISSES but the live seam resolves first —
//               are listed instead, tagged `config`.

import Foundation
import OpenGrokAgentDefinitions
import OpenGrokConfig
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSubagentResolution
import OpenGrokToolTypes

enum LiveAgentsComposition {
    /// The one overlay id; pushing it again replaces the open modal.
    static let overlayID = "agents"

    /// Row-id prefixes for the `Enter`/`o` view round-trip
    /// (`PagerOverlayOutcome.selected` with `"view:agent:{i}"` /
    /// `"view:persona:{i}"` — see `PagerOverlayStack.handle`'s `.agents`
    /// arm).
    static let viewAgentRowPrefix = "view:agent:"
    static let viewPersonaRowPrefix = "view:persona:"

    /// Row-id prefixes for the B9-b2 mutation round-trips (`t`/`s`,
    /// `agents_modal.rs:2152-2196`), riding the same selection channel.
    static let toggleRowPrefix = "toggle:"
    static let defaultRowPrefix = "default:"

    /// Map the controller's intent tab onto the render layer's modal tab.
    static func tab(for intent: OpenGrokPagerAgentsTab) -> PagerAgentsTab {
        switch intent {
        case .agents: return .agents
        case .personas: return .personas
        }
    }

    // MARK: - Modal snapshot

    /// Build the whole modal, both tabs snapshotted fresh at open —
    /// upstream's `AgentsModalState::new` (`agents_modal.rs:287-320`)
    /// discovers agents and merges personas at construction.
    static func overlay(
        initialTab: PagerAgentsTab,
        workingDirectory: String,
        openGrokHome: URL,
        modelAgentType: String?,
        environment: [String: String]
    ) -> PagerAgentsOverlay {
        let cwd = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        let document = effectiveDocument(cwd: cwd, environment: environment)
        let toggles = loadAgentToggle(document: document)
        return PagerAgentsOverlay(
            activeTab: initialTab,
            agents: agentRows(cwd: cwd, toggles: toggles, environment: environment),
            personas: personaRows(document: document, openGrokHome: openGrokHome, cwd: cwd),
            defaultAgentName: resolveDefaultAgentName(
                cwd: cwd,
                modelAgentType: modelAgentType,
                document: document,
                environment: environment
            )
        )
    }

    /// A fresh effective-config load, like upstream's
    /// `load_effective_config()` inside `load_agent_toggle` (`:570`) and
    /// `load_agent_selection_config` (`:698-704`) — the modal shows what a
    /// NEW session would read, not this session's boot-time snapshot. The
    /// same authority chain `resolveUIConfig` reads. Called fresh at open,
    /// at each mutation's compare, and again after each write.
    static func effectiveDocument(
        cwd: URL,
        environment: [String: String]
    ) -> TOMLValue {
        (try? loadAuthorityComposition(
            cwd: cwd,
            environment: environment
        ).effective()) ?? .table(TOMLTable())
    }

    // MARK: - `[subagents.toggle]` reader

    /// `load_agent_toggle` (`agents_modal.rs:569-587`): the toggle map from
    /// the effective config, bool values only, everything else ignored.
    /// The `toggle_agent` writer lives in `PagerAgentsConfigStore`.
    static func loadAgentToggle(document: TOMLValue) -> [String: Bool] {
        guard let table = document[path: ["subagents", "toggle"]]?.table else { return [:] }
        var toggles: [String: Bool] = [:]
        for (key, value) in table.pairs {
            if let enabled = value.boolValue { toggles[key] = enabled }
        }
        return toggles
    }

    // MARK: - Agents tab

    /// The five user-visible built-ins, in upstream's order
    /// (`user_visible_builtins`, `agents_modal.rs:275-283`). The internal
    /// variants (concise/plan/ask-user/codex/opencode/orchestrator) are
    /// deliberately skipped, as upstream skips them.
    static let userVisibleBuiltins: [BuiltinAgentName] = [
        .grokBuild, .generalPurpose, .explore, .plan, .browserUse
    ]

    /// `build_agent_list` (`agents_modal.rs:382-449`): the visible
    /// built-ins first, then discovery, deduped by scope priority
    /// (Project 3 > User 2 > Bundled 1 > BuiltIn 0, `:404-411`), with
    /// builtin-subagent names accepted only at Project scope (`:416-419`).
    static func agentRows(
        cwd: URL,
        toggles: [String: Bool],
        environment: [String: String]
    ) -> [PagerAgentsListEntry] {
        struct Row {
            var entry: PagerAgentsListEntry
            var priority: Int
        }
        var rows: [Row] = userVisibleBuiltins.map { builtin in
            let definition = builtin.definition
            return Row(
                entry: listEntry(
                    for: definition,
                    scope: .builtIn,
                    sourcePath: nil,
                    isBuiltin: true,
                    enabled: toggles[definition.name] ?? true
                ),
                priority: PagerAgentsScope.builtIn.priority
            )
        }
        let subagentNames = BuiltinAgentName.subagentVariants.map(\.definition.name)
        for definition in AgentDefinitionDiscovery(environment: environment).discover(at: cwd) {
            guard definition.scope != .builtIn else { continue }
            // A builtin-subagent name (general-purpose/explore/plan) may
            // only be shadowed from Project scope (`:416-419`).
            if subagentNames.contains(definition.name), definition.scope != .project {
                continue
            }
            let scope = pagerScope(for: definition.scope)
            let entry = listEntry(
                for: definition,
                scope: scope,
                sourcePath: definition.sourcePath,
                isBuiltin: false,
                enabled: toggles[definition.name] ?? true
            )
            if let existing = rows.firstIndex(where: { $0.entry.name == definition.name }) {
                if scope.priority > rows[existing].priority {
                    rows[existing] = Row(entry: entry, priority: scope.priority)
                }
            } else {
                rows.append(Row(entry: entry, priority: scope.priority))
            }
        }
        return rows.map(\.entry)
    }

    private static func pagerScope(for scope: AgentScope) -> PagerAgentsScope {
        switch scope {
        case .project: return .project
        case .user: return .user
        case .bundled: return .bundled
        case .builtIn: return .builtIn
        }
    }

    private static func listEntry(
        for definition: AgentDefinition,
        scope: PagerAgentsScope,
        sourcePath: String?,
        isBuiltin: Bool,
        enabled: Bool
    ) -> PagerAgentsListEntry {
        PagerAgentsListEntry(
            name: definition.name,
            description: definition.description,
            scope: scope,
            sourcePath: sourcePath,
            enabled: enabled,
            isBuiltin: isBuiltin,
            detailLines: formatAgentDetail(
                definition: definition,
                sourcePath: sourcePath,
                scope: scope
            ),
            // `Enter` fallback for path-less entries with a prompt body
            // (`:2134-2141`); file-based entries view their source file.
            viewContent: sourcePath == nil && definition.promptBody != nil
                ? synthesizedAgentMarkdown(for: definition)
                : nil
        )
    }

    /// `format_agent_detail` (`agents_modal.rs:780-826`), line for line.
    /// The port's `AgentToolDefinition` carries no `name_override`, so the
    /// tool name is the id's last `:` segment — the same fallback upstream
    /// applies when no override is set (`:795-799`).
    static func formatAgentDetail(
        definition: AgentDefinition,
        sourcePath: String?,
        scope: PagerAgentsScope
    ) -> [String] {
        var lines: [String] = []
        lines.append("  Model: \(definition.model)")
        let modeLabel = definition.promptMode == .extend ? "extend" : "full"
        lines.append("  Prompt mode: \(modeLabel)")
        let tools = definition.toolConfig.tools
        if tools.isEmpty {
            lines.append("  Tools: (none)")
        } else {
            lines.append("  Tools (\(tools.count)): ")
            for tool in tools {
                lines.append("    \u{2022} \(tool.name)")
            }
        }
        if !definition.skills.isEmpty {
            lines.append("  Skills: \(definition.skills.joined(separator: ", "))")
        }
        if let sourcePath {
            lines.append("  Source: \(sourcePath)")
        }
        let scopeLabel: String
        switch scope {
        case .builtIn: scopeLabel = "built-in"
        case .project: scopeLabel = "project"
        case .user: scopeLabel = "user"
        case .bundled: scopeLabel = "bundled"
        }
        lines.append("  Scope: \(scopeLabel)")
        if let body = definition.promptBody {
            let rendered = renderPromptBody(body)
            let truncated = String(rendered.prefix(120))
            if rendered.count > 120 {
                lines.append("  Prompt extension: \(truncated)...")
                lines.append("  (Enter to view full)")
            } else {
                lines.append("  Prompt extension: \(truncated)")
            }
        } else if sourcePath != nil {
            lines.append("  Prompt extension: (in file \u{2014} Enter to view)")
        } else {
            lines.append("  Prompt extension: (none)")
        }
        return lines
    }

    /// `synthesize_agent_markdown` (`agents_modal.rs:863-872`): the prompt
    /// body with template variables resolved, or the no-extension notice.
    static func synthesizedAgentMarkdown(for definition: AgentDefinition) -> String {
        if let body = definition.promptBody {
            return renderPromptBody(body)
        }
        return "*\(definition.name) uses the base system prompt with no additional instructions.*\n"
    }

    /// `render_prompt_body` (`agents_modal.rs:875-889`). Upstream builds
    /// the kind→name map from each tool's `kind` field; the port's
    /// `AgentToolDefinition` carries no kind, so the substitution uses the
    /// SAME production naming the live `spawn_subagent` descriptors render
    /// with (`LiveSubagentHost.fragmentToolNaming`) — the modal previews
    /// the names the session actually advertises (recorded approximation).
    static func renderPromptBody(_ body: String) -> String {
        substituteToolPlaceholders(body) { kind in
            LiveSubagentHost.fragmentToolNaming.toolForKind(kind)
        }
    }

    // MARK: - Default-agent resolution

    /// `resolve_default_agent_name` (`agents_modal.rs:712-722`), which is
    /// `MvpAgent::resolve_agent_definition` with no profile path and no
    /// ACP profile (`agent_ops.rs:3882-4010`):
    ///
    ///   1. model `agentType` when it names a strict harness AND neither
    ///      `GROK_AGENT` nor `[agent] name` is set;
    ///   2. `[agent] definition` file (fall through on load failure);
    ///   3. `[agent] name` via discovery (fall through when unknown);
    ///   4. `GROK_AGENT` (special names → built-ins, absolute path →
    ///      file, name → discovery, each falling back to the built-in
    ///      default);
    ///   5. the built-in default, `grok-build-plan`;
    ///   plus the trailing strict-harness re-check (`:3990-4009`).
    ///
    /// The `s` writer (`set_default_agent`, `:730-752`) lives in
    /// `PagerAgentsConfigStore`; after a successful write this chain
    /// re-runs against a fresh load (`refresh_default_agent`, `:723-726`).
    static func resolveDefaultAgentName(
        cwd: URL,
        modelAgentType: String?,
        document: TOMLValue,
        environment: [String: String]
    ) -> String {
        let discovery = AgentDefinitionDiscovery(environment: environment)
        let grokAgentValue = environment["GROK_AGENT"]
        let envSet = !(grokAgentValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Upstream's `config_agent_explicitly_set` is `name.is_some()`
        // (`:3893`): presence, not non-emptiness.
        let configName = document[path: ["agent", "name"]]?.stringValue
        let configSet = configName != nil
        let strictRequired: String?
        if let modelAgentType, isStrictHarnessAgentType(modelAgentType) {
            strictRequired = modelAgentType
        } else {
            strictRequired = nil
        }
        if !envSet, !configSet, let required = strictRequired,
           let definition = discovery.byName(required, in: cwd) {
            return definition.name
        }
        // `[agent] definition` — an explicit file path (`:3932-3950`);
        // load failure warns upstream and falls through here too.
        if let path = document[path: ["agent", "definition"]]?.stringValue,
           !path.isEmpty,
           let definition = try? AgentDefinition.fromFile(URL(fileURLWithPath: path)) {
            return definition.name
        }
        // `[agent] name` via discovery (`:3951-3963`); unknown names fall
        // through.
        if let configName, let definition = discovery.byName(configName, in: cwd) {
            return definition.name
        }
        // `GROK_AGENT` (`:3964-3989`), arm for arm.
        let resolved: AgentDefinition
        switch grokAgentValue {
        case "browser-use", "browser_use":
            resolved = .browserUse()
        case "grok-build-concise", "grok_build_concise":
            resolved = .grokBuildConcise()
        case .some(let value) where value.hasPrefix("/"):
            resolved = (try? AgentDefinition.fromFile(URL(fileURLWithPath: value)))
                ?? .grokBuildPlan()
        case .some(let value):
            resolved = discovery.byName(value, in: cwd) ?? .grokBuildPlan()
        case .none:
            resolved = .grokBuildPlan()
        }
        // The trailing strict-harness re-check (`:3990-4009`): the model's
        // required harness wins over the chain default when nothing was
        // explicitly set and discovery knows the name.
        if !envSet, !configSet, let required = strictRequired,
           resolved.name != required,
           let definition = discovery.byName(required, in: cwd) {
            return definition.name
        }
        return resolved.name
    }

    // MARK: - Personas tab

    /// The B9-b0 loader's view: the exact effective persona map a spawn
    /// resolves against (`SubagentPersonaLoader.basePersonas` +
    /// `effectivePersonas`), listed group-by-precedence — config (inline)
    /// first, then project, user, bundled, each alphabetical. Upstream's
    /// modal lists the bundle catalog first and never shows inline config
    /// personas (`merge_persona_lists`, `agents_modal.rs:473-501`); with
    /// no bundle-catalog client in this port, the honest list is the one
    /// the live seam consumes (recorded divergence).
    ///
    /// `projectTrusted: true` mirrors upstream's modal, which reads
    /// `{cwd}/.opengrok/personas` without a trust gate (`:490-499`) even
    /// though resolution gates it — cost: in an untrusted repo the modal
    /// shows a project persona a spawn would not resolve.
    static func personaRows(
        document: TOMLValue,
        openGrokHome: URL,
        cwd: URL
    ) -> [PagerAgentsPersonaEntry] {
        let base = SubagentPersonaLoader.basePersonas(
            configDocument: document,
            openGrokHome: openGrokHome
        )
        let effective = SubagentPersonaLoader.effectivePersonas(
            base: base,
            cwd: cwd,
            projectTrusted: true
        )
        let entries = effective.map { name, persona in
            personaEntry(name: name, persona: persona, openGrokHome: openGrokHome, cwd: cwd)
        }
        let precedence = ["config": 0, "project": 1, "user": 2, "bundled": 3]
        return entries.sorted { lhs, rhs in
            let lhsRank = precedence[lhs.scopeLabel ?? ""] ?? 4
            let rhsRank = precedence[rhs.scopeLabel ?? ""] ?? 4
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.name < rhs.name
        }
    }

    private static func personaEntry(
        name: String,
        persona: SubagentPersona,
        openGrokHome: URL,
        cwd: URL
    ) -> PagerAgentsPersonaEntry {
        // Description sniffing per `persona_detail_from_local_file`
        // (`agents_modal.rs:538-550`): the `description` field, else the
        // first paragraph of `instructions`.
        let description = persona.description
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            ?? persona.instructions.flatMap(firstParagraph(of:))
        return PagerAgentsPersonaEntry(
            name: name,
            description: description,
            hasInputs: !persona.inputs.isEmpty,
            hasOutputs: !persona.outputs.isEmpty,
            sourcePath: persona.sourcePath,
            scopeLabel: personaScopeLabel(persona: persona, openGrokHome: openGrokHome, cwd: cwd),
            // The `Enter` stand-in for inline entries, which have no file
            // to open: their definition fields as TOML-shaped text. The
            // b3 persona detail modal supersedes this.
            viewContent: persona.sourcePath == nil ? inlinePersonaText(persona) : nil
        )
    }

    /// Scope tag from the resolved persona's source: `config` for inline
    /// entries (no upstream label exists — upstream's modal never lists
    /// them; recorded), `project`/`user` per `ConfigFileScope::label`
    /// (`agents_modal.rs:136-141`), `bundled` per the bundle-dir stamping
    /// (`:483-486`).
    static func personaScopeLabel(
        persona: SubagentPersona,
        openGrokHome: URL,
        cwd: URL
    ) -> String {
        guard let sourcePath = persona.sourcePath else { return "config" }
        let source = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath().path
        let bundled = openGrokHome
            .appendingPathComponent("bundled", isDirectory: true)
            .appendingPathComponent("personas", isDirectory: true)
            .resolvingSymlinksInPath().path
        if source.hasPrefix(bundled + "/") { return "bundled" }
        let project = cwd
            .appendingPathComponent(".opengrok", isDirectory: true)
            .appendingPathComponent("personas", isDirectory: true)
            .resolvingSymlinksInPath().path
        if source.hasPrefix(project + "/") { return "project" }
        return "user"
    }

    /// First prose paragraph of an instructions blob — the port of
    /// `extract_first_paragraph` (`skills/discovery.rs:611-613`), reduced
    /// from upstream's pulldown-cmark walk to a plain-text scan that skips
    /// the same block kinds (headings, lists, blockquotes, tables, fenced
    /// code) and flattens the first paragraph's newlines (recorded
    /// approximation — no markdown parser at this seam).
    static func firstParagraph(of text: String) -> String? {
        var paragraph: [String] = []
        var inFence = false
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if line.isEmpty {
                if !paragraph.isEmpty { break }
                continue
            }
            let skippable = line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("|")
                || line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
            if skippable {
                if !paragraph.isEmpty { break }
                continue
            }
            paragraph.append(line)
        }
        guard !paragraph.isEmpty else { return nil }
        return paragraph.joined(separator: " ")
    }

    /// The inline-persona definition view: the fields the config table
    /// declared, re-serialized as TOML-shaped text so the viewer shows the
    /// same keys a file-backed persona's file would.
    static func inlinePersonaText(_ persona: SubagentPersona) -> String {
        var lines: [String] = []
        if let description = persona.description {
            lines.append("description = \"\(description)\"")
        }
        if let instructionsFile = persona.instructionsFile {
            lines.append("instructions_file = \"\(instructionsFile)\"")
        }
        if let instructions = persona.instructions {
            lines.append("instructions = \"\"\"")
            lines.append(instructions)
            lines.append("\"\"\"")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Mutations (`t`/`s`, B9-b2)

    /// `load_config_agent_name` (`agents_modal.rs:707-709`): the EXPLICIT
    /// `[agent] name` from the effective config, empty-string filtered.
    /// This — not the resolved default — is what `s` compares against
    /// (`:2155`), so pressing `s` on the entry the chain merely FALLS BACK
    /// to still sets the key rather than clearing it.
    static func configAgentName(document: TOMLValue) -> String? {
        document[path: ["agent", "name"]]?.stringValue
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Resolve a `t`/`s` mutation row against the real config writers and
    /// return the refreshed overlay to swap in, or nil when the row id is
    /// not a mutation (the view rows fall through to `viewPayload`).
    ///
    /// Both writers target the USER config.toml
    /// (`grok_home().join("config.toml")`, `agents_modal.rs:731`/`:755`),
    /// never the project one — hence `openGrokHome`, not `cwd`.
    static func applyingMutation(
        rowID: String,
        to current: PagerAgentsOverlay,
        workingDirectory: String,
        openGrokHome: URL,
        modelAgentType: String?,
        environment: [String: String]
    ) -> PagerAgentsOverlay? {
        let cwd = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        let store = PagerAgentsConfigStore(
            configPath: openGrokHome.appendingPathComponent("config.toml")
        )
        if rowID.hasPrefix(toggleRowPrefix) {
            guard let index = Int(rowID.dropFirst(toggleRowPrefix.count)),
                  current.agents.indices.contains(index)
            else { return nil }
            return togglingAgent(
                at: index, current: current, store: store,
                cwd: cwd, environment: environment
            )
        }
        if rowID.hasPrefix(defaultRowPrefix) {
            guard let index = Int(rowID.dropFirst(defaultRowPrefix.count)),
                  current.agents.indices.contains(index)
            else { return nil }
            return settingDefaultAgent(
                at: index, current: current, store: store,
                cwd: cwd, modelAgentType: modelAgentType, environment: environment
            )
        }
        return nil
    }

    /// The `t` arm (`agents_modal.rs:2183-2196`): write `!entry.enabled`,
    /// then `rebuild_agents` (`:322-328`) — a fresh effective-config
    /// toggle read plus fresh discovery, selection clamped to the new
    /// length, entries rebuilt collapsed (upstream constructs them with
    /// `expanded: false`). Success paints NO message — the flipped dot
    /// and ` [off]` marker are the feedback. A failed write rebuilds
    /// nothing, so the list keeps showing what disk still says, and the
    /// error surfaces as the inline message (`:2192`).
    private static func togglingAgent(
        at index: Int,
        current: PagerAgentsOverlay,
        store: PagerAgentsConfigStore,
        cwd: URL,
        environment: [String: String]
    ) -> PagerAgentsOverlay {
        var updated = current
        let entry = current.agents[index]
        do {
            try store.toggleAgent(name: entry.name, enabled: !entry.enabled)
            let document = effectiveDocument(cwd: cwd, environment: environment)
            updated.agents = agentRows(
                cwd: cwd,
                toggles: loadAgentToggle(document: document),
                environment: environment
            )
            if updated.selectedAgent >= updated.agents.count {
                updated.selectedAgent = max(0, updated.agents.count - 1)
            }
            updated.expandedAgents = []
        } catch {
            updated.message = .error(writerMessage(error))
        }
        return updated
    }

    /// The `s` arm (`agents_modal.rs:2152-2181`): a fresh
    /// `load_config_agent_name` read decides set vs clear — the selected
    /// entry already being the explicit `[agent] name` means CLEAR the
    /// key (`:2156-2160`); anything else (including a disabled entry —
    /// upstream applies no enabled guard) sets it. On success the default
    /// re-resolves through the full chain against a fresh post-write load
    /// (`refresh_default_agent`, `:723-726`) and the info message quotes
    /// the RE-RESOLVED name (`:2164-2174`) — after clearing, that is
    /// whatever the chain falls back to, not the entry just cleared. The
    /// list is NOT rebuilt (upstream's `s` never calls `rebuild_agents`);
    /// only the marker moves. A failed write re-resolves nothing.
    private static func settingDefaultAgent(
        at index: Int,
        current: PagerAgentsOverlay,
        store: PagerAgentsConfigStore,
        cwd: URL,
        modelAgentType: String?,
        environment: [String: String]
    ) -> PagerAgentsOverlay {
        var updated = current
        let name = current.agents[index].name
        let document = effectiveDocument(cwd: cwd, environment: environment)
        let isAlreadyDefault = configAgentName(document: document) == name
        do {
            try store.setDefaultAgent(isAlreadyDefault ? nil : name)
            let refreshed = effectiveDocument(cwd: cwd, environment: environment)
            updated.defaultAgentName = resolveDefaultAgentName(
                cwd: cwd,
                modelAgentType: modelAgentType,
                document: refreshed,
                environment: environment
            )
            updated.message = .info(isAlreadyDefault
                ? "Cleared \u{2014} new sessions use '\(updated.defaultAgentName)'"
                : "New sessions will start with '\(updated.defaultAgentName)'")
        } catch {
            updated.message = .error(writerMessage(error))
        }
        return updated
    }

    /// The store's errors carry upstream's exact copy in `message`; any
    /// other thrown error would be a programming surprise, surfaced
    /// verbatim rather than swallowed.
    private static func writerMessage(_ error: Error) -> String {
        (error as? PagerAgentsConfigWriteError)?.message ?? "\(error)"
    }

    // MARK: - View resolution (`Enter`/`o`)

    /// Resolve the document-overlay payload for a view row id, from the
    /// OPEN overlay's snapshot. Upstream opens its line viewer over the
    /// modal from the same selection (`agent_view/modals.rs:27-47`); the
    /// title is `"{name} — prompt extension"` (`agents_modal.rs:2127`) for
    /// agents and the b3 detail modal's `"persona: {name}"`
    /// (`persona_detail.rs:382`) for personas. Returns nil for a stale or
    /// unreadable target — upstream's viewer-open failure is silent too
    /// (`open_markdown` returning `None` opens nothing).
    static func viewPayload(
        rowID: String,
        overlay: PagerAgentsOverlay
    ) -> (title: String, content: String)? {
        if rowID.hasPrefix(viewAgentRowPrefix) {
            guard let index = Int(rowID.dropFirst(viewAgentRowPrefix.count)),
                  overlay.agents.indices.contains(index)
            else { return nil }
            let entry = overlay.agents[index]
            let title = "\(entry.name) \u{2014} prompt extension"
            if let path = entry.sourcePath,
               let content = try? String(contentsOfFile: path, encoding: .utf8) {
                return (title, content)
            }
            if let content = entry.viewContent {
                return (title, content)
            }
            return nil
        }
        if rowID.hasPrefix(viewPersonaRowPrefix) {
            guard let index = Int(rowID.dropFirst(viewPersonaRowPrefix.count)),
                  overlay.personas.indices.contains(index)
            else { return nil }
            let entry = overlay.personas[index]
            let title = "persona: \(entry.name)"
            if let path = entry.sourcePath,
               let content = try? String(contentsOfFile: path, encoding: .utf8) {
                return (title, content)
            }
            if let content = entry.viewContent {
                return (title, content)
            }
            return nil
        }
        return nil
    }
}
