import Foundation
import OpenGrokPaths
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokWorkspace

enum LiveSessionWorkingDirectoryError: Error, Sendable, Equatable, CustomStringConvertible {
    case unavailable(String)
    case sessionMismatch(String)
    case workspaceMismatch(String)
    case ownerMismatch(String)
    case invalidDirectory(String)
    case sessionDirectory(String)
    case persistenceFailure(String)

    var description: String {
        switch self {
        case .unavailable(let sessionID):
            return "working-directory changes are unavailable for session \(sessionID)"
        case .sessionMismatch(let sessionID):
            return "working-directory authority belongs to a different session: \(sessionID)"
        case .workspaceMismatch(let directory):
            return "working-directory authority does not cover this session workspace: \(directory)"
        case .ownerMismatch(let directory):
            return "working-directory state belongs to a different owner: \(directory)"
        case .invalidDirectory(let path):
            return "cannot access an existing working directory at \(path)"
        case .sessionDirectory(let path):
            return "\(path) is already the session working directory"
        case .persistenceFailure(let reason):
            return "working-directory state could not be safely updated: \(reason)"
        }
    }
}

struct LiveSessionWorkingDirectoryChange: Sendable, Equatable {
    let changed: Bool
    let directories: [URL]
    let environmentUpdate: String
}

/// One user-controlled, root-session-only working-set authority.
actor LiveSessionWorkingDirectories {
    nonisolated let sessionID: String
    nonisolated let workingDirectory: URL

    private let environment: [String: String]
    private let executor: LiveToolExecutor
    private let persistence: SessionWorkingDirectoriesStore
    private let history: LiveConversationHistory?
    private let environmentUpdateSink: (@Sendable (String) async throws -> Void)?
    private var directories: [URL]
    private var active: Bool

    init(
        sessionID: String,
        workingDirectory: URL,
        openGrokHome: URL,
        environment: [String: String],
        executor: LiveToolExecutor,
        history: LiveConversationHistory? = nil,
        environmentUpdateSink: (@Sendable (String) async throws -> Void)? = nil
    ) async throws {
        let canonicalWorkingDirectory = workingDirectory
            .standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        guard !sessionID.isEmpty,
              executor.resourceAuthorizationScope.authorizationSessionID == sessionID
        else {
            throw LiveSessionWorkingDirectoryError.sessionMismatch(sessionID)
        }
        guard LiveToolExecutor.workspaceRootsMatch(
            canonicalWorkingDirectory,
            executor.workingDirectory
        ) else {
            throw LiveSessionWorkingDirectoryError.workspaceMismatch(workingDirectory.path)
        }
        if let history, await history.sessionID != sessionID {
            throw LiveSessionWorkingDirectoryError.sessionMismatch(sessionID)
        }

        let store = try SessionWorkingDirectoriesStore(
            grokHome: openGrokHome,
            sessionID: sessionID,
            workingDirectory: workingDirectory
        )
        let restored = try store.load()

        self.sessionID = sessionID
        self.workingDirectory = canonicalWorkingDirectory
        self.environment = environment
        self.executor = executor
        self.persistence = store
        self.history = history
        self.environmentUpdateSink = environmentUpdateSink
        self.directories = restored
        self.active = true

        // Restore before the actor is registered or any session can sample a
        // turn. A sandbox that cannot admit an old grant aborts the backend.
        try await executor.updateAdditionalWorkingDirectories(restored, sessionID: sessionID)
    }

    var additionalDirectories: [URL] { directories }

    func add(
        path: String,
        workingDirectory requestDirectory: URL,
        environment requestEnvironment: [String: String]
    ) async throws -> LiveSessionWorkingDirectoryChange {
        try validateInvocation(workingDirectory: requestDirectory, environment: requestEnvironment)
        let directory = try resolve(path: path, requireExisting: true)
        guard directory.path != workingDirectory.path else {
            throw LiveSessionWorkingDirectoryError.sessionDirectory(directory.path)
        }
        if directories.contains(where: { $0.path == directory.path }) {
            return change(changed: false, directories: directories)
        }

        return try await replace(with: directories + [directory])
    }

    func remove(
        path: String,
        workingDirectory requestDirectory: URL,
        environment requestEnvironment: [String: String]
    ) async throws -> LiveSessionWorkingDirectoryChange {
        try validateInvocation(workingDirectory: requestDirectory, environment: requestEnvironment)
        let directory = try resolve(path: path, requireExisting: false)
        let updated = directories.filter { $0.path != directory.path }
        guard updated.count != directories.count else {
            return change(changed: false, directories: directories)
        }

        return try await replace(with: updated)
    }

    /// Session teardown removes live authority without destroying resume state.
    func revoke() async throws {
        guard active else { return }
        active = false
        try await executor.updateAdditionalWorkingDirectories([], sessionID: sessionID)
        directories = []
    }

    private func validateInvocation(
        workingDirectory requestDirectory: URL,
        environment requestEnvironment: [String: String]
    ) throws {
        guard active else {
            throw LiveSessionWorkingDirectoryError.unavailable(sessionID)
        }
        guard LiveToolExecutor.workspaceRootsMatch(requestDirectory, workingDirectory) else {
            throw LiveSessionWorkingDirectoryError.workspaceMismatch(requestDirectory.path)
        }

        let requestedState = OpenGrokHomeResolver.resolve(environment: requestEnvironment)
            .standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let ownerState = persistence.grokHome
            .standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        guard LiveToolExecutor.workspaceRootsMatch(requestedState, ownerState) else {
            throw LiveSessionWorkingDirectoryError.ownerMismatch(requestedState.path)
        }
        if let originalHome = environment["HOME"], let requestedHome = requestEnvironment["HOME"] {
            guard LiveToolExecutor.workspaceRootsMatch(
                URL(fileURLWithPath: originalHome),
                URL(fileURLWithPath: requestedHome)
            ) else {
                throw LiveSessionWorkingDirectoryError.ownerMismatch(requestedHome)
            }
        }
    }

    private func resolve(path rawPath: String, requireExisting: Bool) throws -> URL {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.unicodeScalars.contains("\0") else {
            throw LiveSessionWorkingDirectoryError.invalidDirectory(rawPath)
        }

        let expanded: String
        if path == "~" {
            guard let home = environment["HOME"], !home.isEmpty else {
                throw LiveSessionWorkingDirectoryError.invalidDirectory(path)
            }
            expanded = home
        } else if path.hasPrefix("~/") {
            guard let home = environment["HOME"], !home.isEmpty else {
                throw LiveSessionWorkingDirectoryError.invalidDirectory(path)
            }
            expanded = URL(fileURLWithPath: home)
                .appendingPathComponent(String(path.dropFirst(2))).path
        } else {
            expanded = path
        }

        let joined = isAbsolutePath(expanded)
            ? URL(fileURLWithPath: expanded, isDirectory: true)
            : workingDirectory.appendingPathComponent(expanded, isDirectory: true)
        let standardized = joined.standardizedFileURL
        let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory)
        guard !isUnsafeTrustRoot(canonical.path),
              exists && isDirectory.boolValue || !requireExisting && !exists
        else {
            throw LiveSessionWorkingDirectoryError.invalidDirectory(path)
        }
        return exists ? canonical : standardized
    }

    private func replace(with updated: [URL]) async throws -> LiveSessionWorkingDirectoryChange {
        let previous = directories
        do {
            try persistence.save(updated)
        } catch {
            throw LiveSessionWorkingDirectoryError.persistenceFailure(String(describing: error))
        }

        do {
            try await executor.updateAdditionalWorkingDirectories(updated, sessionID: sessionID)
        } catch {
            // A failed addition must not survive restart as a grant the active
            // OS sandbox rejected. Revocation remains durable when restoring
            // the old document itself fails.
            if updated.count > previous.count {
                do {
                    try persistence.save(previous)
                } catch {
                    active = false
                    try? await executor.updateAdditionalWorkingDirectories([], sessionID: sessionID)
                    throw LiveSessionWorkingDirectoryError.persistenceFailure(
                        "grant rollback failed: \(error)"
                    )
                }
            }
            throw error
        }

        directories = updated
        let result = change(changed: true, directories: updated)
        do {
            try await disclose(result.environmentUpdate)
        } catch {
            // A model that never learns about a working-set transition must
            // not retain the silently widened authority.
            active = false
            try? await executor.updateAdditionalWorkingDirectories([], sessionID: sessionID)
            try? persistence.save([])
            directories = []
            throw LiveSessionWorkingDirectoryError.persistenceFailure(String(describing: error))
        }
        return result
    }

    private func disclose(_ update: String) async throws {
        if let history {
            let record = await history.snapshot()
            guard record.sessionID == sessionID else {
                throw LiveSessionWorkingDirectoryError.sessionMismatch(record.sessionID)
            }
            var items = record.items
            items.append(.systemReminder(update))
            try await history.commit(sessionID: sessionID, items: items)
        }
        if let environmentUpdateSink {
            try await environmentUpdateSink(update)
        }
    }

    private func change(
        changed: Bool,
        directories: [URL]
    ) -> LiveSessionWorkingDirectoryChange {
        LiveSessionWorkingDirectoryChange(
            changed: changed,
            directories: directories,
            environmentUpdate: Self.environmentUpdate(
                workingDirectory: workingDirectory,
                directories: directories
            )
        )
    }

    static func environmentUpdate(workingDirectory: URL, directories: [URL]) -> String {
        let listing = directories.isEmpty
            ? "None. The session working directory is the only in-scope root."
            : directories.map { "- \($0.path)" }.joined(separator: "\n")
        return """
        <environment-update source="working_set">
        The session's working directories changed. The session working directory (\(workingDirectory.path)) stays the base for relative paths. Additional working directories the user granted file Read/Edit scope for, usable alongside it:
        \(listing)
        </environment-update>
        """
    }
}

/// Registry is keyed by authenticated root session, never by child or cwd.
actor LiveSessionWorkingDirectoryRegistry {
    static let shared = LiveSessionWorkingDirectoryRegistry()

    private var backends: [String: LiveSessionWorkingDirectories] = [:]

    func register(_ backend: LiveSessionWorkingDirectories) throws {
        let sessionID = backend.sessionID
        if let existing = backends[sessionID] {
            guard existing === backend else {
                throw LiveSessionWorkingDirectoryError.sessionMismatch(sessionID)
            }
            return
        }
        backends[sessionID] = backend
    }

    func backend(sessionID: String) -> LiveSessionWorkingDirectories? {
        backends[sessionID]
    }

    func unregister(sessionID: String) async throws {
        guard let backend = backends.removeValue(forKey: sessionID) else { return }
        try await backend.revoke()
    }

    func add(
        path: String,
        sessionID: String,
        workingDirectory: URL,
        environment: [String: String]
    ) async throws -> LiveSessionWorkingDirectoryChange {
        guard let backend = backends[sessionID] else {
            throw LiveSessionWorkingDirectoryError.unavailable(sessionID)
        }
        return try await backend.add(
            path: path,
            workingDirectory: workingDirectory,
            environment: environment
        )
    }

    func remove(
        path: String,
        sessionID: String,
        workingDirectory: URL,
        environment: [String: String]
    ) async throws -> LiveSessionWorkingDirectoryChange {
        guard let backend = backends[sessionID] else {
            throw LiveSessionWorkingDirectoryError.unavailable(sessionID)
        }
        return try await backend.remove(
            path: path,
            workingDirectory: workingDirectory,
            environment: environment
        )
    }
}
