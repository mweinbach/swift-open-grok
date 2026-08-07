import Foundation
import OpenGrokAgentDefinitions
import enum OpenGrokToolTypes.AgentCollaborationTool
import enum OpenGrokToolTypes.AgentOrchestrationSurface
import enum OpenGrokToolTypes.SubagentIsolationMode

public typealias AgentDefinition = OpenGrokAgentDefinitions.AgentDefinition
public typealias AgentToolDefinition = OpenGrokAgentDefinitions.AgentToolDefinition
public typealias AgentToolConfiguration = OpenGrokAgentDefinitions.AgentToolConfiguration

public enum ContextSource: String, Codable, Sendable, Equatable {
    case new
    case resumed
}

public enum SubagentCapabilityMode: String, Codable, Sendable, Hashable, Equatable, CaseIterable {
    case readOnly = "read-only"
    case readWrite = "read-write"
    case execute
    case all

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value.lowercased() {
        case "read-only", "readonly", "read_only": self = .readOnly
        case "read-write", "readwrite", "read_write": self = .readWrite
        case "execute": self = .execute
        case "all": self = .all
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "unknown SubagentCapabilityMode: \(value)"
            )
        }
    }

    public var wireString: String { rawValue }

    fileprivate var definitionMode: AgentCapabilityMode {
        switch self {
        case .readOnly: return .readOnly
        case .readWrite: return .readWrite
        case .execute: return .execute
        case .all: return .all
        }
    }
}

public enum DefinitionSource: String, Codable, Sendable, Hashable, Equatable, CaseIterable {
    case builtIn = "built-in"
    case bundled
    case user
    case project
    case agentJSON = "agent-json"
    case cli

    fileprivate var priority: Int {
        switch self {
        case .project: return 60
        case .agentJSON: return 50
        case .builtIn: return 40
        case .user: return 30
        case .bundled: return 20
        case .cli: return 10
        }
    }

    fileprivate init(scope: AgentScope) {
        switch scope {
        case .builtIn: self = .builtIn
        case .bundled: self = .bundled
        case .user: self = .user
        case .project: self = .project
        }
    }
}

public struct PersonaIOField: Codable, Sendable, Hashable, Equatable {
    public var name: String
    public var ioType: String
    public var required: Bool
    public var description: String

    public init(name: String, ioType: String = "file", required: Bool = false, description: String = "") {
        self.name = name
        self.ioType = ioType
        self.required = required
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case ioType = "io_type"
        case required
        case description
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        ioType = try container.decodeIfPresent(String.self, forKey: .ioType) ?? "file"
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    }
}

public struct SubagentRole: Codable, Sendable, Hashable, Equatable {
    public var description: String
    public var defaultCapabilityMode: String?
    public var model: String?
    public var reasoningEffort: String?
    public var promptFile: String?
    public var defaultIsolation: String?
    public var sourceDirectory: URL?
    public var inherits: String?
    public var toolAllowlist: [String]?
    public var toolDenylist: [String]?

    public var sourceDir: URL? {
        get { sourceDirectory }
        set { sourceDirectory = newValue }
    }

    public init(
        description: String = "",
        defaultCapabilityMode: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        promptFile: String? = nil,
        defaultIsolation: String? = nil,
        sourceDirectory: URL? = nil,
        inherits: String? = nil,
        toolAllowlist: [String]? = nil,
        toolDenylist: [String]? = nil
    ) {
        self.description = description
        self.defaultCapabilityMode = defaultCapabilityMode
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.promptFile = promptFile
        self.defaultIsolation = defaultIsolation
        self.sourceDirectory = sourceDirectory
        self.inherits = inherits
        self.toolAllowlist = toolAllowlist
        self.toolDenylist = toolDenylist
    }

    private enum CodingKeys: String, CodingKey {
        case description
        case defaultCapabilityMode = "default_capability_mode"
        case model
        case reasoningEffort = "reasoning_effort"
        case promptFile = "prompt_file"
        case defaultIsolation = "default_isolation"
        case inherits
        case extends
        case parent
        case toolAllowlist = "tool_allowlist"
        case toolDenylist = "tool_denylist"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        defaultCapabilityMode = try container.decodeIfPresent(String.self, forKey: .defaultCapabilityMode)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        promptFile = try container.decodeIfPresent(String.self, forKey: .promptFile)
        defaultIsolation = try container.decodeIfPresent(String.self, forKey: .defaultIsolation)
        inherits = try container.decodeIfPresent(String.self, forKey: .inherits)
            ?? container.decodeIfPresent(String.self, forKey: .extends)
            ?? container.decodeIfPresent(String.self, forKey: .parent)
        sourceDirectory = nil
        toolAllowlist = try container.decodeIfPresent([String].self, forKey: .toolAllowlist)
        toolDenylist = try container.decodeIfPresent([String].self, forKey: .toolDenylist)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(defaultCapabilityMode, forKey: .defaultCapabilityMode)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(promptFile, forKey: .promptFile)
        try container.encodeIfPresent(defaultIsolation, forKey: .defaultIsolation)
        try container.encodeIfPresent(inherits, forKey: .inherits)
        try container.encodeIfPresent(toolAllowlist, forKey: .toolAllowlist)
        try container.encodeIfPresent(toolDenylist, forKey: .toolDenylist)
    }
}

public struct SubagentPersona: Codable, Sendable, Hashable, Equatable {
    public var instructions: String?
    public var description: String?
    public var instructionsFile: String?
    public var inputs: [PersonaIOField]
    public var outputs: [PersonaIOField]
    public var defaultIsolation: String?
    public var model: String?
    public var reasoningEffort: String?
    public var sourceDirectory: URL?
    public var sourcePath: String?
    public var inherits: String?
    public var toolAllowlist: [String]?
    public var toolDenylist: [String]?

    public var sourceDir: URL? {
        get { sourceDirectory }
        set { sourceDirectory = newValue }
    }

    public init(
        instructions: String? = nil,
        description: String? = nil,
        instructionsFile: String? = nil,
        inputs: [PersonaIOField] = [],
        outputs: [PersonaIOField] = [],
        defaultIsolation: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        sourceDirectory: URL? = nil,
        sourcePath: String? = nil,
        inherits: String? = nil,
        toolAllowlist: [String]? = nil,
        toolDenylist: [String]? = nil
    ) {
        self.instructions = instructions
        self.description = description
        self.instructionsFile = instructionsFile
        self.inputs = inputs
        self.outputs = outputs
        self.defaultIsolation = defaultIsolation
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.sourceDirectory = sourceDirectory
        self.sourcePath = sourcePath
        self.inherits = inherits
        self.toolAllowlist = toolAllowlist
        self.toolDenylist = toolDenylist
    }

    private enum CodingKeys: String, CodingKey {
        case instructions
        case description
        case instructionsFile = "instructions_file"
        case inputs
        case outputs
        case defaultIsolation = "default_isolation"
        case model
        case reasoningEffort = "reasoning_effort"
        case inherits
        case extends
        case parent
        case toolAllowlist = "tool_allowlist"
        case toolDenylist = "tool_denylist"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        instructionsFile = try container.decodeIfPresent(String.self, forKey: .instructionsFile)
        inputs = try container.decodeIfPresent([PersonaIOField].self, forKey: .inputs) ?? []
        outputs = try container.decodeIfPresent([PersonaIOField].self, forKey: .outputs) ?? []
        defaultIsolation = try container.decodeIfPresent(String.self, forKey: .defaultIsolation)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        inherits = try container.decodeIfPresent(String.self, forKey: .inherits)
            ?? container.decodeIfPresent(String.self, forKey: .extends)
            ?? container.decodeIfPresent(String.self, forKey: .parent)
        sourceDirectory = nil
        sourcePath = nil
        toolAllowlist = try container.decodeIfPresent([String].self, forKey: .toolAllowlist)
        toolDenylist = try container.decodeIfPresent([String].self, forKey: .toolDenylist)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(instructions, forKey: .instructions)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(instructionsFile, forKey: .instructionsFile)
        try container.encode(inputs, forKey: .inputs)
        try container.encode(outputs, forKey: .outputs)
        try container.encodeIfPresent(defaultIsolation, forKey: .defaultIsolation)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(inherits, forKey: .inherits)
        try container.encodeIfPresent(toolAllowlist, forKey: .toolAllowlist)
        try container.encodeIfPresent(toolDenylist, forKey: .toolDenylist)
    }

    public func renderIOSummary(named name: String) -> String {
        let summary: String
        if let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            summary = description
        } else {
            summary = instructions?
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .prefix(while: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                .joined(separator: " ") ?? "Custom persona"
        }
        var lines = ["- **\(name)**: \(summary.isEmpty ? "Custom persona" : summary)"]
        if let sourcePath { lines.append("  Path: \(sourcePath)") }
        if !inputs.isEmpty {
            lines.append("  Expects in prompt:")
            lines.append(contentsOf: inputs.map { field in
                "    - \(field.name) (\(field.ioType), \(field.required ? "REQUIRED" : "optional")): \(field.description)"
            })
        }
        if !outputs.isEmpty {
            lines.append("  Produces:")
            lines.append(contentsOf: outputs.map { field in
                "    - \(field.name) (\(field.ioType), \(field.required ? "REQUIRED" : "optional")): \(field.description)"
            })
        }
        return lines.joined(separator: "\n")
    }
}

public struct SubagentRuntimeOverrides: Codable, Sendable, Hashable, Equatable {
    public var model: String?
    public var persona: String?
    public var reasoningEffort: String?
    public var capabilityMode: SubagentCapabilityMode?
    public var isolation: SubagentIsolationMode?
    public var permissionMode: PermissionMode?
    public var toolAllowlist: [String]?
    public var toolDenylist: [String]?
    public var allowNestedSubagents: Bool

    public init(
        model: String? = nil,
        persona: String? = nil,
        reasoningEffort: String? = nil,
        capabilityMode: SubagentCapabilityMode? = nil,
        isolation: SubagentIsolationMode? = nil,
        permissionMode: PermissionMode? = nil,
        toolAllowlist: [String]? = nil,
        toolDenylist: [String]? = nil,
        allowNestedSubagents: Bool = false
    ) {
        self.model = model
        self.persona = persona
        self.reasoningEffort = reasoningEffort
        self.capabilityMode = capabilityMode
        self.isolation = isolation
        self.permissionMode = permissionMode
        self.toolAllowlist = toolAllowlist
        self.toolDenylist = toolDenylist
        self.allowNestedSubagents = allowNestedSubagents
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case persona
        case reasoningEffort = "reasoning_effort"
        case capabilityMode = "capability_mode"
        case isolation
        case permissionMode = "permission_mode"
        case toolAllowlist = "tool_allowlist"
        case toolDenylist = "tool_denylist"
        case allowNestedSubagents = "allow_nested_subagents"
    }
}

public struct ParentRuntimeDefaults: Codable, Sendable, Hashable, Equatable {
    public var model: String?
    public var reasoningEffort: String?
    public var capabilityMode: SubagentCapabilityMode?
    public var isolation: SubagentIsolationMode
    public var permissionMode: PermissionMode?
    public var toolAllowlist: [String]?

    public init(
        model: String? = nil,
        reasoningEffort: String? = nil,
        capabilityMode: SubagentCapabilityMode? = nil,
        isolation: SubagentIsolationMode = .none,
        permissionMode: PermissionMode? = nil,
        toolAllowlist: [String]? = nil
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.capabilityMode = capabilityMode
        self.isolation = isolation
        self.permissionMode = permissionMode
        self.toolAllowlist = toolAllowlist
    }
}

public struct EffectiveRuntimeConfig: Codable, Sendable, Hashable, Equatable {
    public var model: String?
    public var reasoningEffort: String?
    public var capabilityMode: SubagentCapabilityMode?
    public var persona: String?
    public var personaInstructions: String?
    public var rolePrompt: String?
    public var rolePromptWarning: String?
    public var roleName: String?
    public var personaError: String?
    public var personaResolutionFatal: Bool
    public var isolation: SubagentIsolationMode
    public var permissionMode: PermissionMode?
    public var toolNames: [String]

    public init(
        model: String? = nil,
        reasoningEffort: String? = nil,
        capabilityMode: SubagentCapabilityMode? = nil,
        persona: String? = nil,
        personaInstructions: String? = nil,
        rolePrompt: String? = nil,
        rolePromptWarning: String? = nil,
        roleName: String? = nil,
        personaError: String? = nil,
        personaResolutionFatal: Bool = false,
        isolation: SubagentIsolationMode = .none,
        permissionMode: PermissionMode? = nil,
        toolNames: [String] = []
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.capabilityMode = capabilityMode
        self.persona = persona
        self.personaInstructions = personaInstructions
        self.rolePrompt = rolePrompt
        self.rolePromptWarning = rolePromptWarning
        self.roleName = roleName
        self.personaError = personaError
        self.personaResolutionFatal = personaResolutionFatal
        self.isolation = isolation
        self.permissionMode = permissionMode
        self.toolNames = toolNames
    }
}

public struct SubagentModelRoute: Codable, Sendable, Hashable, Equatable {
    public var configuredModelID: String
    public var provider: String

    public init(configuredModelID: String, provider: String) {
        self.configuredModelID = configuredModelID
        self.provider = provider
    }

    private enum CodingKeys: String, CodingKey {
        case configuredModelID = "configured_model_id"
        case provider
    }
}

public struct ResumeSourceData: Codable, Sendable, Hashable, Equatable {
    public var subagentID: String
    public var subagentType: String
    public var persona: String?
    public var modelID: String?
    public var modelRoute: SubagentModelRoute?
    public var childCWD: String
    public var worktreePath: URL?
    public var snapshotReference: String?
    public var childSessionID: String
    public var antigravityConversationID: String?

    public var subagentId: String {
        get { subagentID }
        set { subagentID = newValue }
    }

    public var modelId: String? {
        get { modelID }
        set { modelID = newValue }
    }

    public var childCwd: String {
        get { childCWD }
        set { childCWD = newValue }
    }

    public var snapshotRef: String? {
        get { snapshotReference }
        set { snapshotReference = newValue }
    }

    public var childSessionId: String {
        get { childSessionID }
        set { childSessionID = newValue }
    }

    public var antigravityConversationId: String? {
        get { antigravityConversationID }
        set { antigravityConversationID = newValue }
    }

    public init(
        subagentID: String,
        subagentType: String,
        persona: String? = nil,
        modelID: String? = nil,
        modelRoute: SubagentModelRoute? = nil,
        childCWD: String,
        worktreePath: URL? = nil,
        snapshotReference: String? = nil,
        childSessionID: String,
        antigravityConversationID: String? = nil
    ) {
        self.subagentID = subagentID
        self.subagentType = subagentType
        self.persona = persona
        self.modelID = modelID
        self.modelRoute = modelRoute
        self.childCWD = childCWD
        self.worktreePath = worktreePath
        self.snapshotReference = snapshotReference
        self.childSessionID = childSessionID
        self.antigravityConversationID = antigravityConversationID
    }

    public init(
        subagentId: String,
        subagentType: String,
        persona: String? = nil,
        modelId: String? = nil,
        modelRoute: SubagentModelRoute? = nil,
        childCwd: String,
        worktreePath: URL? = nil,
        snapshotRef: String? = nil,
        childSessionId: String,
        antigravityConversationId: String? = nil
    ) {
        self.init(
            subagentID: subagentId,
            subagentType: subagentType,
            persona: persona,
            modelID: modelId,
            modelRoute: modelRoute,
            childCWD: childCwd,
            worktreePath: worktreePath,
            snapshotReference: snapshotRef,
            childSessionID: childSessionId,
            antigravityConversationID: antigravityConversationId
        )
    }

    private enum CodingKeys: String, CodingKey {
        case subagentID = "subagent_id"
        case subagentType = "subagent_type"
        case persona
        case modelID = "model_id"
        case modelRoute = "model_route"
        case childCWD = "child_cwd"
        case worktreePath = "worktree_path"
        case snapshotReference = "snapshot_ref"
        case childSessionID = "child_session_id"
        case antigravityConversationID = "antigravity_conversation_id"
    }
}

public enum ResumeValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    case typeMismatch(requested: String, sourceValue: String)
    case personaMismatch(requested: String, sourceValue: String?)

    public var description: String {
        switch self {
        case let .typeMismatch(requested, sourceValue):
            return "Cannot resume with subagent_type '\(requested)': source subagent was '\(sourceValue)'. Resumed sessions must use the same subagent type as the source."
        case let .personaMismatch(requested, sourceValue):
            let renderedSource = sourceValue.map { "Some(\"\($0)\")" } ?? "None"
            return "Cannot resume with persona '\(requested)': source subagent used \(renderedSource). Resumed sessions must use the same persona as the source."
        }
    }
}

public enum ResolutionError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknown(subagentType: String, available: [String])
    case disabled(subagentType: String)
    case notAllowed(subagentType: String, allowed: [String])
    case personaResolution(String)
    case resumeValidation(ResumeValidationError)
    case invalidName(String)
    case invalidDefinition(String)
    case unknownParent(child: String, parent: String)
    case hierarchyCycle([String])
    case depthExceeded(currentDepth: Int, maximumDepth: Int)
    case modelUnavailable(String)
    case capabilityEscalation(requested: SubagentCapabilityMode, ceiling: SubagentCapabilityMode)

    public var description: String {
        switch self {
        case let .unknown(subagentType, available):
            return "unknown subagent type \"\(subagentType)\"; available: \(available)"
        case let .disabled(subagentType):
            return "subagent \"\(subagentType)\" is disabled"
        case let .notAllowed(subagentType, allowed):
            return "subagent \"\(subagentType)\" is not allowed; allowed: \(allowed)"
        case let .personaResolution(message):
            return "persona resolution failed: \(message)"
        case let .resumeValidation(error):
            return "resume validation failed: \(error)"
        case let .invalidName(name):
            return "invalid subagent name \"\(name)\""
        case let .invalidDefinition(message):
            return "invalid subagent definition: \(message)"
        case let .unknownParent(child, parent):
            return "subagent \"\(child)\" extends unknown definition \"\(parent)\""
        case let .hierarchyCycle(path):
            return "subagent definition inheritance cycle: \(path.joined(separator: " -> "))"
        case let .depthExceeded(currentDepth, maximumDepth):
            return "subagent depth \(currentDepth) exceeds maximum depth \(maximumDepth)"
        case let .modelUnavailable(model):
            return "subagent model \"\(model)\" is unavailable"
        case let .capabilityEscalation(requested, ceiling):
            return "subagent capability \"\(requested.rawValue)\" exceeds parent ceiling \"\(ceiling.rawValue)\""
        }
    }
}

public struct SubagentDefinition: Codable, Sendable, Equatable {
    public var definition: AgentDefinition
    public var extends: String?
    public var source: DefinitionSource
    public var sourcePath: URL?

    public init(
        definition: AgentDefinition,
        extends: String? = nil,
        source: DefinitionSource? = nil,
        sourcePath: URL? = nil
    ) {
        self.definition = definition
        self.extends = extends
        self.source = source ?? DefinitionSource(scope: definition.scope)
        self.sourcePath = sourcePath ?? definition.sourcePath.map { URL(fileURLWithPath: $0) }
    }

    public var name: String { definition.name }
}

public struct DefinitionResolutionContext: Sendable {
    public var cwd: URL
    public var definitions: [SubagentDefinition]
    public var cliAgents: [AgentDefinition]
    public var toggles: [String: Bool]
    public var allowedTypes: [String]?
    public var currentDepth: Int
    public var maximumDepth: Int
    public var parentRuntime: ParentRuntimeDefaults?
    public var includeFilesystemDefinitions: Bool
    /// The session's environment for user-level discovery (`OPENGROK_HOME`,
    /// `HOME`). `nil` reads the process environment — the legacy default,
    /// kept so existing call sites compile unchanged; a live session must
    /// pass its own environment or a `--cwd`/injected-env launch (and every
    /// hermetic test) would scan the developer's real home directory.
    public var environment: [String: String]?

    public init(
        cwd: URL,
        definitions: [SubagentDefinition] = [],
        cliAgents: [AgentDefinition] = [],
        toggles: [String: Bool] = [:],
        allowedTypes: [String]? = nil,
        currentDepth: Int = 0,
        maximumDepth: Int = 1,
        parentRuntime: ParentRuntimeDefaults? = nil,
        includeFilesystemDefinitions: Bool = true,
        environment: [String: String]? = nil
    ) {
        self.cwd = cwd
        self.definitions = definitions
        self.cliAgents = cliAgents
        self.toggles = toggles
        self.allowedTypes = allowedTypes
        self.currentDepth = currentDepth
        self.maximumDepth = maximumDepth
        self.parentRuntime = parentRuntime
        self.includeFilesystemDefinitions = includeFilesystemDefinitions
        self.environment = environment
    }
}

public struct DefinitionValidationContext: Sendable {
    public var cwd: URL
    public var definitions: [SubagentDefinition]
    public var cliAgentNames: [String]
    public var toggles: [String: Bool]
    public var allowedTypes: [String]?
    public var includeFilesystemDefinitions: Bool

    public init(
        cwd: URL,
        definitions: [SubagentDefinition] = [],
        cliAgentNames: [String] = [],
        toggles: [String: Bool] = [:],
        allowedTypes: [String]? = nil,
        includeFilesystemDefinitions: Bool = true
    ) {
        self.cwd = cwd
        self.definitions = definitions
        self.cliAgentNames = cliAgentNames
        self.toggles = toggles
        self.allowedTypes = allowedTypes
        self.includeFilesystemDefinitions = includeFilesystemDefinitions
    }
}

public struct HarnessToolsetContext: Sendable {
    public var harnessOverride: String?
    public var parentAgentName: String?
    public var parentModelAgentType: String?
    public var fileToolOverrides: [AgentToolDefinition]?

    public init(
        harnessOverride: String? = nil,
        parentAgentName: String? = nil,
        parentModelAgentType: String? = nil,
        fileToolOverrides: [AgentToolDefinition]? = nil
    ) {
        self.harnessOverride = harnessOverride
        self.parentAgentName = parentAgentName
        self.parentModelAgentType = parentModelAgentType
        self.fileToolOverrides = fileToolOverrides
    }
}

public func subagentHarnessFlavorIsRepresentable(_ agentType: String) -> Bool {
    false
}

public func applyHarnessToolset(
    subagentType: String,
    context: HarnessToolsetContext,
    definition: inout AgentDefinition
) {
    let selectedHarness = context.harnessOverride
        ?? context.parentAgentName.flatMap { subagentHarnessFlavorIsRepresentable($0) ? $0 : nil }
        ?? context.parentModelAgentType
    if let selectedHarness, subagentHarnessFlavorIsRepresentable(selectedHarness) {
        return
    }
    if let fileToolOverrides = context.fileToolOverrides {
        definition.overrideFileTools(fileToolOverrides)
    }
}

public func intersectCapabilityModes(
    requested: SubagentCapabilityMode?,
    ceiling: SubagentCapabilityMode?
) -> SubagentCapabilityMode? {
    switch (requested, ceiling) {
    case (nil, nil): return nil
    case let (value?, nil), let (nil, value?): return value
    case let (.all, value), let (value, .all): return value
    case (.readOnly, _), (_, .readOnly): return .readOnly
    case (.readWrite, .readWrite): return .readWrite
    case (.execute, .execute): return .execute
    case (.readWrite, .execute), (.execute, .readWrite): return .readOnly
    }
}

public func intersectCapabilityModes(
    _ requested: SubagentCapabilityMode?,
    _ ceiling: SubagentCapabilityMode?
) -> SubagentCapabilityMode? {
    intersectCapabilityModes(requested: requested, ceiling: ceiling)
}

public func validateResumeIdentity(
    requestedType: String,
    requestedPersona: String?,
    source: ResumeSourceData
) throws {
    guard requestedType == source.subagentType else {
        throw ResumeValidationError.typeMismatch(requested: requestedType, sourceValue: source.subagentType)
    }
    if let requestedPersona, source.persona != requestedPersona {
        throw ResumeValidationError.personaMismatch(requested: requestedPersona, sourceValue: source.persona)
    }
}

public func validateResumeIdentity(
    _ requestedType: String,
    _ requestedPersona: String?,
    _ source: ResumeSourceData
) throws {
    try validateResumeIdentity(requestedType: requestedType, requestedPersona: requestedPersona, source: source)
}

public func discoverAgentDefinition(
    subagentType: String,
    context: DefinitionResolutionContext
) -> AgentDefinition? {
    bestDefinition(named: subagentType, context: context)?.definition
}

public func discoverAgentDefinition(
    _ subagentType: String,
    _ context: DefinitionResolutionContext
) -> AgentDefinition? {
    discoverAgentDefinition(subagentType: subagentType, context: context)
}

public func availableAgentNames(context: DefinitionResolutionContext) -> [String] {
    // The toggle filter belongs to the advertised roster only
    // (`discovery.rs` `merge_subagents` step 3). Spawn-time resolution must
    // still FIND a disabled definition so the gate can reject it as
    // `.disabled` — filtering here too would misreport it as unknown.
    mergedDefinitions(context: context)
        .filter { context.toggles[$0.key] != false }
        .keys
        .sorted()
}

public func availableAgentNames(_ context: DefinitionResolutionContext) -> [String] {
    availableAgentNames(context: context)
}

public func gateAgentDefinition(
    subagentType: String,
    context: DefinitionResolutionContext
) throws {
    if context.toggles[subagentType] == false {
        throw ResolutionError.disabled(subagentType: subagentType)
    }
    if let allowedTypes = context.allowedTypes,
       !allowedTypes.contains(where: { $0.caseInsensitiveCompare(subagentType) == .orderedSame }) {
        throw ResolutionError.notAllowed(subagentType: subagentType, allowed: allowedTypes)
    }
}

public func gateAgentDefinition(
    _ subagentType: String,
    _ context: DefinitionResolutionContext
) throws {
    try gateAgentDefinition(subagentType: subagentType, context: context)
}

public func validateAgentName(
    subagentType: String,
    context: DefinitionValidationContext
) throws {
    let resolutionContext = DefinitionResolutionContext(
        cwd: context.cwd,
        definitions: context.definitions,
        cliAgents: context.cliAgentNames.map { AgentDefinition.builtinDefaults(name: $0, description: $0) },
        toggles: context.toggles,
        allowedTypes: context.allowedTypes,
        includeFilesystemDefinitions: context.includeFilesystemDefinitions
    )
    guard bestDefinition(named: subagentType, context: resolutionContext) != nil else {
        throw ResolutionError.unknown(subagentType: subagentType, available: availableAgentNames(context: resolutionContext))
    }
    try gateAgentDefinition(subagentType: subagentType, context: resolutionContext)
}

public func validateAgentName(
    _ subagentType: String,
    _ context: DefinitionValidationContext
) throws {
    try validateAgentName(subagentType: subagentType, context: context)
}

public func resolveAgentDefinition(
    subagentType: String,
    context: DefinitionResolutionContext
) throws -> AgentDefinition {
    guard let entry = bestDefinition(named: subagentType, context: context) else {
        throw ResolutionError.unknown(subagentType: subagentType, available: availableAgentNames(context: context))
    }
    try gateAgentDefinition(subagentType: subagentType, context: context)
    guard context.currentDepth < context.maximumDepth else {
        throw ResolutionError.depthExceeded(currentDepth: context.currentDepth, maximumDepth: context.maximumDepth)
    }
    let resolved = try resolveDefinitionHierarchy(named: entry.name, context: context)
    do {
        try resolved.validate()
    } catch {
        throw ResolutionError.invalidDefinition(String(describing: error))
    }
    return resolved
}

public func resolveAgentDefinition(
    _ subagentType: String,
    _ context: DefinitionResolutionContext
) throws -> AgentDefinition {
    try resolveAgentDefinition(subagentType: subagentType, context: context)
}

public func selectRole(
    subagentType: String,
    overrides: SubagentRuntimeOverrides,
    roles: [String: SubagentRole]
) -> (role: SubagentRole?, roleName: String?) {
    if let role = roles[subagentType] { return (role, subagentType) }
    guard let persona = overrides.persona, let role = roles[persona] else { return (nil, nil) }
    return (role, persona)
}

public func selectRole(
    _ subagentType: String,
    _ overrides: SubagentRuntimeOverrides,
    _ roles: [String: SubagentRole]
) -> (role: SubagentRole?, roleName: String?) {
    selectRole(subagentType: subagentType, overrides: overrides, roles: roles)
}

public func resolveRole(
    named roleName: String,
    roles: [String: SubagentRole]
) throws -> SubagentRole {
    try resolveRole(named: roleName, roles: roles, stack: [])
}

public func resolvePersona(
    named personaName: String,
    personas: [String: SubagentPersona]
) throws -> SubagentPersona {
    try resolvePersona(named: personaName, personas: personas, stack: [])
}

public func applyDefinitionRuntimeDefaults(
    runtime: inout EffectiveRuntimeConfig,
    definition: AgentDefinition
) {
    if runtime.capabilityMode == nil, let capabilityMode = definition.capabilityMode {
        runtime.capabilityMode = SubagentCapabilityMode(agentMode: capabilityMode)
    }
    if runtime.reasoningEffort == nil, let effort = definition.effort {
        runtime.reasoningEffort = effort.rawValue
    }
    if runtime.isolation == .none, definition.isolation == .worktree {
        runtime.isolation = .worktree
    }
    if runtime.permissionMode == nil {
        runtime.permissionMode = definition.permissionMode
    }
}

public func applyDefinitionRuntimeDefaults(
    _ runtime: inout EffectiveRuntimeConfig,
    _ definition: AgentDefinition
) {
    applyDefinitionRuntimeDefaults(runtime: &runtime, definition: definition)
}

public func applyChildToolPolicy(
    definition: inout AgentDefinition,
    capabilityMode: SubagentCapabilityMode?,
    allowNestedSubagents: Bool
) {
    let originalTools = definition.toolConfig.tools
    if let capabilityMode {
        definition.toolConfig.tools = originalTools.filter { toolIsAllowed($0.id, under: capabilityMode) }
    }
    // `ask_user_question` is stripped alongside the plan tools. Recorded
    // divergence: upstream subagents *inherit* the parent's ask-user gate
    // (`xai-grok-shell/src/agent/subagent/mod.rs:196-198`) because their
    // questions ride a session-routed ACP reverse-request back to the pager.
    // The port's child runner has no question surface at all — an advertised
    // tool here would block the child forever on a sheet no one can present.
    definition.toolConfig.tools.removeAll { tool in
        isPlanTool(tool.id)
            || isAskUserTool(tool.id)
            || (!allowNestedSubagents && isNestedSpawnTool(tool.id))
    }
    pruneOrphanedLifecycleTools(in: &definition.toolConfig)
}

public func applyChildToolPolicy(
    _ definition: inout AgentDefinition,
    _ capabilityMode: SubagentCapabilityMode?,
    _ allowNestedSubagents: Bool
) {
    applyChildToolPolicy(
        definition: &definition,
        capabilityMode: capabilityMode,
        allowNestedSubagents: allowNestedSubagents
    )
}

public func resolveEffectiveOverrides(
    overrides: SubagentRuntimeOverrides,
    role: SubagentRole?,
    personas: [String: SubagentPersona],
    cwd: URL?,
    roleName: String? = nil,
    parent: ParentRuntimeDefaults? = nil
) -> EffectiveRuntimeConfig {
    var runtime = EffectiveRuntimeConfig(roleName: roleName)
    let personaName = overrides.persona
    let resolvedPersona = personaName.flatMap { try? resolvePersona(named: $0, personas: personas, stack: []) }
    let personaResult = resolvePersonaInstructions(name: personaName, personas: personas, cwd: cwd)
    runtime.persona = personaName
    runtime.personaInstructions = personaResult.instructions
    runtime.personaError = personaResult.error
    runtime.personaResolutionFatal = personaResult.fatal
    if personaResult.fatal {
        return runtime
    }

    runtime.model = overrides.model ?? role?.model ?? resolvedPersona?.model ?? parent?.model
    runtime.reasoningEffort = overrides.reasoningEffort ?? role?.reasoningEffort ?? resolvedPersona?.reasoningEffort ?? parent?.reasoningEffort
    let roleCapability = role?.defaultCapabilityMode.flatMap(parseCapabilityMode)
    runtime.capabilityMode = intersectCapabilityModes(
        requested: overrides.capabilityMode ?? roleCapability,
        ceiling: parent?.capabilityMode
    )
    if runtime.capabilityMode == nil {
        runtime.capabilityMode = roleCapability ?? parent?.capabilityMode
    }
    runtime.isolation = overrides.isolation
        ?? role?.defaultIsolation.flatMap(parseIsolationMode)
        ?? resolvedPersona?.defaultIsolation.flatMap(parseIsolationMode)
        ?? parent?.isolation
        ?? .none
    runtime.permissionMode = overrides.permissionMode ?? parent?.permissionMode

    if let promptFile = role?.promptFile {
        let base = role?.sourceDirectory ?? cwd
        if let base {
            do {
                runtime.rolePrompt = try String(contentsOf: base.appendingPathComponent(promptFile), encoding: .utf8)
            } catch {
                runtime.rolePromptWarning = "role prompt_file \"\(promptFile)\": \(error.localizedDescription)"
            }
        } else {
            runtime.rolePromptWarning = "role prompt_file \"\(promptFile)\": no source directory or cwd available"
        }
    }
    return runtime
}

public func resolveEffectiveOverrides(
    _ overrides: SubagentRuntimeOverrides,
    _ role: SubagentRole?,
    _ personas: [String: SubagentPersona],
    _ cwd: URL?,
    _ roleName: String? = nil,
    _ parent: ParentRuntimeDefaults? = nil
) -> EffectiveRuntimeConfig {
    resolveEffectiveOverrides(
        overrides: overrides,
        role: role,
        personas: personas,
        cwd: cwd,
        roleName: roleName,
        parent: parent
    )
}

public func resolveRuntimeConfig(
    subagentType: String,
    overrides: SubagentRuntimeOverrides,
    roles: [String: SubagentRole],
    personas: [String: SubagentPersona],
    cwd: URL?,
    definition: AgentDefinition,
    parent: ParentRuntimeDefaults? = nil
) -> EffectiveRuntimeConfig {
    let selected = selectRole(subagentType: subagentType, overrides: overrides, roles: roles)
    var effectiveRole = selected.role
    if let selectedRoleName = selected.roleName, let resolved = try? resolveRole(named: selectedRoleName, roles: roles) {
        effectiveRole = resolved
    }
    var runtime = resolveEffectiveOverrides(
        overrides: overrides,
        role: effectiveRole,
        personas: personas,
        cwd: cwd,
        roleName: selected.roleName,
        parent: parent
    )
    applyDefinitionRuntimeDefaults(runtime: &runtime, definition: definition)
    let persona = overrides.persona.flatMap { personas[$0] }
    runtime.toolNames = resolveToolNames(
        definition: definition,
        capabilityMode: runtime.capabilityMode,
        allowNestedSubagents: overrides.allowNestedSubagents,
        explicitAllowlist: overrides.toolAllowlist,
        explicitDenylist: overrides.toolDenylist,
        role: effectiveRole,
        persona: persona,
        parentAllowlist: parent?.toolAllowlist
    )
    return runtime
}

public func resolveModelRoute(
    requestedModel: String?,
    roleModel: String?,
    personaModel: String?,
    parentRoute: SubagentModelRoute?,
    catalog: [String: SubagentModelRoute]
) throws -> SubagentModelRoute? {
    let selectedID = requestedModel ?? roleModel ?? personaModel ?? parentRoute?.configuredModelID
    guard let selectedID else { return parentRoute }
    if catalog.isEmpty {
        return SubagentModelRoute(configuredModelID: selectedID, provider: parentRoute?.provider ?? "unknown")
    }
    guard let route = catalog[selectedID] else { throw ResolutionError.modelUnavailable(selectedID) }
    return route
}

public func renderSubagentSystemPrompt(
    definition: AgentDefinition,
    runtime: EffectiveRuntimeConfig,
    workingDirectory: URL
) -> String? {
    var sections: [String] = []
    if case let .custom(template) = definition.systemPrompt, !template.isEmpty {
        sections.append(template)
    }
    if let promptBody = definition.promptBody, !promptBody.isEmpty { sections.append(promptBody) }
    if let rolePrompt = runtime.rolePrompt, !rolePrompt.isEmpty {
        sections.append("<role-instructions>\n\(rolePrompt)\n</role-instructions>")
    }
    if let personaInstructions = runtime.personaInstructions, !personaInstructions.isEmpty {
        sections.append("<persona>\n\(personaInstructions)\n</persona>")
    }
    sections.append("Workspace Path: \(workingDirectory.standardizedFileURL.path)")
    return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
}

public func renderSubagentInitialUserMessage(
    definition: AgentDefinition,
    workingDirectory: URL
) -> String? {
    guard definition.agentsMd else { return nil }
    let files = agentsFiles(from: workingDirectory)
    guard !files.isEmpty else { return nil }
    let body = files.compactMap { url -> String? in
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return "## \(url.path)\n\(content)"
    }.joined(separator: "\n\n")
    return body.isEmpty ? nil : body
}

private extension SubagentCapabilityMode {
    init(agentMode: AgentCapabilityMode) {
        switch agentMode {
        case .readOnly: self = .readOnly
        case .readWrite: self = .readWrite
        case .execute: self = .execute
        case .all: self = .all
        }
    }
}

private func parseCapabilityMode(_ value: String) -> SubagentCapabilityMode? {
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "read-only", "readonly", "read_only": return .readOnly
    case "read-write", "readwrite", "read_write": return .readWrite
    case "execute": return .execute
    case "all", "full": return .all
    default: return nil
    }
}

private func parseIsolationMode(_ value: String) -> SubagentIsolationMode? {
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "none": return SubagentIsolationMode.none
    case "worktree", "work-tree", "work_tree": return .worktree
    default: return nil
    }
}

private func resolveRole(
    named roleName: String,
    roles: [String: SubagentRole],
    stack: [String]
) throws -> SubagentRole {
    guard let role = roles[roleName] else {
        throw ResolutionError.unknownParent(child: roleName, parent: roleName)
    }
    guard !stack.contains(roleName) else {
        throw ResolutionError.hierarchyCycle(stack + [roleName])
    }
    guard let parentName = role.inherits else { return role }
    guard roles[parentName] != nil else {
        throw ResolutionError.unknownParent(child: roleName, parent: parentName)
    }
    let parent = try resolveRole(named: parentName, roles: roles, stack: stack + [roleName])
    return mergeRole(parent: parent, child: role)
}

private func mergeRole(parent: SubagentRole, child: SubagentRole) -> SubagentRole {
    SubagentRole(
        description: child.description.isEmpty ? parent.description : child.description,
        defaultCapabilityMode: child.defaultCapabilityMode ?? parent.defaultCapabilityMode,
        model: child.model ?? parent.model,
        reasoningEffort: child.reasoningEffort ?? parent.reasoningEffort,
        promptFile: child.promptFile ?? parent.promptFile,
        defaultIsolation: child.defaultIsolation ?? parent.defaultIsolation,
        sourceDirectory: child.sourceDirectory ?? parent.sourceDirectory,
        inherits: nil,
        toolAllowlist: child.toolAllowlist ?? parent.toolAllowlist,
        toolDenylist: mergeUnique(parent.toolDenylist, child.toolDenylist)
    )
}

private func resolvePersona(
    named personaName: String,
    personas: [String: SubagentPersona],
    stack: [String]
) throws -> SubagentPersona {
    guard let persona = personas[personaName] else {
        throw ResolutionError.personaResolution("persona \"\(personaName)\" not found in config")
    }
    guard !stack.contains(personaName) else {
        throw ResolutionError.hierarchyCycle(stack + [personaName])
    }
    guard let parentName = persona.inherits else { return persona }
    guard personas[parentName] != nil else {
        throw ResolutionError.unknownParent(child: personaName, parent: parentName)
    }
    let parent = try resolvePersona(named: parentName, personas: personas, stack: stack + [personaName])
    return mergePersona(parent: parent, child: persona)
}

private func mergePersona(parent: SubagentPersona, child: SubagentPersona) -> SubagentPersona {
    let mergedInstructions: String?
    switch (parent.instructions, child.instructions) {
    case let (parentValue?, childValue?): mergedInstructions = parentValue + "\n\n" + childValue
    case let (parentValue?, nil): mergedInstructions = parentValue
    case let (nil, childValue?): mergedInstructions = childValue
    case (nil, nil): mergedInstructions = nil
    }
    return SubagentPersona(
        instructions: mergedInstructions,
        description: child.description ?? parent.description,
        instructionsFile: child.instructionsFile ?? parent.instructionsFile,
        inputs: child.inputs.isEmpty ? parent.inputs : parent.inputs + child.inputs,
        outputs: child.outputs.isEmpty ? parent.outputs : parent.outputs + child.outputs,
        defaultIsolation: child.defaultIsolation ?? parent.defaultIsolation,
        model: child.model ?? parent.model,
        reasoningEffort: child.reasoningEffort ?? parent.reasoningEffort,
        sourceDirectory: child.sourceDirectory ?? parent.sourceDirectory,
        sourcePath: child.sourcePath ?? parent.sourcePath,
        inherits: nil,
        toolAllowlist: child.toolAllowlist ?? parent.toolAllowlist,
        toolDenylist: mergeUnique(parent.toolDenylist, child.toolDenylist)
    )
}

private func resolvePersonaInstructions(
    name: String?,
    personas: [String: SubagentPersona],
    cwd: URL?
) -> (instructions: String?, error: String?, fatal: Bool) {
    guard let name else { return (nil, nil, false) }
    guard let persona = try? resolvePersona(named: name, personas: personas, stack: []) else {
        if personas[name] == nil {
            return (nil, "persona \"\(name)\" not found in config", false)
        }
        do {
            _ = try resolvePersona(named: name, personas: personas, stack: [])
        } catch let error as ResolutionError {
            return (nil, error.description, false)
        } catch {
            return (nil, String(describing: error), false)
        }
        return (nil, "persona resolution failed", false)
    }
    var parts: [String] = []
    if let instructions = persona.instructions { parts.append(instructions) }
    if let instructionsFile = persona.instructionsFile {
        guard let base = persona.sourceDirectory ?? cwd else {
            return (nil, "persona \"\(name)\": cannot resolve instructions_file \"\(instructionsFile)\": no source_dir or cwd available", true)
        }
        do {
            parts.append(try String(contentsOf: base.appendingPathComponent(instructionsFile), encoding: .utf8))
        } catch {
            return (nil, "persona \"\(name)\": failed to read instructions_file \"\(instructionsFile)\": \(error.localizedDescription)", true)
        }
    }
    guard !parts.isEmpty else {
        return (nil, "persona \"\(name)\" has no instructions or instructions_file", false)
    }
    return (parts.joined(separator: "\n\n"), nil, false)
}

public func resolveDefinitionHierarchy(
    named name: String,
    context: DefinitionResolutionContext
) throws -> AgentDefinition {
    try resolveDefinitionHierarchy(named: name, context: context, stack: [])
}

private func resolveDefinitionHierarchy(
    named name: String,
    context: DefinitionResolutionContext,
    stack: [String]
) throws -> AgentDefinition {
    guard let entry = bestDefinition(named: name, context: context) else {
        throw ResolutionError.unknownParent(child: stack.last ?? name, parent: name)
    }
    guard !stack.contains(name) else {
        throw ResolutionError.hierarchyCycle(stack + [name])
    }
    guard let parentName = entry.extends else { return entry.definition }
    guard bestDefinition(named: parentName, context: context) != nil else {
        throw ResolutionError.unknownParent(child: name, parent: parentName)
    }
    let parent = try resolveDefinitionHierarchy(named: parentName, context: context, stack: stack + [name])
    return mergeDefinition(parent: parent, child: entry.definition)
}

public func mergeDefinition(parent: AgentDefinition, child: AgentDefinition) -> AgentDefinition {
    var result = parent
    result.name = child.name
    result.pluginName = child.pluginName ?? parent.pluginName
    if !child.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.description = child.description }
    if child.promptMode == .full || parent.promptMode == .extend { result.promptMode = child.promptMode }
    if child.toolConfig != .defaultGrokBuild || parent.toolConfig == .defaultGrokBuild { result.toolConfig = child.toolConfig }
    result.capabilityMode = child.capabilityMode ?? parent.capabilityMode
    if child.permissionMode != .default || parent.permissionMode == .default { result.permissionMode = child.permissionMode }
    result.skills = child.skills.isEmpty ? parent.skills : mergeUnique(parent.skills, child.skills) ?? []
    result.discoverSkills = child.discoverSkills == false || parent.discoverSkills ? child.discoverSkills : parent.discoverSkills
    result.inheritSkills = child.inheritSkills == false || parent.inheritSkills ? child.inheritSkills : parent.inheritSkills
    result.agentsMd = child.agentsMd == false || parent.agentsMd ? child.agentsMd : parent.agentsMd
    result.injectDefaultTools = child.injectDefaultTools == false || parent.injectDefaultTools ? child.injectDefaultTools : parent.injectDefaultTools
    result.tools = child.tools.isEmpty ? parent.tools : child.tools
    result.disallowedTools = mergeUnique(parent.disallowedTools, child.disallowedTools) ?? []
    result.effort = child.effort ?? parent.effort
    result.maxTurns = child.maxTurns ?? parent.maxTurns
    result.isolation = child.isolation ?? parent.isolation
    result.background = child.background ?? parent.background
    result.color = child.color ?? parent.color
    result.initialPrompt = child.initialPrompt ?? parent.initialPrompt
    result.mcpServers = child.mcpServers.isEmpty ? parent.mcpServers : child.mcpServers
    result.mcpInheritance = child.mcpInheritance == .all ? parent.mcpInheritance : child.mcpInheritance
    result.hooks = child.hooks ?? parent.hooks
    result.memory = child.memory ?? parent.memory
    result.model = child.model == .inherit ? parent.model : child.model
    result.completionRequirement = child.completionRequirement ?? parent.completionRequirement
    result.toolOverrides = child.toolOverrides ?? parent.toolOverrides
    result.allowedSubagentTypes = child.allowedSubagentTypes ?? parent.allowedSubagentTypes
    result.sessionToolsAllowlist = child.sessionToolsAllowlist ?? parent.sessionToolsAllowlist
    result.sessionToolsDenylist = mergeUnique(parent.sessionToolsDenylist, child.sessionToolsDenylist)
    result.promptBody = child.promptBody ?? parent.promptBody
    if child.systemPrompt != .none { result.systemPrompt = child.systemPrompt }
    if child.userMessageTemplate != .default { result.userMessageTemplate = child.userMessageTemplate }
    result.sourcePath = child.sourcePath ?? parent.sourcePath
    result.scope = child.scope
    return result
}

private func mergedDefinitions(context: DefinitionResolutionContext) -> [String: SubagentDefinition] {
    var candidates = context.definitions
    candidates.append(contentsOf: AgentDefinition.subagentNames.compactMap { name in
        AgentDefinition.builtIn(named: name).map { SubagentDefinition(definition: $0, source: .builtIn) }
    })
    candidates.append(contentsOf: context.cliAgents.map { SubagentDefinition(definition: $0, source: .cli) })
    if context.includeFilesystemDefinitions {
        candidates.append(contentsOf: filesystemDefinitions(
            cwd: context.cwd,
            environment: context.environment ?? ProcessInfo.processInfo.environment
        ))
    }

    var selected: [String: SubagentDefinition] = [:]
    for candidate in candidates {
        guard !candidate.name.isEmpty else { continue }
        if let existing = selected[candidate.name], !shouldReplace(existing: existing, candidate: candidate) { continue }
        if isBuiltinSubagentName(candidate.name), candidate.source != .project, candidate.source != .agentJSON,
           candidate.source != .builtIn { continue }
        selected[candidate.name] = candidate
    }
    // No toggle filter here: resolution (unlike advertisement) must see
    // disabled definitions. `availableAgentNames` applies the filter.
    return selected
}

private func bestDefinition(named name: String, context: DefinitionResolutionContext) -> SubagentDefinition? {
    mergedDefinitions(context: context)[name]
}

private func shouldReplace(existing: SubagentDefinition, candidate: SubagentDefinition) -> Bool {
    if isBuiltinSubagentName(existing.name) {
        if candidate.source == .project || candidate.source == .agentJSON { return true }
        if existing.source == .builtIn { return false }
    }
    return candidate.source.priority > existing.source.priority
}

private func isBuiltinSubagentName(_ name: String) -> Bool {
    AgentDefinition.subagentNames.contains(name)
}

private func filesystemDefinitions(cwd: URL, environment: [String: String]) -> [SubagentDefinition] {
    var result: [SubagentDefinition] = []
    for directory in projectAgentDirectories(cwd: cwd) {
        result.append(contentsOf: loadDefinitions(in: directory, source: .project))
    }
    let home = environment["HOME"].map { URL(fileURLWithPath: $0) }
    let grokHome = environment["OPENGROK_HOME"].map { URL(fileURLWithPath: $0) }
        ?? home?.appendingPathComponent(".opengrok")
    if let grokHome { result.append(contentsOf: loadDefinitions(in: grokHome.appendingPathComponent("agents"), source: .user)) }
    if let home { result.append(contentsOf: loadDefinitions(in: home.appendingPathComponent(".claude/agents"), source: .user)) }
    if let grokHome { result.append(contentsOf: loadDefinitions(in: grokHome.appendingPathComponent("bundled/agents"), source: .bundled)) }
    return result
}

private func projectAgentDirectories(cwd: URL) -> [URL] {
    var directories: [URL] = []
    var current = cwd.standardizedFileURL
    while true {
        directories.append(current.appendingPathComponent(".opengrok/agents"))
        directories.append(current.appendingPathComponent(".claude/agents"))
        let parent = current.deletingLastPathComponent()
        if parent.path == current.path { break }
        current = parent
    }
    return directories
}

private func loadDefinitions(in directory: URL, source: DefinitionSource) -> [SubagentDefinition] {
    guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
    return urls
        .filter { ["md", "json"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.path < $1.path }
        .compactMap { url in
            do {
                let definition: AgentDefinition
                let extends: String?
                if url.pathExtension.lowercased() == "json" {
                    let data = try Data(contentsOf: url)
                    definition = try AgentDefinition.fromJSONData(data)
                    extends = try parentReference(fromJSONData: data)
                } else {
                    definition = try AgentDefinition.fromFile(url)
                    let content = try String(contentsOf: url, encoding: .utf8)
                    extends = try parentReference(fromMarkdown: content)
                }
                var adjusted = definition
                adjusted.scope = source == .project ? .project : source == .user ? .user : .bundled
                adjusted.sourcePath = url.standardizedFileURL.path
                return SubagentDefinition(definition: adjusted, extends: extends, source: source, sourcePath: url)
            } catch {
                return nil
            }
        }
}

private func parentReference(fromMarkdown content: String) throws -> String? {
    let lines = content.components(separatedBy: .newlines)
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for key in ["extends", "inherits", "parent"] {
            if trimmed.hasPrefix("\(key):") {
                let value = trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
    }
    return nil
}

private func parentReference(fromJSONData data: Data) throws -> String? {
    let value = try JSONDecoder().decode(AgentJSONValue.self, from: data)
    for key in ["extends", "inherits", "parent"] {
        if let parent = value[key]?.stringValue() { return parent }
    }
    return nil
}

private func mergeUnique(_ first: [String]?, _ second: [String]?) -> [String]? {
    guard first != nil || second != nil else { return nil }
    var result: [String] = []
    for value in (first ?? []) + (second ?? []) where !result.contains(value) { result.append(value) }
    return result
}

private func resolveToolNames(
    definition: AgentDefinition,
    capabilityMode: SubagentCapabilityMode?,
    allowNestedSubagents: Bool,
    explicitAllowlist: [String]?,
    explicitDenylist: [String]?,
    role: SubagentRole?,
    persona: SubagentPersona?,
    parentAllowlist: [String]?
) -> [String] {
    var names = definition.toolConfig.toolNames
    if !definition.tools.isEmpty { names = names.filter { matchesAny(definition.tools, id: $0) } }
    names = names.filter { !matchesAny(definition.disallowedTools, id: $0) }
    if let roleAllowlist = role?.toolAllowlist { names = names.filter { matchesAny(roleAllowlist, id: $0) } }
    if let personaAllowlist = persona?.toolAllowlist { names = names.filter { matchesAny(personaAllowlist, id: $0) } }
    if let explicitAllowlist { names = names.filter { matchesAny(explicitAllowlist, id: $0) } }
    let denylist = (role?.toolDenylist ?? []) + (persona?.toolDenylist ?? []) + (explicitDenylist ?? [])
    names = names.filter { !matchesAny(denylist, id: $0) }
    if let parentAllowlist { names = names.filter { matchesAny(parentAllowlist, id: $0) } }
    if let capabilityMode { names = names.filter { toolIsAllowed($0, under: capabilityMode) } }
    if !allowNestedSubagents { names.removeAll { isNestedSpawnTool($0) || isPlanTool($0) } }
    let hasSpawn = names.contains { isNestedSpawnTool($0) }
    let hasBackgroundTerminal = names.contains { isExecuteTool($0) }
    if !hasSpawn && !hasBackgroundTerminal { names.removeAll { isLifecycleTool($0) } }
    return names
}

private func matchesAny(_ patterns: [String], id: String) -> Bool {
    let shortName = id.split(separator: ":").last.map(String.init) ?? id
    return patterns.contains { $0 == id || $0 == shortName }
}

private func toolIsAllowed(_ id: String, under mode: SubagentCapabilityMode) -> Bool {
    let name = id.split(separator: ":").last.map(String.init)?.lowercased() ?? id.lowercased()
    if mode == .all { return true }
    if !isKnownToolName(name) { return true }
    // Every `SubagentCapabilityMode` allow-list carries
    // `ToolKind::AgentCollaboration` (task/types.rs:505, 531, 550, 577): peer
    // messaging is orthogonal to read/write/execute authority.
    if isCollaborationTool(name) { return true }
    if isReadTool(name) { return true }
    if isLifecycleTool(name) { return true }
    if isWebTool(name) || isMemoryTool(name) { return true }
    switch mode {
    case .readOnly: return false
    case .readWrite: return isWriteTool(name) || isWebTool(name) || isMemoryTool(name)
    case .execute: return isExecuteTool(name) || isWebTool(name) || isMemoryTool(name)
    case .all: return true
    }
}

private func isKnownToolName(_ name: String) -> Bool {
    isReadTool(name) || isWriteTool(name) || isExecuteTool(name) || isWebTool(name) || isMemoryTool(name) || isLifecycleTool(name) || isNestedSpawnTool(name) || isPlanTool(name)
}

private func isReadTool(_ name: String) -> Bool {
    ["read_file", "view_image", "list_dir", "list", "grep", "search", "lsp", "glob", "memory_search", "memory_get"].contains(name)
}

private func isWriteTool(_ name: String) -> Bool {
    ["search_replace", "apply_patch", "edit", "write", "delete", "move"].contains(name)
}

private func isExecuteTool(_ name: String) -> Bool {
    ["run_terminal_command", "run_terminal_cmd", "bash", "execute", "process", "terminal"].contains(name)
}

private func isWebTool(_ name: String) -> Bool {
    ["web_search", "web_fetch", "search_tool", "use_tool"].contains(name)
}

private func isMemoryTool(_ name: String) -> Bool {
    ["memory_search", "memory_get"].contains(name)
}

private func isLifecycleTool(_ name: String) -> Bool {
    ["get_command_or_subagent_output", "get_task_output", "wait_commands_or_subagents", "wait_tasks", "kill_command_or_subagent", "kill_task"].contains(name)
}

func isNestedSpawnTool(_ id: String) -> Bool {
    let name = id.split(separator: ":").last.map(String.init)?.lowercased() ?? id.lowercased()
    return ["spawn_subagent", "task", "agent_swarm", "workflow"].contains(name)
}

/// The four team-scoped mailbox tools. Deliberately *not* part of
/// `isNestedSpawnTool`: stripping nested spawn tools from a child keeps its
/// mailbox, which is what `strip_nested_spawn_tools_*` asserts upstream
/// (`xai-grok-tools/.../task/types.rs:1387-1424`).
func isCollaborationTool(_ id: String) -> Bool {
    let name = id.split(separator: ":").last.map(String.init)?.lowercased() ?? id.lowercased()
    return AgentCollaborationTool.allCases.contains { $0.toolID == name }
}

/// Apply the host's subagent-enablement gate to a toolset.
///
/// Mirrors Rust `AgentBuilder::build`'s spawn-tool block
/// (`xai-grok-agent/src/builder.rs:839-897`, commits 7957721e + ad95b111):
/// with subagents disabled, `task`, `agent_swarm`, `workflow` **and** the four
/// collaboration tools are stripped together; with subagents enabled, any
/// collaboration tool missing from the toolset is appended, so the mailbox
/// presence tracks `subagents_enabled` exactly.
///
/// The three orchestration surfaces stay individually addressable here —
/// stripping is by id, never by a collapsed "spawn-ish" class — which is the
/// invariant `task_agent_swarm_and_workflow_stay_three_distinct_surfaces`
/// locks upstream (`.../task/types.rs:1436-1496`).
public func applySubagentEnablement(
    toolNames: [String],
    subagentsEnabled: Bool
) -> [String] {
    guard subagentsEnabled else {
        return toolNames.filter { !isNestedSpawnTool($0) && !isCollaborationTool($0) }
    }
    var names = toolNames
    for tool in AgentCollaborationTool.allCases where !names.contains(where: {
        let short = $0.split(separator: ":").last.map(String.init)?.lowercased() ?? $0.lowercased()
        return short == tool.toolID
    }) {
        names.append(tool.toolID)
    }
    return names
}

private func isPlanTool(_ id: String) -> Bool {
    let name = id.split(separator: ":").last.map(String.init)?.lowercased() ?? id.lowercased()
    return ["enter_plan_mode", "exit_plan_mode"].contains(name)
}

private func isAskUserTool(_ id: String) -> Bool {
    let name = id.split(separator: ":").last.map(String.init)?.lowercased() ?? id.lowercased()
    return name == "ask_user_question"
}

private func pruneOrphanedLifecycleTools(in configuration: inout AgentToolConfiguration) {
    let hasSpawn = configuration.tools.contains { isNestedSpawnTool($0.id) }
    let hasBackgroundTerminal = configuration.tools.contains {
        let name = $0.name.lowercased()
        return name == "run_terminal_command" || name == "run_terminal_cmd" || name == "bash"
    }
    if !hasSpawn && !hasBackgroundTerminal {
        configuration.tools.removeAll { isLifecycleTool($0.id) }
    }
}

private func agentsFiles(from directory: URL) -> [URL] {
    var result: [URL] = []
    var current = directory.standardizedFileURL
    while true {
        let candidate = current.appendingPathComponent("AGENTS.md")
        if FileManager.default.fileExists(atPath: candidate.path) { result.append(candidate) }
        let parent = current.deletingLastPathComponent()
        if parent.path == current.path { break }
        current = parent
    }
    return result.reversed()
}
