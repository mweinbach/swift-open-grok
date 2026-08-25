import Foundation
import OpenGrokConfig
import OpenGrokFileUtils

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ProjectPermissionApprovalPersistenceError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case invalidWorkspace(String)
    case insecureStorage(String)
    case invalidDocument(String)

    public var description: String {
        switch self {
        case .invalidWorkspace(let path):
            return "project permission workspace is not an existing directory: \(path)"
        case .insecureStorage(let path):
            return "project permission state is not private to its owner: \(path)"
        case .invalidDocument(let path):
            return "project permission state is malformed: \(path)"
        }
    }
}

struct ProjectPermissionApprovalState: Sendable, Equatable {
    static let currentMCPServerGrantVersion: Int64 = 1
    static let maximumEntries = 1_024
    static let maximumEntryBytes = 8_192

    var allowBashExecute = false
    var allowedBashCommands: Set<String> = []
    var disallowedBashCommands: Set<String> = []
    var allowedBashGlobs: Set<String> = []
    var allowedWebFetchDomains: Set<String> = []
    var allowedMCPTools: Set<String> = []
    var allowedMCPServers: Set<String> = []
    var validatedMCPServerGrantsVersion: Int64 = currentMCPServerGrantVersion

    mutating func merge(_ other: Self) {
        allowBashExecute = allowBashExecute || other.allowBashExecute
        allowedBashCommands.formUnion(other.allowedBashCommands)
        disallowedBashCommands.formUnion(other.disallowedBashCommands)
        allowedBashGlobs.formUnion(other.allowedBashGlobs)
        allowedWebFetchDomains.formUnion(other.allowedWebFetchDomains)
        allowedMCPTools.formUnion(other.allowedMCPTools)
        allowedMCPServers.formUnion(other.allowedMCPServers)
        validatedMCPServerGrantsVersion = max(
            validatedMCPServerGrantsVersion,
            other.validatedMCPServerGrantsVersion
        )
    }

    var encoded: String {
        let fields: [(String, TOMLValue)] = [
            ("edit_policy", .string("ask")),
            ("allow_bash_execute", .boolean(allowBashExecute)),
            ("allowed_bash_commands", Self.array(allowedBashCommands)),
            ("disallowed_bash_commands", Self.array(disallowedBashCommands)),
            ("allowed_bash_globs", Self.array(allowedBashGlobs)),
            ("allowed_web_fetch_domains", Self.array(allowedWebFetchDomains)),
            ("allowed_mcp_tools", Self.array(allowedMCPTools)),
            ("allowed_mcp_servers", Self.array(allowedMCPServers)),
            ("validated_mcp_server_grants_version", .integer(validatedMCPServerGrantsVersion)),
        ]
        return TOMLEncoder.encode(.table(TOMLTable(fields)))
    }

    init() {}

    init(document: TOMLValue, source: URL) throws {
        guard let table = document.table else {
            throw ProjectPermissionApprovalPersistenceError.invalidDocument(source.path)
        }

        allowedBashCommands = try Self.strings(table["allowed_bash_commands"], source: source)
        disallowedBashCommands = try Self.strings(table["disallowed_bash_commands"], source: source)
        allowedBashGlobs = try Self.strings(table["allowed_bash_globs"], source: source)
        allowedWebFetchDomains = try Self.strings(table["allowed_web_fetch_domains"], source: source)
        allowedMCPTools = try Self.strings(table["allowed_mcp_tools"], source: source)
        allowedMCPServers = try Self.strings(table["allowed_mcp_servers"], source: source)

        if let editPolicy = table["edit_policy"] {
            guard let value = editPolicy.stringValue,
                  ["ask", "allow", "reject"].contains(value)
            else {
                throw ProjectPermissionApprovalPersistenceError.invalidDocument(source.path)
            }
        }
        if let blanket = table["allow_bash_execute"] {
            guard let allowed = blanket.boolValue else {
                throw ProjectPermissionApprovalPersistenceError.invalidDocument(source.path)
            }
            allowBashExecute = allowed
        }

        let version = table["validated_mcp_server_grants_version"]?.int64Value ?? 0
        if version < Self.currentMCPServerGrantVersion {
            allowedMCPServers.removeAll()
            validatedMCPServerGrantsVersion = Self.currentMCPServerGrantVersion
        } else {
            validatedMCPServerGrantsVersion = version
        }
    }

    private static func strings(_ value: TOMLValue?, source: URL) throws -> Set<String> {
        guard let value else { return [] }
        guard let values = value.arrayValue, values.count <= maximumEntries else {
            throw ProjectPermissionApprovalPersistenceError.invalidDocument(source.path)
        }
        var result: Set<String> = []
        for item in values {
            guard let string = item.stringValue,
                  !string.isEmpty,
                  string.utf8.count <= maximumEntryBytes,
                  !string.unicodeScalars.contains("\0")
            else {
                throw ProjectPermissionApprovalPersistenceError.invalidDocument(source.path)
            }
            result.insert(string)
        }
        return result
    }

    private static func array(_ entries: Set<String>) -> TOMLValue {
        .array(entries.sorted().map(TOMLValue.string))
    }
}

struct ProjectPermissionApprovalStore: Sendable {
    static let maximumDocumentBytes = 256 * 1_024

    let openGrokHome: URL
    let workingDirectory: URL
    let scopeRoot: URL
    let directory: URL
    let legacyDirectory: URL?
    let clientIdentifier: String?

    init(
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String],
        clientIdentifier: String? = nil
    ) throws {
        guard workingDirectory.isFileURL, openGrokHome.isFileURL else {
            throw ProjectPermissionApprovalPersistenceError.invalidWorkspace(workingDirectory.path)
        }

        let canonicalWorkingDirectory: URL
        do {
            canonicalWorkingDirectory = try PathSecurity.canonicalize(workingDirectory)
        } catch {
            throw ProjectPermissionApprovalPersistenceError.invalidWorkspace(workingDirectory.path)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: canonicalWorkingDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw ProjectPermissionApprovalPersistenceError.invalidWorkspace(workingDirectory.path)
        }

        let home = openGrokHome.standardizedFileURL
        guard try Self.inspectDirectory(home, ownerPrivate: false) else {
            throw ProjectPermissionApprovalPersistenceError.insecureStorage(home.path)
        }

        var projectRoot = WorkspaceSessionGitMetadata.resolve(at: canonicalWorkingDirectory)
            .gitRootDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let discoveredRoot = projectRoot, let userHome = environment["HOME"],
           canonicalWorkspacePathKey(discoveredRoot.path) == canonicalWorkspacePathKey(userHome) {
            projectRoot = nil
        }
        let scope = projectRoot?.standardizedFileURL.resolvingSymlinksInPath()
            ?? canonicalWorkingDirectory

        self.openGrokHome = home
        self.workingDirectory = canonicalWorkingDirectory
        self.scopeRoot = scope
        self.directory = home
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(encodeCwdDirname(scope.path), isDirectory: true)
        let exactDirectory = home
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(
                encodeCwdDirname(workingDirectory.standardizedFileURL.path),
                isDirectory: true
            )
        self.legacyDirectory = exactDirectory.path == directory.path ? nil : exactDirectory
        self.clientIdentifier = clientIdentifier.map(Self.sanitizeClientIdentifier)
    }

    var fileURL: URL { fileURL(in: directory, clientSpecific: clientIdentifier != nil) }

    func load() throws -> ProjectPermissionApprovalState {
        if let state = try load(in: directory) { return state }
        if let legacyDirectory, let legacy = try load(in: legacyDirectory) { return legacy }
        return ProjectPermissionApprovalState()
    }

    @discardableResult
    func save(_ state: ProjectPermissionApprovalState, merging: Bool) throws
        -> ProjectPermissionApprovalState
    {
        try prepareDirectory()
        let lockURL = fileURL.appendingPathExtension("lock")
        let lock = try AdvisoryFileLock.acquire(at: lockURL)
        defer { lock.release() }

        var updated = state
        if merging, try inspectFile(fileURL) {
            updated.merge(try read(fileURL))
        }
        try AtomicFile.write(fileURL, contents: updated.encoded, options: .ownerOnly)
        guard try inspectFile(fileURL) else {
            throw ProjectPermissionApprovalPersistenceError.insecureStorage(fileURL.path)
        }
        return updated
    }

    private func load(in location: URL) throws -> ProjectPermissionApprovalState? {
        let sessions = openGrokHome.appendingPathComponent("sessions", isDirectory: true)
        guard try Self.inspectDirectory(openGrokHome, ownerPrivate: false),
              try Self.inspectDirectory(sessions, ownerPrivate: true),
              try Self.inspectDirectory(location, ownerPrivate: true)
        else {
            return nil
        }

        if clientIdentifier != nil {
            let perClient = fileURL(in: location, clientSpecific: true)
            if try inspectFile(perClient) { return try read(perClient) }
        }
        let shared = fileURL(in: location, clientSpecific: false)
        return try inspectFile(shared) ? try read(shared) : nil
    }

    private func read(_ path: URL) throws -> ProjectPermissionApprovalState {
        let data = try PathSecurity.readNoFollow(
            path,
            maximumBytes: Self.maximumDocumentBytes,
            requireOwnerOnly: true
        )
        let document: TOMLValue
        do {
            document = try parseTOML(data)
        } catch {
            throw ProjectPermissionApprovalPersistenceError.invalidDocument(path.path)
        }
        return try ProjectPermissionApprovalState(document: document, source: path)
    }

    private func prepareDirectory() throws {
        let sessions = openGrokHome.appendingPathComponent("sessions", isDirectory: true)
        guard try Self.inspectDirectory(openGrokHome, ownerPrivate: false) else {
            throw ProjectPermissionApprovalPersistenceError.insecureStorage(openGrokHome.path)
        }
        for component in [sessions, directory] {
            if try !Self.inspectDirectory(component, ownerPrivate: true) {
                #if os(Windows)
                try createDirAllOwnerOnly(component, stateRoot: openGrokHome)
                #else
                try FileManager.default.createDirectory(
                    at: component,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                #endif
            }
            guard try Self.inspectDirectory(component, ownerPrivate: true) else {
                throw ProjectPermissionApprovalPersistenceError.insecureStorage(component.path)
            }
        }
    }

    private func fileURL(in location: URL, clientSpecific: Bool) -> URL {
        if clientSpecific, let clientIdentifier {
            return location.appendingPathComponent("permission_\(clientIdentifier).toml")
        }
        return location.appendingPathComponent("permission.toml")
    }

    private func inspectFile(_ path: URL) throws -> Bool {
        #if os(Windows)
        guard FileManager.default.fileExists(atPath: path.path) else {
            if (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw ProjectPermissionApprovalPersistenceError.insecureStorage(path.path)
            }
            return false
        }
        guard try !PathSecurity.isSymlink(path), try SecureFile.isOwnerOnly(at: path) else {
            throw ProjectPermissionApprovalPersistenceError.insecureStorage(path.path)
        }
        return true
        #else
        var information = stat()
        guard path.path.withCString({ lstat($0, &information) }) == 0 else {
            if errno == ENOENT { return false }
            throw ProjectPermissionApprovalPersistenceError.insecureStorage(path.path)
        }
        guard information.st_uid == geteuid(),
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_mode & 0o777 == 0o600,
              information.st_nlink == 1
        else {
            throw ProjectPermissionApprovalPersistenceError.insecureStorage(path.path)
        }
        return true
        #endif
    }

    private static func inspectDirectory(_ path: URL, ownerPrivate: Bool) throws -> Bool {
        #if os(Windows)
        let values: URLResourceValues
        do {
            values = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch {
            return false
        }
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ProjectPermissionApprovalPersistenceError.insecureStorage(path.path)
        }
        _ = ownerPrivate
        return true
        #else
        var information = stat()
        guard path.path.withCString({ lstat($0, &information) }) == 0 else {
            if errno == ENOENT { return false }
            throw ProjectPermissionApprovalPersistenceError.insecureStorage(path.path)
        }
        guard information.st_uid == geteuid(),
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              !ownerPrivate || information.st_mode & 0o777 == 0o700
        else {
            throw ProjectPermissionApprovalPersistenceError.insecureStorage(path.path)
        }
        return true
        #endif
    }

    private static func sanitizeClientIdentifier(_ identifier: String) -> String {
        identifier.unicodeScalars.map { scalar in
            let value = scalar.value
            let allowed = (48...57).contains(value)
                || (65...90).contains(value)
                || (97...122).contains(value)
                || value == 45 || value == 95
            return allowed ? String(scalar) : "_"
        }.joined()
    }
}
