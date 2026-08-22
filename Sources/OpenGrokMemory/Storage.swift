import Foundation
import OpenGrokFileUtils
import OpenGrokPaths

public struct MemoryStorage: Equatable, Sendable {
    public let globalDir: URL
    public let workspaceDir: URL
    public let workspacePath: URL
    public let isEphemeral: Bool

    public init(
        cwd: URL,
        rootOverride: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.init(
            cwd: cwd,
            globalDir: rootOverride ?? OpenGrokStatePaths.stateDirectory(environment: environment)
                .appendingPathComponent("memory", isDirectory: true),
            useWorkspaceHash: true
        )
    }

    public static func newFlat(cwd: URL, root: URL) -> MemoryStorage {
        MemoryStorage(cwd: cwd, globalDir: root.standardizedFileURL, useWorkspaceHash: false)
    }

    private init(cwd: URL, globalDir: URL, useWorkspaceHash: Bool) {
        let normalizedCWD = cwd.standardizedFileURL
        let workspaceDir: URL
        if useWorkspaceHash {
            let name = slugify(normalizedCWD.lastPathComponent, maxLength: 40)
            let slug = name.isEmpty ? "workspace" : name
            let hash = String(FileChecksum.sha256Hex(normalizedCWD.path).prefix(8))
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

        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        if append, FileManager.default.fileExists(atPath: path.path) {
            let old = try String(contentsOf: path, encoding: .utf8)
            let timestamp = Self.utcTimestamp()
            try writeAtomically(
                path,
                contents: "\(old)\n\n---\n\n<!-- flush \(timestamp) -->\n\n\(content)"
            )
        } else {
            try writeAtomically(path, contents: content)
        }
        return path
    }

    public func writeLongTerm(scope: MemoryScope, content: String) throws {
        let path: URL
        switch scope {
        case .global:
            path = globalMemoryFile
            try FileManager.default.createDirectory(at: globalDir, withIntermediateDirectories: true)
        case .workspace:
            if isEphemeral { return }
            path = workspaceMemoryFile
            try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        case .session:
            throw MemoryError.unsupportedScope(scope)
        }
        try writeAtomically(path, contents: content)
    }

    public func appendToMemory(scope: MemoryScope, content: String) throws {
        if scope == .workspace, isEphemeral { return }
        let normalized = normalizeMemoryContent(content)
        guard !normalized.isEmpty else { return }

        let path: URL
        switch scope {
        case .global:
            path = globalMemoryFile
            try FileManager.default.createDirectory(at: globalDir, withIntermediateDirectories: true)
        case .workspace:
            path = workspaceMemoryFile
            try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        case .session:
            throw MemoryError.unsupportedScope(scope)
        }

        let existing = FileManager.default.fileExists(atPath: path.path)
            ? try String(contentsOf: path, encoding: .utf8)
            : ""
        let output = existing.isEmpty ? normalized : "\(existing)\n\n\(normalized)"
        try writeAtomically(path, contents: output)
    }

    public func readFile(path: URL, from: Int = 0, lines: Int? = nil) throws -> String {
        let canonicalRoot = globalDir.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: canonicalRoot.path) else {
            throw MemoryError.memoryDirectoryMissing(canonicalRoot.path)
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
        if FileManager.default.fileExists(atPath: globalMemoryFile.path) {
            files.append(globalMemoryFile)
        }
        if FileManager.default.fileExists(atPath: workspaceMemoryFile.path) {
            files.append(workspaceMemoryFile)
        }
        if FileManager.default.fileExists(atPath: sessionsDir.path) {
            let sessionFiles = try FileManager.default.contentsOfDirectory(
                at: sessionsDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            files.append(contentsOf: sessionFiles.filter { $0.pathExtension == "md" }.sorted { $0.path < $1.path })
        }
        return files
    }

    public func ensureInitialized() throws {
        try FileManager.default.createDirectory(at: globalDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: globalMemoryFile.path) {
            try writeAtomically(
                globalMemoryFile,
                contents: "# Global Memory\n\n> This file is automatically managed by Grok's memory system.\n> You can also edit it manually — changes will be indexed on next session.\n\n## Preferences\n\n<!-- Add any cross-project preferences here -->\n"
            )
        }
        if isEphemeral { return }

        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: workspaceMemoryFile.path) {
            try writeAtomically(
                workspaceMemoryFile,
                contents: "# Project Memory — \(workspacePath.path)\n\n> Auto-populated by dream consolidation. Edit freely.\n"
            )
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
