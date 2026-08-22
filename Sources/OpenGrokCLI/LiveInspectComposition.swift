import Foundation
import OpenGrokAgentDefinitions
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokMCP
import OpenGrokPluginMarketplace

private struct LiveInspectSource: Encodable, Sendable {
    let type: String
    let path: String?
    let pluginName: String?

    init(type: String, path: String? = nil, pluginName: String? = nil) {
        self.type = type
        self.path = path
        self.pluginName = pluginName
    }
}

private struct LiveInspectInstruction: Encodable, Sendable {
    let path: String
    let scope: String
    let fileType: String
    let sizeBytes: Int
    let approxTokens: Int
    let vendor: String?
    let disabled: Bool?
    let compatibilityStatus: String?
}

private struct LiveInspectSkippedRule: Encodable, Sendable {
    let rule: String
    let reason: String
}

private struct LiveInspectEnforcedPolicy: Encodable, Sendable {
    let setting: String
    let enabled: Bool
    let source: String
}

private struct LiveInspectPermissions: Encodable, Sendable {
    let sources: [String]
    let loaded: Int
    let skipped: [LiveInspectSkippedRule]
    let mcpServerAllowlist: [String]
    let marketplaceAllowlist: [String]
    let managedSettingsPath: String?
    let managedSettingsExists: Bool
    let managedSettingsActive: Bool
    let enforced: [LiveInspectEnforcedPolicy]?
}

private enum LiveInspectTeam: Encodable, Sendable {
    case one(String)
    case many([String])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .one(let value):
            try container.encode(value)
        case .many(let values):
            try container.encode(values)
        }
    }
}

private struct LiveInspectLoginPolicy: Encodable, Sendable {
    let disableApiKeyAuth: Bool?
    let forceLoginTeamUuid: LiveInspectTeam?
    let apiKeyAuthDisabled: Bool

    private enum CodingKeys: String, CodingKey {
        case disableApiKeyAuth
        case forceLoginTeamUuid
        case apiKeyAuthDisabled
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let disableApiKeyAuth {
            try container.encode(disableApiKeyAuth, forKey: .disableApiKeyAuth)
        } else {
            try container.encodeNil(forKey: .disableApiKeyAuth)
        }
        if let forceLoginTeamUuid {
            try container.encode(forceLoginTeamUuid, forKey: .forceLoginTeamUuid)
        } else {
            try container.encodeNil(forKey: .forceLoginTeamUuid)
        }
        try container.encode(apiKeyAuthDisabled, forKey: .apiKeyAuthDisabled)
    }
}

private struct LiveInspectHook: Encodable, Sendable {
    let event: String
    let hookType: String
    let target: String
    let source: LiveInspectSource
    let matcher: String?
}

private struct LiveInspectSkill: Encodable, Sendable {
    let name: String
    let description: String
    let source: LiveInspectSource
    let userInvocable: Bool
    let vendor: String?
    let disabled: Bool?
    let compatibilityStatus: String?
    let collidesWith: String?
    let invocableAs: String?
}

private struct LiveInspectAgent: Encodable, Sendable {
    let name: String
    let description: String
    let source: LiveInspectSource
}

private struct LiveInspectPluginProvides: Encodable, Sendable {
    let skills: Int
    let agents: Int
    let hooks: Bool
    let mcpServers: Int
}

private struct LiveInspectPlugin: Encodable, Sendable {
    let name: String
    let scope: String
    let path: String
    let enabled: Bool
    let provides: LiveInspectPluginProvides
}

private struct LiveInspectMarketplace: Encodable, Sendable {
    let name: String
    let path: String
    let enabledPlugins: Int
}

private struct LiveInspectMCPServer: Encodable, Sendable {
    let name: String
    let transport: String
    let target: String
    let source: LiveInspectSource
    let disabled: Bool?
    let compatibilityStatus: String?
    let disabledReason: String?
    let vendor: String?
}

private struct LiveInspectLSPServer: Encodable, Sendable {
    let name: String
    let command: String
    let args: [String]
    let source: LiveInspectSource
    let extensions: [String]
    let untrusted: Bool?
}

private struct LiveInspectConfigLayer: Encodable, Sendable {
    let role: String
    let path: String
    let note: String?
}

private struct LiveInspectConfigSources: Encodable, Sendable {
    let layers: [LiveInspectConfigLayer]
}

private struct LiveInspectCompatibilityCell: Encodable, Sendable {
    let vendor: String
    let surface: String
    let enabled: Bool
    let source: String
}

private struct LiveInspectExternalCompatibility: Encodable, Sendable {
    let remoteSettingsLoaded: Bool
    let cells: [LiveInspectCompatibilityCell]
}

private struct LiveInspectMCPProblem: Encodable, Sendable {
    let server: String
    let message: String
}

private struct LiveInspectReport: Encodable, Sendable {
    let grokVersion: String
    let releaseSource: String
    let cwd: String
    let projectRoot: String?
    let projectTrusted: Bool
    let projectInstructions: [LiveInspectInstruction]
    let permissions: LiveInspectPermissions
    let loginPolicy: LiveInspectLoginPolicy
    let hooks: [LiveInspectHook]
    let skills: [LiveInspectSkill]
    let agents: [LiveInspectAgent]
    let plugins: [LiveInspectPlugin]
    let marketplaces: [LiveInspectMarketplace]
    let mcpServers: [LiveInspectMCPServer]
    let lspServers: [LiveInspectLSPServer]
    let configSources: LiveInspectConfigSources
    let externalCompat: LiveInspectExternalCompatibility
    let mcpConfigProblems: [LiveInspectMCPProblem]?

    private enum CodingKeys: String, CodingKey {
        case grokVersion
        case releaseSource
        case cwd
        case projectRoot
        case projectTrusted
        case projectInstructions
        case permissions
        case loginPolicy
        case hooks
        case skills
        case agents
        case plugins
        case marketplaces
        case mcpServers
        case lspServers
        case configSources
        case externalCompat
        case mcpConfigProblems
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(grokVersion, forKey: .grokVersion)
        try container.encode(releaseSource, forKey: .releaseSource)
        try container.encode(cwd, forKey: .cwd)
        if let projectRoot {
            try container.encode(projectRoot, forKey: .projectRoot)
        } else {
            try container.encodeNil(forKey: .projectRoot)
        }
        try container.encode(projectTrusted, forKey: .projectTrusted)
        try container.encode(projectInstructions, forKey: .projectInstructions)
        try container.encode(permissions, forKey: .permissions)
        try container.encode(loginPolicy, forKey: .loginPolicy)
        try container.encode(hooks, forKey: .hooks)
        try container.encode(skills, forKey: .skills)
        try container.encode(agents, forKey: .agents)
        try container.encode(plugins, forKey: .plugins)
        try container.encode(marketplaces, forKey: .marketplaces)
        try container.encode(mcpServers, forKey: .mcpServers)
        try container.encode(lspServers, forKey: .lspServers)
        try container.encode(configSources, forKey: .configSources)
        try container.encode(externalCompat, forKey: .externalCompat)
        try container.encodeIfPresent(mcpConfigProblems, forKey: .mcpConfigProblems)
    }
}

public enum LiveInspectComposition {
    public static func run(
        json: Bool,
        environment: [String: String],
        streams: CLIStreams
    ) -> Int32 {
        let workingDirectory = URL(
            fileURLWithPath: environment["PWD"] ?? FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL
        let home = OpenGrokHomeResolver.resolve(environment: environment).standardizedFileURL
        let security = LiveSecurityContext.resolve(
            workspaceRoot: workingDirectory,
            environment: environment,
            isInteractive: false
        )
        let compatibility = resolveCompatibility(document: security.document, environment: environment)
        let discoveredSkills = LiveSkills.discover(cwd: workingDirectory, environment: environment)
        let discoveredAgents = AgentDefinitionDiscovery(environment: environment)
            .discover(at: workingDirectory)
        let configLayers = configurationLayers(cwd: workingDirectory, home: home)
        let mcp = MCPConfigLoader.load(from: security.document)
        let source = configSource(cwd: workingDirectory, home: home, trusted: security.projectTrusted)
        let plugins = pluginEntries(
            home: home,
            skills: discoveredSkills,
            agents: discoveredAgents
        )
        let managedPath = claudeManagedSettingsProbePath()
        let managedExists = managedPath.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        let enforced: [LiveInspectEnforcedPolicy] = security.permissions.yoloPinReason == nil
            ? []
            : [LiveInspectEnforcedPolicy(
                setting: "alwaysApprove",
                enabled: false,
                source: "requirements.toml"
            )]
        let permissionReport = LiveInspectPermissions(
            sources: security.permissions.sources,
            loaded: security.permissions.config.rules.count,
            skipped: security.permissions.skipped.map {
                LiveInspectSkippedRule(rule: $0.rule, reason: $0.reason)
            },
            mcpServerAllowlist: stringArray(
                security.document[path: ["permissions", "mcp_server_allowlist"]]
            ),
            marketplaceAllowlist: stringArray(
                security.document[path: ["marketplace", "allowlist"]]
            ),
            managedSettingsPath: managedPath?.path,
            managedSettingsExists: managedExists,
            managedSettingsActive: security.permissions.sources.contains("managed-settings.json"),
            enforced: enforced.isEmpty ? nil : enforced
        )

        let report = LiveInspectReport(
            grokVersion: OpenGrokCLIVersion.installedWithCommit(environment: environment),
            releaseSource: "github",
            cwd: workingDirectory.path,
            projectRoot: findProjectRoot(workingDirectory)?.path,
            projectTrusted: security.projectTrusted,
            projectInstructions: instructions(
                cwd: workingDirectory,
                home: home,
                compatibility: compatibility
            ),
            permissions: permissionReport,
            loginPolicy: loginPolicy(document: security.document, environment: environment),
            hooks: hookEntries(document: security.document, source: source),
            skills: skillEntries(discoveredSkills, compatibility: compatibility),
            agents: agentEntries(discoveredAgents, trusted: security.projectTrusted),
            plugins: plugins,
            marketplaces: [],
            mcpServers: mcp.servers.map { declaration in
                let transport: String
                let target: String
                switch declaration.config.transport {
                case .stdio(let command, _, _, _):
                    transport = "stdio"
                    target = command
                case .streamableHttp(let url, let transportType, _, _, _, _, _):
                    transport = transportType == "sse" ? "sse" : "http"
                    target = url
                }
                return LiveInspectMCPServer(
                    name: declaration.name,
                    transport: transport,
                    target: target,
                    source: source,
                    disabled: declaration.isEnabled ? nil : true,
                    compatibilityStatus: nil,
                    disabledReason: declaration.isEnabled ? nil : "disabled in configuration",
                    vendor: nil
                )
            },
            lspServers: lspEntries(document: security.document, source: source),
            configSources: LiveInspectConfigSources(layers: configLayers),
            externalCompat: compatibility,
            mcpConfigProblems: mcp.problems.isEmpty ? nil : mcp.problems.map {
                LiveInspectMCPProblem(server: $0.server, message: $0.message)
            }
        )

        if json {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(report)
                guard let output = String(data: data, encoding: .utf8) else {
                    throw CLIApplicationError.failed("inspection report is not valid UTF-8")
                }
                streams.out(output + "\n")
                return CLIRunner.ExitCode.success.rawValue
            } catch {
                streams.err("open-grok: cannot encode inspection report: \(error).\n")
                return CLIRunner.ExitCode.failure.rawValue
            }
        }
        streams.out(humanReport(report))
        return CLIRunner.ExitCode.success.rawValue
    }

    private static func loginPolicy(
        document: TOMLValue,
        environment: [String: String]
    ) -> LiveInspectLoginPolicy {
        let configured = document[path: ["grok_com_config", "disable_api_key_auth"]]?.boolValue
        let value = OpenGrokConfig.envBool("GROK_DISABLE_API_KEY_AUTH", environment: environment)
            ?? configured
        let rawTeam = document[path: ["grok_com_config", "force_login_team_uuid"]]
        let team: LiveInspectTeam?
        if let single = rawTeam?.stringValue {
            team = .one(single)
        } else if let values = rawTeam?.arrayValue {
            team = .many(values.compactMap(\.stringValue))
        } else {
            team = nil
        }
        let defaults = GrokComConfig.default(environment: environment)
        return LiveInspectLoginPolicy(
            disableApiKeyAuth: value,
            forceLoginTeamUuid: team,
            apiKeyAuthDisabled: value == true || team != nil
                || defaults.apiKeyAuthDisabled(environment: environment)
        )
    }

    private static func resolveCompatibility(
        document: TOMLValue,
        environment: [String: String]
    ) -> LiveInspectExternalCompatibility {
        let surfaces = ["skills", "rules", "agents", "mcps", "hooks", "sessions"]
        var cells: [LiveInspectCompatibilityCell] = []
        for vendor in ["cursor", "claude", "codex"] {
            for surface in surfaces where vendor != "codex" || surface == "sessions" {
                let variable = "GROK_\(vendor.uppercased())_\(surface.uppercased())_ENABLED"
                if let enabled = OpenGrokConfig.envBool(variable, environment: environment) {
                    cells.append(LiveInspectCompatibilityCell(
                        vendor: vendor, surface: surface, enabled: enabled, source: "env"
                    ))
                } else if let configured = document[path: ["compat", vendor, surface]] {
                    if let enabled = configured.boolValue {
                        cells.append(LiveInspectCompatibilityCell(
                            vendor: vendor, surface: surface, enabled: enabled, source: "config"
                        ))
                    } else {
                        cells.append(LiveInspectCompatibilityCell(
                            vendor: vendor, surface: surface, enabled: false, source: "configError"
                        ))
                    }
                } else {
                    cells.append(LiveInspectCompatibilityCell(
                        vendor: vendor, surface: surface, enabled: true, source: "default"
                    ))
                }
            }
        }
        return LiveInspectExternalCompatibility(remoteSettingsLoaded: false, cells: cells)
    }

    private static func instructions(
        cwd: URL,
        home: URL,
        compatibility: LiveInspectExternalCompatibility
    ) -> [LiveInspectInstruction] {
        var candidates: [(URL, String, String?)] = [
            (home.appendingPathComponent("AGENTS.md"), "global", nil),
            (cwd.appendingPathComponent("AGENTS.md"), "project", nil),
            (cwd.appendingPathComponent("CLAUDE.md"), "project", "claude"),
        ]
        for (root, scope, vendor) in [
            (home.appendingPathComponent("rules"), "global", Optional<String>.none),
            (cwd.appendingPathComponent(".opengrok/rules"), "project", Optional<String>.none),
            (cwd.appendingPathComponent(".cursor/rules"), "project", Optional("cursor")),
            (cwd.appendingPathComponent(".claude/rules"), "project", Optional("claude")),
        ] {
            guard (try? PathSecurity.isSymlink(root)) == false,
                  let files = try? FileManager.default.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: nil
                  ) else { continue }
            for file in files where file.pathExtension == "md" || file.pathExtension == "mdc" {
                candidates.append((file, scope, vendor))
            }
        }

        var seen = Set<String>()
        return candidates.compactMap { path, scope, vendor in
            let normalized = path.standardizedFileURL.path
            guard seen.insert(normalized).inserted,
                  (try? PathSecurity.isSymlink(path)) == false,
                  let data = try? PathSecurity.readNoFollow(path)
            else { return nil }
            let fileType = path.lastPathComponent == "AGENTS.md"
                || path.lastPathComponent == "CLAUDE.md" ? "agents_md" : "rules"
            let surface = fileType == "rules" ? "rules" : "agents"
            let status = vendor.flatMap { vendor in
                compatibility.cells.first { $0.vendor == vendor && $0.surface == surface }
            }
            return LiveInspectInstruction(
                path: normalized,
                scope: scope,
                fileType: fileType,
                sizeBytes: data.count,
                approxTokens: String(decoding: data, as: UTF8.self).count / 4,
                vendor: vendor,
                disabled: status?.enabled == false ? true : nil,
                compatibilityStatus: status.map { $0.enabled ? "enabled" : "disabled" }
            )
        }.sorted { $0.path < $1.path }
    }

    private static func skillEntries(
        _ skills: [SkillInfo],
        compatibility: LiveInspectExternalCompatibility
    ) -> [LiveInspectSkill] {
        skills.compactMap { skill in
            let path = URL(fileURLWithPath: skill.path)
            guard (try? PathSecurity.isSymlink(path)) == false else { return nil }
            let vendor = skill.path.contains("/.cursor/") ? "cursor"
                : skill.path.contains("/.claude/") ? "claude" : nil
            let status = vendor.flatMap { vendor in
                compatibility.cells.first { $0.vendor == vendor && $0.surface == "skills" }
            }
            let disabled = !skill.enabled || status?.enabled == false
            return LiveInspectSkill(
                name: skill.name,
                description: skill.description,
                source: source(for: skill.scope, path: skill.path, pluginName: skill.pluginName),
                userInvocable: skill.userInvocable,
                vendor: vendor,
                disabled: disabled ? true : nil,
                compatibilityStatus: status.map { $0.enabled ? "enabled" : "disabled" },
                collidesWith: nil,
                invocableAs: nil
            )
        }
    }

    private static func source(
        for scope: SkillScope,
        path: String,
        pluginName: String?
    ) -> LiveInspectSource {
        switch scope {
        case .local, .repo:
            return LiveInspectSource(type: "project", path: path)
        case .user:
            return LiveInspectSource(type: "user", path: path)
        case .server:
            return LiveInspectSource(type: "server", path: path)
        case .bundled:
            return LiveInspectSource(type: "bundled", path: path)
        case .plugin:
            return LiveInspectSource(type: "plugin", path: path, pluginName: pluginName)
        }
    }

    private static func agentEntries(
        _ agents: [AgentDefinition],
        trusted: Bool
    ) -> [LiveInspectAgent] {
        agents.compactMap { agent in
            if agent.scope == .project, !trusted { return nil }
            let source: LiveInspectSource
            switch agent.scope {
            case .project:
                source = LiveInspectSource(type: "project", path: agent.sourcePath)
            case .user:
                source = LiveInspectSource(type: "user", path: agent.sourcePath)
            case .bundled:
                source = LiveInspectSource(type: "bundled", path: agent.sourcePath)
            case .builtIn:
                source = LiveInspectSource(type: "builtin")
            }
            return LiveInspectAgent(name: agent.name, description: agent.description, source: source)
        }
    }

    private static func pluginEntries(
        home: URL,
        skills: [SkillInfo],
        agents: [AgentDefinition]
    ) -> [LiveInspectPlugin] {
        let location = PluginInstallLocation(grokHome: home)
        guard (try? PathSecurity.isSymlink(location.registryURL)) == false else { return [] }
        let registry = PluginInstallRegistry.load(from: location.registryURL)
        return registry.repositories.flatMap { record in
            let names = record.pluginNames.isEmpty ? [record.repoKey] : record.pluginNames
            return names.map { name in
                LiveInspectPlugin(
                    name: name,
                    scope: "user",
                    path: location.installDirectory.appendingPathComponent(record.repoKey).path,
                    enabled: record.enabled,
                    provides: LiveInspectPluginProvides(
                        skills: skills.filter { $0.pluginName == name }.count,
                        agents: agents.filter { $0.pluginName == name }.count,
                        hooks: false,
                        mcpServers: 0
                    )
                )
            }
        }
    }

    private static func hookEntries(
        document: TOMLValue,
        source: LiveInspectSource
    ) -> [LiveInspectHook] {
        guard let events = document["hooks"]?.table else { return [] }
        var result: [LiveInspectHook] = []
        for (event, groups) in events.pairs {
            for group in groups.arrayValue ?? [] {
                let matcher = group["matcher"]?.stringValue
                for hook in group["hooks"]?.arrayValue ?? [group] {
                    let target = hook["command"]?.stringValue
                        ?? hook["url"]?.stringValue
                        ?? hook["prompt"]?.stringValue
                    guard let target, !target.isEmpty else { continue }
                    result.append(LiveInspectHook(
                        event: event,
                        hookType: hook["type"]?.stringValue ?? "command",
                        target: target,
                        source: source,
                        matcher: matcher
                    ))
                }
            }
        }
        return result
    }

    private static func lspEntries(
        document: TOMLValue,
        source: LiveInspectSource
    ) -> [LiveInspectLSPServer] {
        guard let entries = document["lsp_servers"]?.table else { return [] }
        return entries.pairs.compactMap { name, value in
            guard let command = value["command"]?.stringValue, !command.isEmpty else {
                return nil
            }
            return LiveInspectLSPServer(
                name: name,
                command: command,
                args: stringArray(value["args"]),
                source: source,
                extensions: value["extensions"]?.table?.allKeys
                    ?? stringArray(value["extensions"]),
                untrusted: nil
            )
        }
    }

    private static func configurationLayers(cwd: URL, home: URL) -> [LiveInspectConfigLayer] {
        var candidates: [(String, URL)] = []
        if let system = systemConfigDir() {
            candidates.append(("system-managed", system.appendingPathComponent("managed_config.toml")))
        }
        candidates.append(("managed", home.appendingPathComponent("managed_config.toml")))
        candidates.append(("user", home.appendingPathComponent("config.toml")))
        candidates.append(("requirements", home.appendingPathComponent("requirements.toml")))
        if let system = systemConfigDir() {
            candidates.append(("system-requirements", system.appendingPathComponent("requirements.toml")))
        }

        let boundary = (findProjectRoot(cwd) ?? cwd).standardizedFileURL
        var current = cwd.standardizedFileURL
        var project: [URL] = []
        var visited: Set<String> = []
        while visited.insert(current.path).inserted {
            project.append(current.appendingPathComponent(".opengrok/config.toml"))
            if current.path == boundary.path { break }
            guard let parent = strictlyAscendingParent(of: current) else { break }
            current = parent
        }
        candidates.append(contentsOf: project.reversed().map { ("project", $0) })

        return candidates.compactMap { role, path in
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            guard (try? PathSecurity.isSymlink(path)) == false,
                  let bytes = try? PathSecurity.readNoFollow(path),
                  let contents = String(data: bytes, encoding: .utf8),
                  let parsed = try? parseTOML(contents)
            else {
                return LiveInspectConfigLayer(role: role, path: path.path, note: "parse error")
            }
            return LiveInspectConfigLayer(
                role: role,
                path: path.path,
                note: parsed.isTableEmpty ? "empty" : nil
            )
        }
    }

    private static func configSource(cwd: URL, home: URL, trusted: Bool) -> LiveInspectSource {
        let project = cwd.appendingPathComponent(".opengrok/config.toml")
        if trusted, FileManager.default.fileExists(atPath: project.path) {
            return LiveInspectSource(type: "project", path: project.path)
        }
        return LiveInspectSource(type: "configToml", path: home.appendingPathComponent("config.toml").path)
    }

    private static func findProjectRoot(_ cwd: URL) -> URL? {
        var current = cwd.standardizedFileURL
        var visited: Set<String> = []
        while visited.insert(current.path).inserted {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            guard let parent = strictlyAscendingParent(of: current) else { return nil }
            current = parent
        }
        return nil
    }

    private static func strictlyAscendingParent(of directory: URL) -> URL? {
        let current = directory.standardizedFileURL
        let parent = current.deletingLastPathComponent()
        // NSURL can produce ever-growing `/..` parents at a filesystem root.
        guard parent.path.count < current.path.count else { return nil }
        return parent.standardizedFileURL
    }

    private static func stringArray(_ value: TOMLValue?) -> [String] {
        value?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private static func humanReport(_ report: LiveInspectReport) -> String {
        var lines = [
            "",
            "  Environment",
            "  └ Version: \(report.grokVersion) (GitHub release)",
            "  └ CWD: \(report.cwd)",
        ]
        if let root = report.projectRoot {
            lines.append("  └ Git root: \(root)")
        }
        lines.append("  └ Project trusted: \(report.projectTrusted ? "yes" : "no")")
        appendSection("Project Instructions", report.projectInstructions.map(\.path), into: &lines)
        lines.append("")
        lines.append("  Permissions")
        if report.permissions.sources.isEmpty {
            lines.append("  └ Source: (none)")
        } else {
            lines.append(contentsOf: report.permissions.sources.map { "  └ Source: \($0)" })
        }
        lines.append("  └ \(report.permissions.loaded) loaded, \(report.permissions.skipped.count) skipped")
        lines.append("")
        lines.append("  Login Policy")
        let disabled = report.loginPolicy.disableApiKeyAuth.map(String.init) ?? "(unset)"
        lines.append("  └ disable_api_key_auth: \(disabled)")
        lines.append("  └ api_key_auth_disabled: \(report.loginPolicy.apiKeyAuthDisabled)")
        appendSection("Skills", report.skills.map(\.name), into: &lines)
        appendSection("Agents", report.agents.map(\.name), into: &lines)
        appendSection("Hooks", report.hooks.map { "\($0.event): \($0.target)" }, into: &lines)
        appendSection("MCP Servers", report.mcpServers.map(\.name), into: &lines)
        appendSection("LSP Servers", report.lspServers.map(\.name), into: &lines)
        appendSection("Plugins", report.plugins.map(\.name), into: &lines)
        appendSection("Configuration Sources", report.configSources.layers.map {
            "\($0.role): \($0.path)\($0.note.map { " (\($0))" } ?? "")"
        }, into: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendSection(_ title: String, _ values: [String], into lines: inout [String]) {
        lines.append("")
        lines.append("  \(title)")
        if values.isEmpty {
            lines.append("  └ (none)")
        } else {
            lines.append(contentsOf: values.map { "  └ \($0)" })
        }
    }
}
