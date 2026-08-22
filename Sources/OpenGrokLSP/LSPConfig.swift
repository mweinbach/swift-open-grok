import Foundation
import OpenGrokShared

public struct LspServerConfig: Codable, Sendable, Equatable {
    public var command: String
    public var args: [String]
    public var env: [String: String]
    public var extensions: [String: String]
    public var workspaceFolder: String?
    public var startupTimeoutMs: UInt64?
    public var shutdownTimeoutMs: UInt64?

    public init(
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        extensions: [String: String] = [:],
        workspaceFolder: String? = nil,
        startupTimeoutMs: UInt64? = nil,
        shutdownTimeoutMs: UInt64? = nil
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.extensions = extensions
        self.workspaceFolder = workspaceFolder
        self.startupTimeoutMs = startupTimeoutMs
        self.shutdownTimeoutMs = shutdownTimeoutMs
    }

    enum CodingKeys: String, CodingKey {
        case command
        case args
        case env
        case extensions
        case extensionToLanguage
        case extensionToLanguageId
        case workspaceFolder
        case startupTimeout
        case shutdownTimeout
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        if let mapped = try container.decodeIfPresent([String: String].self, forKey: .extensions) {
            extensions = mapped
        } else if let mapped = try container.decodeIfPresent([String: String].self, forKey: .extensionToLanguage) {
            extensions = mapped
        } else if let mapped = try container.decodeIfPresent([String: String].self, forKey: .extensionToLanguageId) {
            extensions = mapped
        } else {
            extensions = [:]
        }
        workspaceFolder = try container.decodeIfPresent(String.self, forKey: .workspaceFolder)
        startupTimeoutMs = try container.decodeIfPresent(UInt64.self, forKey: .startupTimeout)
        shutdownTimeoutMs = try container.decodeIfPresent(UInt64.self, forKey: .shutdownTimeout)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(command, forKey: .command)
        try container.encode(args, forKey: .args)
        try container.encode(env, forKey: .env)
        try container.encode(extensions, forKey: .extensions)
        try container.encodeIfPresent(workspaceFolder, forKey: .workspaceFolder)
        try container.encodeIfPresent(startupTimeoutMs, forKey: .startupTimeout)
        try container.encodeIfPresent(shutdownTimeoutMs, forKey: .shutdownTimeout)
    }

    public func effectiveRoot(workspaceRoot: String) -> String {
        if let workspaceFolder, !workspaceFolder.isEmpty {
            if workspaceFolder.hasPrefix("/") {
                return URL(fileURLWithPath: workspaceFolder).standardizedFileURL.path
            }
            return URL(
                fileURLWithPath: workspaceFolder,
                relativeTo: URL(fileURLWithPath: workspaceRoot)
            ).standardizedFileURL.path
        }
        return workspaceRoot
    }
}

public enum LSPServerConfigSource: Sendable, Equatable {
    case user
    case project
}

public struct SourcedLSPServerConfig: Sendable, Equatable {
    public let configuration: LspServerConfig
    public let source: LSPServerConfigSource

    public init(configuration: LspServerConfig, source: LSPServerConfigSource) {
        self.configuration = configuration
        self.source = source
    }
}

public enum LSPConfigLoader {
    /// A context-free merge cannot authorize repository-owned commands. Keep
    /// this compatibility overload for already-trusted callers; executable
    /// composition must use the workspace-aware, fail-closed overload below.
    public static func loadMerged(
        userConfigPath: URL?,
        projectConfigPath: URL?
    ) -> [String: LspServerConfig] {
        var servers: [String: LspServerConfig] = [:]
        if let userConfigPath {
            for (name, config) in loadFile(at: userConfigPath) {
                servers[name] = config
            }
        }
        if let projectConfigPath {
            for (name, config) in loadFile(at: projectConfigPath) {
                servers[name] = config
            }
        }
        return servers
    }

    /// Merge only the sources authorized for this exact canonical workspace.
    /// Project configuration is denied until the caller supplies its resolved
    /// folder-trust verdict; owner configuration remains available meanwhile.
    public static func loadMerged(
        userConfigPath: URL?,
        projectConfigPath: URL?,
        workspaceRoot: URL,
        projectTrusted: Bool = false
    ) -> [String: LspServerConfig] {
        filterProjectServers(
            loadSourced(
                userConfigPath: userConfigPath,
                projectConfigPath: projectConfigPath,
                workspaceRoot: workspaceRoot,
                projectTrusted: projectTrusted
            ),
            projectTrusted: projectTrusted
        )
    }

    /// Preserve source provenance so a repository-owned file cannot become a
    /// trusted owner config merely by being passed through another pathname.
    public static func loadSourced(
        userConfigPath: URL?,
        projectConfigPath: URL?,
        workspaceRoot: URL,
        projectTrusted: Bool = false
    ) -> [String: SourcedLSPServerConfig] {
        guard workspaceRoot.isFileURL else { return [:] }
        let canonicalWorkspace = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        var servers: [String: SourcedLSPServerConfig] = [:]

        if let userConfigPath,
           let canonicalUserConfig = canonicalFileURL(userConfigPath) {
            let source: LSPServerConfigSource = contains(
                canonicalUserConfig,
                inside: canonicalWorkspace
            ) ? .project : .user
            if source == .user || projectTrusted {
                for (name, configuration) in loadFile(at: canonicalUserConfig) {
                    servers[name] = SourcedLSPServerConfig(
                        configuration: configuration,
                        source: source
                    )
                }
            }
        }

        guard projectTrusted,
              let projectConfigPath,
              let canonicalProjectConfig = canonicalFileURL(projectConfigPath),
              contains(canonicalProjectConfig, inside: canonicalWorkspace)
        else {
            return servers
        }

        for (name, configuration) in loadFile(at: canonicalProjectConfig) {
            servers[name] = SourcedLSPServerConfig(
                configuration: configuration,
                source: .project
            )
        }
        return servers
    }

    public static func filterProjectServers(
        _ sourced: [String: SourcedLSPServerConfig],
        projectTrusted: Bool = false
    ) -> [String: LspServerConfig] {
        sourced.reduce(into: [:]) { accepted, entry in
            guard projectTrusted || entry.value.source != .project else { return }
            accepted[entry.key] = entry.value.configuration
        }
    }

    public static func loadFile(at url: URL) -> [String: LspServerConfig] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let decoded = try? JSONDecoder().decode([String: LspServerConfig].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func canonicalFileURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func contains(_ candidate: URL, inside root: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let rootComponents = root.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }

        return zip(rootComponents, candidateComponents).allSatisfy { root, candidate in
            #if os(Windows)
            return root.caseInsensitiveCompare(candidate) == .orderedSame
            #else
            return root == candidate
            #endif
        }
    }

    /// Resolve which configured server handles a file path by extension.
    public static func resolveServer(
        for path: String,
        servers: [String: LspServerConfig]
    ) -> (name: String, config: LspServerConfig, languageID: String)? {
        let ext = URL(fileURLWithPath: path).pathExtension
        guard !ext.isEmpty else { return nil }
        let dotExt = ".\(ext)"
        for (name, config) in servers.sorted(by: { $0.key < $1.key }) {
            if let languageID = config.extensions[dotExt] {
                return (name, config, languageID)
            }
        }
        return nil
    }
}
