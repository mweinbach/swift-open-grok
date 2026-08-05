// SkillDiscovery.swift
//
// `SKILL.md` discovery, scope precedence, and frontmatter parsing.
//
// Before this file the word "skill" appeared in `Sources/` only as a plugin
// manifest field: there was no discovery, no Local > Repo > User precedence, no
// `user-invocable` gate, and no slash registration. A whole user-facing
// extensibility surface had nothing behind it.
//
// Port of `xai-grok-tools/src/implementations/skills/discovery.rs` and
// `xai-grok-agent/src/prompt/skills.rs`.
//
// Three behaviors here are subtle enough to call out, because getting them
// wrong silently changes which skill a user gets:
//
//   * Directory listings are sorted lexicographically before walking. Collision
//     handling is first-seen-wins, so an unsorted `contentsOfDirectory` would
//     pick a nondeterministic winner between two skills sharing a name.
//   * `user-invocable: false` hides the *slash command*, not the model-facing
//     listing. `disable-model-invocation: true` does the inverse. They are not
//     two spellings of one switch.
//   * `.cursor` is scanned at startup but never during dynamic path discovery.
//     That asymmetry is intentional upstream and is preserved here.

import Foundation

// MARK: - Scope

/// Where a skill was found. Lower values win: Local overrides Repo overrides
/// User (`skills/types.rs:1-33`).
public enum SkillScope: UInt8, Sendable, Equatable, Hashable, Comparable, Codable {
    /// `cwd/.opengrok/skills` — highest priority.
    case local = 0
    /// `<repo root>/.opengrok/skills`.
    case repo = 1
    /// `~/.opengrok/skills`.
    case user = 2
    /// `~/.opengrok/server-skills`, synced from the skill store.
    case server = 3
    /// Platform built-ins, lowest precedence.
    case bundled = 4
    /// Plugin-provided, lowest priority for bare-name resolution.
    case plugin = 5

    public static func < (lhs: SkillScope, rhs: SkillScope) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var wireName: String {
        switch self {
        case .local: return "local"
        case .repo: return "repo"
        case .user: return "user"
        case .server: return "server"
        case .bundled: return "bundled"
        case .plugin: return "plugin"
        }
    }

    public init?(wireName: String) {
        switch wireName {
        case "local": self = .local
        case "repo": self = .repo
        case "user": self = .user
        case "server": self = .server
        case "bundled": self = .bundled
        case "plugin": self = .plugin
        default: return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let scope = SkillScope(wireName: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown skill scope '\(raw)'")
            )
        }
        self = scope
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireName)
    }
}

// MARK: - Skill model

/// A discovered skill. Field names match the `workspace.discover_skills` RPC
/// wire shape (`xai-grok-workspace-types/src/rpc/skills.rs:98-152`).
public struct SkillInfo: Sendable, Equatable, Codable {
    public var name: String
    public var displayName: String?
    public var description: String
    public var hasUserSpecifiedDescription: Bool
    public var paths: [String]?
    public var whenToUse: String?
    public var shortDescription: String?
    public var author: String?
    public var argumentHint: String?
    public var license: String?
    public var compatibility: String?
    public var metadata: [String: String]?
    public var path: String
    public var scope: SkillScope
    public var pluginName: String?
    public var pluginVersion: String?
    public var allowedTools: [String]?
    public var model: String?
    public var effort: String?
    public var userInvocable: Bool
    public var disableModelInvocation: Bool
    public var enabled: Bool
    public var body: String?

    public init(
        name: String,
        displayName: String? = nil,
        description: String,
        hasUserSpecifiedDescription: Bool = false,
        paths: [String]? = nil,
        whenToUse: String? = nil,
        shortDescription: String? = nil,
        author: String? = nil,
        argumentHint: String? = nil,
        license: String? = nil,
        compatibility: String? = nil,
        metadata: [String: String]? = nil,
        path: String,
        scope: SkillScope,
        pluginName: String? = nil,
        pluginVersion: String? = nil,
        allowedTools: [String]? = nil,
        model: String? = nil,
        effort: String? = nil,
        userInvocable: Bool = true,
        disableModelInvocation: Bool = false,
        enabled: Bool = true,
        body: String? = nil
    ) {
        self.name = name
        self.displayName = displayName
        self.description = description
        self.hasUserSpecifiedDescription = hasUserSpecifiedDescription
        self.paths = paths
        self.whenToUse = whenToUse
        self.shortDescription = shortDescription
        self.author = author
        self.argumentHint = argumentHint
        self.license = license
        self.compatibility = compatibility
        self.metadata = metadata
        self.path = path
        self.scope = scope
        self.pluginName = pluginName
        self.pluginVersion = pluginVersion
        self.allowedTools = allowedTools
        self.model = model
        self.effort = effort
        self.userInvocable = userInvocable
        self.disableModelInvocation = disableModelInvocation
        self.enabled = enabled
        self.body = body
    }

    enum CodingKeys: String, CodingKey {
        case name
        case displayName = "display_name"
        case description
        case hasUserSpecifiedDescription = "has_user_specified_description"
        case paths
        case whenToUse = "when_to_use"
        case shortDescription = "short_description"
        case author
        case argumentHint = "argument_hint"
        case license
        case compatibility
        case metadata
        case path
        case scope
        case pluginName = "plugin_name"
        case pluginVersion = "plugin_version"
        case allowedTools = "allowed_tools"
        case model
        case effort
        case userInvocable = "user_invocable"
        case disableModelInvocation = "disable_model_invocation"
        case enabled
        case body
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        description = try c.decode(String.self, forKey: .description)
        hasUserSpecifiedDescription =
            try c.decodeIfPresent(Bool.self, forKey: .hasUserSpecifiedDescription) ?? false
        paths = try c.decodeIfPresent([String].self, forKey: .paths)
        whenToUse = try c.decodeIfPresent(String.self, forKey: .whenToUse)
        shortDescription = try c.decodeIfPresent(String.self, forKey: .shortDescription)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        argumentHint = try c.decodeIfPresent(String.self, forKey: .argumentHint)
        license = try c.decodeIfPresent(String.self, forKey: .license)
        compatibility = try c.decodeIfPresent(String.self, forKey: .compatibility)
        metadata = try c.decodeIfPresent([String: String].self, forKey: .metadata)
        path = try c.decode(String.self, forKey: .path)
        scope = try c.decode(SkillScope.self, forKey: .scope)
        pluginName = try c.decodeIfPresent(String.self, forKey: .pluginName)
        pluginVersion = try c.decodeIfPresent(String.self, forKey: .pluginVersion)
        allowedTools = try c.decodeIfPresent([String].self, forKey: .allowedTools)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        userInvocable = try c.decodeIfPresent(Bool.self, forKey: .userInvocable) ?? true
        disableModelInvocation =
            try c.decodeIfPresent(Bool.self, forKey: .disableModelInvocation) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        body = try c.decodeIfPresent(String.self, forKey: .body)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encode(description, forKey: .description)
        try c.encode(hasUserSpecifiedDescription, forKey: .hasUserSpecifiedDescription)
        try c.encodeIfPresent(paths, forKey: .paths)
        try c.encodeIfPresent(whenToUse, forKey: .whenToUse)
        try c.encodeIfPresent(shortDescription, forKey: .shortDescription)
        try c.encodeIfPresent(author, forKey: .author)
        try c.encodeIfPresent(argumentHint, forKey: .argumentHint)
        try c.encodeIfPresent(license, forKey: .license)
        try c.encodeIfPresent(compatibility, forKey: .compatibility)
        try c.encodeIfPresent(metadata, forKey: .metadata)
        try c.encode(path, forKey: .path)
        try c.encode(scope, forKey: .scope)
        try c.encodeIfPresent(pluginName, forKey: .pluginName)
        try c.encodeIfPresent(pluginVersion, forKey: .pluginVersion)
        try c.encodeIfPresent(allowedTools, forKey: .allowedTools)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(effort, forKey: .effort)
        try c.encode(userInvocable, forKey: .userInvocable)
        try c.encode(disableModelInvocation, forKey: .disableModelInvocation)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(body, forKey: .body)
    }

    /// What the user sees in a listing.
    public var label: String { displayName ?? name }

    /// The key plugin skills dedupe on, so a plugin skill sharing a bare name
    /// with a native one stays reachable under its qualified form.
    public var dedupKey: String {
        if let pluginName { return "\(pluginName):\(name)" }
        return name
    }

    /// `local:commit` / `my-plugin:hello` — the disambiguated command name used
    /// when the bare name is taken or ambiguous (`skill.rs:138-146`).
    public var qualifiedName: String {
        if let pluginName { return "\(pluginName):\(name)" }
        return "\(scope.wireName):\(name)"
    }
}

// MARK: - Name rules

public enum SkillName {
    public static let maxLength = 64

    /// Lowercase, non-alphanumerics to `-`, collapse runs, trim `-`.
    public static func normalize(_ name: String) -> String {
        var out = ""
        var lastWasDash = false
        for scalar in name.lowercased().unicodeScalars {
            let isAlnum = (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57)
            if isAlnum {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= maxLength else { return false }
        guard !name.hasPrefix("-"), !name.hasSuffix("-"), !name.contains("--") else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57)
                || scalar == "-"
        }
    }
}

// MARK: - Frontmatter

public enum SkillParseError: Error, Sendable, Equatable {
    case noFrontmatter
    case yamlError(String)
    case invalidName(String)
}

/// The parsed frontmatter of a `SKILL.md`, before scope and path are attached.
public struct SkillFrontmatter: Sendable, Equatable {
    public var name: String
    public var description: String
    public var hasUserSpecifiedDescription: Bool
    public var whenToUse: String?
    public var shortDescription: String?
    public var author: String?
    public var argumentHint: String?
    public var license: String?
    public var compatibility: String?
    public var model: String?
    public var effort: String?
    public var paths: [String]?
    public var allowedTools: [String]?
    public var metadata: [String: String]?
    public var userInvocable: Bool
    public var disableModelInvocation: Bool
    public var body: String
}

public enum SkillFrontmatterParser {
    public static let maxFrontmatterBytes = 4096
    public static let maxDescriptionLength = 1024

    /// Split `---` frontmatter from the body and coerce the known fields.
    ///
    /// Parsing is deliberately per-field and tolerant: one mistyped value must
    /// never drop its siblings, because a skill that silently loses its
    /// `description` is far worse than one that keeps a malformed `model`.
    public static func parse(
        _ content: String,
        fallbackName: String?
    ) throws -> SkillFrontmatter {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var first = 0
        while first < lines.count, lines[first].trimmingCharacters(in: .whitespaces).isEmpty {
            first += 1
        }
        guard first < lines.count,
              lines[first].trimmingCharacters(in: .whitespaces) == "---" else {
            throw SkillParseError.noFrontmatter
        }
        var closing: Int?
        if first + 1 < lines.count {
            for index in (first + 1)..<lines.count
            where lines[index].trimmingCharacters(in: .whitespaces) == "---" {
                closing = index
                break
            }
        }
        guard let closing else { throw SkillParseError.noFrontmatter }

        let yamlLines = Array(lines[(first + 1)..<closing])
        let body = Array(lines.dropFirst(closing + 1))
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let fields = parseFields(yamlLines)

        // Name resolution: frontmatter first, then the directory fallback.
        // Both missing is the one hard error — an unnamed skill cannot be
        // addressed by any surface.
        let declared = fields.scalars["name"]
        if declared == nil, fallbackName == nil {
            throw SkillParseError.yamlError("missing 'name' and no directory fallback")
        }
        var resolvedName: String?
        for candidate in [declared, fallbackName].compactMap({ $0 }) {
            let normalizedName = SkillName.normalize(candidate)
            if SkillName.isValid(normalizedName) {
                resolvedName = normalizedName
                break
            }
        }
        guard let resolvedName else {
            throw SkillParseError.invalidName(SkillName.normalize(declared ?? ""))
        }

        let declaredDescription = fields.scalars["description"].map {
            String($0.prefix(maxDescriptionLength))
        }

        return SkillFrontmatter(
            name: resolvedName,
            description: declaredDescription ?? "",
            hasUserSpecifiedDescription: declaredDescription != nil,
            whenToUse: (fields.scalars["when-to-use"] ?? fields.scalars["when_to_use"])
                .map { String($0.prefix(maxDescriptionLength)) },
            shortDescription: fields.metadata["short-description"],
            author: fields.metadata["author"],
            argumentHint: fields.scalars["argument-hint"],
            license: fields.scalars["license"],
            compatibility: fields.scalars["compatibility"],
            model: fields.scalars["model"],
            effort: fields.scalars["effort"],
            paths: normalizePaths(fields.lists["paths"] ?? splitTopLevel(fields.scalars["paths"])),
            allowedTools: fields.lists["allowed-tools"]
                ?? splitTopLevel(fields.scalars["allowed-tools"]),
            metadata: fields.metadata.isEmpty ? nil : fields.metadata,
            // Absent `user-invocable` defaults to true; absent
            // `disable-model-invocation` to false.
            userInvocable: fields.scalars["user-invocable"].map(parseBool) ?? true,
            disableModelInvocation:
                fields.scalars["disable-model-invocation"].map(parseBool) ?? false,
            body: body
        )
    }

    // MARK: Field extraction

    struct Fields {
        var scalars: [String: String] = [:]
        var lists: [String: [String]] = [:]
        var metadata: [String: String] = [:]
    }

    static func parseFields(_ lines: [String]) -> Fields {
        var fields = Fields()
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            let text = raw.trimmingCharacters(in: .whitespaces)
            index += 1
            guard indent == 0, !text.isEmpty, !text.hasPrefix("#") else { continue }
            guard let separator = text.firstIndex(of: ":") else { continue }
            let key = String(text[text.startIndex..<separator])
                .trimmingCharacters(in: .whitespaces)
            var value = String(text[text.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            // A bare block-scalar indicator collects the indented lines below.
            if value == "|" || value == ">" || value.hasPrefix("|") || value.hasPrefix(">") {
                var collected: [String] = []
                while index < lines.count {
                    let child = lines[index]
                    let childIndent = child.prefix { $0 == " " || $0 == "\t" }.count
                    if child.trimmingCharacters(in: .whitespaces).isEmpty {
                        collected.append("")
                        index += 1
                        continue
                    }
                    guard childIndent > 0 else { break }
                    collected.append(child.trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                let joined = value.hasPrefix("|")
                    ? collected.joined(separator: "\n")
                    : collected.joined(separator: " ")
                let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { fields.scalars[key] = trimmed }
                continue
            }

            if value.isEmpty {
                // Either a nested mapping (`metadata:`) or a block list.
                var items: [String] = []
                var mapping: [String: String] = [:]
                while index < lines.count {
                    let child = lines[index]
                    let childIndent = child.prefix { $0 == " " || $0 == "\t" }.count
                    let childText = child.trimmingCharacters(in: .whitespaces)
                    if childText.isEmpty { index += 1; continue }
                    guard childIndent > 0 else { break }
                    index += 1
                    if childText.hasPrefix("-") {
                        let item = unquote(
                            String(childText.dropFirst()).trimmingCharacters(in: .whitespaces)
                        )
                        if !item.isEmpty { items.append(item) }
                    } else if let childSeparator = childText.firstIndex(of: ":") {
                        let childKey = String(childText[childText.startIndex..<childSeparator])
                            .trimmingCharacters(in: .whitespaces)
                        let childValue = unquote(
                            String(childText[childText.index(after: childSeparator)...])
                                .trimmingCharacters(in: .whitespaces)
                        )
                        if !childKey.isEmpty, !childValue.isEmpty {
                            mapping[childKey] = childValue
                        }
                    }
                }
                if !items.isEmpty { fields.lists[key] = items }
                if !mapping.isEmpty {
                    if key == "metadata" {
                        fields.metadata = mapping
                    } else {
                        for (childKey, childValue) in mapping {
                            fields.scalars["\(key).\(childKey)"] = childValue
                        }
                    }
                }
                continue
            }

            // Inline flow list: `allowed-tools: [Read, Bash(git diff:*)]`
            if value.hasPrefix("["), value.hasSuffix("]") {
                let inner = String(value.dropFirst().dropLast())
                let items = splitTopLevel(inner)?.filter { !$0.isEmpty } ?? []
                if !items.isEmpty { fields.lists[key] = items }
                continue
            }

            value = unquote(value)
            if !value.isEmpty { fields.scalars[key] = value }
        }
        return fields
    }

    /// Only literal `true` counts as true, matching Rust's
    /// `parse_boolean_frontmatter`.
    static func parseBool(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespaces).lowercased() == "true"
    }

    static func unquote(_ value: String) -> String {
        var text = value
        if text.count >= 2 {
            let first = text.first, last = text.last
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                return String(text.dropFirst().dropLast())
            }
        }
        // Strip a trailing ` # comment` only on unquoted values.
        if let hash = text.range(of: " #") {
            text = String(text[text.startIndex..<hash.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Split on commas/whitespace while keeping `()` and `{}` groups whole, so
    /// `Bash(git diff:*)` and `{a,b}` survive as single entries.
    static func splitTopLevel(_ value: String?) -> [String]? {
        guard let value, !value.isEmpty else { return nil }
        var result: [String] = []
        var current = ""
        var depth = 0
        for character in value {
            switch character {
            case "(", "{", "[":
                depth += 1
                current.append(character)
            case ")", "}", "]":
                depth = Swift.max(0, depth - 1)
                current.append(character)
            case ",":
                if depth == 0 {
                    let trimmed = unquote(current.trimmingCharacters(in: .whitespaces))
                    if !trimmed.isEmpty { result.append(trimmed) }
                    current = ""
                } else {
                    current.append(character)
                }
            default:
                current.append(character)
            }
        }
        let trimmed = unquote(current.trimmingCharacters(in: .whitespaces))
        if !trimmed.isEmpty { result.append(trimmed) }
        return result.isEmpty ? nil : result
    }

    /// Strip a trailing `/**`, and drop the list entirely when every pattern is
    /// unconditional — a skill gated on `**` is not gated at all.
    static func normalizePaths(_ paths: [String]?) -> [String]? {
        guard let paths, !paths.isEmpty else { return nil }
        let cleaned = paths.map { pattern -> String in
            pattern.hasSuffix("/**") ? String(pattern.dropLast(3)) : pattern
        }
        if cleaned.allSatisfy({ $0 == "**" || $0.isEmpty }) { return nil }
        return cleaned
    }
}

// MARK: - Discovery

public struct SkillDiscovery: Sendable {
    /// Config directory names scanned at startup. `.cursor` is included here
    /// and deliberately absent from ``discoverForPaths``.
    public static let startupConfigDirectories = [".opengrok", ".agents", ".claude", ".cursor"]
    /// Config directories consulted during dynamic upward discovery.
    public static let dynamicConfigDirectories = [".opengrok", ".agents", ".claude"]
    /// Only `<configdir>/skills/` is scanned; `skills-cursor/` was removed.
    public static let skillSubdirectory = "skills"
    public static let maxWalkDepth = 5

    /// Vendor defaults that would otherwise shadow real skills. Path-scoped, so
    /// `~/.opengrok/skills/shell` survives while `.cursor/skills/shell` does not.
    public static let cursorDefaultSkills: Set<String> = [
        "babysit", "canvas", "create-hook", "create-rule", "create-skill",
        "create-subagent", "loop", "migrate-to-skills", "sdk", "shell",
        "split-to-prs", "statusline", "update-cli-config", "update-cursor-settings"
    ]
    public static let claudeDefaultSkills: Set<String> = [
        "pdf", "docx", "xlsx", "pptx", "skill-creator"
    ]

    public var environment: [String: String]
    // Computed rather than stored: `FileManager` is not `Sendable`, and a
    // `Sendable` struct may not store one. `.default` is documented as safe to
    // call from multiple threads, so re-reading the shared instance costs
    // nothing and keeps the conformance honest.
    private var fileManager: FileManager { .default }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    // MARK: Path collection

    /// Every `SKILL.md` beneath `<directory>/skills/`, walked to depth 5.
    ///
    /// Note the walk never accepts a `SKILL.md` sitting directly in `skills/` —
    /// a skill is always a *directory* containing one.
    public func findSkillPaths(configDirectory: URL) -> [URL] {
        let root = configDirectory.appendingPathComponent(Self.skillSubdirectory, isDirectory: true)
        var found: [URL] = []
        walk(root, depth: 0, into: &found)
        return found
    }

    private func walk(_ directory: URL, depth: Int, into found: inout [URL]) {
        guard depth <= Self.maxWalkDepth else { return }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // Lexicographic order is required: collision handling downstream is
        // first-seen-wins, so an unsorted listing picks a random winner.
        let subdirectories = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for subdirectory in subdirectories {
            let candidate = subdirectory.appendingPathComponent("SKILL.md")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                found.append(candidate)
            }
            walk(subdirectory, depth: depth + 1, into: &found)
        }
    }

    // MARK: Scope assignment

    /// Which scope a config directory belongs to, evaluated in Rust's order:
    /// home first, then cwd, then anything inside the repo.
    public func scope(
        for configDirectory: URL,
        cwd: URL,
        gitRoot: URL?,
        home: URL?
    ) -> SkillScope {
        let parent = configDirectory.deletingLastPathComponent().standardizedFileURL
        if let home, parent == home.standardizedFileURL { return .user }
        if parent == cwd.standardizedFileURL { return .local }
        if let gitRoot,
           parent.path.hasPrefix(gitRoot.standardizedFileURL.path) { return .repo }
        return .user
    }

    // MARK: Startup discovery

    /// Discover every skill visible from `cwd`, in precedence order.
    public func discover(
        cwd: URL,
        gitRoot: URL? = nil,
        home: URL? = nil,
        grokHome: URL? = nil,
        configuredPaths: [URL] = []
    ) -> [SkillInfo] {
        let resolvedHome = home ?? environment["HOME"].map { URL(fileURLWithPath: $0) }
        let resolvedGrokHome = grokHome
            ?? environment["OPENGROK_HOME"].map { URL(fileURLWithPath: $0) }
            ?? resolvedHome?.appendingPathComponent(".opengrok")
        let resolvedGitRoot = gitRoot ?? Self.findGitRoot(from: cwd)

        var candidates: [(url: URL, scope: SkillScope)] = []
        var seenDirectories = Set<String>()

        func add(_ directory: URL, _ scope: SkillScope) {
            let key = directory.standardizedFileURL.path
            guard seenDirectories.insert(key).inserted else { return }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: key, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return }
            candidates.append((directory, scope))
        }

        // 1. cwd walked up to the git root (inclusive).
        for directory in Self.ancestorChain(from: cwd, stoppingAt: resolvedGitRoot) {
            for name in Self.startupConfigDirectories {
                let configDirectory = directory.appendingPathComponent(name, isDirectory: true)
                add(
                    configDirectory,
                    scope(
                        for: configDirectory,
                        cwd: cwd,
                        gitRoot: resolvedGitRoot,
                        home: resolvedHome
                    )
                )
            }
        }

        // 2. Global roots.
        if let resolvedGrokHome { add(resolvedGrokHome, .user) }
        if let resolvedHome {
            for name in [".agents", ".claude", ".cursor"] {
                add(resolvedHome.appendingPathComponent(name, isDirectory: true), .user)
            }
        }

        // 3. Explicitly configured `[skills].paths`.
        for path in configuredPaths {
            add(path, resolvedGitRoot.map {
                path.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path)
            } == true ? .repo : .user)
        }

        var files: [(url: URL, scope: SkillScope)] = []
        for (directory, directoryScope) in candidates {
            for file in findSkillPaths(configDirectory: directory) {
                files.append((file, directoryScope))
            }
        }

        // 4. Bundled skills ship under `<grok home>/bundled/skills`.
        if let resolvedGrokHome {
            let bundled = resolvedGrokHome.appendingPathComponent("bundled", isDirectory: true)
            for file in findSkillPaths(configDirectory: bundled) {
                files.append((file, .bundled))
            }
        }

        var skills = parse(files: files)
        // A stable sort on scope puts Local first without disturbing the
        // within-scope discovery order that collision handling depends on.
        skills = Self.stableSortByScope(skills)
        return Self.dedupe(skills)
    }

    /// Upward discovery from paths a tool just touched.
    ///
    /// The walk moves *toward* cwd and stops before scanning it (startup
    /// already did), and can never leave the git root.
    public func discoverForPaths(
        _ filePaths: [URL],
        cwd: URL,
        gitRoot: URL?,
        alreadyChecked: inout Set<String>
    ) -> [SkillInfo] {
        let cwdKey = cwd.standardizedFileURL.path
        let gitRootKey = gitRoot?.standardizedFileURL.path
        var files: [(url: URL, scope: SkillScope)] = []
        var seenFiles = Set<String>()

        for filePath in filePaths {
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: filePath.path, isDirectory: &isDirectory)
            var current: URL? = (exists && isDirectory.boolValue)
                ? filePath
                : filePath.deletingLastPathComponent()

            while let directory = current {
                let key = directory.standardizedFileURL.path
                if key == cwdKey { break }
                if let gitRootKey, !key.hasPrefix(gitRootKey) { break }

                // Already-visited short-circuits the scan but not the ascent.
                if alreadyChecked.insert(key).inserted {
                    for name in Self.dynamicConfigDirectories {
                        let configDirectory = directory.appendingPathComponent(name, isDirectory: true)
                        for file in findSkillPaths(configDirectory: configDirectory) {
                            guard seenFiles.insert(file.standardizedFileURL.path).inserted else {
                                continue
                            }
                            files.append((file, .local))
                        }
                    }
                }

                let parent = directory.deletingLastPathComponent()
                if parent.standardizedFileURL == directory.standardizedFileURL { break }
                current = parent
            }
        }

        // Deepest first, so the most specific skill is offered first.
        return parse(files: files).sorted {
            $0.path.components(separatedBy: "/").count > $1.path.components(separatedBy: "/").count
        }
    }

    // MARK: Parsing

    /// Read and parse each candidate, dropping the ones that cannot be named.
    public func parse(files: [(url: URL, scope: SkillScope)]) -> [SkillInfo] {
        var skills: [SkillInfo] = []
        for (url, scope) in files {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let fallback = url.deletingLastPathComponent().lastPathComponent
            let frontmatter: SkillFrontmatter
            do {
                frontmatter = try SkillFrontmatterParser.parse(content, fallbackName: fallback)
            } catch SkillParseError.invalidName {
                // An unaddressable name is the one unrecoverable case.
                continue
            } catch {
                // Missing or malformed frontmatter still yields a usable skill
                // as long as the directory name is a valid slug.
                let normalized = SkillName.normalize(fallback)
                guard SkillName.isValid(normalized) else { continue }
                frontmatter = SkillFrontmatter(
                    name: normalized,
                    description: "",
                    hasUserSpecifiedDescription: false,
                    whenToUse: nil, shortDescription: nil, author: nil,
                    argumentHint: nil, license: nil, compatibility: nil,
                    model: nil, effort: nil, paths: nil, allowedTools: nil,
                    metadata: nil, userInvocable: true,
                    disableModelInvocation: false,
                    body: Self.extractBody(content)
                )
            }

            if Self.isVendorDefault(path: url.path, name: frontmatter.name) { continue }

            let description = frontmatter.description.isEmpty
                ? Self.deriveDescription(from: frontmatter.body, fallback: frontmatter.name)
                : frontmatter.description

            skills.append(SkillInfo(
                name: frontmatter.name,
                description: description,
                hasUserSpecifiedDescription: frontmatter.hasUserSpecifiedDescription,
                paths: frontmatter.paths,
                whenToUse: frontmatter.whenToUse,
                shortDescription: frontmatter.shortDescription,
                author: frontmatter.author,
                argumentHint: frontmatter.argumentHint,
                license: frontmatter.license,
                compatibility: frontmatter.compatibility,
                metadata: frontmatter.metadata,
                path: url.standardizedFileURL.path,
                scope: scope,
                allowedTools: frontmatter.allowedTools,
                model: frontmatter.model,
                effort: frontmatter.effort,
                userInvocable: frontmatter.userInvocable,
                disableModelInvocation: frontmatter.disableModelInvocation,
                body: frontmatter.body
            ))
        }
        return skills
    }

    /// A vendor's own default skills must not shadow the user's.
    static func isVendorDefault(path: String, name: String) -> Bool {
        if path.contains("/.cursor/") || path.contains("\\.cursor\\") {
            return cursorDefaultSkills.contains(name)
        }
        if path.contains("/.claude/") || path.contains("\\.claude\\") {
            return claudeDefaultSkills.contains(name)
        }
        return false
    }

    public static func extractBody(_ content: String) -> String {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.trimmingCharacters(in: .whitespaces).hasPrefix("---") else {
            return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let closing = normalized.range(of: "\n---", range:
            normalized.index(normalized.startIndex, offsetBy: 3)..<normalized.endIndex
        ) else {
            return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let after = normalized[closing.upperBound...]
        // Drop the remainder of the delimiter line.
        guard let newline = after.firstIndex(of: "\n") else { return "" }
        return String(after[after.index(after: newline)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// When no `description` was declared, fall back to the first prose
    /// paragraph, then the first heading, then the skill's own name.
    static func deriveDescription(from body: String, fallback: String) -> String {
        let peek = String(body.prefix(2048))
        for block in peek.components(separatedBy: "\n\n") {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix(">") {
                continue
            }
            let text = trimmed.hasPrefix("#")
                ? trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                : trimmed
            let collapsed = text
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !collapsed.isEmpty {
                return String(collapsed.prefix(SkillFrontmatterParser.maxDescriptionLength))
            }
        }
        return fallback
    }

    // MARK: Deduplication

    static func stableSortByScope(_ skills: [SkillInfo]) -> [SkillInfo] {
        skills.enumerated()
            .sorted {
                $0.element.scope == $1.element.scope
                    ? $0.offset < $1.offset
                    : $0.element.scope < $1.element.scope
            }
            .map(\.element)
    }

    /// Resolve collisions by canonical path first, then by name.
    ///
    /// Two skills at the same scope sharing a name get a rescue: the challenger
    /// is re-keyed to its directory basename rather than being dropped, so a
    /// sibling pair does not silently lose one member.
    public static func dedupe(_ skills: [SkillInfo]) -> [SkillInfo] {
        var result: [SkillInfo] = []
        var seenPaths = Set<String>()
        var seenNames: [String: (scope: SkillScope, index: Int)] = [:]

        for var skill in skills {
            guard seenPaths.insert(skill.path).inserted else { continue }

            if let incumbent = seenNames[skill.name] {
                let sameScope = incumbent.scope == skill.scope
                    && skill.scope != .server && skill.scope != .bundled
                guard sameScope else { continue }

                // Re-key the challenger to its directory basename.
                let basename = SkillName.normalize(
                    URL(fileURLWithPath: skill.path).deletingLastPathComponent().lastPathComponent
                )
                guard SkillName.isValid(basename),
                      basename != skill.name,
                      seenNames[basename] == nil else { continue }
                skill.displayName = skill.displayName ?? skill.name
                skill.name = basename
            }

            seenNames[skill.name] = (skill.scope, result.count)
            result.append(skill)
        }
        return result
    }

    // MARK: Path helpers

    /// Every directory from `cwd` up to and including `gitRoot`. Without a git
    /// root only `cwd` itself is returned — no unbounded upward walk.
    static func ancestorChain(from cwd: URL, stoppingAt gitRoot: URL?) -> [URL] {
        guard let gitRoot else { return [cwd] }
        let rootPath = gitRoot.standardizedFileURL.path
        var chain: [URL] = []
        var current = cwd.standardizedFileURL
        while true {
            chain.append(current)
            if current.path == rootPath { break }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent == current || !current.path.hasPrefix(rootPath) { break }
            current = parent
        }
        return chain
    }

    public static func findGitRoot(from cwd: URL) -> URL? {
        var current = cwd.standardizedFileURL
        let fileManager = FileManager.default
        while true {
            if fileManager.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent == current { return nil }
            current = parent
        }
    }
}
