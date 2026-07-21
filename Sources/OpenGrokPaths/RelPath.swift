// RelPath.swift
//
// `RelPath` — a relative UTF-8 path wrapper, porting `RelPathBuf` from
// `xai-grok-paths`. Serializes to/from a JSON string via Codable, mirroring
// the Rust `#[serde(try_from = "String", into = "String")]` behavior: an
// absolute string deserialized into a `RelPath` is rejected.

import Foundation

/// A relative UTF-8 path. Serializes to/from string via Codable.
public struct RelPath: Sendable, Equatable, Hashable, Comparable, CustomStringConvertible, Codable {

    /// The relative path string. Guaranteed relative by the constructor.
    public let path: String

    /// Create from a string. Throws `RelPathError.notRelative` if the path is
    /// absolute.
    public init(_ path: String) throws {
        if isAbsolutePath(path) {
            throw RelPathError.notRelative(input: path)
        }
        self.path = path
    }

    /// Construct from a path that is already known to be relative. Bypasses
    /// validation.
    private init(unchecked path: String) {
        self.path = path
    }

    /// Create by stripping the root prefix. Errors if `absPath` is not under
    /// `root`.
    public static func fromAbsolute(root: String, absPath: String) throws -> RelPath {
        guard pathStartsWith(absPath, prefix: root) else {
            throw RelPathError.notRelative(input: absPath)
        }
        let rootComponents = splitComponents(root)
        let absComponents = splitComponents(absPath)
        let remaining = Array(absComponents.dropFirst(rootComponents.count))
        let joined = joinComponents(remaining)
        // The stripped remainder must not be absolute. `joinComponents` of a
        // proper sub-sequence cannot produce an absolute path, but guard
        // explicitly for parity with Rust.
        if isAbsolutePath(joined) {
            throw RelPathError.notRelative(input: absPath)
        }
        if joined == "." {
            // Rust's `strip_prefix` of the exact root yields `""` (empty),
            // which `RelPathBuf::new` accepts. `joinComponents([])` returns
            // `"."` for display; preserve the empty-string form here.
            return RelPath(unchecked: "")
        }
        return RelPath(unchecked: joined)
    }

    /// Join with root to get an absolute path.
    public func toAbsolute(root: String) -> String {
        if path.isEmpty {
            return root
        }
        return fromRelativePath(root: root, relPath: path)
    }

    /// The path as a string.
    public var asString: String { path }

    /// A relative URL (no scheme) pointing at this path.
    public var fileURL: URL { URL(fileURLWithPath: path, relativeTo: nil) }

    /// `FileManager` path for filesystem probes joined with a root.
    public func fileSystemPath(root: String) -> String { toAbsolute(root: root) }

    public var description: String { path }

    // MARK: Comparable

    public static func < (lhs: RelPath, rhs: RelPath) -> Bool {
        lhs.path < rhs.path
    }

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if isAbsolutePath(raw) {
            throw RelPathError.notRelative(input: raw)
        }
        self.path = raw
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(path)
    }
}

// MARK: - ToAbsPath protocol

/// Convert a path to absolute given a root directory.
///
/// For absolute paths, the `root` is ignored. For relative paths, joins with
/// `root`. Mirrors `xai_grok_paths::ToAbsPath`.
public protocol ToAbsPath {
    func toAbsPath(root: String) -> String
}

extension AbsPath: ToAbsPath {
    public func toAbsPath(root: String) -> String { path }
}

extension RelPath: ToAbsPath {
    public func toAbsPath(root: String) -> String { toAbsolute(root: root) }
}

extension String: ToAbsPath {
    public func toAbsPath(root: String) -> String {
        if isAbsolutePath(self) {
            return self
        }
        return fromRelativePath(root: root, relPath: self)
    }
}

extension Substring: ToAbsPath {
    public func toAbsPath(root: String) -> String {
        String(self).toAbsPath(root: root)
    }
}
