// LiveExtensionsComposition.swift
//
// Builds the extensions modal's row snapshots from the LIVE sources — the
// same loaders the running session uses, never parallel re-implementations:
//
//   * Hooks:   `LiveHooksComposition.load` → `HookRegistry.hookInfos`,
//              with the disabled-names file honored.
//   * Skills:  `LiveSkills.discover` (the discovery slash dispatch uses).
//   * Plugins: `PluginInstallRegistry.load` off the real `registry.json` —
//              the honest subset this port can back (upstream's Plugins tab
//              additionally shows per-plugin component counts from the
//              shell, a channel this port does not have).
//   * MCP:     the session's own `MCPServerConnection` list — the facts
//              `/mcps` already shows.
//
// The Marketplace tab is deliberately data-free: this port has no
// marketplace fetch channel in the TUI, so the tab points at the CLI route
// instead of painting a fake source list (AGENTS.md §4).

import Foundation
import OpenGrokAgentDefinitions
import OpenGrokHooks
import OpenGrokHooksPluginTypes
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokPluginMarketplace

public enum LiveExtensionsComposition {
    /// The one overlay id; pushing it again replaces the open modal.
    public static let overlayID = "extensions"

    /// Row-id prefix for the `r` reload round-trip
    /// (`PagerOverlayOutcome.selected` with `"reload:{tab}"`).
    public static let reloadRowPrefix = "reload:"

    /// Map the controller's intent tab onto the render layer's modal tab.
    public static func tab(for intent: OpenGrokPagerExtensionsTab) -> PagerExtensionsTab {
        switch intent {
        case .hooks: return .hooks
        case .plugins: return .plugins
        case .marketplace: return .marketplace
        case .skills: return .skills
        case .mcpServers: return .mcpServers
        }
    }

    /// Build the whole modal, all four data tabs snapshotted fresh at open —
    /// upstream loads every tab's data when the modal opens, so Tab never
    /// lands on stale emptiness.
    public static func overlay(
        tab: PagerExtensionsTab,
        workingDirectory: String,
        openGrokHome: URL,
        sessionID: String,
        connections: [MCPServerConnection],
        environment: [String: String]
    ) -> PagerExtensionsOverlay {
        PagerExtensionsOverlay(
            activeTab: tab,
            hooks: hookRows(
                workingDirectory: workingDirectory,
                openGrokHome: openGrokHome,
                sessionID: sessionID,
                environment: environment
            ),
            skills: skillRows(
                workingDirectory: workingDirectory,
                openGrokHome: openGrokHome,
                environment: environment
            ),
            plugins: pluginRows(openGrokHome: openGrokHome),
            mcpServers: mcpRows(connections: connections)
        )
    }

    /// `r` — re-call the loader for one tab and swap the rows in, keeping
    /// every piece of navigation state (tab, filters, query, expansion).
    public static func reloaded(
        _ overlay: PagerExtensionsOverlay,
        tab: PagerExtensionsTab,
        workingDirectory: String,
        openGrokHome: URL,
        sessionID: String,
        connections: [MCPServerConnection],
        environment: [String: String]
    ) -> PagerExtensionsOverlay {
        var next = overlay
        switch tab {
        case .hooks:
            next.hooks = hookRows(
                workingDirectory: workingDirectory,
                openGrokHome: openGrokHome,
                sessionID: sessionID,
                environment: environment
            )
        case .skills:
            next.skills = skillRows(
                workingDirectory: workingDirectory,
                openGrokHome: openGrokHome,
                environment: environment
            )
        case .plugins:
            next.plugins = pluginRows(openGrokHome: openGrokHome)
        case .mcpServers:
            next.mcpServers = mcpRows(connections: connections)
        case .marketplace:
            break
        }
        return next
    }

    // MARK: - Hooks

    /// The same load path the session's permission pipeline uses
    /// (`LiveHooksComposition.load` → config-declared plus file-discovered
    /// hooks), plus the disabled-names file so the `[disabled]` badge tells
    /// the truth about what would actually fire.
    static func hookRows(
        workingDirectory: String,
        openGrokHome: URL,
        sessionID: String,
        environment: [String: String]
    ) -> [PagerExtensionsHookRow] {
        let loaded = LiveHooksComposition.load(
            sessionId: sessionID,
            workspaceRoot: URL(fileURLWithPath: workingDirectory),
            cwd: workingDirectory,
            environment: environment
        )
        let disabled = disabledHookNames(environment: environment)
        let isDefaultHome = isDefaultGrokHome(environment: environment)
        return loaded.result.registry.hookInfos(disabledNames: disabled).map { info in
            PagerExtensionsHookRow(
                event: info.event.description,
                matcher: info.matcher,
                command: info.command ?? info.url,
                sourceDir: info.sourceDir,
                sourceLabel: sourceLabel(
                    forSourceDir: info.sourceDir,
                    grokHome: openGrokHome,
                    isDefaultGrokHome: isDefaultHome,
                    homeDirectory: environment["HOME"]
                ),
                disabled: info.disabled
            )
        }
    }

    // MARK: - Skills

    static func skillRows(
        workingDirectory: String,
        openGrokHome: URL,
        environment: [String: String]
    ) -> [PagerExtensionsSkillRow] {
        let isDefaultHome = isDefaultGrokHome(environment: environment)
        return LiveSkills.discover(
            cwd: URL(fileURLWithPath: workingDirectory),
            environment: environment
        ).map { skill in
            PagerExtensionsSkillRow(
                // `skill.label()` — display name over name
                // (`xai-grok-tools/src/implementations/skills/types.rs:136-138`).
                label: skill.displayName ?? skill.name,
                source: skillSource(
                    skill,
                    grokHome: openGrokHome,
                    isDefaultGrokHome: isDefaultHome
                ),
                author: skill.author,
                description: skill.shortDescription ?? skill.description,
                path: skill.path,
                tools: skill.allowedTools ?? [],
                enabled: skill.enabled
            )
        }
    }

    // MARK: - Plugins

    static func pluginRows(openGrokHome: URL) -> [PagerExtensionsPluginRow] {
        let location = PluginInstallLocation(grokHome: openGrokHome)
        let registry = PluginInstallRegistry.load(from: location.registryURL)
        return registry.repositories
            .sorted { $0.repoKey < $1.repoKey }
            .map { record in
                PagerExtensionsPluginRow(
                    name: record.repoKey,
                    source: record.sourceIdentifier,
                    url: record.url,
                    path: record.path,
                    ref: record.ref,
                    sha: record.sha,
                    pluginNames: record.pluginNames,
                    enabled: record.enabled
                )
            }
    }

    // MARK: - MCP

    static func mcpRows(connections: [MCPServerConnection]) -> [PagerExtensionsMCPRow] {
        connections.map { connection in
            PagerExtensionsMCPRow(
                name: connection.name,
                toolNames: connection.toolNames,
                failure: connection.failure
            )
        }
    }

    // MARK: - Display helpers

    /// Upstream shows `~/.opengrok` only for the *default* home and the
    /// literal `$OPENGROK_HOME` for an override
    /// (`display_grok_home_prefix_for`, `pager-render/src/util.rs:22-28`).
    static func isDefaultGrokHome(environment: [String: String]) -> Bool {
        (environment["OPENGROK_HOME"] ?? "").isEmpty
    }

    /// Port of `derive_source_label` (`extensions_modal.rs:2238-2303`):
    /// plugin dirs, the global hooks dir, `.claude` settings, project hooks,
    /// then the abbreviated custom-directory fallback. The upstream
    /// `is_custom` half of the return drives the remove key and is dropped —
    /// this viewer removes nothing.
    ///
    /// Every comparison runs on symlink-resolved paths. Upstream compares
    /// raw strings because Rust's `read_dir` preserves the prefix it was
    /// given, so a hook's `source_dir` and `grok_home()` always agree
    /// byte-for-byte. Foundation's `contentsOfDirectory(at:)` does NOT — it
    /// canonicalizes the URLs it returns (`/var/…` comes back
    /// `/private/var/…`) — so a raw prefix check here mislabels the
    /// session's own global hooks "Custom:" whenever `$OPENGROK_HOME` sits
    /// behind a symlink.
    static func sourceLabel(
        forSourceDir sourceDir: String,
        grokHome: URL,
        isDefaultGrokHome: Bool,
        homeDirectory: String?
    ) -> String {
        func normalized(_ path: String) -> String {
            path.replacingOccurrences(of: "\\", with: "/")
        }
        func comparisonKey(_ path: String) -> String {
            #if os(Windows)
            return path.lowercased()
            #else
            return path
            #endif
        }
        func isEqualOrDescendant(_ path: String, of base: String) -> Bool {
            let pathKey = comparisonKey(path)
            let baseKey = comparisonKey(base)
            return pathKey == baseKey || pathKey.hasPrefix(baseKey + "/")
        }
        let source = normalized(URL(fileURLWithPath: sourceDir).resolvingSymlinksInPath().path)
        let homeURL = grokHome.resolvingSymlinksInPath()
        func pluginName(_ subdir: String) -> String? {
            // User grok home (`OPENGROK_HOME`-aware).
            let base = normalized(homeURL.appendingPathComponent(subdir).path)
            if comparisonKey(source).hasPrefix(comparisonKey(base) + "/") {
                let rest = source.dropFirst(base.count + 1)
                if let first = rest.split(separator: "/").first, !first.isEmpty {
                    return String(first)
                }
            }
            // Project-scoped `.opengrok/<subdir>/<name>` anywhere in the path.
            let components = source.split(separator: "/").map(String.init)
            guard components.count >= 3 else { return nil }
            for index in 0...(components.count - 3)
            where components[index] == ".opengrok"
                && components[index + 1] == subdir
                && !components[index + 2].isEmpty {
                return components[index + 2]
            }
            return nil
        }
        if let name = pluginName("plugins") ?? pluginName("installed-plugins") {
            return "Plugin: \(name)"
        }
        let globalHooks = normalized(homeURL.appendingPathComponent("hooks").path)
        if isEqualOrDescendant(source, of: globalHooks) {
            return "Global hooks"
        }
        if source.contains("/.claude/") {
            return "Claude settings"
        }
        if source.hasSuffix("/.opengrok/hooks") || source.contains("/.opengrok/hooks/") {
            return "Project hooks"
        }
        let grokPath = normalized(homeURL.path)
        if isEqualOrDescendant(source, of: grokPath) {
            var rest = String(source.dropFirst(grokPath.count))
            if rest.hasPrefix("/") { rest.removeFirst() }
            let prefix = isDefaultGrokHome ? "~/.opengrok" : "$OPENGROK_HOME"
            return "Custom: \(prefix)/\(rest)"
        }
        if let home = homeDirectory, !home.isEmpty {
            let resolvedHome = normalized(URL(fileURLWithPath: home).resolvingSymlinksInPath().path)
            if isEqualOrDescendant(source, of: resolvedHome) {
                return "Custom: ~\(source.dropFirst(resolvedHome.count))"
            }
        }
        return "Custom: \(source)"
    }

    /// Port of `skill_source_str` (`extensions_modal.rs:2351-2381`),
    /// resolved from scope plus path. Upstream branches on the richer
    /// `config_source`, which this port's `SkillInfo` does not carry —
    /// scope + path reproduces the same strings for every case discovery
    /// can actually produce here (recorded approximation).
    static func skillSource(
        _ skill: SkillInfo,
        grokHome: URL,
        isDefaultGrokHome: Bool
    ) -> String {
        switch skill.scope {
        case .user:
            if skill.path.hasPrefix(grokHome.path) {
                let prefix = isDefaultGrokHome ? "~/.opengrok" : "$OPENGROK_HOME"
                return "\(prefix)/skills"
            }
            if skill.path.contains("/.claude/") {
                return "~/.claude/skills"
            }
            return "user"
        case .repo, .local:
            if skill.path.contains("/.opengrok/") {
                return ".opengrok/skills"
            }
            if skill.path.contains("/.claude/") {
                return ".claude/skills"
            }
            return "project"
        case .plugin:
            return "plugin: \(skill.pluginName ?? "plugin")"
        case .server, .bundled:
            return skill.scope.wireName
        }
    }
}
