// LiveSkills.swift
//
// The CLI-facing half of skills: turning discovered `SKILL.md` files into slash
// commands, gating them, and building the block that gets injected when one is
// invoked.
//
// Discovery, scope precedence and frontmatter parsing live in
// `OpenGrokAgentDefinitions/SkillDiscovery.swift`. This file is registration
// and expansion.
//
// Ports `xai-grok-shell/src/session/slash_commands.rs:490-696`
// (`EffectiveCommandCatalog::build`, `available_commands`) and
// `xai-grok-tools/src/implementations/skills/skill.rs:60-361`
// (`build_skill_block`, `build_skill_information`, `apply_substitutions`).

import Foundation
import OpenGrokACP
import OpenGrokAgentDefinitions
import OpenGrokPager
import OpenGrokShared

public enum LiveSkills {
    // MARK: - Discovery

    /// Discover the skills visible from `cwd`, already deduped and in
    /// precedence order.
    public static func discover(
        cwd: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [SkillInfo] {
        SkillDiscovery(environment: environment).discover(cwd: cwd)
    }

    // MARK: - Slash command registration

    /// A skill paired with the command name it is reachable under.
    public struct SkillCommand: Sendable, Equatable {
        public let commandName: String
        public let skill: SkillInfo

        public init(commandName: String, skill: SkillInfo) {
            self.commandName = commandName
            self.skill = skill
        }
    }

    /// Build the slash-command catalog for `skills`.
    ///
    /// A skill claims its bare name only when that name is unique among
    /// candidates *and* not already taken by a builtin. Otherwise it falls back
    /// to `scope:name`; if that is also taken or ambiguous the skill gets no
    /// command at all rather than shadowing something else.
    ///
    /// - Parameter reservedNames: builtin command names and aliases. Skills
    ///   must never be able to shadow these.
    public static func commandCatalog(
        skills: [SkillInfo],
        reservedNames: Set<String> = []
    ) -> [SkillCommand] {
        // `user-invocable: false` is exactly this gate: no slash command, no
        // ACP advertisement. It does not hide the skill from the model.
        let candidates = skills.filter { $0.userInvocable && $0.enabled }

        var bareCounts: [String: Int] = [:]
        var qualifiedCounts: [String: Int] = [:]
        for skill in candidates {
            bareCounts[skill.name, default: 0] += 1
            qualifiedCounts[skill.qualifiedName, default: 0] += 1
        }

        var taken = reservedNames
        var catalog: [SkillCommand] = []
        for skill in candidates {
            let name: String
            if bareCounts[skill.name] == 1 && !taken.contains(skill.name) {
                name = skill.name
            } else {
                let qualified = skill.qualifiedName
                guard qualifiedCounts[qualified] == 1, !taken.contains(qualified) else { continue }
                name = qualified
            }
            taken.insert(name)
            catalog.append(SkillCommand(commandName: name, skill: skill))
        }
        // Bare names are reserved afterwards so a later non-skill command
        // cannot shadow a skill that took the qualified fallback.
        return catalog
    }

    /// ACP `AvailableCommand` advertisements for a catalog.
    ///
    /// The `_meta` carries `scope` and `path`; a client that sees one without
    /// the other must treat the command as malformed rather than guessing.
    public static func availableCommands(_ catalog: [SkillCommand]) -> [AvailableCommand] {
        catalog.map { entry in
            AvailableCommand(
                name: entry.commandName,
                description: entry.skill.shortDescription ?? entry.skill.description,
                input: entry.skill.argumentHint.map { AvailableCommandInput.unstructured(hint: $0) },
                meta: [
                    "scope": .string(entry.skill.scope.wireName),
                    "path": .string(entry.skill.path)
                ]
            )
        }
    }

    /// Combine the pager's builtin command rows with the same skill catalog
    /// used by slash dispatch. Keeping this conversion here prevents ACP and
    /// the TUI from inventing separate skill names or metadata.
    public static func availableCommands(
        builtins: [OpenGrokPagerCommandRegistration],
        skills: [SkillCommand]
    ) -> [AvailableCommand] {
        let builtinRows = builtins.map { command in
            AvailableCommand(
                name: command.name,
                description: command.summary,
                input: command.usage.map { AvailableCommandInput.unstructured(hint: $0) }
            )
        }
        return builtinRows + availableCommands(skills)
    }

    /// Skills the *model* may invoke. Note this is a different filter from the
    /// slash catalog: `disable-model-invocation` gates here,
    /// `user-invocable` gates there.
    public static func modelInvocable(_ skills: [SkillInfo]) -> [SkillInfo] {
        skills.filter { $0.enabled && !$0.disableModelInvocation }
    }

    // MARK: - Invocation

    /// Load a skill's body with its relative links resolved to absolute paths.
    public static func loadBody(_ skill: SkillInfo) -> String? {
        if let body = skill.body, !body.isEmpty { return body }
        guard let content = try? String(
            contentsOf: URL(fileURLWithPath: skill.path),
            encoding: .utf8
        ) else { return nil }
        return SkillDiscovery.extractBodyForInjection(content)
    }

    /// `<skill name="commit" args="fix typo">…</skill>`
    public static func skillBlock(name: String, args: String, content: String) -> String {
        let header = args.isEmpty
            ? "<skill name=\"\(name)\">"
            : "<skill name=\"\(name)\" args=\"\(escapeAttribute(args))\">"
        return "\(header)\n\(content)\n</skill>"
    }

    /// The `<skill_information>` envelope appended after the user query.
    ///
    /// Returns `nil` when nothing loaded, so an unreadable skill injects
    /// nothing rather than an empty envelope the model has to reason about.
    public static func skillInformation(
        invocations: [(skill: SkillInfo, args: String)],
        sessionID: String? = nil
    ) -> String? {
        var blocks: [String] = []
        var referenced: [String] = []
        for invocation in invocations {
            guard let body = loadBody(invocation.skill) else { continue }
            let substituted = applySubstitutions(
                body,
                args: invocation.args,
                skillDirectory: URL(fileURLWithPath: invocation.skill.path)
                    .deletingLastPathComponent().path,
                sessionID: sessionID
            )
            blocks.append(
                skillBlock(
                    name: invocation.skill.name,
                    args: invocation.args,
                    content: substituted
                )
            )
            referenced.append(
                "<skill name=\"\(invocation.skill.name)\" path=\"\(invocation.skill.path)\"/>"
            )
        }
        guard !blocks.isEmpty else { return nil }
        return """
            <skill_information>
            <skills_referenced>
            \(referenced.joined(separator: "\n"))
            </skills_referenced>
            \(blocks.joined(separator: "\n"))
            </skill_information>
        """
    }

    /// Build the model-facing prompt for one resolved slash skill.
    public static func invocationPrompt(
        commandName: String,
        args: String,
        catalog: [SkillCommand],
        sessionID: String? = nil
    ) -> String? {
        guard let entry = catalog.first(where: { $0.commandName == commandName }),
              let information = skillInformation(
                  invocations: [(skill: entry.skill, args: args)],
                  sessionID: sessionID
              )
        else { return nil }
        let invocation = args.isEmpty ? "/\(commandName)" : "/\(commandName) \(args)"
        return "\(invocation)\n\(information)"
    }

    /// Substitute `$ARGUMENTS`, `$ARGUMENTS[N]`, `$N` and the `${…_DIR}` tokens.
    ///
    /// When no argument token consumed the arguments, they are appended
    /// explicitly — otherwise a skill that ignores `$ARGUMENTS` would silently
    /// drop what the user typed.
    public static func applySubstitutions(
        _ body: String,
        args: String,
        skillDirectory: String,
        sessionID: String? = nil,
        pluginRoot: String? = nil,
        pluginData: String? = nil
    ) -> String {
        let argv = args.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var result = body
        var argumentsSubstituted = false

        // Descending index order so `$10` is replaced before `$1`.
        let upperBound = Swift.max(argv.count, 1) + 20
        for index in stride(from: upperBound, through: 0, by: -1) {
            let token = "$ARGUMENTS[\(index)]"
            if result.contains(token) {
                result = result.replacingOccurrences(
                    of: token,
                    with: index < argv.count ? argv[index] : ""
                )
                argumentsSubstituted = true
            }
        }
        for index in stride(from: upperBound, through: 0, by: -1) {
            let token = "$\(index)"
            // `$100` must survive when only `$1` is meaningful, so only replace
            // when the next character is not another digit.
            if let replaced = replaceNonDigitSuffixed(
                in: result,
                token: token,
                with: index < argv.count ? argv[index] : ""
            ) {
                result = replaced
                argumentsSubstituted = true
            }
        }
        if result.contains("$ARGUMENTS") {
            result = result.replacingOccurrences(of: "$ARGUMENTS", with: args)
            argumentsSubstituted = true
        }

        result = result.replacingOccurrences(of: "${SKILL_DIR}", with: skillDirectory)
        result = result.replacingOccurrences(of: "${CLAUDE_SKILL_DIR}", with: skillDirectory)
        if let sessionID {
            result = result.replacingOccurrences(of: "${SESSION_ID}", with: sessionID)
            result = result.replacingOccurrences(of: "${CLAUDE_SESSION_ID}", with: sessionID)
        }
        if let pluginRoot {
            result = result.replacingOccurrences(of: "${GROK_PLUGIN_ROOT}", with: pluginRoot)
            result = result.replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: pluginRoot)
        }
        if let pluginData {
            result = result.replacingOccurrences(of: "${GROK_PLUGIN_DATA}", with: pluginData)
            result = result.replacingOccurrences(of: "${CLAUDE_PLUGIN_DATA}", with: pluginData)
        }

        if !argumentsSubstituted, !args.isEmpty {
            result += "\n\n**ARGUMENTS:** \(args)"
        }
        return result
    }

    private static func replaceNonDigitSuffixed(
        in text: String,
        token: String,
        with replacement: String
    ) -> String? {
        var result = ""
        var remaining = Substring(text)
        var replaced = false
        while let range = remaining.range(of: token) {
            let after = range.upperBound
            let nextIsDigit = after < remaining.endIndex && remaining[after].isNumber
            result += remaining[remaining.startIndex..<range.lowerBound]
            if nextIsDigit {
                result += token
            } else {
                result += replacement
                replaced = true
            }
            remaining = remaining[after...]
        }
        result += remaining
        return replaced ? result : nil
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    // MARK: - Model-facing listing

    /// The `<agent_skills>` reminder block listing what the model can reach.
    public static func listing(_ skills: [SkillInfo]) -> String? {
        let visible = modelInvocable(skills)
        guard !visible.isEmpty else { return nil }
        let rows = visible.map { skill -> String in
            var detail = skill.description
            if let whenToUse = skill.whenToUse, !whenToUse.isEmpty {
                detail += " — Use when: \(whenToUse)"
            }
            return "<agent_skill fullPath=\"\(skill.path)\">\(detail)</agent_skill>"
        }
        return """
            <agent_skills>
            <available_skills description="Newly discovered skills. Use the Read tool with the \
            provided absolute path to fetch full contents.">
            \(rows.joined(separator: "\n"))
            </available_skills>
            </agent_skills>
            """
    }

    // MARK: - workspace.discover_skills RPC

    public static let discoverSkillsMethod = "workspace.discover_skills"

    /// Serialize a discovery result into the RPC's `{"ok": [...]}` envelope.
    ///
    /// A skill that fails to encode is dropped rather than failing the whole
    /// response, matching the server behavior.
    public static func discoverSkillsResponse(
        cwd: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Data? {
        let skills = discover(cwd: cwd, environment: environment)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var encoded: [Data] = []
        for skill in skills {
            if let data = try? encoder.encode(skill) { encoded.append(data) }
        }
        let array = "[" + encoded.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ",") + "]"
        return Data(("{\"ok\":" + array + "}").utf8)
    }
}

extension SkillDiscovery {
    /// Public shim so the CLI can strip frontmatter without duplicating the
    /// delimiter rules.
    public static func extractBodyForInjection(_ content: String) -> String {
        extractBody(content)
    }
}
