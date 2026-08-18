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
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw PluginInstallError.gitFailed(
                command: arguments.first ?? "?",
                status: -1,
                output: "\(error)"
            )
        }

        // Bounded wait so a git process prompting for credentials on a
        // non-interactive terminal cannot hang the CLI forever.
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                #if os(Windows)
                process.terminate()
                #else
                kill(process.processIdentifier, SIGKILL)
                #endif
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

/// One installed plugin repository.
public struct PluginInstallRecord: Hashable, Sendable, Codable {
    public var repoKey: String
    public var sourceIdentifier: String
    public var url: String?
    public var path: String?
    public var ref: String?
    public var sha: String?
    public var pluginNames: [String]
    public var enabled: Bool

    public init(
        repoKey: String,
        sourceIdentifier: String,
        url: String? = nil,
        path: String? = nil,
        ref: String? = nil,
        sha: String? = nil,
        pluginNames: [String] = [],
        enabled: Bool = true
    ) {
        self.repoKey = repoKey
        self.sourceIdentifier = sourceIdentifier
        self.url = url
        self.path = path
        self.ref = ref
        self.sha = sha
        self.pluginNames = pluginNames
        self.enabled = enabled
    }
}

/// The on-disk `registry.json`.
public struct PluginInstallRegistry: Hashable, Sendable, Codable {
    public var repositories: [PluginInstallRecord]

    public init(repositories: [PluginInstallRecord] = []) {
        self.repositories = repositories
    }

    public static func load(from url: URL) -> PluginInstallRegistry {
        guard let data = try? Data(contentsOf: url),
              let registry = try? JSONDecoder().decode(PluginInstallRegistry.self, from: data)
        else { return PluginInstallRegistry() }
        return registry
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Write-then-rename so a crash mid-save cannot leave a truncated
        // registry that would orphan every installed plugin.
        let temporary = url.appendingPathExtension("tmp")
        try encoder.encode(self).write(to: temporary, options: .atomic)
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporary, to: url)
    }

    public func record(named name: String) -> PluginInstallRecord? {
        repositories.first { $0.repoKey == name || $0.pluginNames.contains(name) }
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
