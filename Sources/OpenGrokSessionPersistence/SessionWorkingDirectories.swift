import Foundation
import OpenGrokFileUtils
import OpenGrokPaths

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum SessionWorkingDirectoriesPersistenceError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case insecureStorage(String)
    case invalidDirectory(String)
    case malformedDocument(String)

    public var description: String {
        switch self {
        case .insecureStorage(let path):
            return "working-directory state is not owner-private: \(path)"
        case .invalidDirectory(let path):
            return "working-directory grant is not an existing canonical directory: \(path)"
        case .malformedDocument(let path):
            return "working-directory state is invalid: \(path)"
        }
    }
}

/// Owner-private Rust-compatible session sidecar: a JSON array of absolute paths.
public struct SessionWorkingDirectoriesStore: Sendable {
    public static let fileName = "working_dirs.json"
    public static let maximumDocumentBytes = 1_048_576
    public static let maximumDirectoryCount = 1_024

    public let grokHome: URL
    public let sessionDirectory: URL
    public let workingDirectory: URL

    public init(grokHome: URL, sessionID: String, workingDirectory: URL) throws {
        self.grokHome = grokHome.standardizedFileURL
        self.workingDirectory = workingDirectory.standardizedFileURL
        self.sessionDirectory = try SessionDocumentStore(grokHome: self.grokHome)
            .sessionDirectory(sessionID: sessionID, cwd: self.workingDirectory.path)
        try PathSecurity.rejectHostileLexical(self.grokHome.path)
        try PathSecurity.rejectHostileLexical(self.sessionDirectory.path)
        guard Self.isContained(self.sessionDirectory, below: self.grokHome) else {
            throw SessionWorkingDirectoriesPersistenceError.insecureStorage(
                self.sessionDirectory.path
            )
        }
    }

    public var fileURL: URL {
        sessionDirectory.appendingPathComponent(Self.fileName)
    }

    /// Missing state means an older or newly created session has no grants.
    /// Ambiguous ownership, links, malformed JSON, or stale grants fail closed.
    public func load() throws -> [URL] {
        guard try secureDirectoryChain(create: false) else { return [] }
        guard try secureDocumentExists() else { return [] }
        let data = try PathSecurity.readNoFollow(
            fileURL,
            maximumBytes: Self.maximumDocumentBytes,
            requireOwnerOnly: true
        )

        let paths: [String]
        do {
            paths = try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw SessionWorkingDirectoriesPersistenceError.malformedDocument(fileURL.path)
        }
        guard paths.count <= Self.maximumDirectoryCount else {
            throw SessionWorkingDirectoriesPersistenceError.malformedDocument(fileURL.path)
        }

        let directories = try paths.map { path -> URL in
            guard isAbsolutePath(path) else {
                throw SessionWorkingDirectoriesPersistenceError.invalidDirectory(path)
            }
            return try validatedDirectory(URL(fileURLWithPath: path, isDirectory: true))
        }
        guard Set(directories.map(\.path)).count == directories.count else {
            throw SessionWorkingDirectoriesPersistenceError.malformedDocument(fileURL.path)
        }
        return directories
    }

    /// Replace the complete grant set atomically; never follow a preexisting link.
    public func save(_ directories: [URL]) throws {
        guard directories.count <= Self.maximumDirectoryCount else {
            throw SessionWorkingDirectoriesPersistenceError.malformedDocument(fileURL.path)
        }
        let canonical = try directories.map(validatedDirectory)
        guard Set(canonical.map(\.path)).count == canonical.count else {
            throw SessionWorkingDirectoriesPersistenceError.malformedDocument(fileURL.path)
        }

        _ = try secureDirectoryChain(create: true)
        _ = try secureDocumentExists()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try RelocationFS.writeAtomicDurable(
            path: fileURL,
            data: encoder.encode(canonical.map(\.path)),
            permissions: 0o600,
            stateRoot: grokHome
        )
        guard try secureDocumentExists() else {
            throw SessionWorkingDirectoriesPersistenceError.insecureStorage(fileURL.path)
        }
    }

    private func validatedDirectory(_ directory: URL) throws -> URL {
        let standardized = directory.standardizedFileURL
        let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              standardized.path == canonical.path,
              canonical.path != canonical.deletingLastPathComponent().path,
              canonical.path != workingDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        else {
            throw SessionWorkingDirectoriesPersistenceError.invalidDirectory(directory.path)
        }
        return canonical
    }

    private func secureDirectoryChain(create: Bool) throws -> Bool {
        #if os(Windows)
        if create {
            try RelocationFS.createDirectoryDurable(grokHome, stateRoot: grokHome)
            try RelocationFS.createDirectoryDurable(sessionDirectory, stateRoot: grokHome)
        }
        return try WindowsSessionDirectoryTraversal.directoryExists(
            at: sessionDirectory,
            stateRoot: grokHome
        )
        #else
        var chain: [URL] = []
        var current = sessionDirectory
        while current.path != grokHome.path {
            chain.append(current)
            let parent = current.deletingLastPathComponent()
            guard parent.path.count < current.path.count else {
                throw SessionWorkingDirectoriesPersistenceError.insecureStorage(current.path)
            }
            current = parent
        }
        chain.append(grokHome)

        for directory in chain.reversed() {
            var information = stat()
            if directory.path.withCString({ lstat($0, &information) }) != 0 {
                guard errno == ENOENT else {
                    throw SessionWorkingDirectoriesPersistenceError.insecureStorage(directory.path)
                }
                guard create else { return false }
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                guard directory.path.withCString({ lstat($0, &information) }) == 0 else {
                    throw SessionWorkingDirectoriesPersistenceError.insecureStorage(directory.path)
                }
            }

            guard information.st_uid == geteuid(),
                  information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            else {
                throw SessionWorkingDirectoriesPersistenceError.insecureStorage(directory.path)
            }
            if information.st_mode & 0o777 != 0o700 {
                guard directory.path.withCString({ chmod($0, mode_t(0o700)) }) == 0
                else {
                    throw SessionWorkingDirectoriesPersistenceError.insecureStorage(directory.path)
                }
            }
        }
        return true
        #endif
    }

    private func secureDocumentExists() throws -> Bool {
        #if os(Windows)
        return try WindowsSessionDirectoryTraversal.documentExists(
            at: fileURL,
            stateRoot: grokHome
        )
        #else
        var information = stat()
        if fileURL.path.withCString({ lstat($0, &information) }) != 0 {
            if errno == ENOENT { return false }
            throw SessionWorkingDirectoriesPersistenceError.insecureStorage(fileURL.path)
        }
        guard information.st_uid == geteuid(),
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_mode & 0o777 == 0o600,
              information.st_nlink == 1
        else {
            throw SessionWorkingDirectoriesPersistenceError.insecureStorage(fileURL.path)
        }
        return true
        #endif
    }

    private static func isContained(_ candidate: URL, below root: URL) -> Bool {
        let path = candidate.standardizedFileURL.path
        let boundary = root.standardizedFileURL.path
        return path == boundary || path.hasPrefix(boundary.hasSuffix("/") ? boundary : boundary + "/")
    }
}
