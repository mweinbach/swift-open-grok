import Foundation
import OpenGrokAgentCoordinator
import OpenGrokFileUtils
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokSubagentResolution

#if os(Windows)
import COpenGrokSockets
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Rust's durable `$session_dir/subagents/<id>/meta.json` record.
/// Provider identity is recorded independently because model slugs overlap.
struct LiveSubagentMetadata: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable {
        case running
        case completed
        case failed
        case cancelled

        var isTerminal: Bool { self != .running }
    }

    var subagentID: String
    var parentSessionID: String
    var childSessionID: String
    var subagentType: String
    var description: String
    var prompt: String
    var status: Status
    var startedAt: Date
    var completedAt: Date?
    var durationMS: UInt64?
    var toolCalls: UInt32?
    var turns: UInt32?
    var error: String?
    var effectiveContextSource: String?
    var contextNormalized: Bool
    var forkCopyError: String?
    var persona: String?
    var resumedFrom: String?
    var childCWD: String?
    var worktreePath: String?
    var snapshotReference: String?
    var effectiveModelID: String?
    var modelRoute: SubagentModelRoute?
    var antigravityConversationID: String?

    init(
        subagentID: String,
        parentSessionID: String,
        childSessionID: String? = nil,
        subagentType: String,
        description: String,
        prompt: String,
        status: Status = .running,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        durationMS: UInt64? = nil,
        toolCalls: UInt32? = nil,
        turns: UInt32? = nil,
        error: String? = nil,
        effectiveContextSource: String? = nil,
        contextNormalized: Bool = false,
        forkCopyError: String? = nil,
        persona: String? = nil,
        resumedFrom: String? = nil,
        childCWD: String? = nil,
        worktreePath: String? = nil,
        snapshotReference: String? = nil,
        effectiveModelID: String? = nil,
        modelRoute: SubagentModelRoute? = nil,
        antigravityConversationID: String? = nil
    ) {
        self.subagentID = subagentID
        self.parentSessionID = parentSessionID
        self.childSessionID = childSessionID ?? subagentID
        self.subagentType = subagentType
        self.description = description
        self.prompt = prompt
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationMS = durationMS
        self.toolCalls = toolCalls
        self.turns = turns
        self.error = error
        self.effectiveContextSource = effectiveContextSource
        self.contextNormalized = contextNormalized
        self.forkCopyError = forkCopyError
        self.persona = persona
        self.resumedFrom = resumedFrom
        self.childCWD = childCWD
        self.worktreePath = worktreePath
        self.snapshotReference = snapshotReference
        self.effectiveModelID = effectiveModelID
        self.modelRoute = modelRoute
        self.antigravityConversationID = antigravityConversationID
    }

    private enum CodingKeys: String, CodingKey {
        case subagentID = "subagent_id"
        case parentSessionID = "parent_session_id"
        case childSessionID = "child_session_id"
        case subagentType = "subagent_type"
        case description, prompt, status
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case durationMS = "duration_ms"
        case toolCalls = "tool_calls"
        case turns, error
        case effectiveContextSource = "effective_context_source"
        case contextNormalized = "context_normalized"
        case forkCopyError = "fork_copy_error"
        case persona
        case resumedFrom = "resumed_from"
        case childCWD = "child_cwd"
        case worktreePath = "worktree_path"
        case snapshotReference = "snapshot_ref"
        case effectiveModelID = "effective_model_id"
        case modelRoute = "model_route"
        case antigravityConversationID = "antigravity_conversation_id"
    }
}

enum LiveSubagentMetadataError: Error, Sendable, CustomStringConvertible {
    case invalidIdentifier(String)
    case insecurePath(String)
    case identityMismatch(String)
    case invalidModelRoute(String)
    case invalidStatusTransition(String)
    case oversizedRecord(String)

    var description: String {
        switch self {
        case .invalidIdentifier(let value):
            return "invalid durable subagent identifier: \(value)"
        case .insecurePath(let path):
            return "durable subagent metadata path is insecure: \(path)"
        case .identityMismatch(let detail):
            return "durable subagent identity does not match its parent: \(detail)"
        case .invalidModelRoute(let detail):
            return "durable subagent model route is invalid: \(detail)"
        case .invalidStatusTransition(let detail):
            return "durable subagent status transition is invalid: \(detail)"
        case .oversizedRecord(let path):
            return "durable subagent metadata exceeds its size limit: \(path)"
        }
    }
}

struct LiveSubagentMetadataStore: Sendable {
    private static let maximumRecordBytes = 256 * 1024

    let openGrokHome: URL
    let parentSessionID: String
    let parentWorkingDirectory: URL

    init(openGrokHome: URL, parentSessionID: String, parentWorkingDirectory: URL) {
        self.openGrokHome = openGrokHome.standardizedFileURL.resolvingSymlinksInPath()
        self.parentSessionID = parentSessionID
        self.parentWorkingDirectory = parentWorkingDirectory.standardizedFileURL
    }

    func metadataURL(id: String) throws -> URL {
        guard isSafeSubagentChildID(parentSessionID), isSafeSubagentChildID(id) else {
            throw LiveSubagentMetadataError.invalidIdentifier(id)
        }

        let sessionsRoot = openGrokHome.appendingPathComponent("sessions", isDirectory: true)
        let parentDirectory = try SessionDocumentStore(grokHome: openGrokHome)
            .sessionDirectory(sessionID: parentSessionID, cwd: parentWorkingDirectory.path)
        let candidate = parentDirectory
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("meta.json", isDirectory: false)

        let canonicalSessionsRoot = sessionsRoot.standardizedFileURL
        let canonicalCandidate = candidate.standardizedFileURL
        guard canonicalCandidate.pathComponents.starts(with: canonicalSessionsRoot.pathComponents),
              sessionsRoot.resolvingSymlinksInPath().standardizedFileURL == canonicalSessionsRoot,
              candidate.resolvingSymlinksInPath().standardizedFileURL == canonicalCandidate
        else {
            throw LiveSubagentMetadataError.insecurePath(candidate.path)
        }
        return candidate
    }

    func save(_ metadata: LiveSubagentMetadata) throws {
        try validateIdentity(metadata, expectedID: metadata.subagentID)
        if metadata.modelRoute != nil {
            _ = try validatedProvider(for: metadata, expectedProvider: nil)
        }

        let path = try metadataURL(id: metadata.subagentID)
        let parent = path.deletingLastPathComponent()
        try Self.secureDirectory(parent.deletingLastPathComponent())
        try Self.secureDirectory(parent)

        // Recheck all existing ancestors after creating directories: an atomic
        // final-file write cannot compensate for a redirected parent directory.
        guard try metadataURL(id: metadata.subagentID) == path else {
            throw LiveSubagentMetadataError.insecurePath(path.path)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        guard data.count <= Self.maximumRecordBytes else {
            throw LiveSubagentMetadataError.oversizedRecord(path.path)
        }
        try SecureFile.write(at: path, contents: data)
        guard try SecureFile.isOwnerOnly(at: path) else {
            throw LiveSubagentMetadataError.insecurePath(path.path)
        }
    }

    func load(id: String) throws -> LiveSubagentMetadata? {
        let path = try metadataURL(id: id)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              try SecureFile.isOwnerOnly(at: path)
        else {
            throw LiveSubagentMetadataError.insecurePath(path.path)
        }
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= Self.maximumRecordBytes else {
            throw LiveSubagentMetadataError.oversizedRecord(path.path)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(LiveSubagentMetadata.self, from: Data(contentsOf: path))
        try validateIdentity(metadata, expectedID: id)
        if metadata.modelRoute != nil {
            _ = try validatedProvider(for: metadata, expectedProvider: nil)
        }
        return metadata
    }

    func resumeSource(
        id: String,
        expectedProvider: ModelProvider? = nil
    ) throws -> ResumeSourceData? {
        guard let metadata = try load(id: id), metadata.status.isTerminal else { return nil }

        if metadata.effectiveModelID?.hasPrefix("antigravity:") != true {
            _ = try validatedProvider(for: metadata, expectedProvider: expectedProvider)
        } else if expectedProvider != nil {
            throw LiveSubagentMetadataError.invalidModelRoute(id)
        }

        let worktree: URL?
        if let recorded = metadata.worktreePath {
            let candidate = URL(fileURLWithPath: recorded, isDirectory: true)
            let validated = try LiveSubagentWorktree.validateReuse(
                candidate,
                sourceDirectory: parentWorkingDirectory,
                openGrokHome: openGrokHome
            )
            guard let childCWD = metadata.childCWD,
                  URL(fileURLWithPath: childCWD, isDirectory: true)
                    .standardizedFileURL.resolvingSymlinksInPath() == validated
            else {
                throw LiveSubagentMetadataError.insecurePath(recorded)
            }
            worktree = validated
        } else {
            worktree = nil
        }

        return ResumeSourceData(
            subagentID: metadata.subagentID,
            subagentType: metadata.subagentType,
            persona: metadata.persona,
            modelID: metadata.effectiveModelID,
            modelRoute: metadata.modelRoute,
            childCWD: metadata.childCWD ?? "",
            worktreePath: worktree,
            snapshotReference: metadata.snapshotReference,
            childSessionID: metadata.childSessionID,
            antigravityConversationID: metadata.antigravityConversationID
        )
    }

    func updateModelRoute(id: String, model: String, provider: ModelProvider) throws {
        guard var metadata = try load(id: id) else {
            throw LiveSubagentMetadataError.identityMismatch(id)
        }
        guard metadata.status == .running, metadata.effectiveModelID == model else {
            throw LiveSubagentMetadataError.invalidModelRoute(id)
        }
        if let sourceID = metadata.resumedFrom,
           try resumeSource(id: sourceID, expectedProvider: provider) == nil
        {
            throw LiveSubagentMetadataError.invalidModelRoute(sourceID)
        }
        metadata.modelRoute = SubagentModelRoute(
            configuredModelID: model,
            provider: provider.asString
        )
        try save(metadata)
    }

    func updateStatus(
        id: String,
        status: LiveSubagentMetadata.Status,
        durationMS: UInt64? = nil,
        toolCalls: UInt32? = nil,
        turns: UInt32? = nil,
        error: String? = nil,
        antigravityConversationID: String? = nil
    ) throws {
        guard var metadata = try load(id: id) else {
            throw LiveSubagentMetadataError.identityMismatch(id)
        }
        guard status.isTerminal,
              metadata.status == .running || metadata.status == status
        else {
            throw LiveSubagentMetadataError.invalidStatusTransition(id)
        }
        metadata.status = status
        metadata.completedAt = metadata.completedAt ?? Date()
        metadata.durationMS = durationMS ?? metadata.durationMS
        metadata.toolCalls = toolCalls ?? metadata.toolCalls
        metadata.turns = turns ?? metadata.turns
        metadata.error = error ?? metadata.error
        metadata.antigravityConversationID = antigravityConversationID
            ?? metadata.antigravityConversationID
        try save(metadata)
    }

    private func validateIdentity(_ metadata: LiveSubagentMetadata, expectedID: String) throws {
        guard metadata.parentSessionID == parentSessionID,
              metadata.subagentID == expectedID,
              metadata.childSessionID == expectedID,
              isSafeSubagentChildID(metadata.subagentID),
              metadata.resumedFrom.map(isSafeSubagentChildID) ?? true
        else {
            throw LiveSubagentMetadataError.identityMismatch(expectedID)
        }
    }

    private func validatedProvider(
        for metadata: LiveSubagentMetadata,
        expectedProvider: ModelProvider?
    ) throws -> ModelProvider {
        guard let route = metadata.modelRoute,
              !route.configuredModelID.isEmpty,
              route.configuredModelID == metadata.effectiveModelID
        else {
            throw LiveSubagentMetadataError.invalidModelRoute(metadata.subagentID)
        }
        let provider: ModelProvider
        do {
            let data = try JSONEncoder().encode(route.provider)
            provider = try JSONDecoder().decode(ModelProvider.self, from: data)
        } catch {
            throw LiveSubagentMetadataError.invalidModelRoute(route.provider)
        }
        guard provider.asString == route.provider,
              expectedProvider.map({ $0 == provider }) ?? true
        else {
            throw LiveSubagentMetadataError.invalidModelRoute(route.provider)
        }
        return provider
    }

    private static func secureDirectory(_ path: URL) throws {
        try PathSecurity.rejectHostileLexical(path.path)
        #if os(Windows)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        guard path.path.withCString({ og_directory_secure_current_user($0) }) == 0 else {
            throw LiveSubagentMetadataError.insecurePath(path.path)
        }
        #else
        try FileManager.default.createDirectory(
            at: path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var information = stat()
        guard path.path.withCString({ lstat($0, &information) }) == 0,
              information.st_uid == getuid(),
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            throw LiveSubagentMetadataError.insecurePath(path.path)
        }
        if information.st_mode & 0o777 != 0o700,
           path.path.withCString({ chmod($0, mode_t(0o700)) }) != 0
        {
            throw LiveSubagentMetadataError.insecurePath(path.path)
        }
        #endif
    }
}

extension LiveSubagentHost {
    var durableSubagentMetadata: LiveSubagentMetadataStore {
        LiveSubagentMetadataStore(
            openGrokHome: context.openGrokHome,
            parentSessionID: context.sessionID,
            parentWorkingDirectory: context.workingDirectory
        )
    }

    func persistSubagentStart(id: String, prompt: String, resumedFrom: String?) throws {
        guard let stats = bookkeeping[id] else {
            throw LiveSubagentMetadataError.identityMismatch(id)
        }
        try durableSubagentMetadata.save(LiveSubagentMetadata(
            subagentID: id,
            parentSessionID: context.sessionID,
            subagentType: stats.subagentType,
            description: stats.description,
            prompt: prompt,
            startedAt: stats.startedAt,
            effectiveContextSource: resumedFrom == nil ? "new" : "resumed",
            persona: stats.persona,
            resumedFrom: resumedFrom,
            childCWD: stats.childCWD?.path,
            worktreePath: stats.worktreePath?.path,
            effectiveModelID: stats.model,
            antigravityConversationID: stats.antigravityConversationID
        ))
    }

    func persistSubagentCompletion(_ result: OpenGrokChildResult) throws {
        let stats = bookkeeping[result.id]
        let status: LiveSubagentMetadata.Status = result.cancelled
            ? .cancelled : result.success ? .completed : .failed
        try durableSubagentMetadata.updateStatus(
            id: result.id,
            status: status,
            durationMS: result.durationMS,
            toolCalls: stats?.terminalToolCalls ?? stats?.toolCalls,
            turns: stats?.terminalTurns ?? stats?.turns,
            error: result.error,
            antigravityConversationID: stats?.antigravityConversationID
        )
    }

    func durableResumeBookkeeping(id: String) throws -> Bookkeeping? {
        guard let source = try durableSubagentMetadata.resumeSource(id: id) else {
            return nil
        }
        return Bookkeeping(
            startedAt: Date(),
            subagentType: source.subagentType,
            description: "Resumed subagent \(id)",
            model: source.modelID ?? source.modelRoute?.configuredModelID ?? context.parentModel,
            persona: source.persona,
            childCWD: source.childCWD.isEmpty ? nil : URL(fileURLWithPath: source.childCWD),
            worktreePath: source.worktreePath,
            worktreeIsolationEnforced: source.worktreePath != nil,
            antigravityConversationID: source.antigravityConversationID
        )
    }
}
