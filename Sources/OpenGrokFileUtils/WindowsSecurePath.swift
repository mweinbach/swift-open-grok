import Foundation

#if os(Windows)
import WinSDK
#endif

/// Windows extended-length paths must be normalized before Win32 stops applying
/// its ordinary namespace and dot-component protections.
public enum WindowsSecurePath: Sendable {
    public static func extendedLengthPath(_ rawPath: String) throws -> String {
        try PathSecurity.rejectHostileLexical(rawPath)
        let path = rawPath.replacingOccurrences(of: "/", with: "\\")
        let extendedPrefix = "\\\\?\\"
        let extendedUNCPrefix = "\\\\?\\UNC\\"

        if path.hasPrefix("\\\\.\\") || path.hasPrefix("\\??\\") {
            throw hostile(rawPath, reason: "Windows device namespaces are not permitted")
        }

        let uncRemainder: Substring?
        let drivePath: String?
        if String(path.prefix(extendedUNCPrefix.count)).caseInsensitiveCompare(extendedUNCPrefix)
            == .orderedSame
        {
            uncRemainder = path.dropFirst(extendedUNCPrefix.count)
            drivePath = nil
        } else if path.hasPrefix(extendedPrefix) {
            uncRemainder = nil
            drivePath = String(path.dropFirst(extendedPrefix.count))
        } else if path.hasPrefix("\\\\") {
            uncRemainder = path.dropFirst(2)
            drivePath = nil
        } else {
            uncRemainder = nil
            drivePath = path
        }

        if let uncRemainder {
            let components = uncRemainder.split(separator: "\\", omittingEmptySubsequences: true)
            guard components.count >= 2 else {
                throw hostile(rawPath, reason: "UNC paths require a server and share")
            }
            try validate(components, original: rawPath)
            return extendedUNCPrefix + components.joined(separator: "\\")
        }

        guard let drivePath else {
            throw hostile(rawPath, reason: "path is not an absolute Windows drive path")
        }
        let bytes = Array(drivePath.utf8)
        guard bytes.count >= 3,
              (65...90).contains(bytes[0]) || (97...122).contains(bytes[0]),
              bytes[1] == 58,
              bytes[2] == 92
        else {
            throw hostile(rawPath, reason: "path is not an absolute Windows drive path")
        }

        let components = drivePath.dropFirst(3).split(
            separator: "\\",
            omittingEmptySubsequences: true
        )
        try validate(components, original: rawPath)
        return extendedPrefix + String(drivePath.prefix(2)) + "\\"
            + components.joined(separator: "\\")
    }

    private static func validate(_ components: [Substring], original: String) throws {
        let reserved: Set<String> = [
            "CON", "PRN", "AUX", "NUL",
            "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
        ]
        for component in components {
            guard component != ".", component != ".." else {
                throw hostile(original, reason: "Windows path contains a dot or traversal component")
            }
            guard !component.hasSuffix(" "), !component.hasSuffix(".") else {
                throw hostile(original, reason: "Windows path contains an ambiguous trailing character")
            }
            guard !component.unicodeScalars.contains(where: {
                $0.value < 32 || ":<>\"|?*".unicodeScalars.contains($0)
            }) else {
                throw hostile(original, reason: "Windows path contains a reserved or stream character")
            }
            let stem = component.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
            guard !reserved.contains(stem.uppercased()) else {
                throw hostile(original, reason: "Windows path contains a reserved device component")
            }
        }
    }

    private static func hostile(_ path: String, reason: String) -> FileUtilsError {
        .hostilePath(path: path, reason: reason)
    }

    #if os(Windows)
    public struct Metadata: Sendable, Equatable {
        public let isDirectory: Bool
        public let isReparsePoint: Bool
        public let isHidden: Bool
    }

    public static func metadata(at path: URL) throws -> Metadata? {
        let native = try extendedLengthPath(path.path)
        let attributes = native.withCString(encodedAs: UTF16.self) { pointer in
            GetFileAttributesW(pointer)
        }
        if attributes == DWORD(INVALID_FILE_ATTRIBUTES) {
            let code = GetLastError()
            if code == DWORD(ERROR_FILE_NOT_FOUND) || code == DWORD(ERROR_PATH_NOT_FOUND) {
                return nil
            }
            throw windowsError(path: path.path, operation: "inspect extended-length path", code: code)
        }
        return Metadata(
            isDirectory: attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0,
            isReparsePoint: attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0,
            isHidden: attributes & DWORD(FILE_ATTRIBUTE_HIDDEN) != 0
        )
    }

    public static func contentsOfDirectory(
        at directory: URL,
        maximumEntries: Int,
        skipsHiddenFiles: Bool = true
    ) throws -> [URL] {
        guard maximumEntries >= 0 else {
            throw hostile(directory.path, reason: "negative directory-entry bound")
        }
        var native = try extendedLengthPath(directory.path)
        if !native.hasSuffix("\\") { native += "\\" }
        native += "*"

        var found = WIN32_FIND_DATAW()
        let rawHandle = native.withCString(encodedAs: UTF16.self) { pointer in
            FindFirstFileW(pointer, &found)
        }
        guard let handle = rawHandle, handle != INVALID_HANDLE_VALUE else {
            let code = GetLastError()
            if code == DWORD(ERROR_FILE_NOT_FOUND) { return [] }
            throw windowsError(path: directory.path, operation: "enumerate session directory", code: code)
        }
        defer { FindClose(handle) }

        var entries: [URL] = []
        while true {
            let capacity = MemoryLayout.size(ofValue: found.cFileName) / MemoryLayout<UInt16>.stride
            let name = withUnsafePointer(to: &found.cFileName) { storage in
                storage.withMemoryRebound(to: UInt16.self, capacity: capacity) { wide in
                    let units = UnsafeBufferPointer(start: wide, count: capacity)
                    return String(decoding: units.prefix { $0 != 0 }, as: UTF16.self)
                }
            }
            let hidden = found.dwFileAttributes & DWORD(FILE_ATTRIBUTE_HIDDEN) != 0
            if name != ".", name != "..", !(skipsHiddenFiles && hidden) {
                guard entries.count < maximumEntries else {
                    throw FileUtilsError.io(
                        path: directory.path,
                        detail: "directory exceeds its bounded entry count"
                    )
                }
                entries.append(directory.appendingPathComponent(
                    name,
                    isDirectory: found.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
                ))
            }
            guard FindNextFileW(handle, &found) else {
                let code = GetLastError()
                if code == DWORD(ERROR_NO_MORE_FILES) { break }
                throw windowsError(path: directory.path, operation: "enumerate session directory", code: code)
            }
        }
        return entries
    }

    static func windowsError(path: String, operation: String, code: DWORD) -> FileUtilsError {
        if code == DWORD(ERROR_FILE_NOT_FOUND) || code == DWORD(ERROR_PATH_NOT_FOUND) {
            return .notFound(path: path)
        }
        if code == DWORD(ERROR_ACCESS_DENIED) || code == DWORD(ERROR_SHARING_VIOLATION) {
            return .permissionDenied(path: path, detail: "\(operation): Windows error \(code)")
        }
        return .io(path: path, detail: "\(operation): Windows error \(code)")
    }
    #endif
}
