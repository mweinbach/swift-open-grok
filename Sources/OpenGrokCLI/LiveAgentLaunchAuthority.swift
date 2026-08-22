import Foundation
import OpenGrokAgentDefinitions
import OpenGrokPaths
import OpenGrokShared

/// The one validated owner of agent-shaping command-line state.
///
/// Resolve this before constructing provider or tool resources: accepting a
/// malformed inline agent or output schema after a session has launched would
/// advertise constraints the running session never actually acquired.
struct LiveAgentLaunchAuthority: Sendable {
    let agentProfile: LiveAgentProfile?
    let selectedAgentDefinition: AgentDefinition?
    let cliAgents: [AgentDefinition]
    let jsonSchema: JSONValue?
    let noPlan: Bool
    let noAskUser: Bool

    private let rules: String?
    private let systemPromptOverride: String?

    var hasSystemPromptOverride: Bool {
        systemPromptOverride != nil
    }

    static func resolve(
        options: CLIExecutionOptions,
        workingDirectory: URL,
        environment: [String: String]
    ) throws -> LiveAgentLaunchAuthority {
        let cliAgents = try parseInlineAgents(options.agentOptions.agentsJSON)
        let jsonSchema = try parseJSONSchema(options.jsonSchema)
        let definition = try resolveAgentDefinition(
            explicitAgent: options.agentOptions.agent,
            explicitProfile: options.common.profile,
            workingDirectory: workingDirectory,
            environment: environment
        )
        let profile = definition.map {
            makeProfile(
                definition: $0,
                workingDirectory: workingDirectory,
                environment: environment
            )
        }
        let override = options.agentOptions.systemPromptOverride.flatMap { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }

        return LiveAgentLaunchAuthority(
            agentProfile: profile,
            selectedAgentDefinition: definition,
            cliAgents: cliAgents,
            jsonSchema: jsonSchema,
            noPlan: options.agentOptions.noPlan,
            noAskUser: options.agentOptions.noAskUser,
            rules: options.agentOptions.rules,
            systemPromptOverride: override
        )
    }

    func applyingSystemPrompt(to base: String?) -> String? {
        if let systemPromptOverride {
            return systemPromptOverride
        }
        guard let rules else {
            return base
        }
        return (base ?? "") + "\n\n<human_rules>\n" + rules + "\n</human_rules>"
    }

    /// Launch switches can narrow the model-visible surface but must never
    /// erase a profile denial, session clamp, or managed permission rule.
    func toolPolicy(tools: String?, disallowedTools: String?) -> LiveAgentToolPolicy? {
        var additionalDenials = LiveAgentToolPolicy.parseCommaSeparatedToolNames(disallowedTools) ?? []
        if noPlan {
            additionalDenials.append(contentsOf: ["enter_plan_mode", "exit_plan_mode"])
        }
        if noAskUser {
            additionalDenials.append("ask_user_question")
        }
        let effectiveDenials: String?
        if disallowedTools == nil, additionalDenials.isEmpty {
            effectiveDenials = nil
        } else {
            effectiveDenials = additionalDenials.joined(separator: ",")
        }
        return LiveAgentToolPolicy.resolveLaunchPolicy(
            tools: tools,
            disallowedTools: effectiveDenials,
            profile: agentProfile?.toolPolicy
        )
    }

    static func parseInlineAgents(_ input: String?) throws -> [AgentDefinition] {
        guard let input else { return [] }

        let value: AgentJSONValue
        do {
            value = try JSONDecoder().decode(AgentJSONValue.self, from: Data(input.utf8))
        } catch {
            throw CLIApplicationError.failed("--agents: invalid JSON: \(error.localizedDescription)")
        }

        guard case let .object(entries) = value else {
            throw CLIApplicationError.failed("--agents: expected a JSON object mapping agent names to definitions")
        }

        return try entries.keys.sorted().map { name in
            guard case let .object(original)? = entries[name] else {
                throw CLIApplicationError.failed("--agents: failed to parse '\(name)': agent definition must be a JSON object")
            }
            var object = original
            if object["promptBody"] == nil, let prompt = object.removeValue(forKey: "prompt") {
                object["promptBody"] = prompt
            }
            if object["name"] == nil {
                object["name"] = .string(name)
            }
            if object["description"] == nil {
                object["description"] = .string(name)
            }

            do {
                var definition = try AgentDefinition.fromJSON(object)
                definition.name = name
                try definition.validate()
                return definition
            } catch {
                throw CLIApplicationError.failed("--agents: failed to parse '\(name)': \(error)")
            }
        }
    }

    static func parseJSONSchema(_ input: String?) throws -> JSONValue? {
        guard let input else { return nil }
        let schema: JSONValue
        do {
            schema = try JSONDecoder().decode(JSONValue.self, from: Data(input.utf8))
        } catch {
            throw CLIApplicationError.failed("--json-schema: invalid JSON: \(error.localizedDescription)")
        }
        guard case .object = schema else {
            throw CLIApplicationError.failed("--json-schema: must be a JSON object describing a JSON Schema")
        }
        return schema
    }

    private static func resolveAgentDefinition(
        explicitAgent: String?,
        explicitProfile: String?,
        workingDirectory: URL,
        environment: [String: String]
    ) throws -> AgentDefinition? {
        if let explicitAgent,
           let file = existingFile(explicitAgent, workingDirectory: workingDirectory)
        {
            return try readAgentFile(file, flag: "--agent")
        }

        if let explicitProfile,
           !explicitProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            if let file = existingFile(explicitProfile, workingDirectory: workingDirectory) {
                return try readAgentFile(file, flag: "--agent-profile")
            }
            return try namedAgent(
                explicitProfile,
                workingDirectory: workingDirectory,
                environment: environment,
                flag: "--agent-profile"
            )
        }

        if let explicitAgent {
            return try namedAgent(
                explicitAgent,
                workingDirectory: workingDirectory,
                environment: environment,
                flag: "--agent"
            )
        }

        guard let environmentAgent = environment["GROK_AGENT"],
              !environmentAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        if isAbsolutePath(environmentAgent),
           let file = existingFile(environmentAgent, workingDirectory: workingDirectory)
        {
            return try readAgentFile(file, flag: "GROK_AGENT")
        }
        return try namedAgent(
            environmentAgent,
            workingDirectory: workingDirectory,
            environment: environment,
            flag: "GROK_AGENT"
        )
    }

    private static func existingFile(_ rawPath: String, workingDirectory: URL) -> URL? {
        let path: URL
        if isAbsolutePath(rawPath) {
            path = URL(fileURLWithPath: rawPath)
        } else {
            path = workingDirectory.appendingPathComponent(rawPath)
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return nil }
        return path.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func readAgentFile(_ file: URL, flag: String) throws -> AgentDefinition {
        do {
            let definition = try AgentDefinition.fromFile(file)
            try definition.validate()
            return definition
        } catch {
            throw CLIApplicationError.failed("\(flag): failed to load agent profile '\(file.path)': \(error)")
        }
    }

    private static func namedAgent(
        _ name: String,
        workingDirectory: URL,
        environment: [String: String],
        flag: String
    ) throws -> AgentDefinition {
        guard let definition = AgentDefinition.byName(
            name,
            in: workingDirectory,
            environment: environment
        ) else {
            throw CLIApplicationError.failed("\(flag): agent profile '\(name)' was not found")
        }
        return definition
    }

    private static func makeProfile(
        definition: AgentDefinition,
        workingDirectory: URL,
        environment: [String: String]
    ) -> LiveAgentProfile {
        let instructionFiles = definition.agentsMd
            ? AgentInstructionDiscovery(environment: environment).discover(at: workingDirectory)
            : []
        let composedPrompt = definition.composePrompt(
            basePrompt: "",
            agentsMdFiles: instructionFiles
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return LiveAgentProfile(
            model: definition.model.modelID,
            systemPrompt: composedPrompt.isEmpty ? nil : composedPrompt,
            toolPolicy: LiveAgentToolPolicy(definition: definition),
            discoverSkills: definition.discoverSkills
        )
    }
}
