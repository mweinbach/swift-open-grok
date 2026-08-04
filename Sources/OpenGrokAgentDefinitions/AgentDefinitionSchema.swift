import Foundation

public enum AgentBuildError: Error, Sendable, Equatable, CustomStringConvertible {
    case parseError(String)
    case missingField(String)
    case unknownToolOverride(String)
    case ioError(String)
    case invalidConfig(String)
    case templateRenderingError(String)

    public var description: String {
        switch self {
        case let .parseError(message): return "failed to parse agent definition: \(message)"
        case let .missingField(field): return "missing required field in agent definition: \(field)"
        case let .unknownToolOverride(tool): return "tool name override references nonexistent tool '\(tool)'"
        case let .ioError(message): return "IO error during agent construction: \(message)"
        case let .invalidConfig(message): return "invalid configuration: \(message)"
        case let .templateRenderingError(message): return "template rendering error: \(message)"
        }
    }
}

public enum AgentJSONValue: Codable, Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([AgentJSONValue])
    case object([String: AgentJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AgentJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AgentJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.typeMismatch(
                AgentJSONValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "unsupported JSON value")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case let .bool(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .number(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .array(value):
            var container = encoder.unkeyedContainer()
            for item in value { try container.encode(item) }
        case let .object(value):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for key in value.keys.sorted() {
                try container.encode(value[key], forKey: DynamicCodingKey(key))
            }
        }
    }

    public subscript(key: String) -> AgentJSONValue? {
        guard case let .object(value) = self else { return nil }
        return value[key]
    }

    public func stableJSONData() throws -> Data {
        Data(StableJSONWriter.write(self).utf8)
    }

    public func stringValue() -> String? {
        guard case let .string(value) = self else { return nil }
        return value
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

private enum StableJSONWriter {
    static func write(_ value: AgentJSONValue) -> String {
        switch value {
        case .null: return "null"
        case let .bool(value): return value ? "true" : "false"
        case let .number(value): return NSDecimalNumber(decimal: value).stringValue
        case let .string(value): return quote(value)
        case let .array(values): return "[" + values.map(write).joined(separator: ",") + "]"
        case let .object(values):
            let fields = values.keys.sorted().map { key in
                "\(quote(key)):\(write(values[key] ?? .null))"
            }
            return "{" + fields.joined(separator: ",") + "}"
        }
    }

    private static func quote(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}

public enum ModelOverride: Codable, Sendable, Equatable, Hashable, CustomStringConvertible {
    case inherit
    case override(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .inherit
            return
        }
        let value = try container.decode(String.self)
        self = value.isEmpty || value.caseInsensitiveCompare("inherit") == .orderedSame
            ? .inherit
            : .override(value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .inherit: try container.encode("inherit")
        case let .override(value): try container.encode(value)
        }
    }

    public var description: String {
        switch self {
        case .inherit: return "inherit"
        case let .override(value): return value
        }
    }

    public var modelID: String? {
        guard case let .override(value) = self else { return nil }
        return value
    }

    public static var `default`: ModelOverride { .inherit }
}

public enum PromptMode: String, Codable, Sendable, Equatable, Hashable {
    case extend
    case full
}

public enum AgentScope: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case project
    case user
    case bundled
    case builtIn = "built-in"

    public var label: String { rawValue }
}

public enum BuiltinAgentName: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case grokBuild = "grok-build"
    case grokBuildConcise = "grok-build-concise"
    case grokBuildPlan = "grok-build-plan"
    case grokBuildPlanNoSubagents = "grok-build-plan-no-subagents"
    case grokBuildAskUser = "grok-build-ask-user"
    case codex
    case opencode
    case generalPurpose = "general-purpose"
    case explore
    case plan
    case browserUse = "browser-use"
    case grokBuildOrchestrator = "grok-build-orchestrator"

    public var definition: AgentDefinition {
        switch self {
        case .grokBuild: return .defaultGrokBuild()
        case .grokBuildConcise: return .grokBuildConcise()
        case .grokBuildPlan: return .grokBuildPlan()
        case .grokBuildPlanNoSubagents: return .grokBuildPlanNoSubagents()
        case .grokBuildAskUser: return .grokBuildAskUser()
        case .codex: return .codex()
        case .opencode: return .opencode()
        case .generalPurpose: return .generalPurpose()
        case .explore: return .explore()
        case .plan: return .plan()
        case .browserUse: return .browserUse()
        case .grokBuildOrchestrator: return .grokBuildOrchestrator()
        }
    }

    public static var subagentVariants: [BuiltinAgentName] { [.generalPurpose, .explore, .plan] }
}

public enum PermissionMode: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case `default`
    case acceptEdits
    case auto
    case dontAsk
    case bypassPermissions
    case plan

    public static let validValues = allCases.map(\.rawValue)
}

public enum Effort: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case low
    case medium
    case high
    case xhigh
    case max

    public static let validValues = allCases.map(\.rawValue)
}

public enum IsolationMode: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case none
    case worktree

    public static let validValues = allCases.map(\.rawValue)
}

public enum AgentColor: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case red
    case blue
    case green
    case yellow
    case purple
    case orange
    case pink
    case cyan

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let color = Self.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(value.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "unknown agent color: \(value)"
            )
        }
        self = color
    }

    public static let validValues = allCases.map(\.rawValue)
}

public enum MemoryScope: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case user
    case project
    case local

    public static let validValues = allCases.map(\.rawValue)

    public func resolveDirectory(agentName: String, projectDirectory: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> ResolvedMemoryDirectory {
        switch self {
        case .user:
            let home = AgentEnvironment.grokHome(environment: environment)
            return ResolvedMemoryDirectory(path: home.appendingPathComponent("agent-memory").appendingPathComponent(agentName), isProjectScoped: false)
        case .project:
            return ResolvedMemoryDirectory(path: projectDirectory.appendingPathComponent(".opengrok/agent-memory").appendingPathComponent(agentName), isProjectScoped: true)
        case .local:
            return ResolvedMemoryDirectory(path: projectDirectory.appendingPathComponent(".opengrok/agent-memory-local").appendingPathComponent(agentName), isProjectScoped: true)
        }
    }
}

public struct ResolvedMemoryDirectory: Sendable, Equatable {
    public var path: URL
    public var isProjectScoped: Bool

    public init(path: URL, isProjectScoped: Bool) {
        self.path = path
        self.isProjectScoped = isProjectScoped
    }
}

public enum AgentCapabilityMode: String, Codable, Sendable, Equatable, Hashable {
    case readOnly = "read-only"
    case readWrite = "read-write"
    case execute
    case all

    public static var write: AgentCapabilityMode { .readWrite }
    public static var full: AgentCapabilityMode { .all }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "read-only", "readonly": self = .readOnly
        case "read-write", "readwrite", "write": self = .readWrite
        case "execute": self = .execute
        case "all", "full": self = .all
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "unknown agent capability mode: \(value)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum McpInheritance: Codable, Sendable, Equatable, Hashable {
    case all
    case none
    case named([String])
    case except([String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            switch value.lowercased() {
            case "all": self = .all
            case "none": self = .none
            default: throw AgentBuildError.parseError("mcpInheritance must be 'all', 'none', or a named/except map")
            }
            return
        }
        let value = try container.decode([String: [String]].self)
        guard value.count == 1, let pair = value.first else {
            throw AgentBuildError.parseError("mcpInheritance map must have exactly one key")
        }
        switch pair.key {
        case "named": self = .named(pair.value)
        case "except": self = .except(pair.value)
        default: throw AgentBuildError.parseError("unknown mcpInheritance key '\(pair.key)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .all: var c = encoder.singleValueContainer(); try c.encode("all")
        case .none: var c = encoder.singleValueContainer(); try c.encode("none")
        case let .named(values): var c = encoder.container(keyedBy: DynamicCodingKey.self); try c.encode(values, forKey: DynamicCodingKey("named"))
        case let .except(values): var c = encoder.container(keyedBy: DynamicCodingKey.self); try c.encode(values, forKey: DynamicCodingKey("except"))
        }
    }

    public static var `default`: McpInheritance { .all }
}

public struct HooksConfig: Codable, Sendable, Equatable, Hashable {
    public var values: [String: AgentJSONValue]

    public init(values: [String: AgentJSONValue] = [:]) { self.values = values }

    public init(from decoder: Decoder) throws {
        let value = try [String: AgentJSONValue](from: decoder)
        self.values = value
    }

    public func encode(to encoder: Encoder) throws { try values.encode(to: encoder) }
}

public enum McpServerRef: Codable, Sendable, Equatable, Hashable {
    case named(String)
    case inline(name: String, config: AgentJSONValue)

    public init(from decoder: Decoder) throws {
        let value = try AgentJSONValue(from: decoder)
        switch value {
        case let .string(name): self = .named(name)
        case let .object(object) where object.count == 1:
            let pair = object.first!
            guard case .object = pair.value else { throw AgentBuildError.parseError("mcpServers inline config for '\(pair.key)' must be an object") }
            self = .inline(name: pair.key, config: pair.value)
        case let .object(object):
            guard let name = object["name"]?.stringValue() else { throw AgentBuildError.parseError("mcpServers entry must include a name") }
            self = .inline(name: name, config: .object(object))
        default: throw AgentBuildError.parseError("mcpServers entry must be a string or object")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .named(name): var c = encoder.singleValueContainer(); try c.encode(name)
        case let .inline(name, config): var c = encoder.container(keyedBy: DynamicCodingKey.self); try c.encode(config, forKey: DynamicCodingKey(name))
        }
    }
}

public struct BashConfig: Codable, Sendable, Equatable, Hashable {
    public var timeoutSecs: Double
    public var outputByteLimit: Int
    public var cmdPrefix: String?

    public init(timeoutSecs: Double = 120, outputByteLimit: Int = 200_000, cmdPrefix: String? = nil) {
        self.timeoutSecs = timeoutSecs
        self.outputByteLimit = outputByteLimit
        self.cmdPrefix = cmdPrefix
    }
}

public struct ToolRetryConfig: Codable, Sendable, Equatable, Hashable {
    public var maxRetries: Int
    public var baseDelayMs: Int
    public var maxDelayMs: Int

    public init(maxRetries: Int, baseDelayMs: Int, maxDelayMs: Int) {
        self.maxRetries = maxRetries
        self.baseDelayMs = baseDelayMs
        self.maxDelayMs = maxDelayMs
    }
}

public struct ToolExecConfig: Codable, Sendable, Equatable, Hashable {
    public var retry: ToolRetryConfig?
    public init(retry: ToolRetryConfig? = nil) { self.retry = retry }
}

public struct RecoveryPolicy: Codable, Sendable, Equatable, Hashable {
    public var maxRetries: Int
    public var baseDelayMs: Int
    public var maxDelayMs: Int

    public init(maxRetries: Int, baseDelayMs: Int, maxDelayMs: Int) {
        self.maxRetries = maxRetries
        self.baseDelayMs = baseDelayMs
        self.maxDelayMs = maxDelayMs
    }
}

public struct CompletionRequirement: Codable, Sendable, Equatable, Hashable {
    public var tool: String
    public var reminder: String
    public var recovery: RecoveryPolicy?

    public init(tool: String, reminder: String, recovery: RecoveryPolicy? = nil) {
        self.tool = tool
        self.reminder = reminder
        self.recovery = recovery
    }
}

public struct AgentToolDefinition: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var execution: ToolExecConfig?

    public init(id: String, execution: ToolExecConfig? = nil) {
        self.id = id
        self.execution = execution
    }

    public var name: String { id.split(separator: ":").last.map(String.init) ?? id }
}

public struct AgentToolConfiguration: Codable, Sendable, Equatable, Hashable {
    public var tools: [AgentToolDefinition]
    public var behaviorPreset: String?

    public init(tools: [AgentToolDefinition] = [], behaviorPreset: String? = nil) {
        self.tools = tools
        self.behaviorPreset = behaviorPreset
    }

    public var toolNames: [String] { tools.map(\.id) }

    public func contains(_ name: String) -> Bool {
        tools.contains { AgentToolMatching.matches(name, id: $0.id) }
    }
}

public struct AgentToolOverrides: Codable, Sendable, Equatable, Hashable {
    public var xSearch: AgentJSONValue?
    public var webSearch: AgentJSONValue?

    public init(xSearch: AgentJSONValue? = nil, webSearch: AgentJSONValue? = nil) {
        self.xSearch = xSearch
        self.webSearch = webSearch
    }
}

public enum TemplateOverride: Codable, Sendable, Equatable, Hashable {
    case none
    case codex
    case custom(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            switch value {
            case "none": self = .none
            case "codex": self = .codex
            default: self = .custom(value)
            }
            return
        }
        let object = try container.decode([String: String].self)
        guard object.count == 1, let value = object["custom"] else { throw AgentBuildError.parseError("systemPrompt must be none, codex, or {custom: ...}") }
        self = .custom(value)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .none: var c = encoder.singleValueContainer(); try c.encode("none")
        case .codex: var c = encoder.singleValueContainer(); try c.encode("codex")
        case let .custom(value): var c = encoder.container(keyedBy: DynamicCodingKey.self); try c.encode(value, forKey: DynamicCodingKey("custom"))
        }
    }
}

public enum UserMessageTemplate: Codable, Sendable, Equatable, Hashable {
    case `default`
    case custom(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = value == "default" ? .default : .custom(value)
            return
        }
        let object = try container.decode([String: String].self)
        guard object.count == 1, let value = object["custom"] else { throw AgentBuildError.parseError("userMessageTemplate must be default or {custom: ...}") }
        self = .custom(value)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .default: var c = encoder.singleValueContainer(); try c.encode("default")
        case let .custom(value): var c = encoder.container(keyedBy: DynamicCodingKey.self); try c.encode(value, forKey: DynamicCodingKey("custom"))
        }
    }

    public var surfacesLocalDate: Bool {
        switch self {
        case .default: return true
        case let .custom(value): return value.contains("today_local")
        }
    }
}

public struct AgentDefinition: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var pluginName: String?
    public var promptMode: PromptMode
    public var toolConfig: AgentToolConfiguration
    public var capabilityMode: AgentCapabilityMode?
    public var permissionMode: PermissionMode
    public var skills: [String]
    public var discoverSkills: Bool
    public var inheritSkills: Bool
    public var agentsMd: Bool
    public var injectDefaultTools: Bool
    public var tools: [String]
    public var disallowedTools: [String]
    public var effort: Effort?
    public var maxTurns: Int?
    public var isolation: IsolationMode?
    public var background: Bool?
    public var color: AgentColor?
    public var initialPrompt: String?
    public var mcpServers: [McpServerRef]
    public var mcpInheritance: McpInheritance
    public var hooks: HooksConfig?
    public var memory: MemoryScope?
    public var model: ModelOverride
    public var completionRequirement: CompletionRequirement?
    public var toolOverrides: AgentToolOverrides?
    public var allowedSubagentTypes: [String]?
    public var sessionToolsAllowlist: [String]?
    public var sessionToolsDenylist: [String]?
    public var promptBody: String?
    public var systemPrompt: TemplateOverride
    public var userMessageTemplate: UserMessageTemplate
    public var sourcePath: String?
    public var scope: AgentScope

    public init(
        name: String,
        description: String,
        promptMode: PromptMode = .extend,
        toolConfig: AgentToolConfiguration = .defaultGrokBuild,
        capabilityMode: AgentCapabilityMode? = nil,
        permissionMode: PermissionMode = .default,
        skills: [String] = [],
        discoverSkills: Bool = true,
        inheritSkills: Bool = true,
        agentsMd: Bool = true,
        injectDefaultTools: Bool = true,
        tools: [String] = [],
        disallowedTools: [String] = [],
        effort: Effort? = nil,
        maxTurns: Int? = nil,
        isolation: IsolationMode? = nil,
        background: Bool? = nil,
        color: AgentColor? = nil,
        initialPrompt: String? = nil,
        mcpServers: [McpServerRef] = [],
        mcpInheritance: McpInheritance = .all,
        hooks: HooksConfig? = nil,
        memory: MemoryScope? = nil,
        model: ModelOverride = .inherit,
        completionRequirement: CompletionRequirement? = nil,
        toolOverrides: AgentToolOverrides? = nil,
        promptBody: String? = nil,
        systemPrompt: TemplateOverride = .none,
        userMessageTemplate: UserMessageTemplate = .default,
        sourcePath: String? = nil,
        scope: AgentScope = .builtIn
    ) {
        self.name = name
        self.description = description
        self.pluginName = nil
        self.promptMode = promptMode
        self.toolConfig = toolConfig
        self.capabilityMode = capabilityMode
        self.permissionMode = permissionMode
        self.skills = skills
        self.discoverSkills = discoverSkills
        self.inheritSkills = inheritSkills
        self.agentsMd = agentsMd
        self.injectDefaultTools = injectDefaultTools
        self.tools = tools
        self.disallowedTools = disallowedTools
        self.effort = effort
        self.maxTurns = maxTurns
        self.isolation = isolation
        self.background = background
        self.color = color
        self.initialPrompt = initialPrompt
        self.mcpServers = mcpServers
        self.mcpInheritance = mcpInheritance
        self.hooks = hooks
        self.memory = memory
        self.model = model
        self.completionRequirement = completionRequirement
        self.toolOverrides = toolOverrides
        self.allowedSubagentTypes = nil
        self.sessionToolsAllowlist = nil
        self.sessionToolsDenylist = nil
        self.promptBody = promptBody
        self.systemPrompt = systemPrompt
        self.userMessageTemplate = userMessageTemplate
        self.sourcePath = sourcePath
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, promptMode, toolConfig, capabilityMode, permissionMode, skills, discoverSkills, inheritSkills, agentsMd, injectDefaultTools, tools, disallowedTools, effort, maxTurns, isolation, background, color, initialPrompt, mcpServers, mcpInheritance, hooks, memory, model, completionRequirement, toolOverrides, systemPrompt, userMessageTemplate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = try container.decodeIfPresent(String.self, forKey: .name), !name.isEmpty else { throw AgentBuildError.missingField("name") }
        guard let description = try container.decodeIfPresent(String.self, forKey: .description) else { throw AgentBuildError.missingField("description") }
        self.init(
            name: name,
            description: description,
            promptMode: try container.decodeIfPresent(PromptMode.self, forKey: .promptMode) ?? .extend,
            toolConfig: try container.decodeIfPresent(AgentToolConfiguration.self, forKey: .toolConfig) ?? .defaultGrokBuild,
            capabilityMode: try container.decodeIfPresent(AgentCapabilityMode.self, forKey: .capabilityMode),
            permissionMode: try container.decodeIfPresent(PermissionMode.self, forKey: .permissionMode) ?? .default,
            skills: try container.decodeIfPresent([String].self, forKey: .skills) ?? [],
            discoverSkills: try container.decodeIfPresent(Bool.self, forKey: .discoverSkills) ?? true,
            inheritSkills: try container.decodeIfPresent(Bool.self, forKey: .inheritSkills) ?? true,
            agentsMd: try container.decodeIfPresent(Bool.self, forKey: .agentsMd) ?? true,
            injectDefaultTools: try container.decodeIfPresent(Bool.self, forKey: .injectDefaultTools) ?? true,
            tools: try AgentDefinition.decodeStringList(container, key: .tools),
            disallowedTools: try AgentDefinition.decodeStringList(container, key: .disallowedTools),
            effort: try container.decodeIfPresent(Effort.self, forKey: .effort),
            maxTurns: try AgentDefinition.decodePositiveTurns(container),
            isolation: try container.decodeIfPresent(IsolationMode.self, forKey: .isolation),
            background: try container.decodeIfPresent(Bool.self, forKey: .background),
            color: try AgentDefinition.decodeColor(container),
            initialPrompt: try container.decodeIfPresent(String.self, forKey: .initialPrompt),
            mcpServers: try container.decodeIfPresent([McpServerRef].self, forKey: .mcpServers) ?? [],
            mcpInheritance: try container.decodeIfPresent(McpInheritance.self, forKey: .mcpInheritance) ?? .all,
            hooks: try container.decodeIfPresent(HooksConfig.self, forKey: .hooks),
            memory: try container.decodeIfPresent(MemoryScope.self, forKey: .memory),
            model: try container.decodeIfPresent(ModelOverride.self, forKey: .model) ?? .inherit,
            completionRequirement: try container.decodeIfPresent(CompletionRequirement.self, forKey: .completionRequirement),
            toolOverrides: try container.decodeIfPresent(AgentToolOverrides.self, forKey: .toolOverrides),
            systemPrompt: try container.decodeIfPresent(TemplateOverride.self, forKey: .systemPrompt) ?? .none,
            userMessageTemplate: try container.decodeIfPresent(UserMessageTemplate.self, forKey: .userMessageTemplate) ?? .default
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(promptMode, forKey: .promptMode)
        try container.encode(toolConfig, forKey: .toolConfig)
        try container.encodeIfPresent(capabilityMode, forKey: .capabilityMode)
        try container.encode(permissionMode, forKey: .permissionMode)
        try container.encode(skills, forKey: .skills)
        try container.encode(discoverSkills, forKey: .discoverSkills)
        try container.encode(inheritSkills, forKey: .inheritSkills)
        try container.encode(agentsMd, forKey: .agentsMd)
        try container.encode(injectDefaultTools, forKey: .injectDefaultTools)
        try container.encode(tools, forKey: .tools)
        try container.encode(disallowedTools, forKey: .disallowedTools)
        try container.encodeIfPresent(effort, forKey: .effort)
        try container.encodeIfPresent(maxTurns, forKey: .maxTurns)
        try container.encodeIfPresent(isolation, forKey: .isolation)
        try container.encodeIfPresent(background, forKey: .background)
        try container.encodeIfPresent(color, forKey: .color)
        try container.encodeIfPresent(initialPrompt, forKey: .initialPrompt)
        try container.encode(mcpServers, forKey: .mcpServers)
        try container.encode(mcpInheritance, forKey: .mcpInheritance)
        try container.encodeIfPresent(hooks, forKey: .hooks)
        try container.encodeIfPresent(memory, forKey: .memory)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(completionRequirement, forKey: .completionRequirement)
        try container.encodeIfPresent(toolOverrides, forKey: .toolOverrides)
        try container.encode(systemPrompt, forKey: .systemPrompt)
        try container.encode(userMessageTemplate, forKey: .userMessageTemplate)
    }

    private static func decodeStringList(_ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> [String] {
        guard let value = try container.decodeIfPresent(AgentJSONValue.self, forKey: key) else { return [] }
        return try AgentToolMatching.stringList(value)
    }

    private static func decodeColor(_ container: KeyedDecodingContainer<CodingKeys>) throws -> AgentColor? {
        guard let value = try container.decodeIfPresent(AgentJSONValue.self, forKey: .color) else { return nil }
        guard case let .string(raw) = value else { return nil }
        return AgentColor.allCases.first {
            $0.rawValue.caseInsensitiveCompare(raw.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }
    }

    private static func decodePositiveTurns(_ container: KeyedDecodingContainer<CodingKeys>) throws -> Int? {
        guard let value = try container.decodeIfPresent(Int.self, forKey: .maxTurns) else { return nil }
        guard value > 0 else { throw AgentBuildError.invalidConfig("maxTurns must be greater than 0") }
        return value
    }

    public static func builtinDefaults(name: String, description: String) -> AgentDefinition {
        AgentDefinition(name: name, description: description)
    }

    public static func defaultGrokBuild() -> AgentDefinition { builtinDefaults(name: "grok-build", description: "Grok Build agent for software engineering tasks.") }
    public static func grokBuildConcise() -> AgentDefinition { var value = builtinDefaults(name: "grok-build-concise", description: "Grok Build agent with concise output format."); value.toolConfig = .preset("grok-build-concise"); value.agentsMd = false; return value }
    public static func grokBuildPlan() -> AgentDefinition { var value = builtinDefaults(name: "grok-build-plan", description: "Grok Build agent with plan mode support."); value.toolConfig = .preset("grok-build-plan"); return value }
    public static func grokBuildPlanNoSubagents() -> AgentDefinition { var value = builtinDefaults(name: "grok-build-plan-no-subagents", description: "Grok Build agent with plan mode (no subagents)."); value.toolConfig = .preset("grok-build-plan-no-subagents"); return value }
    public static func grokBuildAskUser() -> AgentDefinition { var value = builtinDefaults(name: "grok-build-ask-user", description: "Grok Build agent with ask-user-question tool."); value.toolConfig = .preset("grok-build-ask-user"); return value }
    public static func codex() -> AgentDefinition { var value = builtinDefaults(name: "codex", description: "Codex toolset and prompt"); value.toolConfig = .preset("codex"); value.systemPrompt = .codex; return value }
    public static func opencode() -> AgentDefinition { var value = builtinDefaults(name: "opencode", description: "OpenCode toolset — opencode-style tools and parameter conventions"); value.toolConfig = .preset("opencode"); return value }
    public static func generalPurpose() -> AgentDefinition { var value = builtinDefaults(name: "general-purpose", description: "General purpose agent for multi-step tasks."); value.promptBody = "Complete the assigned task directly. Do what was asked; nothing more, nothing less.\n\nRespond with a detailed writeup when done."; return value }
    public static func explore() -> AgentDefinition { var value = builtinDefaults(name: "explore", description: "Fast, read-only agent specialized for codebase exploration."); value.toolConfig = .preset("explore"); value.permissionMode = .plan; value.promptBody = "You are a fast, read-only codebase exploration agent.\n\n=== READ-ONLY MODE ===\n\nYou have NO file editing tools. Do not create, modify, or delete files."; value.inheritSkills = false; return value }
    public static func plan() -> AgentDefinition { var value = builtinDefaults(name: "plan", description: "Software architect for planning implementation strategies."); value.toolConfig = .preset("plan"); value.permissionMode = .plan; value.promptBody = "You are a read-only software architect. Explore the codebase and design implementation plans.\n\n=== READ-ONLY MODE ===\n\nYou have NO file editing tools. Do not create, modify, or delete files."; value.inheritSkills = false; return value }
    public static func browserUse() -> AgentDefinition { var value = builtinDefaults(name: "browser-use", description: "Web browsing and interaction agent."); value.promptMode = .full; value.agentsMd = false; value.promptBody = "You are a web browsing agent. You can navigate, interact with, and extract information from web pages. Use the available browsing tools to complete the user's request."; return value }
    public static func grokBuildOrchestrator() -> AgentDefinition { var value = builtinDefaults(name: "grok-build-orchestrator", description: "GrokBuild orchestrator that delegates coding to specialized subagents"); value.toolConfig = .preset("grok-build-orchestrator"); value.injectDefaultTools = false; value.promptBody = "## Orchestrator Mode\n\nYou are a technical lead orchestrating a team of senior-engineer subagents. Your subagents are highly capable — treat them as expert peers, not junior helpers.\n\nYour job is to think, plan, coordinate, and review. Their job is to explore, implement, and execute. Use them aggressively and liberally — spawn subagents early and often."; return value }

    public static var allBuiltInNames: [String] { ["grok-build", "grok-build-concise", "grok-build-plan", "grok-build-plan-no-subagents", "grok-build-ask-user", "codex", "opencode", "general-purpose", "explore", "plan", "browser-use", "grok-build-orchestrator"] }
    public static var subagentNames: [String] { ["general-purpose", "explore", "plan"] }

    public static func builtIn(named name: String) -> AgentDefinition? {
        switch name {
        case "grok-build": return .defaultGrokBuild()
        case "grok-build-concise": return .grokBuildConcise()
        case "grok-build-plan": return .grokBuildPlan()
        case "grok-build-plan-no-subagents": return .grokBuildPlanNoSubagents()
        case "grok-build-ask-user": return .grokBuildAskUser()
        case "codex": return .codex()
        case "opencode": return .opencode()
        case "general-purpose": return .generalPurpose()
        case "explore": return .explore()
        case "plan": return .plan()
        case "browser-use": return .browserUse()
        case "grok-build-orchestrator": return .grokBuildOrchestrator()
        default: return nil
        }
    }

    public static func builtIn(named name: BuiltinAgentName) -> AgentDefinition { name.definition }

    public func isStrictHarness() -> Bool {
        if case .none = systemPrompt, case .default = userMessageTemplate, injectDefaultTools { return false }
        return true
    }

    public func carriesTaskCompletionDiscipline() -> Bool { false }

    public func sessionToolsAllowed(_ id: String) -> Bool {
        if let denied = sessionToolsDenylist, AgentToolMatching.matchesAny(denied, id: id) { return false }
        guard let allowed = sessionToolsAllowlist else { return true }
        return AgentToolMatching.matchesAny(allowed, id: id)
    }

    public func hostedToolAllowed(_ id: String) -> Bool {
        if AgentToolMatching.matchesAny(disallowedTools, id: id) { return false }
        if !tools.isEmpty && !AgentToolMatching.matchesAny(tools, id: id) { return false }
        return sessionToolsAllowed(id)
    }

    public mutating func overrideFileTools(_ replacements: [AgentToolDefinition]) {
        let slots = [
            ["GrokBuild:read_file", "GrokBuildHashline:hashline_read"],
            ["GrokBuild:search_replace", "GrokBuildHashline:hashline_edit"],
            ["GrokBuild:grep", "GrokBuildHashline:hashline_grep"]
        ]
        for index in toolConfig.tools.indices {
            guard let slotIndex = slots.firstIndex(where: { $0.contains(toolConfig.tools[index].id) }), replacements.indices.contains(slotIndex) else { continue }
            toolConfig.tools[index] = replacements[slotIndex]
        }
    }

    public static func fromJSON(_ object: [String: AgentJSONValue]) throws -> AgentDefinition {
        let data = try AgentJSONValue.object(object).stableJSONData()
        var value = try JSONDecoder().decode(AgentDefinition.self, from: data)
        if case let .string(body)? = object["promptBody"], !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value.promptBody = body.trimmingCharacters(in: .whitespacesAndNewlines) }
        if case .object = object["toolConfig"] { } else { value.toolConfig = .defaultGrokBuild }
        value.scope = .builtIn
        return value
    }

    public func toJSONObject() throws -> [String: AgentJSONValue] {
        let data = try JSONEncoder().encode(self)
        var value = try JSONDecoder().decode(AgentJSONValue.self, from: data)
        guard case var .object(object) = value else { return [:] }
        if let promptBody { object["promptBody"] = .string(promptBody) }
        value = .object(object)
        guard case let .object(result) = value else { return [:] }
        return result
    }

    public func stableJSONData() throws -> Data { try AgentJSONValue.object(toJSONObject()).stableJSONData() }
}

extension AgentToolConfiguration {
    public static let defaultGrokBuild = AgentToolConfiguration(tools: [
        "run_terminal_command", "read_file", "view_image", "search_replace", "list_dir", "grep",
        "kill_command_or_subagent", "todo_write", "get_command_or_subagent_output", "wait_commands_or_subagents",
        "spawn_subagent", "agent_swarm", "scheduler_create", "scheduler_delete", "scheduler_list", "monitor",
        "search_tool", "use_tool", "update_goal", "workflow"
    ].map { AgentToolDefinition(id: $0) })

    public static func preset(_ name: String) -> AgentToolConfiguration {
        ToolsetPresets.configuration(named: name) ?? .defaultGrokBuild
    }
}

private enum AgentToolMatching {
    static func shortName(_ id: String) -> String { id.split(separator: ":").last.map(String.init) ?? id }
    static func matches(_ entry: String, id: String) -> Bool { entry == id || entry == shortName(id) }
    static func matchesAny(_ entries: [String], id: String) -> Bool { entries.contains { matches($0, id: id) } }

    static func stringList(_ value: AgentJSONValue) throws -> [String] {
        switch value {
        case .null: return []
        case let .string(value): return tokenize(value)
        case let .array(values):
            var result: [String] = []
            for item in values {
                guard case let .string(value) = item else { throw AgentBuildError.parseError("expected an array of strings") }
                result.append(value)
            }
            return result
        default: throw AgentBuildError.parseError("expected a string or array of strings")
        }
    }

    static func tokenize(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        for character in value {
            if character == "(" { depth += 1 }
            if character == ")" { depth = max(0, depth - 1) }
            if character == "," && depth == 0 {
                let item = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !item.isEmpty { result.append(item) }
                current = ""
            } else { current.append(character) }
        }
        let item = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !item.isEmpty { result.append(item) }
        return result
    }
}

private enum AgentEnvironment {
    static func grokHome(environment: [String: String]) -> URL {
        if let configured = environment["OPENGROK_HOME"], !configured.isEmpty { return URL(fileURLWithPath: configured) }
        if let home = environment["HOME"], !home.isEmpty { return URL(fileURLWithPath: home).appendingPathComponent(".opengrok") }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".opengrok")
    }
}

private enum ToolsetPresets {
    private static let store = Store()
    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var custom: [String: (@Sendable () -> AgentToolConfiguration, Bool)] = [:]
    }

    static let nativeNames = ["grok-build", "grok-build-concise", "grok-build-plan", "codex", "explore", "plan", "grok-computer"]

    static func configuration(named name: String) -> AgentToolConfiguration? {
        let normalized = normalize(name)
        switch normalized {
        case "grok-build": return .defaultGrokBuild
        case "grok-build-concise": return list(["run_terminal_command", "read_file", "view_image", "search_replace", "list_dir", "grep", "kill_command_or_subagent", "todo_write", "get_command_or_subagent_output", "scheduler_create", "scheduler_delete", "scheduler_list", "monitor", "update_goal", "workflow"])
        case "grok-build-plan": return list(AgentToolConfiguration.defaultGrokBuild.toolNames + ["enter_plan_mode", "exit_plan_mode", "ask_user_question"])
        case "grok-build-plan-no-subagents": return list(AgentToolConfiguration.defaultGrokBuild.toolNames.filter { !["spawn_subagent", "agent_swarm"].contains($0) } + ["enter_plan_mode", "exit_plan_mode", "ask_user_question"])
        case "grok-build-ask-user": return list(AgentToolConfiguration.defaultGrokBuild.toolNames + ["ask_user_question"])
        case "codex": return list(["run_terminal_command", "read_file", "view_image", "apply_patch", "list_dir", "grep", "kill_command_or_subagent", "todo_write", "get_command_or_subagent_output", "wait_commands_or_subagents", "spawn_subagent", "agent_swarm", "workflow", "scheduler_create", "scheduler_delete", "scheduler_list", "monitor", "search_tool", "use_tool", "update_goal", "enter_plan_mode", "exit_plan_mode", "ask_user_question"])
        case "explore": return list(["read_file", "view_image", "list_dir", "grep"])
        case "plan": return list(["read_file", "view_image", "list_dir", "grep", "todo_write"])
        case "grok-computer": return list(["run_terminal_command", "read_file", "search_replace", "write", "list_dir", "grep", "kill_command_or_subagent", "get_command_or_subagent_output"])
        case "grok-build-orchestrator": return list(["run_terminal_command", "read_file", "list_dir", "grep", "spawn_subagent", "agent_swarm", "get_command_or_subagent_output", "wait_commands_or_subagents", "kill_command_or_subagent", "search_tool", "use_tool", "todo_write", "enter_plan_mode", "exit_plan_mode", "ask_user_question", "update_goal", "workflow", "scheduler_create", "scheduler_delete", "scheduler_list", "monitor", "web_search", "web_fetch", "memory_search", "memory_get"])
        case "opencode": return list(["run_terminal_command", "read_file", "edit", "write", "grep", "glob", "todo_write", "skill", "kill_command_or_subagent", "get_command_or_subagent_output"])
        default:
            store.lock.lock(); defer { store.lock.unlock() }
            return store.custom[normalized]?.0()
        }
    }

    static func publicNames() -> [String] {
        store.lock.lock(); defer { store.lock.unlock() }
        let custom = store.custom.filter { $0.value.1 }.map(\.key).sorted()
        return nativeNames + custom.filter { !nativeNames.contains($0) }
    }

    static func register(_ name: String, builder: @escaping @Sendable () -> AgentToolConfiguration, public: Bool) {
        store.lock.lock(); defer { store.lock.unlock() }
        store.custom[normalize(name)] = (builder, `public`)
    }

    private static func normalize(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-") }
    private static func list(_ names: [String]) -> AgentToolConfiguration { AgentToolConfiguration(tools: names.map { AgentToolDefinition(id: $0) }) }
}

public typealias ToolsetPresetBuilder = @Sendable () -> AgentToolConfiguration

public func registerToolsetPreset(name: String, builder: @escaping ToolsetPresetBuilder) { ToolsetPresets.register(name, builder: builder, public: true) }
public func registerInternalToolsetPreset(name: String, builder: @escaping ToolsetPresetBuilder) { ToolsetPresets.register(name, builder: builder, public: false) }
public func presetNames() -> [String] { ToolsetPresets.publicNames() }
public func toolsetForPreset(_ preset: String) -> AgentToolConfiguration? { ToolsetPresets.configuration(named: preset) }
public func workspaceGrokBuildToolset() -> AgentToolConfiguration {
    let additions = [
        "write", "enter_plan_mode", "exit_plan_mode", "ask_user_question", "web_search",
        "image_gen", "image_to_video", "reference_to_video", "web_fetch", "memory_search",
        "memory_get", "lsp"
    ]
    return AgentToolConfiguration(tools: (AgentToolConfiguration.defaultGrokBuild.toolNames + additions).map { AgentToolDefinition(id: $0) })
}
