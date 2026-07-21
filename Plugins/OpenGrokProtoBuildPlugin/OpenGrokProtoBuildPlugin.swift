// OpenGrokProtoBuildPlugin.swift
//
// Open Grok build support command plugin (W0-S1).
//
// Read-only, sandboxed, network-free validation of the checked-in generated
// protocol fixture manifest. It recomputes each fixture file's byte size and
// SHA-256 and compares against `ProtocolFixtures/manifest.json`, failing when
// checked-in output is stale, missing, or unexpected, or when the manifest
// itself is missing. This is the SwiftPM command-plugin equivalent of the
// Rust `xai-proto-build` freshness check.
//
// Regeneration of the manifest is performed by the separate, deterministic
// `scripts/regenerate-protocol-manifest.sh` helper so that this command never
// needs write access and runs frictionlessly in CI.
//
// Path isolation: every manifest entry path must be a normalized relative
// path rooted exactly under `ProtocolFixtures`. Absolute paths, traversal
// components (`..`), and symlink escapes are rejected before any file is
// hashed, so a hostile or corrupt manifest cannot make this command read
// outside `ProtocolFixtures`.
//
// Command plugins compile in an isolated sandbox and cannot import package
// library targets, so SHA-256 is reimplemented in `SHA256.swift` within this
// plugin target (algorithmically identical to OpenGrokBuildSupport.SHA256).
//
// Usage:
//   swift package ogrok-validate-protocols

import Foundation
import PackagePlugin

@main
struct OpenGrokProtoBuildPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let packageRoot = context.package.directory.string
        let fixturesDir = "\(packageRoot)/ProtocolFixtures"
        let manifestPath = "\(fixturesDir)/manifest.json"
        let fm = FileManager.default

        if !arguments.isEmpty {
            throw CLIError.unknownArgument(arguments.joined(separator: " "))
        }

        // A missing manifest is a validation failure, not a silent success:
        // the checked-in freshness metadata is the contract this command
        // exists to enforce. Returning exit 0 would mask a broken bootstrap
        // and let stale fixtures ship.
        guard fm.fileExists(atPath: manifestPath) else {
            throw CLIError.manifestMissing(manifestPath)
        }

        // Resolve the fixtures directory to a canonical absolute URL once,
        // then verify every manifest entry resolves under it. This is the
        // path-isolation boundary: a hostile or corrupt manifest cannot
        // make us hash or read outside `ProtocolFixtures`.
        let fixturesRootURL = URL(fileURLWithPath: fixturesDir).standardizedFileURL
        // If the fixtures directory itself is a symlink, resolve it.
        let resolvedFixturesRoot = try resolveSymlinkIfPossible(at: fixturesRootURL)

        let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        var failures: [String] = []
        var seen: Set<String> = []
        for entry in manifest.files {
            seen.insert(entry.path)
            // Path containment: reject absolute paths, traversal components,
            // and any entry that resolves outside `ProtocolFixtures`.
            do {
                try validateContainedRelativePath(entry.path, root: resolvedFixturesRoot, kind: "manifest entry")
            } catch let CLIError.pathEscape(path, reason) {
                failures.append("path escape: \(path) (\(reason))")
                continue
            }
            let abs = packageRoot + "/" + entry.path
            // Re-resolve the absolute path through realpath so symlinks
            // cannot escape the fixtures root.
            let resolvedAbs = try resolveSymlinkIfPossible(at: URL(fileURLWithPath: abs))
            guard isUnder(resolvedAbs, root: resolvedFixturesRoot) else {
                failures.append("path escape: \(entry.path) (resolved outside ProtocolFixtures)")
                continue
            }
            guard fm.fileExists(atPath: abs) else {
                failures.append("missing: \(entry.path)")
                continue
            }
            let fileData = try Data(contentsOf: URL(fileURLWithPath: abs))
            if fileData.count != entry.sizeBytes {
                failures.append("size mismatch: \(entry.path) expected \(entry.sizeBytes) actual \(fileData.count)")
            }
            let digest = PluginSHA256.hexDigest(fileData)
            if digest != entry.sha256 {
                failures.append("digest mismatch: \(entry.path) expected \(entry.sha256) actual \(digest)")
            }
        }
        if let contents = try? fm.contentsOfDirectory(atPath: fixturesDir) {
            for name in contents where name != "manifest.json" {
                let rel = "ProtocolFixtures/\(name)"
                if !seen.contains(rel) {
                    failures.append("unexpected: \(rel)")
                }
            }
        }
        if failures.isEmpty {
            print("Protocol fixtures are fresh.")
        } else {
            for f in failures { print("error: \(f)") }
            throw CLIError.stale(failures)
        }
    }

    // MARK: - Path containment helpers

    /// Resolve `url` through symlink resolution so symlink escapes are
    /// detectable. Uses `URL.resolvingSymlinksInPath()`, which resolves
    /// symlinks for paths that exist on disk. For non-existent paths the
    /// URL is returned standardized (no symlink resolution possible), so
    /// the caller can still report a deterministic missing-file failure
    /// rather than crashing.
    private func resolveSymlinkIfPossible(at url: URL) throws -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Returns `true` when `candidate` is `root` or lives under `root`.
    /// Both URLs must be resolved (standardized + symlinks resolved) before
    /// this comparison.
    private func isUnder(_ candidate: URL, root: URL) -> Bool {
        let c = candidate.standardizedFileURL.path
        let r = root.standardizedFileURL.path
        if c == r { return true }
        return c.hasPrefix(r + "/")
    }

    /// Validate that `path` is a normalized relative path rooted exactly
    /// under the fixtures directory: no leading `/`, no `..` traversal
    /// components, and no absolute or Windows-drive form. Throws
    /// `CLIError.pathEscape` with a human-readable reason on rejection.
    ///
    /// This is the syntactic check; `isUnder` performs the resolved-path
    /// containment check that catches symlink escapes.
    private func validateContainedRelativePath(_ path: String, root: URL, kind: String) throws {
        if path.isEmpty {
            throw CLIError.pathEscape(path, "empty \(kind) path")
        }
        // Reject absolute POSIX paths.
        if path.hasPrefix("/") {
            throw CLIError.pathEscape(path, "absolute \(kind) path")
        }
        // Reject Windows drive-letter forms (e.g. C:\ or C:/).
        if path.contains(":\\") || path.contains(":/") {
            throw CLIError.pathEscape(path, "absolute Windows \(kind) path")
        }
        // Reject any `..` traversal component. Splitting on `/` and checking
        // each component catches both `../NOTICE` and
        // `ProtocolFixtures/../../outside`.
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        for comp in components {
            if comp == ".." {
                throw CLIError.pathEscape(path, "traversal component in \(kind) path")
            }
            if comp == "." {
                throw CLIError.pathEscape(path, "redundant `.` component in \(kind) path")
            }
        }
        // Require the path to begin with `ProtocolFixtures/` so it is
        // rooted exactly under the fixtures directory. The library
        // validator and the manifest generator both use this convention.
        if !path.hasPrefix("ProtocolFixtures/") {
            throw CLIError.pathEscape(path, "\(kind) path not rooted under ProtocolFixtures")
        }
    }
}

// Manifest model mirroring OpenGrokBuildSupport.GeneratedManifest.
private struct Manifest: Codable {
    let version: Int
    let generatedAt: String
    let referenceRevision: String
    let files: [ManifestEntry]
}

private struct ManifestEntry: Codable {
    let path: String
    let sizeBytes: Int
    let sha256: String
}

private enum CLIError: Error {
    case unknownArgument(String)
    case manifestMissing(String)
    case stale([String])
    case pathEscape(String, String)
}
