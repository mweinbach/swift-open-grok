// Profiles.swift
//
// Sandbox profile resolution. Built-ins: workspace, devbox, read-only, strict,
// off. Custom profiles via `$OPENGROK_HOME/sandbox.toml` or
// `.opengrok/sandbox.toml`. Ported from `xai-grok-sandbox/src/profiles.rs`.

import Foundation
import OpenGrokConfig
import OpenGrokPaths

// MARK: - Config shapes

/// Per-profile TOML configuration.
public struct ProfileConfig: Sendable, Equatable, Hashable {
    public var extends: String?
    public var restrictNetwork: Bool?
    public var readOnly: [String]
    public var readWrite: [String]
    public var deny: [String]

    public init(
        extends: String? = nil,
        restrictNetwork: Bool? = nil,
        readOnly: [String] = [],
        readWrite: [String] = [],
        deny: [String] = []
    ) {
        self.extends = extends
        self.restrictNetwork = restrictNetwork
        self.readOnly = readOnly
        self.readWrite = readWrite
        self.deny = deny
    }
}

/// Loaded sandbox configuration (global + project, merged additively).
public struct SandboxConfig: Sendable, Equatable {
    public var profiles: [String: ProfileConfig]

    public init(profiles: [String: ProfileConfig] = [:]) {
        self.profiles = profiles
    }
}

/// A resolved sandbox profile ready for platform enforcement.
public struct ResolvedSandboxProfile: Sendable, Equatable {
    public var name: String
    public var readOnly: [URL]
    public var readWrite: [URL]
    public var deny: [URL]
    /// Exact deny strings (may include globs for Seatbelt regex expansion).
    public var denyEntries: [String]
    public var defaultRead: Bool
    public var restrictNetwork: Bool

    public init(
        name: String,
        readOnly: [URL],
        readWrite: [URL],
        deny: [URL],
        denyEntries: [String] = [],
        defaultRead: Bool,
        restrictNetwork: Bool
    ) {
        self.name = name
        self.readOnly = readOnly
        self.readWrite = readWrite
        self.deny = deny
        self.denyEntries = denyEntries
        self.defaultRead = defaultRead
        self.restrictNetwork = restrictNetwork
    }
}

/// Built-in and custom profile names.
public enum ProfileName: Sendable, Equatable, Hashable, CustomStringConvertible {
    case workspace
    case devbox
    case readOnly
    case strict
    case off
    case custom(String)

    public var description: String {
        switch self {
        case .workspace: return "workspace"
        case .devbox: return "devbox"
        case .readOnly: return "read-only"
        case .strict: return "strict"
        case .off: return "off"
        case .custom(let name): return name
        }
    }

    public var restrictsNetwork: Bool {
        switch self {
        case .readOnly, .strict: return true
        default: return false
        }
    }

    public init(parsing raw: String) {
        switch raw {
        case "workspace": self = .workspace
        case "devbox": self = .devbox
        case "read-only", "readonly": self = .readOnly
        case "strict": self = .strict
        case "off", "none": self = .off
        default: self = .custom(raw)
        }
    }

    /// Resolve into a fully-specified profile for logging and enforcement.
    public func resolve(
        workspace: URL,
        config: SandboxConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ResolvedSandboxProfile {
        switch self {
        case .off:
            throw SandboxError.profileInvalid(
                "sandbox profile 'off' cannot be resolved as a base profile; choose workspace, devbox, read-only, or strict"
            )

        case .workspace:
            return ResolvedSandboxProfile(
                name: "workspace",
                readOnly: [],
                readWrite: essentialWritablePaths(workspace: workspace, environment: environment),
                deny: [],
                defaultRead: true,
                restrictNetwork: false
            )

        case .devbox:
            // Everything under `/` top-level dirs except `/data`, plus workspace.
            var readWrite: [URL] = [workspace]
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: "/"),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                let exclude: Set<String> = ["/data", "/proc", "/sys", "/dev"]
                for entry in entries {
                    if exclude.contains(entry.path) { continue }
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir),
                       isDir.boolValue
                    {
                        readWrite.append(entry)
                    }
                }
            }
            return ResolvedSandboxProfile(
                name: "devbox",
                readOnly: [],
                readWrite: readWrite,
                deny: [],
                defaultRead: true,
                restrictNetwork: false
            )

        case .readOnly:
            return ResolvedSandboxProfile(
                name: "read-only",
                readOnly: [],
                readWrite: essentialWritablePathsMinimal(environment: environment),
                deny: [],
                defaultRead: true,
                restrictNetwork: true
            )

        case .strict:
            let home = OpenGrokStatePaths.userHomeDirectory(environment: environment)
            let systemReadCandidates = [
                "/usr", "/lib", "/lib64", "/bin", "/sbin", "/etc", "/dev", "/proc", "/sys",
                "/tmp", "/run", "/var",
                "/System", "/Library", "/private",
            ]
            var systemRead: [URL] = []
            for p in systemReadCandidates {
                let url = URL(fileURLWithPath: p)
                if FileManager.default.fileExists(atPath: url.path) {
                    systemRead.append(url)
                }
            }
            let library = home.appendingPathComponent("Library")
            if FileManager.default.fileExists(atPath: library.path) {
                systemRead.append(library)
            }
            systemRead.append(workspace)
            return ResolvedSandboxProfile(
                name: "strict",
                readOnly: systemRead,
                readWrite: essentialWritablePaths(workspace: workspace, environment: environment),
                deny: [],
                defaultRead: false,
                restrictNetwork: true
            )

        case .custom(let name):
            guard let profileConfig = config.profiles[name] else {
                throw SandboxError.profileInvalid(
                    "Custom sandbox profile '\(name)' not found. Define it in $OPENGROK_HOME/sandbox.toml or .opengrok/sandbox.toml"
                )
            }
            let base: ProfileName
            if let baseName = profileConfig.extends {
                base = ProfileName(parsing: baseName)
                if case .off = base {
                    throw SandboxError.profileInvalid(
                        "Profile '\(name)' extends '\(baseName)', but 'off'/'none' is not a valid base profile"
                    )
                }
                if case .custom = base {
                    throw SandboxError.profileInvalid(
                        "Profile '\(name)' extends '\(baseName)', but custom profiles cannot extend other custom profiles"
                    )
                }
            } else {
                base = .workspace
            }
            var profile = try base.resolve(workspace: workspace, config: config, environment: environment)
            profile.name = name
            if let rn = profileConfig.restrictNetwork {
                profile.restrictNetwork = rn
            }
            for pathStr in profileConfig.readOnly {
                profile.readOnly.append(URL(fileURLWithPath: pathStr, relativeTo: workspace))
            }
            for pathStr in profileConfig.readWrite {
                profile.readWrite.append(URL(fileURLWithPath: pathStr, relativeTo: workspace))
            }
            var denyURLs: [URL] = []
            for entry in profileConfig.deny {
                profile.denyEntries.append(entry)
                // Exact (non-glob) paths resolve relative to workspace.
                if !entry.contains("*") && !entry.contains("?") {
                    let url: URL
                    if entry.hasPrefix("/") {
                        url = URL(fileURLWithPath: entry)
                    } else {
                        url = workspace.appendingPathComponent(entry)
                    }
                    denyURLs.append(url)
                }
            }
            profile.deny = denyURLs
            return profile
        }
    }
}

// MARK: - Config load / merge

/// Load sandbox config from `$OPENGROK_HOME/sandbox.toml` and project
/// `.opengrok/sandbox.toml`. Project may only **add** new profile names.
public func loadSandboxConfig(
    workspace: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> SandboxConfig {
    var config = SandboxConfig()
    let globalPath = sandboxGrokHome(environment: environment).appendingPathComponent("sandbox.toml")
    if let global = loadSandboxConfigFile(globalPath) {
        config = global
    }
    let projectPath = workspace
        .appendingPathComponent(".opengrok")
        .appendingPathComponent("sandbox.toml")
    if let project = loadSandboxConfigFile(projectPath) {
        mergeProjectProfiles(into: &config, project: project)
    }
    return config
}

/// Names of project custom profiles that conflict with global definitions.
public func mismatchedProfileNames(global: SandboxConfig, project: SandboxConfig) -> [String] {
    var names: [String] = []
    for (name, projectProfile) in project.profiles {
        if case .custom = ProfileName(parsing: name),
           let globalProfile = global.profiles[name],
           globalProfile != projectProfile
        {
            names.append(name)
        }
    }
    return names.sorted()
}

/// Warn (via returned messages) when project redefines a user custom profile.
public func sandboxProfileConflictWarnings(
    workspace: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> [String] {
    let globalPath = sandboxGrokHome(environment: environment).appendingPathComponent("sandbox.toml")
    let projectPath = workspace
        .appendingPathComponent(".opengrok")
        .appendingPathComponent("sandbox.toml")
    let global = loadSandboxConfigFile(globalPath) ?? SandboxConfig()
    let project = loadSandboxConfigFile(projectPath) ?? SandboxConfig()
    return mismatchedProfileNames(global: global, project: project).map { name in
        "warning: project sandbox profile '\(name)' in '\(projectPath.path)' conflicts with a different user profile in '\(globalPath.path)'; the project definition is ignored"
    }
}

func mergeProjectProfiles(into config: inout SandboxConfig, project: SandboxConfig) {
    for (name, profile) in project.profiles {
        if config.profiles[name] == nil {
            config.profiles[name] = profile
        }
    }
}

func loadSandboxConfigFile(_ path: URL) -> SandboxConfig? {
    guard let content = try? String(contentsOf: path, encoding: .utf8) else { return nil }
    guard let root = try? parseTOML(content) else { return nil }
    guard case .table(let table) = root else { return nil }
    var profiles: [String: ProfileConfig] = [:]
    if case .table(let profilesTable)? = table["profiles"] {
        for (name, value) in profilesTable.pairs {
            guard case .table(let pt) = value else { continue }
            var pc = ProfileConfig()
            if case .string(let e)? = pt["extends"] { pc.extends = e }
            if case .boolean(let b)? = pt["restrict_network"] { pc.restrictNetwork = b }
            pc.readOnly = stringArray(pt["read_only"])
            pc.readWrite = stringArray(pt["read_write"])
            pc.deny = stringArray(pt["deny"])
            profiles[name] = pc
        }
    }
    return SandboxConfig(profiles: profiles)
}

private func stringArray(_ value: TOMLValue?) -> [String] {
    guard case .array(let arr)? = value else { return [] }
    return arr.compactMap { v in
        if case .string(let s) = v { return s }
        return nil
    }
}

/// Whether kernel read-deny enforcement is required for this profile.
public func requiresReadDeny(profile: ProfileName, workspace: URL, config: SandboxConfig? = nil) -> Bool {
    switch profile {
    case .custom(let name):
        let cfg = config ?? loadSandboxConfig(workspace: workspace)
        guard let p = cfg.profiles[name] else { return false }
        return !p.deny.isEmpty
    default:
        return false
    }
}

/// Whether a profile is devbox or extends devbox (write-denies `/data` via bwrap).
public func isDevboxBased(profile: ProfileName, config: SandboxConfig) -> Bool {
    switch profile {
    case .devbox: return true
    case .custom(let name):
        return config.profiles[name]?.extends == "devbox"
    default: return false
    }
}
