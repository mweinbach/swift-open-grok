import Foundation

public struct AgentConfigFile: Codable, Sendable, Equatable, Hashable {
    public var fileName: String
    public var filePath: String
    public var content: String

    public init(fileName: String, filePath: String, content: String) {
        self.fileName = fileName
        self.filePath = filePath
        self.content = content
    }
}

public enum AgentConfigSource: Sendable, Equatable, Hashable {
    case builtIn
    case project(path: String)
    case user(path: String)
    case bundled(path: String)
}

public enum SubagentSource: Sendable, Equatable, Hashable {
    case builtin(BuiltinAgentName)
    case userDefined(scope: AgentScope)
}

public struct SubagentEntry: Sendable, Equatable, Hashable {
    public var name: String
    public var description: String
    public var source: SubagentSource
    public var shadowsBuiltin: BuiltinAgentName?
    public var configSource: AgentConfigSource

    public init(
        name: String,
        description: String,
        source: SubagentSource,
        shadowsBuiltin: BuiltinAgentName? = nil,
        configSource: AgentConfigSource
    ) {
        self.name = name
        self.description = description
        self.source = source
        self.shadowsBuiltin = shadowsBuiltin
        self.configSource = configSource
    }
}

public struct AgentDefinitionDiscovery: Sendable {
    public var environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func projectAgentDirectories(at cwd: URL) -> [URL] {
        let chain = projectDirectoryChain(at: cwd)
        return chain.flatMap { directory in
            [
                directory.appendingPathComponent(".opengrok/agents"),
                directory.appendingPathComponent(".claude/agents")
            ].filter(isDirectory)
        }
    }

    public func userAgentDirectories(home: URL? = nil, grokHome: URL? = nil) -> [(url: URL, scope: AgentScope)] {
        let resolvedHome = home ?? homeDirectory()
        let resolvedGrokHome = grokHome ?? grokHomeDirectory(home: resolvedHome)
        let legacyGrokHome = resolvedHome?.appendingPathComponent(".opengrok")
        var directories: [(url: URL, scope: AgentScope)] = []

        directories.append((resolvedGrokHome.appendingPathComponent("agents"), .user))
        if let legacyGrokHome, !samePath(legacyGrokHome, resolvedGrokHome) {
            directories.append((legacyGrokHome.appendingPathComponent("agents"), .user))
        }
        if let resolvedHome {
            directories.append((resolvedHome.appendingPathComponent(".claude/agents"), .user))
        }
        directories.append((resolvedGrokHome.appendingPathComponent("bundled/agents"), .bundled))
        if let legacyGrokHome, !samePath(legacyGrokHome, resolvedGrokHome) {
            directories.append((legacyGrokHome.appendingPathComponent("bundled/agents"), .bundled))
        }
        return directories
    }

    public func discover(at cwd: URL) -> [AgentDefinition] {
        var definitions: [AgentDefinition] = []
        var seenNames = Set<String>()

        for directory in projectAgentDirectories(at: cwd) {
            loadDefinitions(from: directory, scope: .project, into: &definitions, seenNames: &seenNames)
        }
        for (directory, scope) in userAgentDirectories() where isDirectory(directory) {
            loadDefinitions(from: directory, scope: scope, into: &definitions, seenNames: &seenNames)
        }
        return definitions
    }

    public func byName(_ name: String, in cwd: URL? = nil) -> AgentDefinition? {
        if let cwd {
            for directory in projectAgentDirectories(at: cwd) {
                if let definition = loadDefinition(named: name, from: directory, scope: .project) {
                    return definition
                }
            }
        }

        for (directory, scope) in userAgentDirectories() {
            if let definition = loadDefinition(named: name, from: directory, scope: scope) {
                return definition
            }
        }

        if let builtIn = AgentDefinition.builtIn(named: name) {
            return builtIn
        }
        return nil
    }

    public func allSubagents(at cwd: URL, toggles: [String: Bool] = [:]) -> [SubagentEntry] {
        var entries = BuiltinAgentName.subagentVariants.map { builtIn in
            let definition = builtIn.definition
            return SubagentEntry(
                name: definition.name,
                description: definition.description,
                source: .builtin(builtIn),
                configSource: .builtIn
            )
        }

        for definition in discover(at: cwd) where definition.scope != .builtIn {
            let builtIn = BuiltinAgentName(rawValue: definition.name)
            if let builtIn, BuiltinAgentName.subagentVariants.contains(builtIn), definition.scope != .project {
                continue
            }

            let source = AgentConfigSource.forDefinition(definition)
            if let index = entries.firstIndex(where: { $0.name == definition.name }) {
                let shouldReplace: Bool
                switch entries[index].source {
                case .builtin:
                    shouldReplace = true
                case let .userDefined(scope):
                    shouldReplace = scope.priority < definition.scope.priority
                }
                if shouldReplace {
                    entries[index] = SubagentEntry(
                        name: definition.name,
                        description: definition.description,
                        source: .userDefined(scope: definition.scope),
                        shadowsBuiltin: builtIn,
                        configSource: source
                    )
                }
            } else {
                entries.append(SubagentEntry(
                    name: definition.name,
                    description: definition.description,
                    source: .userDefined(scope: definition.scope),
                    configSource: source
                ))
            }
        }

        return entries.filter { toggles[$0.name] ?? true }
    }

    private func loadDefinitions(
        from directory: URL,
        scope: AgentScope,
        into definitions: inout [AgentDefinition],
        seenNames: inout Set<String>
    ) {
        for file in markdownFiles(in: directory) {
            guard var definition = try? AgentDefinition.fromFile(file) else { continue }
            definition.scope = scope
            guard seenNames.insert(definition.name).inserted else { continue }
            definitions.append(definition)
        }
    }

    private func loadDefinition(named name: String, from directory: URL, scope: AgentScope) -> AgentDefinition? {
        let file = directory.appendingPathComponent("\(name).md")
        guard isFile(file), var definition = try? AgentDefinition.fromFile(file) else { return nil }
        definition.scope = scope
        return definition
    }

    private func markdownFiles(in directory: URL) -> [URL] {
        guard isDirectory(directory), let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "md" && isFile($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func projectDirectoryChain(at cwd: URL) -> [URL] {
        let start = cwd.standardizedFileURL
        let home = homeDirectory()
        var current: URL? = start
        var chain: [URL] = []
        var gitRoot: URL?

        while let directory = current {
            chain.append(directory)
            if isHome(directory, home: home) { break }
            if isDirectory(directory.appendingPathComponent(".git")) || isFile(directory.appendingPathComponent(".git")) {
                gitRoot = directory
                break
            }
            let parent = directory.deletingLastPathComponent()
            current = parent == directory ? nil : parent
        }

        guard let gitRoot else { return [start] }
        if isHome(gitRoot, home: home) { return [start] }
        return chain
    }

    private func homeDirectory() -> URL? {
        guard let value = environment["HOME"], !value.isEmpty else {
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    private func grokHomeDirectory(home: URL?) -> URL {
        if let value = environment["OPENGROK_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return (home ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
            .appendingPathComponent(".opengrok", isDirectory: true)
    }

    private func isHome(_ path: URL, home: URL?) -> Bool {
        guard let home else { return false }
        return samePath(path, home)
    }

    private func samePath(_ lhs: URL, _ rhs: URL?) -> Bool {
        guard let rhs else { return false }
        return lhs.standardizedFileURL.resolvingSymlinksInPath().path == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}

public extension AgentConfigSource {
    static func forDefinition(_ definition: AgentDefinition) -> AgentConfigSource {
        guard let path = definition.sourcePath else { return .builtIn }
        switch definition.scope {
        case .project: return .project(path: path)
        case .user: return .user(path: path)
        case .bundled: return .bundled(path: path)
        case .builtIn: return .builtIn
        }
    }
}

public extension AgentScope {
    var priority: Int {
        switch self {
        case .project: return 3
        case .user: return 2
        case .bundled: return 1
        case .builtIn: return 0
        }
    }
}

public func discoverAgentDefinitions(
    at cwd: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> [AgentDefinition] {
    AgentDefinitionDiscovery(environment: environment).discover(at: cwd)
}

public extension AgentDefinition {
    static func discover(
        at cwd: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [AgentDefinition] {
        AgentDefinitionDiscovery(environment: environment).discover(at: cwd)
    }

    static func byName(
        _ name: String,
        in cwd: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AgentDefinition? {
        AgentDefinitionDiscovery(environment: environment).byName(name, in: cwd)
    }
}

public func agentDefinition(
    named name: String,
    in cwd: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> AgentDefinition? {
    AgentDefinitionDiscovery(environment: environment).byName(name, in: cwd)
}

public func allBuiltinAgentDefinitions() -> [AgentDefinition] {
    BuiltinAgentName.allCases.map(\.definition)
}

public func isStrictHarnessAgentType(_ name: String) -> Bool {
    guard let builtIn = BuiltinAgentName(rawValue: name) else { return false }
    return builtIn.definition.isStrictHarness()
}

public struct AgentPromptContext: Codable, Sendable, Equatable, Hashable {
    public var version: Int
    public var promptMode: PromptMode
    public var promptBody: String?
    public var systemPrompt: TemplateOverride
    public var agentsMdFiles: [AgentConfigFile]
    public var personaSummaries: [String]
    public var skillInstructions: [String]

    public init(
        promptMode: PromptMode,
        promptBody: String? = nil,
        systemPrompt: TemplateOverride = .none,
        agentsMdFiles: [AgentConfigFile] = [],
        personaSummaries: [String] = [],
        skillInstructions: [String] = [],
        version: Int = 1
    ) {
        self.version = version
        self.promptMode = promptMode
        self.promptBody = promptBody
        self.systemPrompt = systemPrompt
        self.agentsMdFiles = agentsMdFiles
        self.personaSummaries = personaSummaries
        self.skillInstructions = skillInstructions
    }

    public func formatAgentsMDSection() -> String? {
        guard !agentsMdFiles.isEmpty else { return nil }
        var result = "\n\n<system-reminder>\nAs you answer the user's questions, you can use the following context (ordered from repo root to current directory - deeper files take precedence on conflicts):\n"
        for file in agentsMdFiles {
            result += "\n## From: \(neutralizeReminderTags(file.filePath))\n"
            result += neutralizeReminderTags(file.content)
            result += "\n"
        }
        result += "\nFollow these instructions exactly. When working in subdirectories not listed above, check for additional project instruction files (AGENTS.md, Claude.md, etc.).\n</system-reminder>"
        return result
    }

    public func agentsMDUserReminder() -> String? { formatAgentsMDSection() }

    public func composedPrompt(basePrompt: String) -> String {
        var sections: [String] = []
        let primary: String
        switch promptMode {
        case .full:
            primary = promptBody ?? ""
        case .extend:
            switch systemPrompt {
            case .custom(let value): primary = value
            case .none, .codex: primary = basePrompt
            }
        }
        if !primary.isEmpty { sections.append(primary) }
        if promptMode == .extend, let promptBody, !promptBody.isEmpty { sections.append(promptBody) }
        if let agentsSection = formatAgentsMDSection() { sections.append(agentsSection) }
        if !personaSummaries.isEmpty { sections.append(personaSummaries.joined(separator: "\n")) }
        if !skillInstructions.isEmpty { sections.append(skillInstructions.joined(separator: "\n")) }
        return sections.joined(separator: "\n\n")
    }
}

public extension AgentDefinition {
    func promptContext(
        agentsMdFiles: [AgentConfigFile] = [],
        personaSummaries: [String] = [],
        skillInstructions: [String] = []
    ) -> AgentPromptContext {
        AgentPromptContext(
            promptMode: promptMode,
            promptBody: promptBody,
            systemPrompt: systemPrompt,
            agentsMdFiles: agentsMdFiles,
            personaSummaries: personaSummaries,
            skillInstructions: skillInstructions
        )
    }

    func composePrompt(
        basePrompt: String,
        agentsMdFiles: [AgentConfigFile] = [],
        personaSummaries: [String] = [],
        skillInstructions: [String] = []
    ) -> String {
        promptContext(
            agentsMdFiles: agentsMdFiles,
            personaSummaries: personaSummaries,
            skillInstructions: skillInstructions
        ).composedPrompt(basePrompt: basePrompt)
    }
}

public struct AgentInstructionDiscovery: Sendable {
    public var environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func discover(at cwd: URL) -> [AgentConfigFile] {
        let definitionDiscovery = AgentDefinitionDiscovery(environment: environment)
        let home = homeDirectory()
        let grokHome = grokHomeDirectory(home: home)
        var roots: [(URL, Bool, [String])] = []
        roots.append((grokHome, true, ["rules"]))
        if let home {
            roots.append((home.appendingPathComponent(".claude"), true, ["rules"]))
            roots.append((home.appendingPathComponent(".cursor"), true, ["rules"]))
        }
        let projectChain = definitionDiscovery.projectDirectoryChainForInstructions(at: cwd)
        for directory in projectChain.reversed() {
            roots.append((directory, true, [".opengrok/rules", ".claude/rules", ".cursor/rules"]))
        }

        var results: [AgentConfigFile] = []
        var seenPaths = Set<String>()
        for (root, scanNamedFiles, rulesDirectories) in roots {
            if scanNamedFiles {
                for relativePath in ["Agents.md", "Claude.md", "CLAUDE.md", "CLAUDE.local.md", "AGENT.md", "AGENTS.md", ".claude/CLAUDE.md", ".claude/CLAUDE.local.md"] {
                    appendInstruction(root.appendingPathComponent(relativePath), to: &results, seenPaths: &seenPaths)
                }
            }
            for relativeDirectory in rulesDirectories {
                let directory = root.appendingPathComponent(relativeDirectory)
                guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
                for file in files.filter({ $0.pathExtension.lowercased() == "md" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    appendInstruction(file, to: &results, seenPaths: &seenPaths)
                }
            }
        }
        return results
    }

    public static func readAgentsConfig(
        at cwd: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [AgentConfigFile] {
        AgentInstructionDiscovery(environment: environment).discover(at: cwd)
    }

    private func appendInstruction(_ file: URL, to results: inout [AgentConfigFile], seenPaths: inout Set<String>) {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return }
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        guard seenPaths.insert(path).inserted else { return }
        results.append(AgentConfigFile(fileName: file.lastPathComponent, filePath: file.standardizedFileURL.path, content: content))
    }

    private func homeDirectory() -> URL? {
        guard let value = environment["HOME"], !value.isEmpty else { return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    private func grokHomeDirectory(home: URL?) -> URL {
        if let value = environment["OPENGROK_HOME"], !value.isEmpty { return URL(fileURLWithPath: value, isDirectory: true) }
        return (home ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)).appendingPathComponent(".opengrok", isDirectory: true)
    }
}

extension AgentDefinitionDiscovery {
    func projectDirectoryChainForInstructions(at cwd: URL) -> [URL] {
        let start = cwd.standardizedFileURL
        var current: URL? = start
        var chain: [URL] = []
        while let directory = current {
            chain.append(directory)
            if isDirectory(directory.appendingPathComponent(".git")) || isFile(directory.appendingPathComponent(".git")) { break }
            let parent = directory.deletingLastPathComponent()
            current = parent == directory ? nil : parent
        }
        return chain
    }
}

private func neutralizeReminderTags(_ value: String) -> String {
    value
        .replacingOccurrences(of: "<system-reminder", with: "&lt;system-reminder")
        .replacingOccurrences(of: "<system_reminder", with: "&lt;system_reminder")
}

public func formatAgentsMDSection(_ files: [AgentConfigFile]) -> String? {
    AgentPromptContext(promptMode: .extend, agentsMdFiles: files).formatAgentsMDSection()
}
