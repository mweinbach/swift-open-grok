// GeneratedManifest.swift
//
// Deterministic manifest describing checked-in generated Open Grok protocol
// fixtures (ACP, tool protocol, sampling types, etc.). The manifest records each
// generated file's path (relative to the package root), byte size, and SHA-256
// digest so that the `OpenGrokProtoBuildPlugin` command plugin and Wave 11
// compatibility tests can prove the checked-in output is fresh without any
// network access or Rust toolchain dependency.

import Foundation

/// A single generated-protocol fixture entry.
public struct GeneratedFixtureEntry: Codable, Equatable, Sendable {
    /// Path relative to the package root, using POSIX forward slashes.
    public var path: String
    /// Recorded byte length of the fixture file.
    public var sizeBytes: Int
    /// Lowercase hex SHA-256 of the fixture file contents.
    public var sha256: String

    public init(path: String, sizeBytes: Int, sha256: String) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
}

/// A deterministic manifest of generated protocol fixtures.
public struct GeneratedManifest: Codable, Equatable, Sendable {
    /// Manifest schema version. Bumped only on incompatible format changes.
    public var version: Int
    /// ISO-8601 date the manifest was regenerated.
    public var generatedAt: String
    /// Open Grok reference revision the fixtures were captured from.
    public var referenceRevision: String
    /// Ordered fixture entries.
    public var files: [GeneratedFixtureEntry]

    public init(version: Int = 1, generatedAt: String, referenceRevision: String, files: [GeneratedFixtureEntry]) {
        self.version = version
        self.generatedAt = generatedAt
        self.referenceRevision = referenceRevision
        self.files = files
    }

    private enum CodingKeys: String, CodingKey {
        case version, generatedAt, referenceRevision, files
    }
}
