// OpenGrokPaths.swift
//
// Open Grok — Swift port of `xai-grok-paths`.
//
// Type-safe path wrappers for absolute and relative UTF-8 paths, plus the
// lexical normalization helpers used by the workspace, file-utils, and
// session-persistence targets.
//
// The Swift port preserves the Rust invariants:
//   * `AbsPath` only ever holds an absolute, UTF-8 path string.
//   * `RelPath` only ever holds a relative, UTF-8 path string and serializes
//     to/from a JSON string via Codable.
//   * `normalizeLexically` resolves `.` and `..` components without touching
//     the filesystem, matching `std::path::Component` semantics on Unix and
//     Windows (prefix/root preservation, `..` after root is dropped, etc.).
//   * `containsPath` normalizes only the *candidate* and checks component-aware
//     `starts_with` against the (un-normalized) stored root, exactly like the
//     Rust `AbsPathBuf::contains_path`.
//
// No slice other than W0-S3 may edit this directory.

import Foundation

// MARK: - Errors

/// Error returned when creating an `AbsPath` from an invalid path.
public enum AbsPathError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The path was not absolute.
    case notAbsolute(input: String)
    /// The path was not valid UTF-8.
    ///
    /// Foundation `String` is always UTF-8; this case is preserved for API
    /// parity with the Rust crate and is never produced in practice on
    /// Swift-supported platforms.
    case notUtf8(path: String)

    public var description: String {
        switch self {
        case .notAbsolute(let input):
            return "Path is not absolute: \(input)"
        case .notUtf8(let path):
            return "Path is not valid UTF-8: \(path)"
        }
    }
}

/// Error returned when creating a `RelPath` from an invalid path.
public enum RelPathError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The path was not relative.
    case notRelative(input: String)
    /// The path was not valid UTF-8.
    case notUtf8(path: String)

    public var description: String {
        switch self {
        case .notRelative(let input):
            return "Path is not relative: \(input)"
        case .notUtf8(let path):
            return "Path is not valid UTF-8: \(path)"
        }
    }
}

// MARK: - Path component model

/// A single lexical path component, mirroring `std::path::Component`.
public enum PathComponent: Sendable, Equatable, Hashable {
    /// A Windows path prefix such as `C:`, `\\server\share`, or `\\?\C:`.
    ///
    /// On non-Windows platforms this case is never produced by
    /// `splitComponents` but remains representable so cross-platform test
    /// fixtures can exercise the same logic.
    case prefix(String)
    /// The root separator: `/` on Unix, `\` (after a prefix) on Windows.
    case root
    /// The `.` component.
    case curDir
    /// The `..` component.
    case parentDir
    /// Any other component.
    case normal(String)
}

// MARK: - Platform absoluteness

/// Cross-platform absolute-path check that matches `std::path::Path::is_absolute`.
///
/// On Unix a path is absolute iff it begins with `/`. On Windows a path is
/// absolute iff it is drive-absolute (`C:\` or `C:/`), UNC (`\\server\share` or
/// `//server/share`), or a verbatim/device path (`\\?\`, `\\.\`). A drive-
/// relative path like `C:foo` is NOT absolute.
@inlinable
public func isAbsolutePath(_ path: String) -> Bool {
    #if os(Windows)
    if path.hasPrefix("\\\\?\\") || path.hasPrefix("\\\\.\\") {
        // Verbatim/device paths are absolute; require a separator after the
        // marker so `\\?\C:` alone (no root) is treated as drive-relative.
        // `\\?\C:\` and `\\?\UNC\server\share` are absolute.
        let after = path.dropFirst(4)
        if after.hasPrefix("UNC\\") || after.hasPrefix("UNC/") { return true }
        return windowsHasDriveRoot(String(after))
    }
    if path.hasPrefix("\\\\") || path.hasPrefix("//") {
        // UNC: \\server\share — absolute once a share component follows.
        let after = path.dropFirst(2)
        return after.contains("\\") || after.contains("/")
    }
    return windowsHasDriveRoot(path)
    #else
    return path.hasPrefix("/")
    #endif
}

#if os(Windows)
@inlinable
internal func windowsHasDriveRoot(_ path: String) -> Bool {
    let scalars = Array(path.unicodeScalars)
    guard scalars.count >= 3 else { return false }
    let first = scalars[0]
    let isLetter = (first >= Unicode.Scalar("a") && first <= Unicode.Scalar("z"))
        || (first >= Unicode.Scalar("A") && first <= Unicode.Scalar("Z"))
    let second = scalars[1]
    let third = scalars[2]
    return isLetter && second == ":" && (third == "\\" || third == "/")
}
#endif

// MARK: - Component splitting

/// Split `path` into lexical components, mirroring `std::path::Path::components`.
///
/// Consecutive separators collapse into a single root/separator boundary,
/// matching Rust's behavior. A trailing separator does not produce a trailing
/// empty component.
public func splitComponents(_ path: String) -> [PathComponent] {
    var components: [PathComponent] = []
    var index = path.startIndex

    #if os(Windows)
    if let prefix = windowsPrefix(path) {
        components.append(.prefix(prefix.string))
        index = prefix.nextIndex
    }
    #endif

    let isSep: (Character) -> Bool = { ch in
        #if os(Windows)
        return ch == "/" || ch == "\\"
        #else
        return ch == "/"
        #endif
    }

    // Leading separator → root.
    if index < path.endIndex && isSep(path[index]) {
        components.append(.root)
        index = path.index(after: index)
        while index < path.endIndex && isSep(path[index]) {
            index = path.index(after: index)
        }
    }

    var current = ""
    while index < path.endIndex {
        let ch = path[index]
        if isSep(ch) {
            if !current.isEmpty {
                components.append(PathComponent.from(current))
                current = ""
            }
            index = path.index(after: index)
            while index < path.endIndex && isSep(path[index]) {
                index = path.index(after: index)
            }
        } else {
            current.append(ch)
            index = path.index(after: index)
        }
    }
    if !current.isEmpty {
        components.append(PathComponent.from(current))
    }
    return components
}

extension PathComponent {
    @inlinable
    static func from(_ s: String) -> PathComponent {
        if s == "." { return .curDir }
        if s == ".." { return .parentDir }
        return .normal(s)
    }
}

#if os(Windows)
internal struct WindowsPrefix {
    let string: String
    let nextIndex: String.Index
}

internal func windowsPrefix(_ path: String) -> WindowsPrefix? {
    // Verbatim: \\?\C:\ or \\?\UNC\server\share
    if path.hasPrefix("\\\\?\\") {
        let after = path.dropFirst(4)
        // \\?\UNC\server\share — prefix is \\?\UNC\server\share (share included)
        if after.hasPrefix("UNC\\") || after.hasPrefix("UNC/") {
            // Take UNC\server\share — first two components after UNC.
            let remainder = after.dropFirst(4)
            if let firstSep = remainder.firstIndex(where: { $0 == "\\" || $0 == "/" }) {
                let afterServer = remainder.index(after: firstSep)
                if let secondSep = remainder[afterServer...].firstIndex(where: { $0 == "\\" || $0 == "/" }) {
                    let prefixEnd = remainder.index(after: secondSep)
                    let prefixString = "\\\\?\\UNC\\" + String(remainder[..<prefixEnd])
                    // Convert dropFirst offset back to original index.
                    let endInOriginal = path.index(path.startIndex, offsetBy: 8 + distance(from: remainder.startIndex, to: prefixEnd))
                    return WindowsPrefix(string: prefixString, nextIndex: endInOriginal)
                }
            }
            // Fall through: no share, treat the whole thing as the prefix.
            return WindowsPrefix(string: String(path), nextIndex: path.endIndex)
        }
        // \\?\C:\ — prefix is \\?\C:
        let scalars = Array(after.unicodeScalars)
        if scalars.count >= 2 {
            let first = scalars[0]
            let isLetter = (first >= Unicode.Scalar("a") && first <= Unicode.Scalar("z"))
                || (first >= Unicode.Scalar("A") && first <= Unicode.Scalar("Z"))
            if isLetter && scalars[1] == ":" {
                let prefixEnd = path.index(path.startIndex, offsetBy: 6) // "\\\\?\C:"
                return WindowsPrefix(string: String(path[path.startIndex..<prefixEnd]), nextIndex: prefixEnd)
            }
        }
        return WindowsPrefix(string: String(path), nextIndex: path.endIndex)
    }
    // Device: \\.\COM1
    if path.hasPrefix("\\\\.\\") {
        let after = path.dropFirst(4)
        if let sep = after.firstIndex(where: { $0 == "\\" || $0 == "/" }) {
            let prefixEnd = path.index(path.startIndex, offsetBy: 4 + distance(from: after.startIndex, to: sep))
            return WindowsPrefix(string: String(path[path.startIndex..<prefixEnd]), nextIndex: prefixEnd)
        }
        return WindowsPrefix(string: String(path), nextIndex: path.endIndex)
    }
    // UNC: \\server\share — prefix is \\server\share
    if path.hasPrefix("\\\\") || path.hasPrefix("//") {
        let leading = String(path.prefix(2))
        let after = path.dropFirst(2)
        if let firstSep = after.firstIndex(where: { $0 == "\\" || $0 == "/" }) {
            let afterServer = after.index(after: firstSep)
            if let secondSep = after[afterServer...].firstIndex(where: { $0 == "\\" || $0 == "/" }) {
                let shareEnd = after.index(after: secondSep)
                let prefixString = leading + String(after[..<shareEnd])
                let endInOriginal = path.index(path.startIndex, offsetBy: 2 + distance(from: after.startIndex, to: shareEnd))
                return WindowsPrefix(string: prefixString, nextIndex: endInOriginal)
            }
        }
        return WindowsPrefix(string: String(path), nextIndex: path.endIndex)
    }
    // Disk: C:
    let scalars = Array(path.unicodeScalars)
    if scalars.count >= 2 {
        let first = scalars[0]
        let isLetter = (first >= Unicode.Scalar("a") && first <= Unicode.Scalar("z"))
            || (first >= Unicode.Scalar("A") && first <= Unicode.Scalar("Z"))
        if isLetter && scalars[1] == ":" {
            let prefixEnd = path.index(path.startIndex, offsetBy: 2)
            return WindowsPrefix(string: String(path[path.startIndex..<prefixEnd]), nextIndex: prefixEnd)
        }
    }
    return nil
}

@inlinable
internal func distance(from start: String.Index, to end: String.Index) -> Int {
    return start.distance(to: end)
}
#endif

// MARK: - Lexical normalization

/// Resolve `.` and `..` components without touching the filesystem.
///
/// Use only for lexical display or containment. If `b` is a symlink,
/// normalizing `a/b/../c` can name a different filesystem target than the OS
/// would resolve from the original spelling. Filesystem consumers must preserve
/// the original path or deliberately canonicalize it before use.
///
/// Matches `xai_grok_paths::normalize_lexically`:
///   * `.` is dropped.
///   * `..` after a `normal` component pops the normal component.
///   * `..` after a root (or, on Windows, after a prefix with no root) is dropped.
///   * `..` after another `..` (with no preceding normal/root) is preserved.
///   * If the result has no components, returns `"."`.
public func normalizeLexically(_ path: String) -> String {
    var components: [PathComponent] = []
    for component in splitComponents(path) {
        switch component {
        case .curDir:
            continue
        case .parentDir:
            if let last = components.last {
                switch last {
                case .normal:
                    components.removeLast()
                case .root:
                    continue
                case .prefix:
                    // A prefix without a following root (e.g. `C:` with no `\`)
                    // is drive-relative; `..` is preserved.
                    components.append(.parentDir)
                case .curDir, .parentDir:
                    components.append(.parentDir)
                }
            } else {
                components.append(.parentDir)
            }
        case .prefix, .root, .normal:
            components.append(component)
        }
    }
    if components.isEmpty {
        return "."
    }
    return joinComponents(components)
}

/// Join a sequence of `PathComponent`s back into a path string using the
/// platform separator. Prefix and root components are emitted without a
/// leading separator; subsequent components are joined by the separator.
public func joinComponents(_ components: [PathComponent]) -> String {
    if components.isEmpty {
        return "."
    }

    #if os(Windows)
    let sep: Character = "\\"
    #else
    let sep: Character = "/"
    #endif

    var result = ""
    var justHadRootOrPrefix = false
    for component in components {
        switch component {
        case .prefix(let p):
            result += p
            justHadRootOrPrefix = true
        case .root:
            result += String(sep)
            justHadRootOrPrefix = true
        case .curDir:
            if !result.isEmpty && !justHadRootOrPrefix {
                result += String(sep)
            }
            result += "."
            justHadRootOrPrefix = false
        case .parentDir:
            if !result.isEmpty && !justHadRootOrPrefix {
                result += String(sep)
            }
            result += ".."
            justHadRootOrPrefix = false
        case .normal(let s):
            if !result.isEmpty && !justHadRootOrPrefix {
                result += String(sep)
            }
            result += s
            justHadRootOrPrefix = false
        }
    }
    return result
}

/// Component-aware `starts_with` matching `std::path::Path::starts_with`.
///
/// Returns `true` iff `prefix`'s components are a leading subsequence of
/// `path`'s components, comparing each component (prefix, root, normal, etc.)
/// for equality.
public func pathStartsWith(_ path: String, prefix: String) -> Bool {
    let pathComponents = splitComponents(path)
    let prefixComponents = splitComponents(prefix)
    if prefixComponents.count > pathComponents.count {
        return false
    }
    for i in 0..<prefixComponents.count {
        if pathComponents[i] != prefixComponents[i] {
            return false
        }
    }
    return true
}

// MARK: - Relative/absolute conversion helpers

/// Convert an absolute path to relative by stripping the root prefix.
///
/// Returns the path unchanged if not under `root`. For strict validation, use
/// `RelPath.fromAbsolute(root:absPath:)` instead.
public func toRelativePath(root: String, absPath: String) -> String {
    if pathStartsWith(absPath, prefix: root) {
        let rootComponents = splitComponents(root)
        let absComponents = splitComponents(absPath)
        let remaining = Array(absComponents.dropFirst(rootComponents.count))
        if remaining.isEmpty {
            // Rust's `strip_prefix` of the exact root yields an empty PathBuf.
            return ""
        }
        return joinComponents(remaining)
    }
    return absPath
}

/// Convert a relative path to absolute by joining with root.
public func fromRelativePath(root: String, relPath: String) -> String {
    if isAbsolutePath(relPath) {
        return relPath
    }
    #if os(Windows)
    let sep: Character = "\\"
    #else
    let sep: Character = "/"
    #endif
    if root.hasSuffix(String(sep)) {
        return root + relPath
    }
    return root + String(sep) + relPath
}
