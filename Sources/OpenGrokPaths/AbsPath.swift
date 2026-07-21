// AbsPath.swift
//
// `AbsPath` — an absolute UTF-8 path wrapper, porting `AbsPathBuf` from
// `xai-grok-paths`. The Swift value type holds a `String` that is guaranteed
// absolute at construction time. Filesystem probes (`isDir`) defer to
// `FileManager` so the value itself stays pure and Sendable.

import Foundation

/// An absolute UTF-8 path.
public struct AbsPath: Sendable, Equatable, Hashable, Comparable, CustomStringConvertible {

    /// The absolute path string. Guaranteed absolute by the constructor.
    public let path: String

    /// Create from a path string. Throws `AbsPathError.notAbsolute` if the path
    /// is not absolute, or `AbsPathError.notUtf8` if it cannot be represented as
    /// UTF-8 (never happens for Swift `String`).
    public init(_ path: String) throws {
        if !isAbsolutePath(path) {
            throw AbsPathError.notAbsolute(input: path)
        }
        self.path = path
    }

    /// Construct from a path that is already known to be absolute (e.g. the
    /// result of joining two absolute-path components). Bypasses validation.
    private init(unchecked path: String) {
        self.path = path
    }

    /// The path as a string.
    public var asString: String { path }

    /// A `file://` URL pointing at this path.
    public var fileURL: URL { URL(fileURLWithPath: path) }

    /// `FileManager` path for filesystem probes.
    public var fileSystemPath: String { path }

    /// True if the path points at an existing directory.
    public var isDir: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Join with a path component, returning a new `AbsPath`.
    public func join(_ component: String) -> AbsPath {
        #if os(Windows)
        let sep: Character = "\\"
        #else
        let sep: Character = "/"
        #endif
        if path.hasSuffix(String(sep)) {
            return AbsPath(unchecked: path + component)
        }
        return AbsPath(unchecked: path + String(sep) + component)
    }

    /// Check if `self` contains `candidate` (normalizing `.`/`..` in the
    /// candidate only, exactly like `AbsPathBuf::contains_path`).
    public func containsPath(_ candidate: AbsPath) -> Bool {
        let normalizedCandidate = normalizeLexically(candidate.path)
        return pathStartsWith(normalizedCandidate, prefix: self.path)
    }

    public var description: String { path }

    // MARK: Comparable

    public static func < (lhs: AbsPath, rhs: AbsPath) -> Bool {
        lhs.path < rhs.path
    }
}
