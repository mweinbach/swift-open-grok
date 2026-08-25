import Foundation
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokPaths

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct MemoryStorage: Equatable, Sendable {
    public let globalDir: URL
    public let workspaceDir: URL
    public let workspacePath: URL
    public let isEphemeral: Bool

    public init(
        cwd: URL,
        rootOverride: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workspaceIdentity: String? = nil
    ) {
        self.init(
            cwd: cwd,
            globalDir: rootOverride ?? OpenGrokStatePaths.stateDirectory(environment: environment)
                .appendingPathComponent("memory", isDirectory: true),
            useWorkspaceHash: true,
            workspaceIdentity: workspaceIdentity ?? Self.discoverWorkspaceIdentity(cwd: cwd)
        )
    }

    public static func newFlat(cwd: URL, root: URL) -> MemoryStorage {
        MemoryStorage(
            cwd: cwd,
            globalDir: root.standardizedFileURL,
            useWorkspaceHash: false,
            workspaceIdentity: nil
        )
    }

    private init(cwd: URL, globalDir: URL, useWorkspaceHash: Bool, workspaceIdentity: String?) {
        let normalizedCWD = cwd.standardizedFileURL
        let workspaceDir: URL
        if useWorkspaceHash {
            let canonicalCWD = normalizedCWD.resolvingSymlinksInPath().standardizedFileURL
            let identity = workspaceIdentity.flatMap(Self.validatedWorkspaceIdentity)
            let slugSource = identity?.split(separator: "/").last.map(String.init)
                ?? canonicalCWD.lastPathComponent
            let name = slugify(slugSource, maxLength: 40)
            let slug = name.isEmpty ? "workspace" : name
            let hash = Blake3.hexPrefix(identity ?? canonicalCWD.path, length: 8)
            workspaceDir = globalDir.appendingPathComponent("\(slug)-\(hash)", isDirectory: true)
        } else {
            workspaceDir = globalDir
        }

        self.globalDir = globalDir.standardizedFileURL
        self.workspaceDir = workspaceDir.standardizedFileURL
        self.workspacePath = normalizedCWD
        self.isEphemeral = useWorkspaceHash && MemoryStorage.isEphemeralPath(normalizedCWD)
    }

    public var globalMemoryFile: URL {
        globalDir.appendingPathComponent("MEMORY.md")
    }

    public var workspaceMemoryFile: URL {
        workspaceDir.appendingPathComponent("MEMORY.md")
    }

    public var sessionsDir: URL {
        workspaceDir.appendingPathComponent("sessions", isDirectory: true)
    }

    public func classifySource(_ path: URL) -> String {
        if isWithin(path, root: workspaceDir) {
            return path.lastPathComponent == "MEMORY.md" ? "workspace" : "session"
        }
        if isWithin(path, root: globalDir) {
            return "global"
        }
        return "session"
    }

    public func writeDailyLog(
        date: String,
        slug: String,
        sessionID: String,
        content: String,
        append: Bool
    ) throws -> URL {
        guard isSafeFilenameComponent(date), isSafeFilenameComponent(slug), isSafeFilenameComponent(sessionID) else {
            throw MemoryError.unsafePath("\(date)-\(slug)-\(sessionID)")
        }

        let suffix = String(sessionID.prefix(8))
        let path = sessionsDir.appendingPathComponent("\(date)-\(slug)-\(suffix).md")
        if isEphemeral {
            return path
        }

        try Self.ensureSecureDirectory(globalDir)
        try Self.ensureSecureDirectory(workspaceDir)
        try Self.ensureSecureDirectory(sessionsDir)
        if append, FileManager.default.fileExists(atPath: path.path) {
            try SecureFile.ensureOwnerOnlyPermissions(at: path)
            let old = try String(contentsOf: path, encoding: .utf8)
            let timestamp = Self.utcTimestamp()
            try SecureFile.write(
                at: path,
                contents: "\(old)\n\n---\n\n<!-- flush \(timestamp) -->\n\n\(content)"
            )
        } else {
            try SecureFile.write(at: path, contents: content)
        }
        return path
    }

    public func writeLongTerm(scope: MemoryScope, content: String) throws {
        let path: URL
        switch scope {
        case .global:
            path = globalMemoryFile
            try Self.ensureSecureDirectory(globalDir)
        case .workspace:
            if isEphemeral { return }
            path = workspaceMemoryFile
            try Self.ensureSecureDirectory(globalDir)
            try Self.ensureSecureDirectory(workspaceDir)
        case .session:
            throw MemoryError.unsupportedScope(scope)
        }
        try SecureFile.write(at: path, contents: content)
    }

    public func appendToMemory(scope: MemoryScope, content: String) throws {
        if scope == .workspace, isEphemeral { return }
        let normalized = normalizeMemoryContent(content)
        guard !normalized.isEmpty else { return }

        let path: URL
        switch scope {
        case .global:
            path = globalMemoryFile
            try Self.ensureSecureDirectory(globalDir)
        case .workspace:
            path = workspaceMemoryFile
            try Self.ensureSecureDirectory(globalDir)
            try Self.ensureSecureDirectory(workspaceDir)
        case .session:
            throw MemoryError.unsupportedScope(scope)
        }

        let existing: String
        if FileManager.default.fileExists(atPath: path.path) {
            try SecureFile.ensureOwnerOnlyPermissions(at: path)
            existing = try String(contentsOf: path, encoding: .utf8)
        } else {
            existing = ""
        }
        let output = existing.isEmpty ? normalized : "\(existing)\n\n\(normalized)"
        try SecureFile.write(at: path, contents: output)
    }

    public func readFile(path: URL, from: Int = 0, lines: Int? = nil) throws -> String {
        let canonicalRoot = globalDir.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: canonicalRoot.path) else {
            throw MemoryError.memoryDirectoryMissing(canonicalRoot.path)
        }

        if try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw MemoryError.unsafePath(path.path)
        }
        let canonicalPath = path.resolvingSymlinksInPath().standardizedFileURL
        guard isWithin(canonicalPath, root: canonicalRoot) else {
            throw MemoryError.pathOutsideMemory(path: path.path, root: canonicalRoot.path)
        }
        let content = try String(contentsOf: canonicalPath, encoding: .utf8)
        guard from >= 0 else { throw MemoryError.unsafePath("negative line offset") }
        guard from > 0 || lines != nil else { return content }

        let selectedLines = memoryLines(content).dropFirst(from)
        if let lines {
            return selectedLines.prefix(max(0, lines)).joined(separator: "\n")
        }
        return selectedLines.joined(separator: "\n")
    }

    public func listMemoryFiles() throws -> [URL] {
        var files: [URL] = []
        if try Self.isSafeRegularFile(globalMemoryFile) {
            files.append(globalMemoryFile)
        }
        if try Self.isSafeRegularFile(workspaceMemoryFile) {
            files.append(workspaceMemoryFile)
        }
        if FileManager.default.fileExists(atPath: sessionsDir.path) {
            try Self.ensureSecureDirectory(sessionsDir)
            let sessionFiles = try FileManager.default.contentsOfDirectory(
                at: sessionsDir,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            for file in sessionFiles where file.pathExtension == "md" {
                if try Self.isSafeRegularFile(file) {
                    files.append(file)
                }
            }
            files.sort { $0.path < $1.path }
        }
        return files
    }

    public func ensureInitialized() throws {
        try Self.ensureSecureDirectory(globalDir)
        if !FileManager.default.fileExists(atPath: globalMemoryFile.path) {
            try SecureFile.write(
                at: globalMemoryFile,
                contents: "# Global Memory\n\n> This file is automatically managed by Grok's memory system.\n> You can also edit it manually — changes will be indexed on next session.\n\n## Preferences\n\n<!-- Add any cross-project preferences here -->\n"
            )
        } else {
            try SecureFile.ensureOwnerOnlyPermissions(at: globalMemoryFile)
        }
        if isEphemeral { return }

        try Self.ensureSecureDirectory(workspaceDir)
        if !FileManager.default.fileExists(atPath: workspaceMemoryFile.path) {
            try SecureFile.write(
                at: workspaceMemoryFile,
                contents: "# Project Memory — \(workspacePath.path)\n\n> Auto-populated by dream consolidation. Edit freely.\n"
            )
        } else {
            try SecureFile.ensureOwnerOnlyPermissions(at: workspaceMemoryFile)
        }
    }

    @discardableResult
    public func clearWorkspace() throws -> Bool {
        guard FileManager.default.fileExists(atPath: workspaceDir.path) else { return false }
        try FileManager.default.removeItem(at: workspaceDir)
        return true
    }

    @discardableResult
    public func clearGlobal() throws -> Bool {
        guard FileManager.default.fileExists(atPath: globalMemoryFile.path) else { return false }
        try FileManager.default.removeItem(at: globalMemoryFile)
        return true
    }

    public static func normalizeRemoteURL(_ remote: String) -> String? {
        let value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let colon = value.firstIndex(of: ":")
        else { return nil }

        let prefix = value[..<colon]
        let rawPath: Substring
        if prefix.contains("@"), !prefix.contains("/") {
            rawPath = value[value.index(after: colon)...]
        } else {
            guard let scheme = value.range(of: "//"),
                  let firstSlash = value[scheme.upperBound...].firstIndex(of: "/")
            else { return nil }
            rawPath = value[value.index(after: firstSlash)...]
        }

        var cleaned = String(rawPath)
        if cleaned.hasSuffix(".git") {
            cleaned.removeLast(4)
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return validatedWorkspaceIdentity(cleaned)
    }

    /// Read repository-local configuration without running a shell. The live
    /// composition can inject Git's authoritative answer when includes apply.
    public static func discoverWorkspaceIdentity(cwd: URL) -> String? {
        var current = cwd.resolvingSymlinksInPath().standardizedFileURL
        while true {
            let marker = current.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                let gitDirectory: URL
                if isDirectory.boolValue {
                    gitDirectory = marker
                } else {
                    guard let pointer = try? String(contentsOf: marker, encoding: .utf8),
                          pointer.hasPrefix("gitdir:")
                    else { return nil }
                    let rawPath = String(pointer.dropFirst("gitdir:".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !rawPath.isEmpty else { return nil }
                    gitDirectory = URL(fileURLWithPath: rawPath, relativeTo: current)
                        .standardizedFileURL
                }

                let commonMarker = gitDirectory.appendingPathComponent("commondir")
                let commonDirectory: URL
                if let relative = try? String(contentsOf: commonMarker, encoding: .utf8) {
                    commonDirectory = URL(
                        fileURLWithPath: relative.trimmingCharacters(in: .whitespacesAndNewlines),
                        relativeTo: gitDirectory
                    ).standardizedFileURL
                } else {
                    commonDirectory = gitDirectory
                }
                return originIdentity(in: commonDirectory.appendingPathComponent("config"))
                    ?? originIdentity(in: gitDirectory.appendingPathComponent("config"))
            }

            let parent = current.deletingLastPathComponent().standardizedFileURL
            guard parent.path.count < current.path.count else { return nil }
            current = parent
        }
    }

    static func ensureSecureDirectory(_ directory: URL) throws {
        try PathSecurity.rejectHostileLexical(directory.path)
        if FileManager.default.fileExists(atPath: directory.path) {
            try validateSecureDirectory(directory, enforcePermissions: false)
        }
        try createDirAllOwnerOnly(directory)
        try validateSecureDirectory(directory)
    }

    private static func validateSecureDirectory(
        _ directory: URL,
        enforcePermissions: Bool = true
    ) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw MemoryError.unsafePath(directory.path)
        }
        #if !os(Windows)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw MemoryError.unsafePath(directory.path)
        }
        if enforcePermissions {
            guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
                throw MemoryError.unsafePath(directory.path)
            }
        }
        #endif
    }

    private static func isSafeRegularFile(_ path: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MemoryError.unsafePath(path.path)
        }
        try SecureFile.ensureOwnerOnlyPermissions(at: path)
        guard try SecureFile.isOwnerOnly(at: path) else {
            throw MemoryError.unsafePath(path.path)
        }
        return true
    }

    private static func validatedWorkspaceIdentity(_ identity: String) -> String? {
        guard identity.contains("/"), !identity.contains("\\"),
              !identity.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        let components = identity.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return identity
    }

    private static func originIdentity(in configuration: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: configuration.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= 1_048_576,
              let contents = try? String(contentsOf: configuration, encoding: .utf8)
        else { return nil }

        var inOrigin = false
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inOrigin = trimmed.lowercased() == "[remote \"origin\"]"
                continue
            }
            guard inOrigin, let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "url" else { continue }
            let value = trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return normalizeRemoteURL(value)
        }
        return nil
    }
}

public func normalizeMemoryContent(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    if trimmed.first == "#" { return trimmed }

    guard let newline = trimmed.firstIndex(where: \.isNewline) else {
        return "## \(trimmed)"
    }

    let firstLine = String(trimmed[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
    let restStart = trimmed.index(after: newline)
    let rest = String(trimmed[restStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
    if firstLine.utf8.count <= 80 {
        return "## \(firstLine)\n\n\(rest)"
    }
    return "## Note\n\n\(trimmed)"
}

public func slugify(_ input: String, maxLength: Int) -> String {
    var result = ""
    var previousWasDash = false
    for character in input.lowercased() {
        let isASCIIAlphaNumeric = character.isASCII && (character.isLetter || character.isNumber)
        if isASCIIAlphaNumeric {
            result.append(character)
            previousWasDash = false
        } else if !previousWasDash {
            result.append("-")
            previousWasDash = true
        }
    }
    return String(result.prefix(max(0, maxLength))).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

private func memoryLines(_ content: String) -> [String] {
    var lines = content.split(
        omittingEmptySubsequences: false,
        whereSeparator: \.isNewline
    ).map(String.init)
    if lines.last == "" { lines.removeLast() }
    return lines
}

private func isSafeFilenameComponent(_ component: String) -> Bool {
    !component.isEmpty && component != "." && component != ".." &&
        !component.contains("/") && !component.contains("\\")
}

private func isWithin(_ candidate: URL, root: URL) -> Bool {
    let candidatePath = candidate.standardizedFileURL.path
    let rootPath = root.standardizedFileURL.path
    return candidatePath == rootPath || candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/")
}

private extension MemoryStorage {
    static func isEphemeralPath(_ path: URL) -> Bool {
        let canonical = path.resolvingSymlinksInPath().standardizedFileURL.path
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        return canonical == temporary || canonical.hasPrefix(temporary.hasSuffix("/") ? temporary : "\(temporary)/") ||
            canonical.hasPrefix("/tmp/") || canonical.hasPrefix("/private/tmp/") ||
            canonical.hasPrefix("/var/tmp/") || canonical.contains("/var/folders/") && canonical.contains("/T/")
    }

    static func utcTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm:ss 'UTC'"
        return formatter.string(from: Date())
    }
}
