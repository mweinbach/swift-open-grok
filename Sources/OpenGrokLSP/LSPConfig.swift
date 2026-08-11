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

public enum LSPConfigLoader {
    /// Load and merge user + project `lsp.json` files. Project wins on name collision.
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

    public static func loadFile(at url: URL) -> [String: LspServerConfig] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let decoded = try? JSONDecoder().decode([String: LspServerConfig].self, from: data) else {
            return [:]
        }
        return decoded
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
