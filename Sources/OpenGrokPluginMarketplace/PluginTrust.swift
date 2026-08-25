// PluginTrust.swift
//
// The SHA-pinning trust model for remote plugin installs, and the git
// operations that enforce it.
//
// This is the only integrity control on remote plugin code. The marketplace
// module already parsed indexes and manifests, but nothing enforced pinning —
// so wiring `plugin install` up without this file would have shipped a weaker
// trust model than the Rust reference, which is why it lands first.
//
// Port of `xai-grok-plugin-marketplace/src/config.rs:33-52` (`load_require_sha`,
// `env_require_sha`) and `xai-grok-agent/src/plugins/git_install.rs:122-206,
// 398-489` (`is_full_commit_sha`, `ensure_pinned`, `hoist_pin_slots`,
// `clone_repo_at_sha`).
//
// Policy summary, which must not drift:
//
//   * Default **off**, so existing unpinned catalogs keep installing.
//   * Enabled by `[marketplace] require_sha = true` **or** either environment
//     variable — a pure OR, never a precedence. This is *tighten-only*: a falsy
//     environment value can never relax a policy the config file set.
//   * When on, a remote source with no full 40/64-hex commit SHA is a **hard
//     failure** for that install. Not a skip, not a warning.
//   * Local directory installs are exempt; there is nothing to pin.

import Foundation
import OpenGrokFileUtils
import OpenGrokShared

// MARK: - Trust policy

public enum PluginTrustPolicy {
    /// Preferred spelling.
    public static let requireSHAEnvironmentVariable = "OPENGROK_MARKETPLACE_REQUIRE_SHA"
    /// Legacy upstream alias, honored with equal weight.
    public static let legacyRequireSHAEnvironmentVariable = "GROK_MARKETPLACE_REQUIRE_SHA"

    /// Whether either environment variable turns pinning on.
    public static func environmentRequiresSHA(_ environment: [String: String]) -> Bool {
        parseBool(environment[requireSHAEnvironmentVariable]) == true
            || parseBool(environment[legacyRequireSHAEnvironmentVariable]) == true
    }

    /// Resolve the effective policy.
    ///
    /// The OR is deliberate. Any source may tighten; none may loosen another.
    /// A falsy environment variable must not be able to switch off a config
    /// file that asked for pinning.
    public static func requireSHA(
        configuredValue: Bool?,
        environment: [String: String]
    ) -> Bool {
        environmentRequiresSHA(environment) || (configuredValue ?? false)
    }

    /// Accepted truthy/falsy spellings, matching `xai_grok_config::env_bool`.
    static func parseBool(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on", "enabled": return true
        case "0", "false", "no", "off", "disabled": return false
        default: return nil
        }
    }
}

// MARK: - SHA validation

public enum PluginPin {
    /// A full commit SHA: exactly 40 (SHA-1) or 64 (SHA-256) hex characters.
    ///
    /// Branches, tags and short prefixes are rejected on purpose — they are
    /// mutable or forgeable, so pinning to one proves nothing about the code
    /// that will actually be checked out.
    public static func isFullCommitSHA(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 40 || trimmed.count == 64 else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 97 && scalar.value <= 102)
                || (scalar.value >= 65 && scalar.value <= 70)
        }
    }

    /// A catalog that publishes its pin in the `ref` slot still gets the
    /// verified path: move a full-hex ref into the sha slot.
    public static func hoistPinSlots(ref: String?, sha: String?) -> (ref: String?, sha: String?) {
        if sha == nil, let ref, isFullCommitSHA(ref) {
            return (nil, ref)
        }
        return (ref, sha)
    }

    /// A ref that is already immutable enough to skip the pin gate on update:
    /// a full SHA, or a version tag like `v1.2.3`.
    public static func isPinnedRef(_ ref: String) -> Bool {
        if isFullCommitSHA(ref) { return true }
        return ref.hasPrefix("v") && ref.contains(".")
    }
}

// MARK: - Errors

public enum PluginInstallError: Error, Sendable, Equatable, CustomStringConvertible {
    case unpinnedRemoteRefused(plugin: String, url: String)
    case shaMismatch(expected: String, actual: String)
    case invalidGitOperand(String)
    case gitFailed(command: String, status: Int32, output: String)
    case notFound(String)
    case ioFailure(String)

    public var description: String {
        switch self {
        case .unpinnedRemoteRefused(let plugin, let url):
            return """
                refusing unpinned remote plugin code for '\(plugin)' from \(url): \
                marketplace.require_sha / OPENGROK_MARKETPLACE_REQUIRE_SHA is enabled and no full \
                commit sha (40/64 hex) is pinned
                """
        case .shaMismatch(let expected, let actual):
            return "git checkout resolved to \(actual) but \(expected) was pinned"
        case .invalidGitOperand(let value):
            return "invalid git operand '\(value)'"
        case .gitFailed(let command, let status, let output):
            return "git \(command) failed (\(status)): \(output)"
        case .notFound(let name):
            return "plugin '\(name)' not found"
        case .ioFailure(let detail):
            return detail
        }
    }
}

// MARK: - The gate

public enum PluginPinGate {
    /// Refuse a remote install that carries no full commit SHA when pinning is
    /// required.
    ///
    /// Call this before any network fetch, not after — the point is that
    /// unpinned code is never downloaded, let alone executed.
    public static func ensurePinned(
        requireSHA: Bool,
        sha: String?,
        plugin: String,
        url: String
    ) throws {
        guard requireSHA else { return }
        if let sha, PluginPin.isFullCommitSHA(sha) { return }
        throw PluginInstallError.unpinnedRemoteRefused(plugin: plugin, url: url)
    }
}

// MARK: - Git operations

/// Fetches plugin repositories with `git`, verifying pins.
public struct PluginGitClient: Sendable {
    public let gitPath: String

    public init(gitPath: String = "/usr/bin/git") {
        self.gitPath = gitPath
    }

    /// Reject operands git would read as options, or that carry a NUL.
    ///
    /// Every free operand goes through this and every invocation terminates its
    /// options with `--`, so a repository URL beginning with `-` can never be
    /// reinterpreted as a flag.
    public static func validateOperand(_ value: String) throws {
        guard !value.isEmpty,
              !value.hasPrefix("-"),
              !value.contains("\0") else {
            throw PluginInstallError.invalidGitOperand(value)
        }
    }

    /// Clone `url` into `destination`, pinned to `sha` when one is given.
    ///
    /// The pinned path does `init` + `fetch --depth 1 <sha>` + `checkout
    /// FETCH_HEAD`, then re-reads `HEAD` and refuses if it is not the SHA that
    /// was asked for. Without that last check a malicious remote could serve
    /// different code than the pin names.
    public func clone(
        url: String,
        destination: URL,
        ref: String?,
        sha: String?
    ) throws {
        try Self.validateOperand(url)
        let (resolvedRef, resolvedSHA) = PluginPin.hoistPinSlots(ref: ref, sha: sha)

        if let resolvedSHA {
            try Self.validateOperand(resolvedSHA)
            guard PluginPin.isFullCommitSHA(resolvedSHA) else {
                throw PluginInstallError.invalidGitOperand(
                    "git commit SHA must be 40 or 64 hexadecimal characters"
                )
            }
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
            try run(["init", "--quiet"], in: destination)
            try run(["remote", "add", "--", "origin", url], in: destination)
            try run(["fetch", "--depth", "1", "--", "origin", resolvedSHA], in: destination)
            try run(["checkout", "--quiet", "FETCH_HEAD"], in: destination)

            let head = try run(["rev-parse", "HEAD"], in: destination)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard head.lowercased() == resolvedSHA.lowercased() else {
                try? FileManager.default.removeItem(at: destination)
                throw PluginInstallError.shaMismatch(expected: resolvedSHA, actual: head)
            }
            return
        }

        var arguments = ["clone", "--depth", "1"]
        if let resolvedRef {
            try Self.validateOperand(resolvedRef)
            arguments.append(contentsOf: ["--branch", resolvedRef])
        }
        arguments.append(contentsOf: ["--", url, destination.path])
        try run(arguments, in: destination.deletingLastPathComponent())
    }

    /// Current `HEAD` of a checkout, or `nil` when it cannot be read.
    public func head(at directory: URL) -> String? {
        try? run(["rev-parse", "HEAD"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func run(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_LFS_SKIP_SMUDGE"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }

        do {
            try process.run()
            try? pipe.fileHandleForWriting.close()
        } catch {
            throw PluginInstallError.gitFailed(
                command: arguments.first ?? "?",
                status: -1,
                output: "\(error)"
            )
        }

        // Install the handler before launch: Process.isRunning can stay stale
        // after a fast failed child exits, making polling consume the full cap.
        if completion.wait(timeout: .now() + 120) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + .milliseconds(200)) == .timedOut {
                #if os(Windows)
                process.terminate()
                #else
                kill(process.processIdentifier, SIGKILL)
                #endif
                _ = completion.wait(timeout: .now() + 1)
            }
            throw PluginInstallError.gitFailed(
                command: arguments.first ?? "?",
                status: -1,
                output: "timed out"
            )
        }

        let output = String(
            decoding: (try? pipe.fileHandleForReading.readToEnd()) ?? Data(),
            as: UTF8.self
        )
        guard process.terminationStatus == 0 else {
            throw PluginInstallError.gitFailed(
                command: arguments.first ?? "?",
                status: process.terminationStatus,
                output: output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return output
    }
}

// MARK: - Install registry

/// Where installed plugins live, and the stable directory key each repo gets.
public struct PluginInstallLocation: Sendable {
    public static let defaultInstallDirectoryName = "installed-plugins"
    public static let registryFileName = "registry.json"

    public let installDirectory: URL

    public init(grokHome: URL, configuredInstallDirectory: URL? = nil) {
        self.installDirectory = configuredInstallDirectory
            ?? grokHome.appendingPathComponent(
                Self.defaultInstallDirectoryName,
                isDirectory: true
            )
    }

    public var registryURL: URL {
        installDirectory.appendingPathComponent(Self.registryFileName)
    }

    /// `<basename>-<first 8 hex of sha256(source id)>`.
    ///
    /// Hashing the source id keeps two different remotes that happen to share a
    /// repository basename in separate directories.
    public static func repoKey(sourceIdentifier: String) -> String {
        let basename = sourceIdentifier
            .split(separator: "/")
            .last
            .map(String.init)?
            .replacingOccurrences(of: ".git", with: "")
            ?? "plugin"
        let digest = FileChecksum.sha256Hex(sourceIdentifier)
        return "\(sanitize(basename))-\(String(digest.prefix(8)))"
    }

    static func sanitize(_ value: String) -> String {
        let allowed = value.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "-"
        }
        let joined = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return joined.isEmpty ? "plugin" : joined
    }

    public func directory(forSourceIdentifier identifier: String) -> URL {
        installDirectory.appendingPathComponent(
            Self.repoKey(sourceIdentifier: identifier),
            isDirectory: true
        )
    }
}

/// Per-plugin metadata retained in Rust's `InstalledRepo.plugins` map.
public struct PluginRepositoryPlugin: Hashable, Sendable, Codable {
    public var subdirectory: String?
    public var version: String?
    public var additionalFields: [String: JSONValue]

    public init(
        subdirectory: String? = nil,
        version: String? = nil,
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.subdirectory = subdirectory
        self.version = version
        self.additionalFields = additionalFields
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard var object = value.objectValue else {
            throw PluginRegistryError.malformed("plugin metadata must be a JSON object")
        }
        subdirectory = try PluginInstallRegistry.optionalString(
            object.removeValue(forKey: "subdir"), field: "plugins.*.subdir"
        )
        version = try PluginInstallRegistry.optionalString(
            object.removeValue(forKey: "version"), field: "plugins.*.version"
        )
        additionalFields = object
    }

    public func encode(to encoder: Encoder) throws {
        var object = additionalFields
        if let subdirectory { object["subdir"] = .string(subdirectory) }
        if let version { object["version"] = .string(version) }
        try JSONValue.object(object).encode(to: encoder)
    }
}

public enum PluginRegistryError: Error, Sendable, Equatable, CustomStringConvertible {
    case malformed(String)
    case unsupportedVersion(Int)
    case injectedSaveFailure

    public var description: String {
        switch self {
        case .malformed(let reason): return "invalid plugin install registry: \(reason)"
        case .unsupportedVersion(let version):
            return "unsupported plugin install registry version \(version)"
        case .injectedSaveFailure: return "test-injected registry save failure"
        }
    }
}

/// One installed plugin repository, preserving Rust's complete registry shape.
public struct PluginInstallRecord: Hashable, Sendable, Codable {
    public var repoKey: String
    public var sourceIdentifier: String
    public var url: String?
    public var path: String?
    public var ref: String?
    public var sha: String?
    public var pluginNames: [String]
    public var enabled: Bool
    public var installedPath: String?
    public var installedAt: String
    public var updatedAt: String
    public var commit: String?
    public var subdirectory: String?
    public var pluginDetails: [String: PluginRepositoryPlugin]
    public var marketplace: MarketplaceProvenance?
    public var additionalFields: [String: JSONValue]
    public var additionalKindFields: [String: JSONValue]
    public var additionalMarketplaceFields: [String: JSONValue]

    public init(
        repoKey: String,
        sourceIdentifier: String,
        url: String? = nil,
        path: String? = nil,
        ref: String? = nil,
        sha: String? = nil,
        pluginNames: [String] = [],
        enabled: Bool = true,
        installedPath: String? = nil,
        installedAt: String? = nil,
        updatedAt: String? = nil,
        commit: String? = nil,
        subdirectory: String? = nil,
        pluginDetails: [String: PluginRepositoryPlugin] = [:],
        marketplace: MarketplaceProvenance? = nil,
        additionalFields: [String: JSONValue] = [:],
        additionalKindFields: [String: JSONValue] = [:],
        additionalMarketplaceFields: [String: JSONValue] = [:]
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        self.repoKey = repoKey
        self.sourceIdentifier = sourceIdentifier
        self.url = url
        self.path = path
        self.ref = ref
        self.sha = sha
        self.pluginNames = pluginNames
        self.enabled = enabled
        self.installedPath = installedPath
        self.installedAt = installedAt ?? timestamp
        self.updatedAt = updatedAt ?? self.installedAt
        self.commit = commit
        self.subdirectory = subdirectory
        var details = pluginDetails
        for name in pluginNames where details[name] == nil {
            details[name] = PluginRepositoryPlugin()
        }
        self.pluginDetails = details
        self.marketplace = marketplace
        self.additionalFields = additionalFields
        self.additionalKindFields = additionalKindFields
        self.additionalMarketplaceFields = additionalMarketplaceFields
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard let object = value.objectValue else {
            throw PluginRegistryError.malformed("repository record must be a JSON object")
        }
        if object["kind"] != nil {
            guard let key = object["repo_key"]?.stringValue else {
                throw PluginRegistryError.malformed("standalone repository is missing repo_key")
            }
            self = try Self.canonical(key: key, object: object)
        } else {
            self = try Self.legacy(object: object)
        }
    }

    public func encode(to encoder: Encoder) throws {
        try JSONValue.object(canonicalObject()).encode(to: encoder)
    }

    static func canonical(key: String, object original: [String: JSONValue]) throws -> Self {
        var object = original
        guard let kindValue = object.removeValue(forKey: "kind"),
              var kind = kindValue.objectValue,
              let type = kind.removeValue(forKey: "type")?.stringValue else {
            throw PluginRegistryError.malformed("repo '\(key)' has no valid installation kind")
        }
        guard let installedPath = object.removeValue(forKey: "path")?.stringValue else {
            throw PluginRegistryError.malformed("repo '\(key)' is missing its installed path")
        }
        guard let installedAt = object.removeValue(forKey: "installed_at")?.stringValue,
              let updatedAt = object.removeValue(forKey: "updated_at")?.stringValue else {
            throw PluginRegistryError.malformed("repo '\(key)' is missing install timestamps")
        }
        guard let pluginObject = object.removeValue(forKey: "plugins")?.objectValue else {
            throw PluginRegistryError.malformed("repo '\(key)' has no plugin map")
        }

        let subdirectory = try PluginInstallRegistry.optionalString(
            kind.removeValue(forKey: "subdir"), field: "repos.\(key).kind.subdir"
        )
        let sourceIdentifier: String
        let url: String?
        let path: String?
        let ref: String?
        let commit: String?
        switch type {
        case "Git":
            guard let gitURL = kind.removeValue(forKey: "url")?.stringValue,
                  let gitCommit = kind.removeValue(forKey: "commit")?.stringValue else {
                throw PluginRegistryError.malformed("Git repo '\(key)' requires url and commit")
            }
            url = gitURL
            path = nil
            ref = try PluginInstallRegistry.optionalString(
                kind.removeValue(forKey: "git_ref"), field: "repos.\(key).kind.git_ref"
            )
            commit = gitCommit
            sourceIdentifier = subdirectory.map { "\(gitURL)#\($0)" } ?? gitURL
        case "Local":
            guard let sourcePath = kind.removeValue(forKey: "source_path")?.stringValue else {
                throw PluginRegistryError.malformed("Local repo '\(key)' requires source_path")
            }
            url = nil
            path = sourcePath
            ref = nil
            commit = nil
            sourceIdentifier = subdirectory.map { "\(sourcePath)#\($0)" } ?? sourcePath
        default:
            throw PluginRegistryError.malformed("repo '\(key)' uses unsupported kind '\(type)'")
        }

        var details: [String: PluginRepositoryPlugin] = [:]
        for (name, plugin) in pluginObject {
            let data = try JSONEncoder().encode(plugin)
            details[name] = try JSONDecoder().decode(PluginRepositoryPlugin.self, from: data)
        }
        let marketplace: MarketplaceProvenance?
        let marketplaceAdditionalFields: [String: JSONValue]
        if let value = object.removeValue(forKey: "marketplace") {
            guard var marketplaceObject = value.objectValue else {
                throw PluginRegistryError.malformed("repo '\(key)' marketplace must be an object")
            }
            marketplace = try JSONDecoder().decode(
                MarketplaceProvenance.self,
                from: JSONEncoder().encode(value)
            )
            marketplaceObject.removeValue(forKey: "source_url_or_path")
            marketplaceObject.removeValue(forKey: "source_display_name")
            marketplaceObject.removeValue(forKey: "plugin_subdir")
            marketplaceAdditionalFields = marketplaceObject
        } else {
            marketplace = nil
            marketplaceAdditionalFields = [:]
        }
        let enabledValue = object.removeValue(forKey: "enabled")
        if let enabledValue, enabledValue.boolValue == nil {
            throw PluginRegistryError.malformed("repo '\(key)' enabled must be a boolean")
        }
        let enabled = enabledValue?.boolValue ?? true

        return self.init(
            repoKey: key,
            sourceIdentifier: sourceIdentifier,
            url: url,
            path: path,
            ref: ref,
            sha: ref.flatMap { PluginPin.isFullCommitSHA($0) ? $0 : nil },
            pluginNames: details.keys.sorted(),
            enabled: enabled,
            installedPath: installedPath,
            installedAt: installedAt,
            updatedAt: updatedAt,
            commit: commit,
            subdirectory: subdirectory,
            pluginDetails: details,
            marketplace: marketplace,
            additionalFields: object,
            additionalKindFields: kind,
            additionalMarketplaceFields: marketplaceAdditionalFields
        )
    }

    static func legacy(object: [String: JSONValue]) throws -> Self {
        guard let key = object["repoKey"]?.stringValue,
              let identifier = object["sourceIdentifier"]?.stringValue else {
            throw PluginRegistryError.malformed("legacy repository requires repoKey and sourceIdentifier")
        }
        guard let namesValue = object["pluginNames"]?.arrayValue else {
            throw PluginRegistryError.malformed("legacy repo '\(key)' requires pluginNames")
        }
        let names = try namesValue.map { value -> String in
            guard let name = value.stringValue else {
                throw PluginRegistryError.malformed("legacy repo '\(key)' has a non-string plugin name")
            }
            return name
        }
        let enabledValue = object["enabled"]
        if let enabledValue, enabledValue.boolValue == nil {
            throw PluginRegistryError.malformed("legacy repo '\(key)' enabled must be a boolean")
        }
        return self.init(
            repoKey: key,
            sourceIdentifier: identifier,
            url: try PluginInstallRegistry.optionalString(object["url"], field: "url"),
            path: try PluginInstallRegistry.optionalString(object["path"], field: "path"),
            ref: try PluginInstallRegistry.optionalString(object["ref"], field: "ref"),
            sha: try PluginInstallRegistry.optionalString(object["sha"], field: "sha"),
            pluginNames: names,
            enabled: enabledValue?.boolValue ?? true
        )
    }

    func canonicalObject() -> [String: JSONValue] {
        var kind = additionalKindFields
        if let url {
            kind["type"] = .string("Git")
            kind["url"] = .string(url)
            kind["commit"] = .string(commit ?? sha ?? "")
            if let ref = ref ?? sha { kind["git_ref"] = .string(ref) }
        } else {
            kind["type"] = .string("Local")
            kind["source_path"] = .string(path ?? sourceIdentifier)
        }
        if let subdirectory { kind["subdir"] = .string(subdirectory) }

        var plugins: [String: JSONValue] = [:]
        for name in Set(pluginNames).union(pluginDetails.keys) {
            let detail = pluginDetails[name] ?? PluginRepositoryPlugin()
            var entry = detail.additionalFields
            if let subdirectory = detail.subdirectory { entry["subdir"] = .string(subdirectory) }
            if let version = detail.version { entry["version"] = .string(version) }
            plugins[name] = .object(entry)
        }

        var object = additionalFields
        object["kind"] = .object(kind)
        object["installed_at"] = .string(installedAt)
        object["updated_at"] = .string(updatedAt)
        object["path"] = .string(installedPath ?? path ?? sourceIdentifier)
        object["plugins"] = .object(plugins)
        if let marketplace {
            var provenance = additionalMarketplaceFields
            provenance["source_url_or_path"] = .string(marketplace.sourceURLOrPath)
            provenance["source_display_name"] = .string(marketplace.sourceDisplayName)
            provenance["plugin_subdir"] = .string(marketplace.pluginSubdirectory)
            object["marketplace"] = .object(provenance)
        }
        if !enabled { object["enabled"] = .bool(false) }
        return object
    }
}

/// Rust-compatible `{ "version": 1, "repos": { ... } }` install registry.
public struct PluginInstallRegistry: Hashable, Sendable, Codable {
    public static let testFailRegistrySaveEnvironmentKey =
        "XAI_GROK_TEST_FAIL_REGISTRY_SAVE_AFTER_SERIALIZE"

    public var repositories: [PluginInstallRecord]
    public var additionalFields: [String: JSONValue]

    public init(
        repositories: [PluginInstallRecord] = [],
        additionalFields: [String: JSONValue] = [:]
    ) {
        self.repositories = repositories
        self.additionalFields = additionalFields
    }

    public static func load(from url: URL) -> PluginInstallRegistry {
        (try? loadOrThrow(from: url)) ?? PluginInstallRegistry()
    }

    /// Missing files are empty; unreadable, malformed, or unknown schemas fail closed.
    public static func loadOrThrow(from url: URL) throws -> PluginInstallRegistry {
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            throw PluginRegistryError.malformed("registry.json must not be a symbolic link")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileReadNoSuchFileError {
                return PluginInstallRegistry()
            }
            throw error
        }
        do {
            return try JSONDecoder().decode(PluginInstallRegistry.self, from: data)
        } catch let error as PluginRegistryError {
            throw error
        } catch {
            throw PluginRegistryError.malformed(error.localizedDescription)
        }
    }

    public func save(
        to url: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var normalized = self
        for index in normalized.repositories.indices
        where normalized.repositories[index].installedPath == nil {
            normalized.repositories[index].installedPath = url
                .deletingLastPathComponent()
                .appendingPathComponent(normalized.repositories[index].repoKey)
                .path
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(normalized)
        if environment[Self.testFailRegistrySaveEnvironmentKey] != nil {
            throw PluginRegistryError.injectedSaveFailure
        }
        // Foundation's `.atomic` writes a sibling then renames over the old
        // file; removing the old registry first creates a crash-visible hole.
        try data.write(to: url, options: .atomic)
    }

    public func record(named name: String) -> PluginInstallRecord? {
        repositories.first { $0.repoKey == name || $0.pluginNames.contains(name) }
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard var object = value.objectValue else {
            throw PluginRegistryError.malformed("registry root must be a JSON object")
        }
        let declaredVersion = object.removeValue(forKey: "version")
        if let version = declaredVersion {
            guard let number = version.int64Value else {
                throw PluginRegistryError.malformed("registry version must be an integer")
            }
            guard number == 1 else {
                throw PluginRegistryError.unsupportedVersion(Int(number))
            }
        }

        if let repos = object.removeValue(forKey: "repos") {
            guard declaredVersion != nil else {
                throw PluginRegistryError.malformed("canonical registry is missing its version")
            }
            guard let map = repos.objectValue else {
                throw PluginRegistryError.malformed("repos must be an object keyed by repository")
            }
            repositories = try map.keys.sorted().map { key in
                guard let record = map[key]?.objectValue else {
                    throw PluginRegistryError.malformed("repo '\(key)' must be a JSON object")
                }
                return try PluginInstallRecord.canonical(key: key, object: record)
            }
            additionalFields = object
            return
        }

        if let legacy = object.removeValue(forKey: "repositories") {
            guard let entries = legacy.arrayValue else {
                throw PluginRegistryError.malformed("legacy repositories must be an array")
            }
            repositories = try entries.map { entry in
                guard let record = entry.objectValue else {
                    throw PluginRegistryError.malformed("legacy repository must be a JSON object")
                }
                return try PluginInstallRecord.legacy(object: record)
            }
            additionalFields = object
            return
        }

        if let marketplace = object.removeValue(forKey: "plugins") {
            guard declaredVersion != nil else {
                throw PluginRegistryError.malformed("legacy marketplace registry is missing its version")
            }
            guard let entries = marketplace.arrayValue else {
                throw PluginRegistryError.malformed("legacy marketplace plugins must be an array")
            }
            repositories = try entries.map { value in
                let plugin = try JSONDecoder().decode(
                    InstalledMarketplacePlugin.self,
                    from: JSONEncoder().encode(value)
                )
                let source = plugin.provenance.sourceURLOrPath
                let remote = source.contains("://") || source.hasPrefix("git@")
                return PluginInstallRecord(
                    repoKey: plugin.key,
                    sourceIdentifier: "\(source)#\(plugin.provenance.pluginSubdirectory)",
                    url: remote ? source : nil,
                    path: remote ? nil : source,
                    pluginNames: [plugin.name],
                    installedPath: plugin.path,
                    installedAt: plugin.installedAt,
                    updatedAt: plugin.updatedAt,
                    commit: remote ? "" : nil,
                    subdirectory: plugin.provenance.pluginSubdirectory,
                    pluginDetails: [
                        plugin.name: PluginRepositoryPlugin(version: plugin.version)
                    ],
                    marketplace: plugin.provenance
                )
            }
            additionalFields = object
            return
        }

        throw PluginRegistryError.malformed("expected canonical repos or a supported legacy registry")
    }

    public func encode(to encoder: Encoder) throws {
        var root = additionalFields
        var repos: [String: JSONValue] = [:]
        for record in repositories {
            guard repos[record.repoKey] == nil else {
                throw PluginRegistryError.malformed("duplicate repository key '\(record.repoKey)'")
            }
            repos[record.repoKey] = .object(record.canonicalObject())
        }
        root["version"] = .number(.int64(1))
        root["repos"] = .object(repos)
        try JSONValue.object(root).encode(to: encoder)
    }

    static func optionalString(_ value: JSONValue?, field: String) throws -> String? {
        guard let value, !value.isNull else { return nil }
        guard let string = value.stringValue else {
            throw PluginRegistryError.malformed("\(field) must be a string")
        }
        return string
    }
}

// MARK: - Source parsing

/// What `plugin install <source>` was pointed at.
public enum PluginInstallSource: Sendable, Equatable {
    case local(path: String, subdirectory: String?)
    case git(url: String, ref: String?, subdirectory: String?)

    /// The stable identity used for the on-disk repo key.
    public var identifier: String {
        switch self {
        case .local(let path, let subdirectory):
            return subdirectory.map { "\(path)#\($0)" } ?? path
        case .git(let url, _, let subdirectory):
            return subdirectory.map { "\(url)#\($0)" } ?? url
        }
    }

    public var isRemote: Bool {
        if case .git = self { return true }
        return false
    }

    /// Parse `owner/repo`, a URL, an `scp`-style git address, or a local path,
    /// each optionally carrying `@ref` and `#subdir`.
    public static func parse(_ raw: String, cwd: URL) -> PluginInstallSource {
        var text = raw.trimmingCharacters(in: .whitespaces)
        var subdirectory: String?
        if let hash = text.lastIndex(of: "#") {
            subdirectory = String(text[text.index(after: hash)...])
            text = String(text[text.startIndex..<hash])
        }

        let looksRemote = text.hasPrefix("http://")
            || text.hasPrefix("https://")
            || text.hasPrefix("file://")
            || text.hasPrefix("git@")
            || text.hasPrefix("ssh://")

        // `@ref` is only meaningful for remotes, and must not eat the `@` in an
        // scp-style address like `git@github.com:owner/repo`.
        var ref: String?
        if looksRemote || !text.hasPrefix(".") {
            if let at = text.lastIndex(of: "@"), at != text.startIndex {
                let candidate = String(text[text.index(after: at)...])
                let prefix = String(text[text.startIndex..<at])
                if !candidate.contains("/"), !candidate.contains(":"), prefix.contains("/") {
                    ref = candidate
                    text = prefix
                }
            }
        }

        if looksRemote {
            return .git(url: text, ref: ref, subdirectory: subdirectory)
        }
        // `owner/repo` shorthand: exactly two segments, neither a path token.
        let segments = text.split(separator: "/", omittingEmptySubsequences: false)
        if segments.count == 2,
           !text.hasPrefix("."),
           !text.hasPrefix("/"),
           !text.hasPrefix("~"),
           segments.allSatisfy({ !$0.isEmpty && $0 != ".." }) {
            return .git(
                url: "https://github.com/\(text).git",
                ref: ref,
                subdirectory: subdirectory
            )
        }

        var path = text
        if path.hasPrefix("~") {
            let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
            path = home + String(path.dropFirst())
        }
        if !path.hasPrefix("/") {
            path = cwd.appendingPathComponent(path).standardizedFileURL.path
        }
        return .local(path: path, subdirectory: subdirectory)
    }
}
