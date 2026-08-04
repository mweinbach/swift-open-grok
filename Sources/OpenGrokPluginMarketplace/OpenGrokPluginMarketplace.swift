import Foundation

public let officialMarketplaceSourceName = "xAI Official"
public let officialMarketplaceSourceGitURL = "https://github.com/xai-org/plugin-marketplace.git"

public enum MarketplacePathError: String, Error, Hashable, Sendable, Codable, Equatable, CustomStringConvertible {
    case empty
    case absolute
    case parentComponent
    case prefix
    case currentComponent
    case escapesRoot

    public var description: String {
        switch self {
        case .empty: return "marketplace path is empty"
        case .absolute: return "marketplace path must be relative"
        case .parentComponent: return "marketplace path must not contain parent components"
        case .prefix: return "marketplace path must not contain a platform prefix"
        case .currentComponent: return "marketplace path must not contain current-directory components"
        case .escapesRoot: return "marketplace path escapes marketplace root"
        }
    }
}

public enum MarketplaceError: Error, Hashable, Sendable, Codable, Equatable, CustomStringConvertible, LocalizedError {
    case io(path: String, reason: String)
    case invalidJSON(path: String)
    case invalidIndex(path: String, reason: String)
    case invalidManifest(path: String, reason: String)
    case unsupportedCatalogVersion(path: String, version: Int)
    case invalidPath(path: String, reason: MarketplacePathError)
    case missingSource(plugin: String)
    case missingPlugin(plugin: String)
    case ambiguousPlugin(plugin: String, matches: [String])
    case alreadyInstalled(plugin: String)
    case notInstalled(plugin: String)
    case invalidGitOperand(kind: String, value: String)
    case unpinnedRemote(plugin: String, url: String)
    case integrityMismatch(expected: String, actual: String)
    case conflict(plugin: String, reason: String)
    case installFailed(detail: String)

    public var description: String {
        switch self {
        case let .io(path, reason): return "I/O error at \(path): \(reason)"
        case let .invalidJSON(path): return "JSON error at \(path)"
        case let .invalidIndex(path, reason): return "invalid marketplace index at \(path): \(reason)"
        case let .invalidManifest(path, reason): return "invalid plugin manifest at \(path): \(reason)"
        case let .unsupportedCatalogVersion(path, version): return "unsupported plugin catalog version \(version) at \(path)"
        case let .invalidPath(path, reason): return "invalid marketplace path '\(path)': \(reason)"
        case let .missingSource(plugin): return "plugin '\(plugin)' is missing a source"
        case let .missingPlugin(plugin): return "plugin '\(plugin)' was not found"
        case let .ambiguousPlugin(plugin, matches): return "plugin '\(plugin)' is ambiguous: \(matches.joined(separator: ", "))"
        case let .alreadyInstalled(plugin): return "plugin '\(plugin)' is already installed"
        case let .notInstalled(plugin): return "plugin '\(plugin)' is not installed from this marketplace"
        case let .invalidGitOperand(kind, value): return "invalid git \(kind): \(value)"
        case let .unpinnedRemote(plugin, url): return "refusing unpinned remote plugin code for '\(plugin)' from \(url): marketplace.require_sha / OPENGROK_MARKETPLACE_REQUIRE_SHA is enabled and no full commit sha (40/64 hex) is pinned"
        case let .integrityMismatch(expected, actual): return "SHA verification failed: expected \(expected), got \(actual)"
        case let .conflict(plugin, reason): return "plugin '\(plugin)' conflicts: \(reason)"
        case let .installFailed(detail): return "install failed: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}

public struct MarketplaceRelativePath: Hashable, Sendable, Codable, Equatable, CustomStringConvertible {
    public let value: String

    public init(_ input: String) throws {
        self.value = try Self.normalize(input)
    }

    public static func parse(_ input: String) throws -> MarketplaceRelativePath {
        try MarketplaceRelativePath(input)
    }

    public var description: String { value }
    public var asString: String { value }

    public func resolve(under root: URL) throws -> URL {
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = rootURL.appendingPathComponent(value, isDirectory: false)
        let fileManager = FileManager.default
        var existing = candidate
        var missing: [String] = []
        while !fileManager.fileExists(atPath: existing.path) {
            guard let last = existing.pathComponents.last, last != "/" else {
                throw MarketplaceError.invalidPath(path: value, reason: .escapesRoot)
            }
            missing.append(last)
            existing.deleteLastPathComponent()
        }
        let canonicalExisting = existing.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isContained(canonicalExisting, in: rootURL) else {
            throw MarketplaceError.invalidPath(path: value, reason: .escapesRoot)
        }
        var resolved = canonicalExisting
        for component in missing.reversed() {
            resolved.appendPathComponent(component, isDirectory: false)
        }
        return resolved
    }

    private static func normalize(_ input: String) throws -> String {
        var stripped = input
        if stripped.hasPrefix("./") { stripped.removeFirst(2) }
        guard !stripped.isEmpty else { throw MarketplaceError.invalidPath(path: input, reason: .empty) }
        if stripped.hasPrefix("/") || stripped.hasPrefix("\\") { throw MarketplaceError.invalidPath(path: input, reason: .absolute) }
        let segments = stripped.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
        guard !segments.isEmpty else { throw MarketplaceError.invalidPath(path: input, reason: .empty) }
        for segment in segments {
            let part = String(segment)
            if part.isEmpty { throw MarketplaceError.invalidPath(path: input, reason: .prefix) }
            if part == ".." { throw MarketplaceError.invalidPath(path: input, reason: .parentComponent) }
            if part == "." { throw MarketplaceError.invalidPath(path: input, reason: .currentComponent) }
            if part.contains(":") { throw MarketplaceError.invalidPath(path: input, reason: .prefix) }
        }
        return segments.map(String.init).joined(separator: "/")
    }

    private static func isContained(_ path: URL, in root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let pathComponents = path.standardizedFileURL.pathComponents
        guard pathComponents.count >= rootComponents.count else { return false }
        return Array(pathComponents.prefix(rootComponents.count)) == rootComponents
    }
}

public enum SourceKind: Hashable, Sendable, Codable, Equatable {
    case local(path: String)
    case git(url: String, branch: String?)

    private enum CodingKeys: String, CodingKey { case type, path, url, branch }
    private enum Tag: String, Codable { case local, git }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(Tag.self, forKey: .type)
        switch type {
        case .local: self = .local(path: try container.decode(String.self, forKey: .path))
        case .git: self = .git(url: try container.decode(String.self, forKey: .url), branch: try container.decodeIfPresent(String.self, forKey: .branch))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .local(path):
            try container.encode(Tag.local, forKey: .type)
            try container.encode(path, forKey: .path)
        case let .git(url, branch):
            try container.encode(Tag.git, forKey: .type)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(branch, forKey: .branch)
        }
    }

    public var identity: String {
        switch self {
        case let .local(path): return path
        case let .git(url, _): return url
        }
    }
}

public struct MarketplaceSource: Hashable, Sendable, Codable, Equatable {
    public var name: String
    public var kind: SourceKind

    public init(name: String, kind: SourceKind) {
        self.name = name
        self.kind = kind
    }

    public var sourceURLOrPath: String { kind.identity }
}

public enum JSONValue: Hashable, Sendable, Codable, Equatable {
    case null
    case boolean(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null; return }
        if let value = try? single.decode(Bool.self) { self = .boolean(value); return }
        if let value = try? single.decode(Double.self) { self = .number(value); return }
        if let value = try? single.decode(String.self) { self = .string(value); return }
        if let value = try? single.decode([JSONValue].self) { self = .array(value); return }
        self = .object(try single.decode([String: JSONValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null: var container = encoder.singleValueContainer(); try container.encodeNil()
        case let .boolean(value): var container = encoder.singleValueContainer(); try container.encode(value)
        case let .number(value): var container = encoder.singleValueContainer(); try container.encode(value)
        case let .string(value): var container = encoder.singleValueContainer(); try container.encode(value)
        case let .array(value): var container = encoder.unkeyedContainer(); for item in value { try container.encode(item) }
        case let .object(value): var container = encoder.container(keyedBy: DynamicCodingKey.self); for (key, item) in value { try container.encode(item, forKey: DynamicCodingKey(key)) }
        }
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }
}

public struct PluginAuthor: Hashable, Sendable, Codable, Equatable {
    public var name: String?
    public var email: String?
    public var url: String?

    public init(name: String? = nil, email: String? = nil, url: String? = nil) {
        self.name = name
        self.email = email
        self.url = url
    }
}

public enum ManifestPathValue: Hashable, Sendable, Codable, Equatable {
    case single(String)
    case multiple([String])

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let value = try? single.decode(String.self) { self = .single(value) }
        else { self = .multiple(try single.decode([String].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case let .single(value): try single.encode(value)
        case let .multiple(value): try single.encode(value)
        }
    }

    fileprivate var paths: [String] {
        switch self { case let .single(path): return [path]; case let .multiple(paths): return paths }
    }
}

public enum ManifestComponentValue: Hashable, Sendable, Codable, Equatable {
    case path(String)
    case inline(JSONValue)

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let path = try? single.decode(String.self) { self = .path(path) }
        else { self = .inline(try single.decode(JSONValue.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case let .path(value): try single.encode(value)
        case let .inline(value): try single.encode(value)
        }
    }
}

public struct PluginManifest: Hashable, Sendable, Codable, Equatable {
    public var name: String
    public var version: String?
    public var description: String?
    public var author: PluginAuthor?
    public var homepage: String?
    public var repository: String?
    public var license: String?
    public var keywords: [String]
    public var skills: ManifestPathValue?
    public var commands: ManifestPathValue?
    public var agents: ManifestPathValue?
    public var hooks: ManifestComponentValue?
    public var mcpServers: ManifestComponentValue?
    public var lspServers: ManifestComponentValue?

    public init(name: String, version: String? = nil, description: String? = nil, author: PluginAuthor? = nil, homepage: String? = nil, repository: String? = nil, license: String? = nil, keywords: [String] = [], skills: ManifestPathValue? = nil, commands: ManifestPathValue? = nil, agents: ManifestPathValue? = nil, hooks: ManifestComponentValue? = nil, mcpServers: ManifestComponentValue? = nil, lspServers: ManifestComponentValue? = nil) {
        self.name = name; self.version = version; self.description = description; self.author = author; self.homepage = homepage; self.repository = repository; self.license = license; self.keywords = keywords; self.skills = skills; self.commands = commands; self.agents = agents; self.hooks = hooks; self.mcpServers = mcpServers; self.lspServers = lspServers
    }

    private enum CodingKeys: String, CodingKey {
        case name, version, description, author, homepage, repository, license, keywords
        case skills, commands, agents, hooks
        case mcpServers, lspServers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        author = try container.decodeIfPresent(PluginAuthor.self, forKey: .author)
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        repository = try container.decodeIfPresent(String.self, forKey: .repository)
        license = try container.decodeIfPresent(String.self, forKey: .license)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        skills = try container.decodeIfPresent(ManifestPathValue.self, forKey: .skills)
        commands = try container.decodeIfPresent(ManifestPathValue.self, forKey: .commands)
        agents = try container.decodeIfPresent(ManifestPathValue.self, forKey: .agents)
        hooks = try container.decodeIfPresent(ManifestComponentValue.self, forKey: .hooks)
        mcpServers = try container.decodeIfPresent(ManifestComponentValue.self, forKey: .mcpServers)
        lspServers = try container.decodeIfPresent(ManifestComponentValue.self, forKey: .lspServers)
    }

    public func validate() throws {
        let valid = !name.isEmpty && name.count <= 64 && name.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) || scalar.value == 45
        } && !name.hasPrefix("-") && !name.hasSuffix("-")
        guard valid else { throw MarketplaceError.invalidManifest(path: "plugin.json", reason: "name must be 1-64 chars, lowercase alphanumeric + hyphens, with no leading or trailing hyphens") }
    }

    public func componentDirectories(_ value: ManifestPathValue?, root: URL, defaultName: String) -> [URL] {
        let paths = value?.paths ?? [defaultName]
        return paths.compactMap { path in
            guard let relative = try? MarketplaceRelativePath(path), let resolved = try? relative.resolve(under: root), FileManager.default.fileExists(atPath: resolved.path) else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return resolved
        }
    }

    public func componentFile(_ value: ManifestComponentValue?, root: URL, defaultName: String) -> URL? {
        if case .inline = value { return nil }
        let path: String
        if case let .path(value) = value { path = value } else { path = defaultName }
        guard let relative = try? MarketplaceRelativePath(path), let resolved = try? relative.resolve(under: root) else { return nil }
        return FileManager.default.fileExists(atPath: resolved.path) ? resolved : nil
    }
}

public enum ManifestLoadResult: Hashable, Sendable, Codable, Equatable {
    case found(PluginManifest)
    case notFound
}

public func loadPluginManifest(from pluginRoot: URL) throws -> ManifestLoadResult {
    let candidates = ["plugin.json", ".opengrok-plugin/plugin.json", ".claude-plugin/plugin.json"]
    for relative in candidates {
        let path = pluginRoot.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: path.path) else { continue }
        do {
            let data = try Data(contentsOf: path)
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
            do { try manifest.validate() } catch { throw MarketplaceError.invalidManifest(path: path.path, reason: manifestErrorReason(error)) }
            return .found(manifest)
        } catch let error as MarketplaceError { throw error }
        catch { throw MarketplaceError.invalidManifest(path: path.path, reason: "invalid JSON") }
    }
    return .notFound
}

public func nameFromDirectory(_ directory: URL) -> String? {
    let name = directory.lastPathComponent
    let sanitized = name.lowercased().map { character -> Character in
        if character.isASCII && (character.isLetter || character.isNumber || character == "-") { return character }
        return "-"
    }
    let result = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return result.isEmpty || result.count > 64 ? nil : result
}

public struct IndexOwner: Hashable, Sendable, Codable, Equatable {
    public var name: String
    public var email: String?
    public init(name: String, email: String? = nil) { self.name = name; self.email = email }
}

public struct IndexSource: Hashable, Sendable, Codable, Equatable {
    public var type: String?
    public var path: String?
    public var url: String?
    public var gitRef: String?
    public var gitSHA: String?

    public init(type: String? = nil, path: String? = nil, url: String? = nil, gitRef: String? = nil, gitSHA: String? = nil) {
        self.type = type; self.path = path; self.url = url; self.gitRef = gitRef; self.gitSHA = gitSHA
    }

    public var isRemote: Bool { url != nil }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let path = try? single.decode(String.self) { self.init(type: "local", path: path); return }
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let explicitType = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("type"))
        let sourceType = try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("source"))
        self.init(
            type: explicitType ?? sourceType,
            path: try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("path")),
            url: try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("url")),
            gitRef: try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("ref")),
            gitSHA: try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("sha"))
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encodeIfPresent(type, forKey: DynamicCodingKey("type")); try container.encodeIfPresent(path, forKey: DynamicCodingKey("path")); try container.encodeIfPresent(url, forKey: DynamicCodingKey("url")); try container.encodeIfPresent(gitRef, forKey: DynamicCodingKey("ref")); try container.encodeIfPresent(gitSHA, forKey: DynamicCodingKey("sha"))
    }
}

public struct MarketplaceIndexEntry: Hashable, Sendable, Codable, Equatable {
    public var name: String
    public var version: String?
    public var description: String?
    public var category: String?
    public var author: IndexOwner?
    public var source: IndexSource?
    public var homepage: String?
    public var tags: [String]
    public var keywords: [String]
    public var domains: [String]

    public init(name: String, version: String? = nil, description: String? = nil, category: String? = nil, author: IndexOwner? = nil, source: IndexSource? = nil, homepage: String? = nil, tags: [String] = [], keywords: [String] = [], domains: [String] = []) {
        self.name = name; self.version = version; self.description = description; self.category = category; self.author = author; self.source = source; self.homepage = homepage; self.tags = tags; self.keywords = keywords; self.domains = domains
    }

    private enum CodingKeys: String, CodingKey {
        case name, version, description, category, author, source, homepage
        case tags, keywords, domains
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        author = try container.decodeIfPresent(IndexOwner.self, forKey: .author)
        source = try container.decodeIfPresent(IndexSource.self, forKey: .source)
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        domains = try container.decodeIfPresent([String].self, forKey: .domains) ?? []
    }

    public func resolvedMarketplacePath() throws -> MarketplaceRelativePath {
        guard let source else { throw MarketplaceError.missingSource(plugin: name) }
        guard !source.isRemote else { throw MarketplaceError.installFailed(detail: "remote source has no local path") }
        guard let path = source.path else { throw MarketplaceError.installFailed(detail: "missing source path") }
        return try MarketplaceRelativePath(path)
    }

    public var remoteURL: (url: String, ref: String?)? { guard let source, let url = source.url else { return nil }; return (url, source.gitRef) }
    public var remoteSHA: String? { source?.gitSHA }
    public var remoteSubdirectory: String? { source?.isRemote == true ? source?.path : nil }
}

public struct MarketplaceIndex: Hashable, Sendable, Codable, Equatable {
    public var name: String
    public var description: String?
    public var owner: IndexOwner?
    public var plugins: [MarketplaceIndexEntry]
    public init(name: String, description: String? = nil, owner: IndexOwner? = nil, plugins: [MarketplaceIndexEntry] = []) { self.name = name; self.description = description; self.owner = owner; self.plugins = plugins }

    private enum CodingKeys: String, CodingKey { case name, description, owner, plugins }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        owner = try container.decodeIfPresent(IndexOwner.self, forKey: .owner)
        plugins = try container.decodeIfPresent([MarketplaceIndexEntry].self, forKey: .plugins) ?? []
    }
}

public func loadMarketplaceIndex(from root: URL) throws -> MarketplaceIndex? {
    let candidates = [
        root.appendingPathComponent(".opengrok-plugin/marketplace.json"),
        root.appendingPathComponent(".opengrok-plugin/plugin.json"),
        root.appendingPathComponent(".claude-plugin/marketplace.json"),
        root.appendingPathComponent(".claude-plugin/plugin.json")
    ]
    for path in candidates {
        guard FileManager.default.fileExists(atPath: path.path) else { continue }
        do {
            return try JSONDecoder().decode(MarketplaceIndex.self, from: Data(contentsOf: path))
        } catch { throw MarketplaceError.invalidIndex(path: path.path, reason: "invalid JSON") }
    }
    return nil
}

public struct MarketplaceComponentItem: Hashable, Sendable, Codable, Equatable {
    public var name: String
    public var description: String?
    public init(name: String, description: String? = nil) { self.name = name; self.description = description }
    public mutating func sanitize() {
        name = Self.clean(name, limit: 120)
        if let description { self.description = Self.clean(description, limit: 120).isEmpty ? nil : Self.clean(description, limit: 120) }
    }
    private static func clean(_ value: String, limit: Int) -> String {
        let scalars = value.unicodeScalars.filter { scalar in
            guard scalar.properties.generalCategory != .control else { return false }
            let code = scalar.value
            return !(0x200b...0x200f).contains(code) && !(0x202a...0x202e).contains(code) && !(0x2066...0x2069).contains(code) && code != 0xfeff
        }
        return String(String.UnicodeScalarView(scalars).prefix(limit))
    }
}

public struct PluginComponents: Hashable, Sendable, Codable, Equatable {
    public var skills: [MarketplaceComponentItem]
    public var commands: [MarketplaceComponentItem]
    public var agents: [MarketplaceComponentItem]
    public var mcpServers: [MarketplaceComponentItem]
    public var hooks: [MarketplaceComponentItem]
    public var lspServers: [MarketplaceComponentItem]
    public init(skills: [MarketplaceComponentItem] = [], commands: [MarketplaceComponentItem] = [], agents: [MarketplaceComponentItem] = [], mcpServers: [MarketplaceComponentItem] = [], hooks: [MarketplaceComponentItem] = [], lspServers: [MarketplaceComponentItem] = []) { self.skills = skills; self.commands = commands; self.agents = agents; self.mcpServers = mcpServers; self.hooks = hooks; self.lspServers = lspServers }

    private enum CodingKeys: String, CodingKey { case skills, commands, agents, mcpServers, hooks, lspServers }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        skills = try container.decodeIfPresent([MarketplaceComponentItem].self, forKey: .skills) ?? []
        commands = try container.decodeIfPresent([MarketplaceComponentItem].self, forKey: .commands) ?? []
        agents = try container.decodeIfPresent([MarketplaceComponentItem].self, forKey: .agents) ?? []
        mcpServers = try container.decodeIfPresent([MarketplaceComponentItem].self, forKey: .mcpServers) ?? []
        hooks = try container.decodeIfPresent([MarketplaceComponentItem].self, forKey: .hooks) ?? []
        lspServers = try container.decodeIfPresent([MarketplaceComponentItem].self, forKey: .lspServers) ?? []
    }

    public mutating func sanitize() { sanitize(&skills); sanitize(&commands); sanitize(&agents); sanitize(&mcpServers); sanitize(&hooks); sanitize(&lspServers) }
    public var isEmpty: Bool { skills.isEmpty && commands.isEmpty && agents.isEmpty && mcpServers.isEmpty && hooks.isEmpty && lspServers.isEmpty }
    private func sanitize(_ items: inout [MarketplaceComponentItem]) { items = Array(items.prefix(50)); for index in items.indices { items[index].sanitize() } }
}

public struct MarketplaceCatalogEntry: Hashable, Sendable, Codable, Equatable {
    public var sha: String?
    public var components: PluginComponents
    public init(sha: String? = nil, components: PluginComponents) { self.sha = sha; self.components = components }
}

public struct PluginCatalog: Hashable, Sendable, Codable, Equatable {
    public var version: Int
    public var plugins: [String: MarketplaceCatalogEntry]
    public init(version: Int, plugins: [String: MarketplaceCatalogEntry] = [:]) { self.version = version; self.plugins = plugins }

    private enum CodingKeys: String, CodingKey { case version, plugins }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        plugins = try container.decodeIfPresent([String: MarketplaceCatalogEntry].self, forKey: .plugins) ?? [:]
    }

    public func components(for indexName: String, indexSHA: String?) -> PluginComponents? {
        guard let entry = plugins[indexName] else { return nil }
        if let indexSHA, entry.sha != indexSHA { return nil }
        return entry.components
    }
}

public func loadPluginCatalog(from root: URL) -> PluginCatalog? {
    let candidates = [root.appendingPathComponent(".opengrok-plugin/plugin-index.json"), root.appendingPathComponent(".claude-plugin/plugin-index.json")]
    for path in candidates {
        guard FileManager.default.fileExists(atPath: path.path) else { continue }
        guard let data = try? Data(contentsOf: path), var catalog = try? JSONDecoder().decode(PluginCatalog.self, from: data) else { return nil }
        guard catalog.version == 1 else { return nil }
        for key in catalog.plugins.keys { catalog.plugins[key]?.components.sanitize() }
        return catalog
    }
    return nil
}

public struct MarketplaceEntry: Hashable, Sendable, Codable, Equatable {
    public var name: String
    public var version: String?
    public var description: String?
    public var category: String?
    public var author: String?
    public var tags: [String]
    public var keywords: [String]
    public var domains: [String]
    public var homepage: String?
    public var relativePath: String
    public var skillCount: Int
    public var hasHooks: Bool
    public var hasAgents: Bool
    public var hasMcp: Bool
    public var remoteURL: String?
    public var remoteRef: String?
    public var remoteSHA: String?
    public var remoteSubdirectory: String?
    public var components: PluginComponents?

    public init(name: String, version: String? = nil, description: String? = nil, category: String? = nil, author: String? = nil, tags: [String] = [], keywords: [String] = [], domains: [String] = [], homepage: String? = nil, relativePath: String, skillCount: Int = 0, hasHooks: Bool = false, hasAgents: Bool = false, hasMcp: Bool = false, remoteURL: String? = nil, remoteRef: String? = nil, remoteSHA: String? = nil, remoteSubdirectory: String? = nil, components: PluginComponents? = nil) {
        self.name = name; self.version = version; self.description = description; self.category = category; self.author = author; self.tags = tags; self.keywords = keywords; self.domains = domains; self.homepage = homepage; self.relativePath = relativePath; self.skillCount = skillCount; self.hasHooks = hasHooks; self.hasAgents = hasAgents; self.hasMcp = hasMcp; self.remoteURL = remoteURL; self.remoteRef = remoteRef; self.remoteSHA = remoteSHA; self.remoteSubdirectory = remoteSubdirectory; self.components = components
    }

    private enum CodingKeys: String, CodingKey {
        case name, version, description, category, author, tags, keywords, domains, homepage
        case relativePath = "relative_path"
        case skillCount = "skill_count"
        case hasHooks = "has_hooks"
        case hasAgents = "has_agents"
        case hasMcp = "has_mcp"
        case remoteURL = "remote_url"
        case remoteRef = "remote_ref"
        case remoteSHA = "remote_sha"
        case remoteSubdirectory = "remote_subdir"
        case components
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        domains = try container.decodeIfPresent([String].self, forKey: .domains) ?? []
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        skillCount = try container.decodeIfPresent(Int.self, forKey: .skillCount) ?? 0
        hasHooks = try container.decodeIfPresent(Bool.self, forKey: .hasHooks) ?? false
        hasAgents = try container.decodeIfPresent(Bool.self, forKey: .hasAgents) ?? false
        hasMcp = try container.decodeIfPresent(Bool.self, forKey: .hasMcp) ?? false
        remoteURL = try container.decodeIfPresent(String.self, forKey: .remoteURL)
        remoteRef = try container.decodeIfPresent(String.self, forKey: .remoteRef)
        remoteSHA = try container.decodeIfPresent(String.self, forKey: .remoteSHA)
        remoteSubdirectory = try container.decodeIfPresent(String.self, forKey: .remoteSubdirectory)
        components = try container.decodeIfPresent(PluginComponents.self, forKey: .components)
    }
}

public struct MarketplaceScan: Hashable, Sendable, Codable, Equatable {
    public var entries: [MarketplaceEntry]
    public var catalogLoaded: Bool
    public init(entries: [MarketplaceEntry], catalogLoaded: Bool) { self.entries = entries; self.catalogLoaded = catalogLoaded }
}

public func scanMarketplace(_ root: URL) -> MarketplaceScan {
    let index: MarketplaceIndex?
    do {
        index = try loadMarketplaceIndex(from: root)
    } catch {
        index = nil
    }
    guard let index else { return MarketplaceScan(entries: scanFilesystemMarketplace(root), catalogLoaded: false) }
    let catalog = loadPluginCatalog(from: root)
    var entries: [MarketplaceEntry] = []
    for indexed in index.plugins {
        if let remote = indexed.remoteURL {
            entries.append(MarketplaceEntry(name: indexed.name, version: indexed.version, description: indexed.description, category: indexed.category, author: indexed.author?.name, tags: indexed.tags, keywords: indexed.keywords, domains: indexed.domains, homepage: indexed.homepage, relativePath: indexed.name, remoteURL: remote.url, remoteRef: remote.ref, remoteSHA: indexed.remoteSHA, remoteSubdirectory: indexed.remoteSubdirectory, components: indexed.remoteSHA.flatMap { catalog?.components(for: indexed.name, indexSHA: $0) }))
            continue
        }
        guard let relative = try? indexed.resolvedMarketplacePath(), let pluginURL = try? relative.resolve(under: root), isDirectory(pluginURL) else { continue }
        var entry = scanPluginDirectory(pluginURL, relativePath: relative.value)
        if entry.description == nil { entry.description = indexed.description }
        entry.category = indexed.category; entry.tags = indexed.tags; entry.keywords = indexed.keywords; entry.domains = indexed.domains; entry.homepage = indexed.homepage
        if entry.author == nil { entry.author = indexed.author?.name }
        entry.components = catalog?.components(for: indexed.name, indexSHA: nil)
        entries.append(entry)
    }
    return MarketplaceScan(entries: entries, catalogLoaded: catalog != nil)
}

private func scanFilesystemMarketplace(_ root: URL) -> [MarketplaceEntry] {
    let plugins = root.appendingPathComponent("plugins", isDirectory: true)
    guard let children = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
    return children.filter(isDirectory).sorted { $0.lastPathComponent < $1.lastPathComponent }.map { scanPluginDirectory($0, relativePath: "plugins/\($0.lastPathComponent)") }
}

private func scanPluginDirectory(_ plugin: URL, relativePath: String) -> MarketplaceEntry {
    let manifest: PluginManifest?
    do {
        switch try loadPluginManifest(from: plugin) {
        case let .found(value): manifest = value
        case .notFound: manifest = nil
        }
    } catch {
        manifest = nil
    }
    let name = manifest?.name ?? plugin.lastPathComponent
    let skillDirectories = manifest?.componentDirectories(manifest?.skills, root: plugin, defaultName: "skills") ?? [plugin.appendingPathComponent("skills")].filter(isDirectory)
    let skillCount = skillDirectories.reduce(0) { count, directory in
        count + ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])) ?? []).filter { isDirectory($0) && FileManager.default.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }.count
    }
    let hooks = manifest?.componentFile(manifest?.hooks, root: plugin, defaultName: "hooks/hooks.json") != nil || (manifest == nil && FileManager.default.fileExists(atPath: plugin.appendingPathComponent("hooks/hooks.json").path))
    let agents: Bool
    if let manifest {
        agents = manifest.componentDirectories(manifest.agents, root: plugin, defaultName: "agents").contains(where: isDirectoryWithContents)
    } else {
        agents = isDirectory(plugin.appendingPathComponent("agents"))
    }
    let mcp = manifest?.componentFile(manifest?.mcpServers, root: plugin, defaultName: ".mcp.json") != nil || (manifest == nil && FileManager.default.fileExists(atPath: plugin.appendingPathComponent(".mcp.json").path))
    return MarketplaceEntry(name: name, version: manifest?.version, description: manifest?.description, author: manifest?.author?.name, relativePath: relativePath, skillCount: skillCount, hasHooks: hooks, hasAgents: agents, hasMcp: mcp)
}

public struct MarketplaceKeywordCandidate: Hashable, Sendable, Codable, Equatable {
    public var name: String
    public var domains: [String]
    public var keywords: [String]
    public init(name: String, domains: [String] = [], keywords: [String] = []) { self.name = name; self.domains = domains; self.keywords = keywords }
}

public func matchPluginKeyword(_ draft: String, candidates: [MarketplaceKeywordCandidate]) -> Int? {
    guard draft.count >= 3 else { return nil }
    let haystack = draft.lowercased()
    var pairs: [(keyword: String, index: Int, order: Int)] = []
    var order = 0
    for (index, candidate) in candidates.enumerated() {
        for keyword in candidate.keywords {
            if let normalized = normalizedKeyword(keyword) {
                pairs.append((normalized, index, order))
                order += 1
            }
        }
        for domain in candidate.domains {
            if let normalized = normalizeDomain(domain) {
                pairs.append((normalized, index, order))
                order += 1
            }
        }
        if let name = normalizedKeyword(candidate.name) {
            pairs.append((name, index, order))
            order += 1
        }
    }
    pairs.sort { lhs, rhs in
        if lhs.keyword.utf8.count != rhs.keyword.utf8.count {
            return lhs.keyword.utf8.count > rhs.keyword.utf8.count
        }
        return lhs.order < rhs.order
    }
    return pairs.first { keywordMatches(haystack, $0.keyword) }?.index
}

public func compatibleMarketplaceEntries(for draft: String, entries: [MarketplaceEntry]) -> [MarketplaceEntry] {
    let candidates = entries.map { MarketplaceKeywordCandidate(name: $0.name, domains: $0.domains, keywords: $0.keywords) }
    guard let index = matchPluginKeyword(draft, candidates: candidates) else { return [] }
    return [entries[index]]
}

private func normalizedKeyword(_ value: String) -> String? { let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(); return value.isEmpty ? nil : value }
private func normalizeDomain(_ value: String) -> String? {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let withoutScheme = value.components(separatedBy: "://").last ?? value
    let host = withoutScheme.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).first.map(String.init) ?? ""
    let normalized = host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)).lowercased() : host.lowercased()
    return normalized.isEmpty ? nil : normalized
}
private func keywordMatches(_ haystack: String, _ keyword: String) -> Bool {
    guard !keyword.isEmpty else { return false }
    var searchStart = haystack.startIndex
    while let range = haystack.range(of: keyword, range: searchStart..<haystack.endIndex) {
        let before = range.lowerBound > haystack.startIndex ? haystack[haystack.index(before: range.lowerBound)] : nil
        let after = range.upperBound < haystack.endIndex ? haystack[range.upperBound] : nil
        let startOK = before.map { isWordCharacter($0) } != isWordCharacter(haystack[range.lowerBound])
        let endCharacter = haystack.index(before: range.upperBound)
        let endOK = after.map { isWordCharacter($0) } != isWordCharacter(haystack[endCharacter])
        if startOK && endOK { return true }
        searchStart = range.upperBound
    }
    return false
}
private func isWordCharacter(_ value: Character) -> Bool { value.isASCII && (value.isLetter || value.isNumber || value == "_") }

public func canonicalGitHubOwnerRepository(_ url: String) -> String? {
    var value = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value.hasSuffix("/") { value.removeLast() }
    if value.hasSuffix(".git") { value.removeLast(4) }
    for prefix in ["https://", "http://", "ssh://"] where value.hasPrefix(prefix) { value.removeFirst(prefix.count); break }
    if value.hasPrefix("git@") { value.removeFirst(4) }
    if value.hasPrefix("www.") { value.removeFirst(4) }
    if value.hasPrefix("github.com/") { return String(value.dropFirst("github.com/".count)) }
    if value.hasPrefix("github.com:") { return String(value.dropFirst("github.com:".count)) }
    return nil
}

public func isOfficialMarketplaceSourceURL(_ url: String) -> Bool { canonicalGitHubOwnerRepository(url) == "xai-org/plugin-marketplace" }
public func slugifyMarketplaceName(_ name: String) -> String { name.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: "-") }

public struct MarketplaceRef: Hashable, Sendable, Codable, Equatable {
    public var name: String
    public var qualifier: String?
    public init(name: String, qualifier: String? = nil) { self.name = name; self.qualifier = qualifier }
}

public func parseMarketplaceReference(_ argument: String) -> MarketplaceRef? {
    guard !argument.contains("://"), !argument.hasPrefix("git@"), !argument.contains("#"), !argument.hasPrefix("/"), !argument.hasPrefix("\\"), !argument.hasPrefix("."), !argument.hasPrefix("~") else { return nil }
    let bytes = Array(argument.utf8); if bytes.count >= 2, bytes[0].isASCIIAlpha, bytes[1] == 58 { return nil }
    let parts = argument.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    guard let namePart = parts.first, !namePart.isEmpty, !namePart.contains("/"), !namePart.contains("\\") else { return nil }
    let qualifier = parts.count == 2 ? String(parts[1]) : nil
    guard qualifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true else { return nil }
    return MarketplaceRef(name: String(namePart), qualifier: qualifier)
}

public func addressableMarketplaceQualifier(_ source: MarketplaceSource) -> String {
    switch source.kind {
    case let .git(url, _): return canonicalGitHubOwnerRepository(url) ?? "git/\(slugifyMarketplaceName(source.name))"
    case .local: return "local/\(slugifyMarketplaceName(source.name))"
    }
}

public enum QualifierResolutionError: Error, Hashable, Sendable, Codable, Equatable, CustomStringConvertible {
    case unknown
    case ambiguous([Int])
    public var description: String { switch self { case .unknown: return "marketplace qualifier is unknown"; case let .ambiguous(indices): return "marketplace qualifier is ambiguous: \(indices.map(String.init).joined(separator: ", "))" } }
}

public func resolveMarketplaceQualifier(_ qualifier: String, sources: [MarketplaceSource]) -> Result<Int, QualifierResolutionError> {
    let trimmed = qualifier.trimmingCharacters(in: .whitespacesAndNewlines)
    var normalizedValue = trimmed
    if normalizedValue.hasSuffix("/") { normalizedValue.removeLast() }
    if normalizedValue.hasSuffix(".git") { normalizedValue.removeLast(4) }
    let normalized = normalizedValue.lowercased()
    let localSlug = trimmed.hasPrefix("local/") ? String(trimmed.dropFirst("local/".count)) : nil
    let gitSlug = trimmed.hasPrefix("git/") ? String(trimmed.dropFirst("git/".count)) : nil
    let matches = sources.indices.filter { index in
        let source = sources[index]
        let ownerRepo: Bool
        if case let .git(url, _) = source.kind {
            ownerRepo = canonicalGitHubOwnerRepository(url) == normalized
        } else {
            ownerRepo = false
        }
        let local = localSlug.map { slug in
            if case .local = source.kind { return slugifyMarketplaceName(source.name) == slug }
            return false
        } ?? false
        let git = gitSlug.map { slug in
            if case .git = source.kind { return slugifyMarketplaceName(source.name) == slug }
            return false
        } ?? false
        let byName = source.name == qualifier || slugifyMarketplaceName(source.name) == slugifyMarketplaceName(qualifier)
        return ownerRepo || local || git || byName
    }
    switch matches.count { case 0: return .failure(.unknown); case 1: return .success(matches[0]); default: return .failure(.ambiguous(matches)) }
}

public struct BareNameSelection: Hashable, Sendable, Codable, Equatable { public var chosen: Int; public var otherCount: Int; public init(chosen: Int, otherCount: Int) { self.chosen = chosen; self.otherCount = otherCount } }
public enum BareNameError: Error, Hashable, Sendable, Codable, Equatable { case notFound; case ambiguous([Int]) }

public func selectMarketplaceEntry(name: String, scanned: [(source: MarketplaceSource, entry: MarketplaceEntry)]) -> Result<BareNameSelection, BareNameError> {
    let matches = scanned.indices.filter { scanned[$0].entry.name.caseInsensitiveCompare(name) == .orderedSame }
    guard !matches.isEmpty else { return .failure(.notFound) }
    guard matches.count > 1 else { return .success(BareNameSelection(chosen: matches[0], otherCount: 0)) }
    let official = matches.filter { if case let .git(url, _) = scanned[$0].source.kind { return isOfficialMarketplaceSourceURL(url) }; return false }
    guard official.count == 1 else { return .failure(.ambiguous(matches)) }
    return .success(BareNameSelection(chosen: official[0], otherCount: matches.count - 1))
}

public func isFullCommitSHA(_ value: String) -> Bool { (value.count == 40 || value.count == 64) && value.allSatisfy(\.isHexDigit) }

public func validateGitURL(_ value: String) throws -> String { try validateGitOperand(value, kind: "URL") }
public func validateGitReference(_ value: String) throws -> String { try validateGitOperand(value, kind: "ref") }
public func validateGitSHA(_ value: String) throws -> String { let value = value.trimmingCharacters(in: .whitespacesAndNewlines); guard !value.contains("\0"), !value.hasPrefix("-"), isFullCommitSHA(value) else { throw MarketplaceError.invalidGitOperand(kind: "commit SHA", value: value) }; return value }
private func validateGitOperand(_ value: String, kind: String) throws -> String { let value = value.trimmingCharacters(in: .whitespacesAndNewlines); guard !value.isEmpty, !value.contains("\0"), !value.hasPrefix("-") else { throw MarketplaceError.invalidGitOperand(kind: kind, value: value) }; return value }
public func requirePinnedRemote(plugin: String, url: String, sha: String?, requireSHA: Bool) throws { guard requireSHA else { return }; guard let sha, isFullCommitSHA(sha.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw MarketplaceError.unpinnedRemote(plugin: plugin, url: url) } }

public func normalizeMarketplaceRemotePin(ref: String?, sha: String?) throws -> (ref: String?, sha: String?) {
    let normalizedRef = try ref.map(validateGitReference)
    let normalizedSHA = try sha.map(validateGitSHA)
    if normalizedSHA == nil, let normalizedRef, isFullCommitSHA(normalizedRef) {
        return (nil, normalizedRef)
    }
    return (normalizedRef, normalizedSHA)
}

public func verifyMarketplaceIntegrity(expected: String, actual: String) throws {
    let expectedValue = expected.trimmingCharacters(in: .whitespacesAndNewlines)
    let actualValue = actual.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !expectedValue.isEmpty, !actualValue.isEmpty, !expectedValue.contains("\0"), !actualValue.contains("\0") else {
        throw MarketplaceError.integrityMismatch(expected: expectedValue, actual: actualValue)
    }
    guard expectedValue.caseInsensitiveCompare(actualValue) == .orderedSame else {
        throw MarketplaceError.integrityMismatch(expected: expectedValue, actual: actualValue)
    }
}

public struct MarketplaceProvenance: Hashable, Sendable, Codable, Equatable {
    public var sourceURLOrPath: String
    public var sourceDisplayName: String
    public var pluginSubdirectory: String
    public init(sourceURLOrPath: String, sourceDisplayName: String, pluginSubdirectory: String) { self.sourceURLOrPath = sourceURLOrPath; self.sourceDisplayName = sourceDisplayName; self.pluginSubdirectory = pluginSubdirectory }

    private enum CodingKeys: String, CodingKey {
        case sourceURLOrPath = "source_url_or_path"
        case sourceDisplayName = "source_display_name"
        case pluginSubdirectory = "plugin_subdir"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceURLOrPath = try container.decode(String.self, forKey: .sourceURLOrPath)
        sourceDisplayName = try container.decode(String.self, forKey: .sourceDisplayName)
        pluginSubdirectory = try container.decode(String.self, forKey: .pluginSubdirectory)
    }
}

public enum MarketplaceInstallSource: Hashable, Sendable, Codable, Equatable {
    case local(root: String, relativePath: String)
    case remote(url: String, ref: String?, sha: String?, subdirectory: String?)
}

public struct InstalledMarketplacePlugin: Hashable, Sendable, Codable, Equatable {
    public var key: String
    public var name: String
    public var version: String?
    public var path: String
    public var provenance: MarketplaceProvenance
    public var installedAt: String
    public var updatedAt: String
    public init(key: String, name: String, version: String? = nil, path: String, provenance: MarketplaceProvenance, installedAt: String, updatedAt: String) { self.key = key; self.name = name; self.version = version; self.path = path; self.provenance = provenance; self.installedAt = installedAt; self.updatedAt = updatedAt }

    private enum CodingKeys: String, CodingKey { case key, name, version, path, provenance, installedAt = "installed_at", updatedAt = "updated_at" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        path = try container.decode(String.self, forKey: .path)
        provenance = try container.decode(MarketplaceProvenance.self, forKey: .provenance)
        installedAt = try container.decode(String.self, forKey: .installedAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
    }
}

public enum MarketplacePlanOperation: String, Hashable, Sendable, Codable, Equatable { case install, update, remove }

public struct MarketplacePlan: Hashable, Sendable, Codable, Equatable {
    public var operation: MarketplacePlanOperation
    public var pluginName: String
    public var relativePath: String
    public var source: MarketplaceInstallSource?
    public var provenance: MarketplaceProvenance
    public var repositoryKey: String
    public var finalPath: String
    public var stagingPath: String?
    public var backupPath: String?
    public var requiresNetwork: Bool
    public var requiresConfirmation: Bool
    public var keepData: Bool
    public var oldVersion: String?
    public var newVersion: String?
    public init(operation: MarketplacePlanOperation, pluginName: String, relativePath: String, source: MarketplaceInstallSource?, provenance: MarketplaceProvenance, repositoryKey: String, finalPath: String, stagingPath: String?, backupPath: String?, requiresNetwork: Bool, requiresConfirmation: Bool, keepData: Bool, oldVersion: String? = nil, newVersion: String? = nil) { self.operation = operation; self.pluginName = pluginName; self.relativePath = relativePath; self.source = source; self.provenance = provenance; self.repositoryKey = repositoryKey; self.finalPath = finalPath; self.stagingPath = stagingPath; self.backupPath = backupPath; self.requiresNetwork = requiresNetwork; self.requiresConfirmation = requiresConfirmation; self.keepData = keepData; self.oldVersion = oldVersion; self.newVersion = newVersion }
}

public enum MarketplacePlanResult: Hashable, Sendable, Codable, Equatable {
    case planned(MarketplacePlan)
    case alreadyInstalled(InstalledMarketplacePlugin)
}

public func marketplaceInstallDirectory(environment: [String: String] = ProcessInfo.processInfo.environment, homeDirectory: URL? = nil) -> URL {
    let home: URL
    if let override = environment["OPENGROK_HOME"], !override.isEmpty { home = URL(fileURLWithPath: override) }
    else if let homeDirectory { home = homeDirectory.appendingPathComponent(".opengrok", isDirectory: true) }
    else { home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opengrok", isDirectory: true) }
    return home.appendingPathComponent("installed-plugins", isDirectory: true)
}

public func planMarketplaceInstall(root: URL, entry: MarketplaceEntry, provenance: MarketplaceProvenance, installed: [InstalledMarketplacePlugin] = [], requireSHA: Bool = false, environment: [String: String] = ProcessInfo.processInfo.environment, homeDirectory: URL? = nil) throws -> MarketplacePlanResult {
    let normalizedPath = try MarketplaceRelativePath(entry.relativePath).value
    let normalizedProvenance = try MarketplaceRelativePath(provenance.pluginSubdirectory).value
    guard normalizedPath == normalizedProvenance else { throw MarketplaceError.installFailed(detail: "marketplace entry path mismatch: requested \(normalizedProvenance), found \(normalizedPath)") }
    if let existing = installed.first(where: { $0.provenance.sourceURLOrPath == provenance.sourceURLOrPath && $0.provenance.pluginSubdirectory == normalizedProvenance }) { return .alreadyInstalled(existing) }
    let source: MarketplaceInstallSource
    let network: Bool
    switch entry.remoteURL {
    case let .some(url):
        let normalizedURL = try validateGitURL(url)
        let pin = try normalizeMarketplaceRemotePin(ref: entry.remoteRef, sha: entry.remoteSHA)
        try requirePinnedRemote(plugin: entry.name, url: normalizedURL, sha: pin.sha, requireSHA: requireSHA)
        let remoteSubdir = try entry.remoteSubdirectory.map { try MarketplaceRelativePath($0).value }
        source = .remote(url: normalizedURL, ref: pin.ref, sha: pin.sha, subdirectory: remoteSubdir); network = true
    case nil:
        let safeRoot = root.standardizedFileURL.resolvingSymlinksInPath(); _ = try MarketplaceRelativePath(normalizedPath).resolve(under: safeRoot)
        let resolved = try MarketplaceRelativePath(normalizedPath).resolve(under: safeRoot)
        guard isDirectory(resolved) else { throw MarketplaceError.installFailed(detail: "plugin directory not found: \(resolved.path)") }
        source = .local(root: safeRoot.path, relativePath: normalizedPath); network = false
    }
    let key = marketplaceRepositoryKey(source: source, fallbackPluginName: entry.name)
    let installDirectory = marketplaceInstallDirectory(environment: environment, homeDirectory: homeDirectory)
    let final = installDirectory.appendingPathComponent(key, isDirectory: true).path
    return .planned(MarketplacePlan(operation: .install, pluginName: entry.name, relativePath: normalizedPath, source: source, provenance: MarketplaceProvenance(sourceURLOrPath: provenance.sourceURLOrPath, sourceDisplayName: provenance.sourceDisplayName, pluginSubdirectory: normalizedPath), repositoryKey: key, finalPath: final, stagingPath: installDirectory.appendingPathComponent(".staging-\(key)").path, backupPath: nil, requiresNetwork: network, requiresConfirmation: true, keepData: false, newVersion: entry.version))
}

public func planMarketplaceUpdate(root: URL, entry: MarketplaceEntry, provenance: MarketplaceProvenance, installed: [InstalledMarketplacePlugin], requireSHA: Bool = false, environment: [String: String] = ProcessInfo.processInfo.environment, homeDirectory: URL? = nil) throws -> MarketplacePlan {
    let normalizedPath = try MarketplaceRelativePath(entry.relativePath).value
    let normalizedProvenance = try MarketplaceRelativePath(provenance.pluginSubdirectory).value
    guard normalizedPath == normalizedProvenance else { throw MarketplaceError.installFailed(detail: "marketplace entry path mismatch: requested \(normalizedProvenance), found \(normalizedPath)") }
    guard let current = installed.first(where: { $0.provenance.sourceURLOrPath == provenance.sourceURLOrPath && $0.provenance.pluginSubdirectory == normalizedPath }) else { throw MarketplaceError.notInstalled(plugin: entry.name) }
    let installDirectory = marketplaceInstallDirectory(environment: environment, homeDirectory: homeDirectory)
    let safeCurrentPath = try MarketplaceRelativePath(current.key).resolve(under: installDirectory)
    guard safeCurrentPath.path == URL(fileURLWithPath: current.path).standardizedFileURL.path else { throw MarketplaceError.invalidPath(path: current.path, reason: .escapesRoot) }
    let result = try planMarketplaceInstall(root: root, entry: entry, provenance: provenance, installed: [], requireSHA: requireSHA, environment: environment, homeDirectory: homeDirectory)
    guard case let .planned(planned) = result else { throw MarketplaceError.installFailed(detail: "update planning unexpectedly found an existing installation") }
    return MarketplacePlan(operation: .update, pluginName: entry.name, relativePath: planned.relativePath, source: planned.source, provenance: planned.provenance, repositoryKey: current.key, finalPath: current.path, stagingPath: installDirectory.appendingPathComponent(".staging-\(current.key)").path, backupPath: installDirectory.appendingPathComponent(".backup-\(current.key)").path, requiresNetwork: planned.requiresNetwork, requiresConfirmation: true, keepData: false, oldVersion: current.version, newVersion: entry.version)
}

public func planMarketplaceRemove(pluginName: String, provenance: MarketplaceProvenance, installed: [InstalledMarketplacePlugin], keepData: Bool = false, environment: [String: String] = ProcessInfo.processInfo.environment, homeDirectory: URL? = nil) throws -> MarketplacePlan {
    let normalizedPath = try MarketplaceRelativePath(provenance.pluginSubdirectory).value
    guard let current = installed.first(where: { $0.provenance.sourceURLOrPath == provenance.sourceURLOrPath && $0.provenance.pluginSubdirectory == normalizedPath }) else { throw MarketplaceError.notInstalled(plugin: pluginName) }
    let installDirectory = marketplaceInstallDirectory(environment: environment, homeDirectory: homeDirectory)
    let safePath = try MarketplaceRelativePath(current.key).resolve(under: installDirectory)
    guard safePath.path == URL(fileURLWithPath: current.path).standardizedFileURL.path else { throw MarketplaceError.invalidPath(path: current.path, reason: .escapesRoot) }
    let normalizedProvenance = MarketplaceProvenance(sourceURLOrPath: provenance.sourceURLOrPath, sourceDisplayName: provenance.sourceDisplayName, pluginSubdirectory: normalizedPath)
    return MarketplacePlan(operation: .remove, pluginName: pluginName, relativePath: normalizedPath, source: nil, provenance: normalizedProvenance, repositoryKey: current.key, finalPath: current.path, stagingPath: nil, backupPath: nil, requiresNetwork: false, requiresConfirmation: true, keepData: keepData, oldVersion: current.version)
}

public func marketplaceRepositoryKey(source: MarketplaceInstallSource, fallbackPluginName: String = "plugin") -> String {
    let sourceIdentity: String
    switch source {
    case let .local(root, relativePath):
        sourceIdentity = URL(fileURLWithPath: root).appendingPathComponent(relativePath).standardizedFileURL.path
    case let .remote(url, _, _, subdirectory):
        sourceIdentity = url + (subdirectory.map { "#\($0)" } ?? "")
    }
    return stableRepositoryKey(sourceIdentity: sourceIdentity, fallbackPluginName: fallbackPluginName)
}

private func stableRepositoryKey(sourceIdentity: String, fallbackPluginName: String) -> String {
    var basename = sourceIdentity
    while basename.hasSuffix("/") { basename.removeLast() }
    if basename.hasSuffix(".git") { basename.removeLast(4) }
    basename = basename.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? fallbackPluginName
    let sanitized = basename.lowercased().map { character -> Character in
        if character.isASCII && (character.isLetter || character.isNumber || character == "-") { return character }
        return "-"
    }
    let name = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let fallback = slugifyMarketplaceName(fallbackPluginName).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in sourceIdentity.utf8 { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }
    let hash8 = String(format: "%08x", UInt32(truncatingIfNeeded: hash))
    return "\(String((name.isEmpty ? fallback : name).prefix(64)))-\(hash8)"
}

public func loadMarketplaceSources(from text: String, homeDirectory: URL? = nil) -> [MarketplaceSource] {
    var result: [MarketplaceSource] = []
    var current: [String: String] = [:]
    var inSources = false

    func flush() {
        defer { current.removeAll() }
        guard inSources, let name = current["name"] else { return }
        if let git = current["git"] {
            result.append(MarketplaceSource(name: name, kind: .git(url: git, branch: current["branch"])))
        } else if let path = current["path"] {
            result.append(MarketplaceSource(name: name, kind: .local(path: expandTilde(path, homeDirectory: homeDirectory))))
        }
    }

    for rawLine in text.split(whereSeparator: \.isNewline) {
        let line = stripTOMLComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
        if line == "[[marketplace.sources]]" {
            flush()
            inSources = true
            continue
        }
        if line.hasPrefix("[") {
            flush()
            inSources = false
            continue
        }
        guard inSources, let equals = line.firstIndex(of: "=") else { continue }
        let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue = line[line.index(after: equals)...]
        current[String(key)] = parseTOMLString(String(rawValue))
    }
    flush()
    return result
}

public func marketplaceRequireSHA(configurationText: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    var inMarketplace = false
    var configValue = false
    for rawLine in configurationText.split(whereSeparator: \.isNewline) {
        let line = stripTOMLComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("[") {
            inMarketplace = line == "[marketplace]"
            continue
        }
        guard inMarketplace, let equals = line.firstIndex(of: "=") else { continue }
        let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
        guard key == "require_sha" else { continue }
        configValue = parseTOMLString(String(line[line.index(after: equals)...])).lowercased() == "true"
    }
    func enabled(_ key: String) -> Bool { guard let value = environment[key]?.lowercased() else { return false }; return ["1", "true", "yes", "on"].contains(value) }
    return configValue || enabled("OPENGROK_MARKETPLACE_REQUIRE_SHA") || enabled("GROK_MARKETPLACE_REQUIRE_SHA")
}

public func loadExtraMarketplaceSources(existing: [MarketplaceSource], roots: [URL]) -> [MarketplaceSource] {
    var result: [MarketplaceSource] = []; var seen = Set(existing.compactMap { if case let .git(url, _) = $0.kind { return url }; return nil })
    func appendEntries(_ object: [String: JSONValue]) {
        for name in object.keys.sorted() {
            guard let value = object[name] else { continue }
            guard case let .object(entry) = value, case let .object(source)? = entry["source"], case let .string(kind)? = source["source"] else { continue }
            switch kind {
            case "git": guard case let .string(url)? = source["url"], seen.insert(url).inserted else { continue }; result.append(MarketplaceSource(name: name, kind: .git(url: url, branch: nil)))
            case "github": guard case let .string(repo)? = source["repo"] else { continue }; let url = "https://github.com/\(repo).git"; guard seen.insert(url).inserted else { continue }; result.append(MarketplaceSource(name: name, kind: .git(url: url, branch: nil)))
            case "local": guard case let .string(path)? = source["path"] else { continue }; result.append(MarketplaceSource(name: name, kind: .local(path: expandTilde(path, homeDirectory: nil))))
            default: continue
            }
        }
    }
    for root in roots { for filename in ["settings.local.json", "settings.json"] { let path = root.appendingPathComponent(filename); guard let data = try? Data(contentsOf: path), let value = try? JSONDecoder().decode(JSONValue.self, from: data), case let .object(object) = value, case let .object(marketplaces)? = object["extraKnownMarketplaces"] else { continue }; appendEntries(marketplaces) } }
    for root in roots { let path = root.appendingPathComponent("plugins/known_marketplaces.json"); guard let data = try? Data(contentsOf: path), let value = try? JSONDecoder().decode(JSONValue.self, from: data), case let .object(object) = value else { continue }; appendEntries(object) }
    return result
}

private func expandTilde(_ path: String, homeDirectory: URL?) -> String {
    guard path.hasPrefix("~") else { return path }
    let home = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(String(path.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: "/"))).path
}

private func stripTOMLComment(_ value: String) -> String {
    var quote: Character?
    var escaped = false
    var result = ""
    for character in value {
        if quote == "\"" && escaped {
            escaped = false
            result.append(character)
            continue
        }
        if quote == "\"" && character == "\\" {
            escaped = true
            result.append(character)
            continue
        }
        if character == "\"" || character == "'" {
            if quote == nil {
                quote = character
            } else if quote == character {
                quote = nil
            }
            result.append(character)
            continue
        }
        if character == "#" && quote == nil { break }
        result.append(character)
    }
    return result
}

private func parseTOMLString(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2, let first = trimmed.first, let last = trimmed.last, first == last, first == "\"" || first == "'" else {
        return trimmed
    }
    let inner = String(trimmed.dropFirst().dropLast())
    guard first == "\"" else { return inner }
    return inner
        .replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "\\r", with: "\r")
        .replacingOccurrences(of: "\\t", with: "\t")
        .replacingOccurrences(of: "\\\"", with: "\"")
        .replacingOccurrences(of: "\\\\", with: "\\")
}

private func manifestErrorReason(_ error: Error) -> String {
    if let marketplace = error as? MarketplaceError {
        if case let .invalidManifest(_, reason) = marketplace { return reason }
        return marketplace.description
    }
    return "invalid manifest"
}
private func isDirectory(_ url: URL) -> Bool { var isDirectory: ObjCBool = false; return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue }
private func isDirectoryWithContents(_ url: URL) -> Bool { guard isDirectory(url) else { return false }; return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])) ?? []).isEmpty == false }
private struct DynamicCodingKey: CodingKey { let stringValue: String; let intValue: Int? = nil; init(_ string: String) { stringValue = string }; init?(stringValue: String) { self.init(stringValue) }; init?(intValue: Int) { return nil } }
private extension UInt8 { var isASCIIAlpha: Bool { (65...90).contains(self) || (97...122).contains(self) } }
