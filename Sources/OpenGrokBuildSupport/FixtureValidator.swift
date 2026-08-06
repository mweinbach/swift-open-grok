// FixtureValidator.swift
//
// Deterministic validation of checked-in generated protocol fixtures. The
// validator recomputes each fixture file's byte size and SHA-256 and compares
// against a `GeneratedManifest`. It performs no I/O outside the package
// directory and no network access, satisfying the W0-S1 acceptance that a
// deterministic generation plugin can fail when checked-in output is stale.
//
// Path isolation: every manifest entry path must be a normalized relative
// path rooted exactly under `ProtocolFixtures`. Absolute paths, traversal
// components (`..`), and symlink escapes are rejected before any file is
// hashed, so a hostile or corrupt manifest cannot make this validator read
// outside `ProtocolFixtures`. This mirrors the same path-isolation contract
// enforced by `OpenGrokProtoBuildPlugin`.

import Foundation

/// Result of validating a generated-fixture manifest against the filesystem.
public enum FixtureValidationResult: Sendable, Equatable {
    /// All recorded fixtures match their on-disk files.
    case fresh
    /// One or more fixtures are stale, missing, or unexpected.
    case stale([FixtureValidationIssue])
}

/// A single discrepancy found during fixture validation.
public enum FixtureValidationIssue: Sendable, Equatable {
    case missing(path: String)
    case sizeMismatch(path: String, expected: Int, actual: Int)
    case digestMismatch(path: String, expected: String, actual: String)
    /// A file present on disk but absent from the manifest.
    case unexpected(path: String)
    /// A manifest entry path that escapes `ProtocolFixtures` (absolute,
    /// traversal, or symlink escape). The validator refuses to read such
    /// paths, preserving package/path isolation.
    case pathEscape(path: String, reason: String)
    /// The manifest and provenance index name different reference revisions.
    case referenceRevisionMismatch(expected: String, actual: String)
    /// The provenance index is missing from the fixture corpus.
    case provenanceMissing(path: String)
    /// The provenance index cannot be decoded or has no reference revision.
    case provenanceMalformed(path: String)
}

/// Errors raised by manifest path containment validation.
public enum FixturePathError: Error, Equatable, Sendable {
    /// The path is empty.
    case empty
    /// The path is absolute (POSIX or Windows drive form).
    case absolute(String)
    /// The path contains a `..` traversal component.
    case traversal(String)
    /// The path contains a redundant `.` component.
    case dotComponent(String)
    /// The path is not rooted under `ProtocolFixtures`.
    case notRootedUnderFixtures(String)
    /// The resolved path escapes the resolved `ProtocolFixtures` directory
    /// (symlink escape).
    case escape(String, String)
}

/// Deterministic generated-fixture validator.
public enum FixtureValidator {
    /// Validate `manifest` against the files rooted at `packageRoot`.
    ///
    /// - Parameters:
    ///   - manifest: The recorded manifest to check against.
    ///   - packageRoot: Absolute URL of the package root that fixture paths
    ///     are relative to.
    ///   - allowUnexpectedFiles: When `true`, files present on disk but absent
    ///     from the manifest are tolerated (useful during bootstrap before a
    ///     fixture directory is fully populated). Defaults to `false`.
    public static func validate(
        manifest: GeneratedManifest,
        packageRoot: URL,
        allowUnexpectedFiles: Bool = false
    ) -> FixtureValidationResult {
        var issues: [FixtureValidationIssue] = []
        var seen: Set<String> = []
        let provenanceURL = packageRoot.appendingPathComponent("ProtocolFixtures/PROVENANCE.json")
        if !FileManager.default.fileExists(atPath: provenanceURL.path) {
            issues.append(.provenanceMissing(path: "ProtocolFixtures/PROVENANCE.json"))
        } else if let provenanceData = try? Data(contentsOf: provenanceURL),
                  let provenance = try? JSONDecoder().decode(FixtureProvenance.self, from: provenanceData) {
            if provenance.referenceRevision != manifest.referenceRevision {
                issues.append(.referenceRevisionMismatch(
                    expected: manifest.referenceRevision,
                    actual: provenance.referenceRevision
                ))
            }
        } else {
            issues.append(.provenanceMalformed(path: "ProtocolFixtures/PROVENANCE.json"))
        }
        // Resolve the fixtures root once and reuse it for every entry, so a
        // hostile or corrupt manifest cannot make us hash or read outside
        // `ProtocolFixtures`.
        let fixturesRoot = packageRoot.appendingPathComponent("ProtocolFixtures")
        let resolvedFixturesRoot = fixturesRoot.resolvingSymlinksInPath().standardizedFileURL
        for entry in manifest.files {
            seen.insert(entry.path)
            // Path containment: reject absolute paths, traversal components,
            // and any entry that resolves outside `ProtocolFixtures`.
            do {
                try validateContainedFixturePath(entry.path, packageRoot: packageRoot, resolvedFixturesRoot: resolvedFixturesRoot)
            } catch FixturePathError.absolute {
                issues.append(.pathEscape(path: entry.path, reason: "absolute path"))
                continue
            } catch FixturePathError.traversal {
                issues.append(.pathEscape(path: entry.path, reason: "traversal component"))
                continue
            } catch FixturePathError.dotComponent {
                issues.append(.pathEscape(path: entry.path, reason: "redundant `.` component"))
                continue
            } catch FixturePathError.notRootedUnderFixtures {
                issues.append(.pathEscape(path: entry.path, reason: "path not rooted under ProtocolFixtures"))
                continue
            } catch FixturePathError.escape {
                issues.append(.pathEscape(path: entry.path, reason: "resolved outside ProtocolFixtures"))
                continue
            } catch FixturePathError.empty {
                issues.append(.pathEscape(path: entry.path, reason: "empty path"))
                continue
            } catch {
                issues.append(.pathEscape(path: entry.path, reason: "path validation failed: \(error)"))
                continue
            }
            let url = packageRoot.appendingPathComponent(entry.path)
            // Re-resolve the absolute path through symlink resolution so
            // symlinks cannot escape the fixtures root.
            let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
            guard isUnder(resolvedURL, root: resolvedFixturesRoot) else {
                issues.append(.pathEscape(path: entry.path, reason: "resolved outside ProtocolFixtures"))
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                issues.append(.missing(path: entry.path))
                continue
            }
            let actualSize = data.count
            if actualSize != entry.sizeBytes {
                issues.append(.sizeMismatch(path: entry.path, expected: entry.sizeBytes, actual: actualSize))
            }
            let actualDigest = SHA256.hexDigest(Array(data))
            if actualDigest != entry.sha256 {
                issues.append(.digestMismatch(path: entry.path, expected: entry.sha256, actual: actualDigest))
            }
        }
        if !allowUnexpectedFiles {
            // Detect files in the ProtocolFixtures directory not listed in the manifest.
            let fixturesDir = packageRoot.appendingPathComponent("ProtocolFixtures")
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: fixturesDir,
                includingPropertiesForKeys: nil
            ) {
                for url in contents where url.lastPathComponent != "manifest.json" {
                    let rel = "ProtocolFixtures/\(url.lastPathComponent)"
                    if !seen.contains(rel) {
                        issues.append(.unexpected(path: rel))
                    }
                }
            }
        }
        return issues.isEmpty ? .fresh : .stale(issues)
    }

    /// Build a fresh `GeneratedManifest` entry for a single file at `url`,
    /// with its path expressed relative to `packageRoot`.
    public static func entry(for url: URL, relativeTo packageRoot: URL) -> GeneratedFixtureEntry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let absPath = url.path
        let rootPath = packageRoot.path
        let rel: String
        if absPath.hasPrefix(rootPath + "/") {
            rel = String(absPath.dropFirst(rootPath.count + 1))
        } else {
            rel = url.lastPathComponent
        }
        return GeneratedFixtureEntry(
            path: rel,
            sizeBytes: data.count,
            sha256: SHA256.hexDigest(Array(data))
        )
    }

    // MARK: - Path containment helpers

    /// Validate that `path` is a normalized relative path rooted exactly
    /// under `ProtocolFixtures`: no leading `/`, no `..` traversal
    /// components, no absolute or Windows-drive form, and the resolved
    /// path must remain under `resolvedFixturesRoot`. Throws
    /// `FixturePathError` on rejection.
    ///
    /// This is the syntactic + resolved-path check that catches both
    /// manifest-level path-injection (e.g. `../NOTICE`) and symlink escapes
    /// (e.g. `ProtocolFixtures/secret` where `secret` is a symlink to
    /// `/etc/passwd`).
    public static func validateContainedFixturePath(
        _ path: String,
        packageRoot: URL,
        resolvedFixturesRoot: URL
    ) throws {
        if path.isEmpty {
            throw FixturePathError.empty
        }
        // Reject absolute POSIX paths.
        if path.hasPrefix("/") {
            throw FixturePathError.absolute(path)
        }
        // Reject Windows drive-letter forms (e.g. C:\ or C:/).
        if path.contains(":\\") || path.contains(":/") {
            throw FixturePathError.absolute(path)
        }
        // Reject any `..` traversal component and redundant `.` components.
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        for comp in components {
            if comp == ".." {
                throw FixturePathError.traversal(path)
            }
            if comp == "." {
                throw FixturePathError.dotComponent(path)
            }
        }
        // Require the path to begin with `ProtocolFixtures/` so it is
        // rooted exactly under the fixtures directory, matching the
        // manifest generator and the plugin.
        if !path.hasPrefix("ProtocolFixtures/") {
            throw FixturePathError.notRootedUnderFixtures(path)
        }
        // Resolve the absolute path through symlink resolution and verify
        // it stays under `resolvedFixturesRoot`. This catches symlink
        // escapes that the syntactic checks above cannot.
        let absURL = packageRoot.appendingPathComponent(path)
        let resolved = absURL.resolvingSymlinksInPath().standardizedFileURL
        if !isUnder(resolved, root: resolvedFixturesRoot) {
            throw FixturePathError.escape(path, resolved.path)
        }
    }

    /// Returns `true` when `candidate` is `root` or lives under `root`.
    /// Both URLs must be resolved (standardized + symlinks resolved) before
    /// this comparison.
    public static func isUnder(_ candidate: URL, root: URL) -> Bool {
        let c = candidate.standardizedFileURL.path
        let r = root.standardizedFileURL.path
        if c == r { return true }
        return c.hasPrefix(r + "/")
    }
}

private struct FixtureProvenance: Decodable {
    let referenceRevision: String
}
