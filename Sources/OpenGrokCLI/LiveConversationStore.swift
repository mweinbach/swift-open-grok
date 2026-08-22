import Foundation
import OpenGrokAgentCoordinator
import OpenGrokAgentDefinitions
import OpenGrokACPRuntime
import OpenGrokAuth
import OpenGrokChatState
import OpenGrokCodeMode
import OpenGrokCompaction
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokDiagnostics
import OpenGrokFileTools
import OpenGrokFastWorktree
import OpenGrokHTTP
import OpenGrokHooks
import OpenGrokHooksPluginTypes
import OpenGrokHunkTracker
import OpenGrokInterjection
import OpenGrokLSP
import OpenGrokModels
import OpenGrokPager
import OpenGrokPagerCommandUI
import OpenGrokPagerMinimal
import OpenGrokPagerRender
import OpenGrokTokenEstimation
import OpenGrokProviderSession
import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokSandbox
import OpenGrokScheduler
import OpenGrokSessionPersistence
import OpenGrokSessionRuntime
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokShellSessionSupport
import OpenGrokSubagentResolution
import OpenGrokTerminalCore
import OpenGrokTextArea
import OpenGrokToolRegistry
import OpenGrokToolTypes
import OpenGrokToolsAPI
import OpenGrokTTY
import OpenGrokVersion
import OpenGrokVoice
import OpenGrokWebMediaTools
import OpenGrokWorkspace


struct LiveConversationRecord: Codable, Sendable, Equatable {
    var sessionID: String
    var workingDirectory: String
    var parentSessionID: String?
    var sessionKind: String?
    var cacheAffinityID: String?
    var createdAt: Date
    var updatedAt: Date
    var items: [ConversationItem]
    var sandboxProfile: String?
    var currentModelID: String?
    var currentProvider: ModelProvider?
    var everUsedNonXAI: Bool?
    var usageSnapshot: LiveSessionUsageSnapshot?
    /// User-chosen session title (`/rename`, upstream rename.rs:42-53).
    /// `nil` means "never renamed"; readers derive a title from the first
    /// real user turn instead. Optional so records written before this field
    /// existed keep decoding unchanged.
    var title: String?
    /// Terminal tool-card display outcomes keyed by call id. Optional so
    /// pre-Wave-A records keep decoding; `/resume` treats a missing entry as
    /// `.pending` when the call has no paired output rather than inventing
    /// success. See `ToolCallOutcomeMap` — not a provider wire field.
    var toolOutcomes: ToolCallOutcomeMap?

    init(
        sessionID: String,
        workingDirectory: String,
        parentSessionID: String?,
        sessionKind: String? = nil,
        cacheAffinityID: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        items: [ConversationItem],
        sandboxProfile: String? = nil,
        currentModelID: String? = nil,
        currentProvider: ModelProvider? = nil,
        everUsedNonXAI: Bool? = nil,
        usageSnapshot: LiveSessionUsageSnapshot? = nil,
        title: String? = nil,
        toolOutcomes: ToolCallOutcomeMap? = nil
    ) {
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.parentSessionID = parentSessionID
        self.sessionKind = sessionKind
        self.cacheAffinityID = cacheAffinityID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.items = items
        self.sandboxProfile = sandboxProfile
        self.currentModelID = currentModelID
        self.currentProvider = currentProvider
        self.everUsedNonXAI = everUsedNonXAI
        self.usageSnapshot = usageSnapshot
        self.title = title
        self.toolOutcomes = toolOutcomes
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case workingDirectory
        case parentSessionID
        case sessionKind = "session_kind"
        case cacheAffinityID = "cache_affinity_id"
        case createdAt
        case updatedAt
        case items
        case sandboxProfile = "sandbox_profile"
        case currentModelID = "current_model_id"
        case currentProvider = "current_provider"
        case everUsedNonXAI = "ever_used_codex"
        case usageSnapshot = "session_usage"
        case title
        case toolOutcomes = "tool_outcomes"
    }

    // Explicit so `tool_outcomes` cannot silently vanish on a future
    // synthesized-key drift. Pre-Wave-A files omit the key; that is `nil`,
    // not an empty map inventing success. Cost: adding a stored property
    // now requires a matching key or `/resume` drops it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        workingDirectory = try c.decode(String.self, forKey: .workingDirectory)
        parentSessionID = try c.decodeIfPresent(String.self, forKey: .parentSessionID)
        sessionKind = try c.decodeIfPresent(String.self, forKey: .sessionKind)
        cacheAffinityID = try c.decodeIfPresent(String.self, forKey: .cacheAffinityID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        items = try c.decode([ConversationItem].self, forKey: .items)
        sandboxProfile = try c.decodeIfPresent(String.self, forKey: .sandboxProfile)
        currentModelID = try c.decodeIfPresent(String.self, forKey: .currentModelID)
        currentProvider = try c.decodeIfPresent(ModelProvider.self, forKey: .currentProvider)
        everUsedNonXAI = try c.decodeIfPresent(Bool.self, forKey: .everUsedNonXAI)
        usageSnapshot = try c.decodeIfPresent(LiveSessionUsageSnapshot.self, forKey: .usageSnapshot)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        toolOutcomes = try c.decodeIfPresent(ToolCallOutcomeMap.self, forKey: .toolOutcomes)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(workingDirectory, forKey: .workingDirectory)
        try c.encodeIfPresent(parentSessionID, forKey: .parentSessionID)
        try c.encodeIfPresent(sessionKind, forKey: .sessionKind)
        try c.encodeIfPresent(cacheAffinityID, forKey: .cacheAffinityID)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(items, forKey: .items)
        try c.encodeIfPresent(sandboxProfile, forKey: .sandboxProfile)
        try c.encodeIfPresent(currentModelID, forKey: .currentModelID)
        try c.encodeIfPresent(currentProvider, forKey: .currentProvider)
        try c.encodeIfPresent(everUsedNonXAI, forKey: .everUsedNonXAI)
        try c.encodeIfPresent(usageSnapshot, forKey: .usageSnapshot)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(toolOutcomes, forKey: .toolOutcomes)
    }

    static func new(
        sessionID: String,
        workingDirectory: URL,
        sandboxProfile: String? = nil
    ) -> LiveConversationRecord {
        let now = Date()
        return LiveConversationRecord(
            sessionID: sessionID,
            workingDirectory: workingDirectory.standardizedFileURL.path,
            parentSessionID: nil,
            createdAt: now,
            updatedAt: now,
            items: [],
            sandboxProfile: sandboxProfile,
            currentModelID: nil,
            currentProvider: nil,
            everUsedNonXAI: false
        )
    }
}

actor LiveConversationStore {
    private let sessionsDirectory: URL
    private let documentStore: SessionDocumentStore
    private let fileManager: FileManager

    init(openGrokHome: URL, fileManager: FileManager = .default) {
        self.sessionsDirectory = openGrokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL
        self.documentStore = SessionDocumentStore(grokHome: openGrokHome)
        self.fileManager = fileManager
    }

    static func validateSessionID(_ sessionID: String) throws {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !sessionID.isEmpty,
              sessionID.count <= 128,
              sessionID != ".",
              sessionID != "..",
              sessionID.allSatisfy(allowed.contains)
        else {
            throw CLIApplicationError.failed("invalid session ID: \(sessionID)")
        }
    }

    func load(sessionID: String) throws -> LiveConversationRecord {
        guard let record = try loadIfPresent(sessionID: sessionID) else {
            throw CLIApplicationError.failed("session not found: \(sessionID)")
        }
        return record
    }

    func loadIfPresent(sessionID: String) throws -> LiveConversationRecord? {
        try Self.validateSessionID(sessionID)
        do {
            let persisted = try documentStore.load(sessionID: sessionID)
            if let persisted,
               try canonicalSummaryExists(for: persisted.summary)
            {
                let record = try Self.record(from: persisted, requestedSessionID: sessionID)
                return try reconcileCompatibilitySandboxPin(record)
            }

            let url = fileURL(sessionID: sessionID)
            if fileManager.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                let record = try JSONDecoder().decode(LiveConversationRecord.self, from: data)
                guard record.sessionID == sessionID else {
                    throw CLIApplicationError.failed("session file ID mismatch: \(sessionID)")
                }
                try save(record)
                return record
            }

            guard let persisted else { return nil }
            let record = try Self.record(from: persisted, requestedSessionID: sessionID)
            try save(record)
            return record
        } catch let error as CLIApplicationError {
            throw error
        } catch {
            throw CLIApplicationError.failed("failed to load session \(sessionID): \(error)")
        }
    }

    func latest(workingDirectory: URL) throws -> LiveConversationRecord? {
        guard fileManager.fileExists(atPath: sessionsDirectory.path) else { return nil }
        let expectedDirectory = workingDirectory.standardizedFileURL.path
        let canonicalRecords: [LiveConversationRecord]
        do {
            canonicalRecords = try documentStore.list(cwd: expectedDirectory).compactMap { summary in
                guard let state = try documentStore.load(
                    sessionID: summary.sessionID.rawValue,
                    cwd: expectedDirectory
                ) else { return nil }
                return try Self.record(from: state, requestedSessionID: summary.sessionID.rawValue)
            }
        } catch {
            throw CLIApplicationError.failed("failed to list sessions: \(error)")
        }

        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: sessionsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw CLIApplicationError.failed("failed to list sessions: \(error)")
        }

        let canonicalIDs = Set(canonicalRecords.map(\.sessionID))
        let legacyRecords = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> LiveConversationRecord? in
                guard let data = try? Data(contentsOf: url),
                      let record = try? JSONDecoder().decode(LiveConversationRecord.self, from: data),
                      URL(fileURLWithPath: record.workingDirectory).standardizedFileURL.path == expectedDirectory,
                      !canonicalIDs.contains(record.sessionID)
                else { return nil }
                if let directory = try? documentStore.sessionDirectory(
                    sessionID: record.sessionID,
                    cwd: record.workingDirectory
                ), fileManager.fileExists(
                    atPath: directory.appendingPathComponent("summary.json").path
                ) {
                    return nil
                }
                return record
            }
        return (canonicalRecords + legacyRecords)
            .max { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.sessionID < rhs.sessionID
                }
                return lhs.updatedAt < rhs.updatedAt
            }
    }

    func save(_ record: LiveConversationRecord) throws {
        try Self.validateSessionID(record.sessionID)
        do {
            let existing = try documentStore.load(
                sessionID: record.sessionID,
                cwd: record.workingDirectory
            )
            let state = try Self.persistedState(for: record, preserving: existing)
            try documentStore.save(state)

            try fileManager.createDirectory(
                at: sessionsDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(record)
            try writeLiveConversationDataAtomically(
                data,
                to: fileURL(sessionID: record.sessionID),
                fileManager: fileManager
            )
        } catch {
            throw CLIApplicationError.failed("failed to save session \(record.sessionID): \(error)")
        }
    }

    /// `x.ai/session/rename` for a session that is NOT the live spine: load,
    /// set the stored title, persist — one actor turn, so the read-modify-
    /// write cannot interleave with another store call. Returns `false` when
    /// no such session exists. The LIVE session must rename through its
    /// `LiveConversationHistory` instead: the turn loop re-saves the whole
    /// in-memory record on every commit, so a title written here for the
    /// resident session would silently vanish at the next turn's save.
    func renameStored(sessionID: String, title: String) throws -> Bool {
        guard var record = try loadIfPresent(sessionID: sessionID) else { return false }
        record.title = title
        record.updatedAt = Date()
        try save(record)
        return true
    }

    /// Copy one session as a coupled transcript/rewind artifact transaction.
    ///
    /// The export marker and provider route are copied before the child can be
    /// launched, and a rewind sidecar is copied byte-for-byte when present so
    /// the child coordinator resumes the parent's prompt numbering and points.
    /// A legacy source is refused because its export boundary cannot be safely
    /// inherited. Any partial child artifacts are removed before the error is
    /// returned, so a failed fork never leaves a misleading session behind.
    func fork(
        sourceSessionID: String,
        destinationSessionID: String,
        workingDirectory: URL
    ) throws -> LiveConversationRecord {
        try Self.validateSessionID(sourceSessionID)
        try Self.validateSessionID(destinationSessionID)
        guard sourceSessionID != destinationSessionID else {
            throw CLIApplicationError.failed("forked session ID must differ from the source session")
        }
        guard let source = try loadIfPresent(sessionID: sourceSessionID) else {
            throw CLIApplicationError.failed("session not found: \(sourceSessionID)")
        }
        guard source.everUsedNonXAI != nil else {
            throw CLIApplicationError.failed(
                "cannot fork legacy session \(sourceSessionID): its session record has no "
                    + "ever_used_codex export-boundary marker. Resume it once with this build "
                    + "to persist the boundary before forking."
            )
        }
        guard try loadIfPresent(sessionID: destinationSessionID) == nil else {
            throw CLIApplicationError.failed("session already exists: \(destinationSessionID)")
        }

        let destinationRecordURL = fileURL(sessionID: destinationSessionID)
        let sourceRewindURL = LiveRewindStore.rewindFileURL(
            openGrokHome: sessionsDirectory.deletingLastPathComponent(),
            sessionID: sourceSessionID
        )
        let destinationRewindURL = LiveRewindStore.rewindFileURL(
            openGrokHome: sessionsDirectory.deletingLastPathComponent(),
            sessionID: destinationSessionID
        )
        guard !fileManager.fileExists(atPath: destinationRewindURL.path) else {
            throw CLIApplicationError.failed("rewind state already exists: \(destinationSessionID)")
        }

        let now = Date()
        let child = LiveConversationRecord(
            sessionID: destinationSessionID,
            workingDirectory: workingDirectory.standardizedFileURL.path,
            parentSessionID: source.sessionID,
            sessionKind: "fork",
            cacheAffinityID: source.cacheAffinityID ?? source.sessionID,
            createdAt: now,
            updatedAt: now,
            items: source.items,
            sandboxProfile: source.sandboxProfile,
            currentModelID: source.currentModelID,
            currentProvider: source.currentProvider,
            everUsedNonXAI: source.everUsedNonXAI,
            title: source.title,
            toolOutcomes: source.toolOutcomes
        )

        do {
            try fileManager.createDirectory(
                at: sessionsDirectory,
                withIntermediateDirectories: true
            )
            try documentStore.copySession(
                from: sourceSessionID,
                sourceCWD: source.workingDirectory,
                to: destinationSessionID,
                destinationCWD: child.workingDirectory
            )
            try save(child)
            if fileManager.fileExists(atPath: sourceRewindURL.path) {
                let rewindBytes = try Data(contentsOf: sourceRewindURL)
                try writeLiveConversationDataAtomically(
                    rewindBytes,
                    to: destinationRewindURL,
                    fileManager: fileManager
                )
            }
            let sourceSessionDir = sessionsDirectory.appendingPathComponent(sourceSessionID)
            let destinationSessionDir = sessionsDirectory.appendingPathComponent(destinationSessionID)
            if fileManager.fileExists(atPath: sourceSessionDir.path) {
                try copyCheckpoints(from: sourceSessionDir, to: destinationSessionDir)
                try copyCheckpoints(
                    from: sourceSessionDir,
                    to: documentStore.sessionDirectory(
                        sessionID: destinationSessionID,
                        cwd: child.workingDirectory
                    )
                )
            }
            let sourceDocumentDirectory = try documentStore.sessionDirectory(
                sessionID: sourceSessionID,
                cwd: source.workingDirectory
            )
            if fileManager.fileExists(atPath: sourceDocumentDirectory.path) {
                try copyCheckpoints(
                    from: sourceDocumentDirectory,
                    to: documentStore.sessionDirectory(
                        sessionID: destinationSessionID,
                        cwd: child.workingDirectory
                    )
                )
            }
        } catch {
            if let destinationDocumentDirectory = try? documentStore.sessionDirectory(
                sessionID: destinationSessionID,
                cwd: child.workingDirectory
            ) {
                try? fileManager.removeItem(at: destinationDocumentDirectory)
            }
            try? fileManager.removeItem(at: destinationRecordURL)
            try? fileManager.removeItem(at: destinationRewindURL)
            try? fileManager.removeItem(
                at: sessionsDirectory.appendingPathComponent(destinationSessionID, isDirectory: true)
            )
            throw CLIApplicationError.failed(
                "failed to fork session \(sourceSessionID) as \(destinationSessionID): \(error)"
            )
        }
        return child
    }

    private func fileURL(sessionID: String) -> URL {
        sessionsDirectory.appendingPathComponent(sessionID).appendingPathExtension("json")
    }

    private func canonicalSummaryExists(
        for summary: OpenGrokShellSessionSupport.SessionSummary
    ) throws -> Bool {
        let directory = try documentStore.sessionDirectory(
            sessionID: summary.sessionID.rawValue,
            cwd: summary.cwd
        )
        return fileManager.fileExists(
            atPath: directory.appendingPathComponent("summary.json").path
        )
    }

    private func reconcileCompatibilitySandboxPin(
        _ canonical: LiveConversationRecord
    ) throws -> LiveConversationRecord {
        let compatibilityURL = fileURL(sessionID: canonical.sessionID)
        guard fileManager.fileExists(atPath: compatibilityURL.path) else {
            return canonical
        }

        let compatibility = try JSONDecoder().decode(
            LiveConversationRecord.self,
            from: Data(contentsOf: compatibilityURL)
        )
        guard compatibility.sessionID == canonical.sessionID else {
            throw CLIApplicationError.failed("session file ID mismatch: \(canonical.sessionID)")
        }
        guard let compatibilityProfile = compatibility.sandboxProfile,
              !compatibilityProfile.isEmpty
        else { return canonical }

        guard let canonicalProfile = canonical.sandboxProfile,
              !canonicalProfile.isEmpty
        else {
            var result = canonical
            result.sandboxProfile = compatibilityProfile
            return result
        }

        let canonicalName = ProfileName(parsing: canonicalProfile)
        let compatibilityName = ProfileName(parsing: compatibilityProfile)
        guard canonicalName != compatibilityName else { return canonical }

        let canonicalRank = SandboxMode.from(profile: canonicalName).rank
        let compatibilityRank = SandboxMode.from(profile: compatibilityName).rank
        if compatibilityRank > canonicalRank {
            var result = canonical
            result.sandboxProfile = compatibilityProfile
            return result
        }
        if canonicalRank > compatibilityRank {
            return canonical
        }

        throw CLIApplicationError.failed(
            "conflicting persisted sandbox profiles '\(canonicalName.description)' "
                + "and '\(compatibilityName.description)' for session \(canonical.sessionID)"
        )
    }

    private static func persistedState(
        for record: LiveConversationRecord,
        preserving existing: PersistedSessionState?
    ) throws -> PersistedSessionState {
        let chatHistory = try record.items.map(JSONValue.encode)
        let commonPrefixCount = zip(existing?.chatHistory ?? [], chatHistory)
            .prefix { pair in pair.0 == pair.1 }
            .count
        var updates = existing?.updates ?? []
        let timestamp = UInt64(max(0, record.updatedAt.timeIntervalSince1970))
        for item in record.items.dropFirst(commonPrefixCount) {
            updates.append(contentsOf: try sessionUpdates(
                for: item,
                sessionID: record.sessionID,
                timestamp: timestamp,
                outcomes: record.toolOutcomes
            ))
        }

        var extra = existing?.summary.extra ?? [:]
        if let cacheAffinityID = record.cacheAffinityID,
           !cacheAffinityID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            extra["cache_affinity_id"] = .string(cacheAffinityID)
        }
        setMetadata("sandbox_profile", value: record.sandboxProfile, in: &extra)
        if let provider = record.currentProvider {
            extra["current_provider"] = try JSONValue.encode(provider)
        } else {
            extra["current_provider"] = .null
        }
        if let title = record.title {
            let unchangedGeneratedTitle = existing?.summary.extra["generated_title"]?.stringValue
                == title
            extra["generated_title"] = .string(title)
            if !unchangedGeneratedTitle {
                extra["title_is_manual"] = .bool(true)
            }
        }
        if let toolOutcomes = record.toolOutcomes {
            extra["tool_outcomes"] = try JSONValue.encode(toolOutcomes)
        } else {
            extra["tool_outcomes"] = .null
        }
        if let usageSnapshot = record.usageSnapshot {
            extra["session_usage"] = try JSONValue.encode(usageSnapshot)
        } else if extra["session_usage"] != nil {
            // Copying a transcript creates a new bill; a null tombstone is
            // required because document saves preserve unknown summary keys.
            extra["session_usage"] = .null
        }
        extra["swift_legacy_export_boundary_missing"] = .bool(record.everUsedNonXAI == nil)

        let previousSummary = existing?.summary.sessionSummary
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryText = (previousSummary?.isEmpty == false ? previousSummary : nil)
            ?? record.title
            ?? record.items.lazy.compactMap { item -> String? in
                guard case .user(let user) = item,
                      user.syntheticReason == nil
                else { return nil }
                return item.textContent()
            }.first
            ?? ""
        let summary = OpenGrokShellSessionSupport.SessionSummary(
            sessionID: SessionID(record.sessionID),
            cwd: record.workingDirectory,
            sessionSummary: summaryText,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            messageCount: UInt64(updates.count),
            chatMessageCount: UInt64(chatHistory.count),
            currentModelID: record.currentModelID ?? existing?.summary.currentModelID ?? "",
            parentSessionID: record.parentSessionID,
            nextTraceTurn: existing?.summary.nextTraceTurn ?? 0,
            chatFormatVersion: existing?.summary.chatFormatVersion ?? chatFormatVersion,
            everUsedCodex: record.everUsedNonXAI ?? existing?.summary.everUsedCodex ?? false,
            sessionKind: record.sessionKind
                ?? existing?.summary.sessionKind
                ?? (record.parentSessionID == nil ? nil : "fork"),
            extra: extra
        )

        return PersistedSessionState(
            summary: summary,
            chatHistory: chatHistory,
            updates: updates,
            transcript: existing?.transcript ?? SessionTranscript(),
            toolHistory: existing?.toolHistory ?? [],
            recovery: existing?.recovery ?? SessionRecoveryState(),
            pendingCommands: existing?.pendingCommands ?? []
        )
    }

    static func record(
        from state: PersistedSessionState,
        requestedSessionID: String
    ) throws -> LiveConversationRecord {
        guard state.summary.sessionID.rawValue == requestedSessionID else {
            throw CLIApplicationError.failed("session file ID mismatch: \(requestedSessionID)")
        }
        let extra = state.summary.extra
        let provider: ModelProvider?
        if let value = extra["current_provider"], value != .null {
            provider = try value.decode(ModelProvider.self)
        } else {
            provider = nil
        }
        let toolOutcomes: ToolCallOutcomeMap?
        if let value = extra["tool_outcomes"], value != .null {
            toolOutcomes = try value.decode(ToolCallOutcomeMap.self)
        } else {
            toolOutcomes = nil
        }
        let usageSnapshot: LiveSessionUsageSnapshot?
        if let value = extra["session_usage"], value != .null {
            usageSnapshot = try value.decode(LiveSessionUsageSnapshot.self)
        } else {
            usageSnapshot = nil
        }
        let exportBoundaryMissing = extra["swift_legacy_export_boundary_missing"]?.boolValue == true

        return LiveConversationRecord(
            sessionID: state.summary.sessionID.rawValue,
            workingDirectory: state.summary.cwd,
            parentSessionID: state.summary.parentSessionID,
            sessionKind: state.summary.sessionKind,
            cacheAffinityID: extra["cache_affinity_id"]?.stringValue,
            createdAt: state.summary.createdAt,
            updatedAt: state.summary.updatedAt,
            items: try state.chatHistory.map { try $0.decode(ConversationItem.self) },
            sandboxProfile: extra["sandbox_profile"]?.stringValue,
            currentModelID: state.summary.currentModelID.isEmpty
                ? nil
                : state.summary.currentModelID,
            currentProvider: provider,
            everUsedNonXAI: exportBoundaryMissing ? nil : state.summary.everUsedCodex,
            usageSnapshot: usageSnapshot,
            title: extra["generated_title"]?.stringValue ?? extra["title"]?.stringValue,
            toolOutcomes: toolOutcomes
        )
    }

    private static func setMetadata(
        _ key: String,
        value: String?,
        in metadata: inout [String: JSONValue]
    ) {
        if let value {
            metadata[key] = .string(value)
        } else {
            metadata[key] = .null
        }
    }

    private static func sessionUpdates(
        for item: ConversationItem,
        sessionID: String,
        timestamp: UInt64,
        outcomes: ToolCallOutcomeMap?
    ) throws -> [SessionUpdateEnvelope] {
        let wrap: ([String: JSONValue]) throws -> SessionUpdateEnvelope = { update in
            try SessionUpdateEnvelope(
                timestamp: timestamp,
                method: "session/update",
                params: .object([
                    "sessionId": .string(sessionID),
                    "update": .object(update),
                ])
            )
        }

        switch item {
        case .user(let user):
            return try user.content.compactMap { part in
                guard case .text(let text) = part else { return nil }
                var update: [String: JSONValue] = [
                    "sessionUpdate": .string("user_message_chunk"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string(text),
                    ]),
                ]
                if let promptIndex = user.promptIndex {
                    update["_meta"] = .object([
                        "promptIndex": .number(.int64(Int64(promptIndex)))
                    ])
                }
                return try wrap(update)
            }

        case .assistant(let assistant):
            var updates: [SessionUpdateEnvelope] = []
            if !assistant.content.isEmpty {
                updates.append(try wrap([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string(assistant.content),
                    ]),
                ]))
            }
            for call in assistant.toolCalls {
                let rawInput = (try? JSONDecoder().decode(
                    JSONValue.self,
                    from: Data(call.arguments.utf8)
                )) ?? .string(call.arguments)
                updates.append(try wrap([
                    "sessionUpdate": .string("tool_call"),
                    "toolCallId": .string(call.id),
                    "title": .string(call.name),
                    "kind": .string("other"),
                    "status": .string("in_progress"),
                    "rawInput": rawInput,
                ]))
            }
            return updates

        case .toolResult(let result):
            let outcome = outcomes?.outcome(for: result.toolCallId)
            let status: String
            switch outcome {
            case .failed, .denied, .cancelled:
                status = "failed"
            case .pending, .succeeded, nil:
                status = "completed"
            }
            return [try wrap([
                "sessionUpdate": .string("tool_call_update"),
                "toolCallId": .string(result.toolCallId),
                "status": .string(status),
                "content": .array([
                    .object([
                        "type": .string("content"),
                        "content": .object([
                            "type": .string("text"),
                            "text": .string(result.content),
                        ]),
                    ])
                ]),
                "rawOutput": .object(["output": .string(result.content)]),
            ])]

        case .system, .reasoning, .backendToolCall, .customToolOutput:
            return []
        }
    }
}

struct LiveAgentProfile: Sendable, Equatable {
    let model: String?
    let systemPrompt: String?
    let toolPolicy: LiveAgentToolPolicy
    let discoverSkills: Bool
}

struct LiveAgentToolPolicy: Sendable, Equatable {
    let configuredTools: [String]
    let allowlist: [String]
    let denylist: [String]
    let sessionAllowlist: [String]?
    let sessionDenylist: [String]
    let capabilityMode: AgentCapabilityMode?

    init(definition: AgentDefinition) {
        configuredTools = definition.toolConfig.toolNames
        allowlist = definition.tools
        denylist = definition.disallowedTools
        sessionAllowlist = definition.sessionToolsAllowlist
        sessionDenylist = definition.sessionToolsDenylist ?? []
        capabilityMode = definition.capabilityMode
    }

    private init(
        configuredTools: [String],
        allowlist: [String],
        denylist: [String],
        sessionAllowlist: [String]?,
        sessionDenylist: [String],
        capabilityMode: AgentCapabilityMode?
    ) {
        self.configuredTools = configuredTools
        self.allowlist = allowlist
        self.denylist = denylist
        self.sessionAllowlist = sessionAllowlist
        self.sessionDenylist = sessionDenylist
        self.capabilityMode = capabilityMode
    }

    /// Merge CLI `--tools` / `--disallowed-tools` with an optional agent-profile
    /// policy.
    ///
    /// Merge rules (CLI wins on allowlist, unions on denylist):
    /// - `--tools` set: `configuredTools` and `allowlist` become those names
    ///   (replacing any profile allowlist — membership in `configuredTools` is
    ///   required by `allows()`, so no wildcard).
    /// - only `--disallowed-tools`: `configuredTools = ["*"]`, denylist = those
    ///   names.
    /// - both: allowlist/`configuredTools` from `--tools`, denylist from
    ///   `--disallowed-tools`.
    /// - with a profile: CLI `--tools` replaces the profile allowlist when set;
    ///   CLI disallowed unions with the profile denylist. Session lists and
    ///   capability mode stay on the profile.
    /// - neither CLI flag nor profile: `nil` (unrestricted surface).
    static func resolveLaunchPolicy(
        tools: String?,
        disallowedTools: String?,
        profile: LiveAgentToolPolicy?
    ) -> LiveAgentToolPolicy? {
        let cliTools = parseCommaSeparatedToolNames(tools)
        let cliDenied = parseCommaSeparatedToolNames(disallowedTools)
        if cliTools == nil, cliDenied == nil {
            return profile
        }

        if let profile {
            let configured: [String]
            let allow: [String]
            if let cliTools {
                configured = cliTools
                allow = cliTools
            } else {
                configured = profile.configuredTools
                allow = profile.allowlist
            }
            let denied = uniquingPreserveOrder(profile.denylist + (cliDenied ?? []))
            return LiveAgentToolPolicy(
                configuredTools: configured,
                allowlist: allow,
                denylist: denied,
                sessionAllowlist: profile.sessionAllowlist,
                sessionDenylist: profile.sessionDenylist,
                capabilityMode: profile.capabilityMode
            )
        }

        if let cliTools {
            return LiveAgentToolPolicy(
                configuredTools: cliTools,
                allowlist: cliTools,
                denylist: cliDenied ?? [],
                sessionAllowlist: nil,
                sessionDenylist: [],
                capabilityMode: nil
            )
        }
        return LiveAgentToolPolicy(
            configuredTools: [wildcard],
            allowlist: [],
            denylist: cliDenied ?? [],
            sessionAllowlist: nil,
            sessionDenylist: [],
            capabilityMode: nil
        )
    }

    /// Comma-separated tool names: trim whitespace, drop empties. `nil` input
    /// stays `nil` (flag absent); an empty/whitespace-only string yields `[]`.
    static func parseCommaSeparatedToolNames(_ raw: String?) -> [String]? {
        guard let raw else { return nil }
        return raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func uniquingPreserveOrder(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names where seen.insert(name).inserted {
            result.append(name)
        }
        return result
    }

    /// A policy that constrains nothing except the capability mode.
    ///
    /// `allows(liveToolName:)` requires membership in `configuredTools`, so an
    /// "unrestricted" policy cannot express itself as an empty list — the
    /// sentinel below makes every name match instead. Used for a workflow child
    /// in a session that has no agent profile: the only thing to enforce is the
    /// clamped capability.
    init(unrestrictedWith capabilityMode: AgentCapabilityMode) {
        self.init(
            configuredTools: [Self.wildcard],
            allowlist: [],
            denylist: [],
            sessionAllowlist: nil,
            sessionDenylist: [],
            capabilityMode: capabilityMode
        )
    }

    /// The same policy with a different capability mode. Narrowing only: the
    /// caller (`LiveWorkflowLaunch.clampedPolicy`) has already clamped against
    /// the parent's mode.
    func withCapabilityMode(_ mode: AgentCapabilityMode) -> LiveAgentToolPolicy {
        LiveAgentToolPolicy(
            configuredTools: configuredTools,
            allowlist: allowlist,
            denylist: denylist,
            sessionAllowlist: sessionAllowlist,
            sessionDenylist: sessionDenylist,
            capabilityMode: mode
        )
    }

    static let wildcard = "*"

    func allows(liveToolName: String) -> Bool {
        let aliases = Self.aliases(for: liveToolName)
        guard Self.matches(configuredTools, aliases: aliases) else { return false }
        if !allowlist.isEmpty, !Self.matches(allowlist, aliases: aliases) { return false }
        if Self.matches(denylist, aliases: aliases) { return false }
        if Self.matches(sessionDenylist, aliases: aliases) { return false }
        if let sessionAllowlist, !Self.matches(sessionAllowlist, aliases: aliases) { return false }
        guard let capabilityMode else { return true }
        switch capabilityMode {
        case .readOnly, .readWrite:
            // `monitor` is upstream's process-control class alongside bash:
            // `kind_allowed` keeps `ToolKind::Monitor` only under Execute
            // and All (`xai-grok-workspace/src/capability.rs:157-160`) — it
            // starts an arbitrary command, so it is exactly as execute-
            // shaped as `run_terminal_cmd`.
            return liveToolName != "run_terminal_cmd"
                && liveToolName != LiveMonitorTools.toolName
        case .execute, .all:
            return true
        }
    }

    private static func aliases(for liveToolName: String) -> Set<String> {
        if liveToolName == "run_terminal_cmd" {
            return [liveToolName, "run_terminal_command"]
        }
        // The live surface advertises upstream's production names
        // (`xai-grok-agent/src/config.rs:161-173`); permission rules may still
        // spell either the production name or the registry alias. Without both
        // spellings here, a profile that grants `get_task_output` would
        // silently fail to match the `get_command_or_subagent_output` the
        // session advertises.
        if let alias = Self.backgroundTaskAliases[liveToolName] {
            return [liveToolName, alias]
        }
        // The spawn surface goes the other way: advertised under the
        // production name `spawn_subagent` (config.rs:152-156), matched under
        // the canonical registry id `task` as well, so a profile written
        // against either spelling gates the same surface.
        if liveToolName == LiveSubagentHost.advertisedToolName {
            return [liveToolName, "task"]
        }
        return [liveToolName]
    }

    private static let backgroundTaskAliases: [String: String] = [
        "get_command_or_subagent_output": "get_task_output",
        "wait_commands_or_subagents": "wait_tasks",
        "kill_command_or_subagent": "kill_task",
    ]

    private static func matches(_ entries: [String], aliases: Set<String>) -> Bool {
        entries.contains { entry in
            if entry == wildcard { return true }
            let shortName = entry.split(separator: ":").last.map(String.init) ?? entry
            return aliases.contains(entry) || aliases.contains(shortName)
        }
    }
}

actor LiveConversationHistory {
    private var record: LiveConversationRecord
    private let store: LiveConversationStore
    private let exportBoundary: ExportBoundary
    private var usageHandle: ChatStateHandle
    private var usageCancellationToken: ChatStateCancellationToken
    private var usageSamplingConfig: SamplingConfig
    private var activeUsagePromptID: String?

    init(
        record: LiveConversationRecord,
        store: LiveConversationStore,
        exportBoundary: ExportBoundary? = nil,
        samplingConfig: SamplingConfig? = nil
    ) {
        let resolvedSamplingConfig = samplingConfig ?? SamplingConfig(
            baseURL: "",
            model: record.currentModelID ?? "",
            provider: record.currentProvider ?? .defaultValue,
            contextWindow: 1
        )
        let cancellationToken = ChatStateCancellationToken()
        self.record = record
        self.store = store
        self.exportBoundary = exportBoundary ?? ExportBoundary(
            everUsedNonXAI: record.everUsedNonXAI != false
        )
        self.usageSamplingConfig = resolvedSamplingConfig
        self.usageCancellationToken = cancellationToken
        self.usageHandle = ChatStateActor.spawn(
            initialConversation: record.items,
            samplingConfig: resolvedSamplingConfig,
            initialSessionUsage: record.usageSnapshot?.usageLedger,
            persistence: NullChatPersistence(),
            cancellationToken: cancellationToken
        )
    }

    deinit {
        usageCancellationToken.cancel()
    }

    var items: [ConversationItem] { record.items }

    var sessionID: String { record.sessionID }

    var cacheAffinityID: String { record.cacheAffinityID ?? record.sessionID }

    var sharedExportBoundary: ExportBoundary { exportBoundary }

    var usageSnapshot: LiveSessionUsageSnapshot? { record.usageSnapshot }

    func snapshot() -> LiveConversationRecord { record }

    /// Switch the in-memory spine only after the replacement record is
    /// durably written. The old record remains available through the store.
    func replace(with record: LiveConversationRecord) throws {
        try LiveConversationStore.validateSessionID(record.sessionID)
        usageCancellationToken.cancel()
        let cancellationToken = ChatStateCancellationToken()
        var samplingConfig = usageSamplingConfig
        if let model = record.currentModelID {
            samplingConfig.model = model
        }
        if let provider = record.currentProvider {
            samplingConfig.provider = provider
        }
        usageSamplingConfig = samplingConfig
        usageCancellationToken = cancellationToken
        usageHandle = ChatStateActor.spawn(
            initialConversation: record.items,
            samplingConfig: samplingConfig,
            initialSessionUsage: record.usageSnapshot?.usageLedger,
            persistence: NullChatPersistence(),
            cancellationToken: cancellationToken
        )
        activeUsagePromptID = nil
        self.record = record
        if record.everUsedNonXAI != false {
            self.exportBoundary.sync(everUsedNonXAI: true)
        }
    }

    /// Rewrite history to its provider-neutral spine ahead of a provider
    /// change, and persist the result. Returns how many items were dropped.
    ///
    /// This is destructive on purpose: the persisted session must not keep
    /// carriers the next provider would be handed on resume.
    @discardableResult
    func isolateForProviderSwitch() async throws -> Int {
        let before = record.items
        let sanitized = liveProviderNeutralHistory(before)
        guard sanitized != before else { return 0 }
        var next = record
        next.items = sanitized
        next.updatedAt = Date()
        try await store.save(next)
        record = next
        usageHandle.replaceConversation(sanitized)
        return before.count - sanitized.count
    }

    /// Persist the route before the next provider can observe replayed history.
    /// A legacy record with no route metadata is treated as unsafe when it has
    /// opaque carriers; its unknown export marker remains nil rather than being
    /// rewritten to a falsely clean value.
    @discardableResult
    func reconcileRoute(modelID: String, provider: ModelProvider) async throws -> Int {
        let before = record
        let sanitized = liveProviderNeutralHistory(before.items)
        let hasOpaqueItems = sanitized != before.items
        let routeChanged = before.currentProvider != provider
        let legacyRoute = before.currentModelID == nil || before.currentProvider == nil
        let xAIExportClosed = provider.profile.allowsXaiServices && before.everUsedNonXAI == true
        let shouldSanitize = hasOpaqueItems && (routeChanged || legacyRoute || xAIExportClosed)

        var next = before
        if shouldSanitize {
            next.items = sanitized
        }
        next.currentModelID = modelID
        next.currentProvider = provider
        if !provider.profile.allowsXaiServices {
            next.everUsedNonXAI = true
        }
        if next != before {
            next.updatedAt = Date()
        }
        try await store.save(next)
        record = next
        if shouldSanitize {
            usageHandle.replaceConversation(next.items)
        }
        usageSamplingConfig.model = modelID
        usageSamplingConfig.provider = provider
        usageHandle.updateSamplingConfig(usageSamplingConfig)
        exportBoundary.observe(provider)
        return shouldSanitize ? before.items.count - sanitized.count : 0
    }

    func itemsForTurn(
        sessionID: String,
        prompt: String,
        schedulerFired: Bool = false
    ) -> [ConversationItem] {
        var items = sessionID == record.sessionID ? record.items : []
        // A scheduler-fired prompt persists with the turn like any user item,
        // tagged so compaction/replay/analytics see the cron turn — the port
        // of `ConversationItem::scheduler_fired` at the same seam
        // (acp_session_impl/turn.rs:858-860).
        items.append(schedulerFired ? .schedulerFired(prompt) : .user(prompt))
        return items
    }

    func commit(sessionID: String, items: [ConversationItem]) async throws {
        guard sessionID == record.sessionID else {
            throw CLIApplicationError.failed("conversation session mismatch: \(sessionID)")
        }
        record.items = items
        record.updatedAt = Date()
        try await store.save(record)
        usageHandle.replaceConversation(items)
    }

    func beginUsagePrompt(_ promptID: String) async {
        activeUsagePromptID = promptID
        usageHandle.incrementPromptIndex()
    }

    func endUsagePrompt(_ promptID: String) async {
        if activeUsagePromptID == promptID {
            activeUsagePromptID = nil
        }
    }

    func recordMainUsage(
        modelID: String,
        usage: TokenUsage?,
        costUsdTicks: Int64?
    ) async throws {
        if let usage {
            usageHandle.recordTokenUsage(totalTokens: UInt64(usage.totalTokens))
            usageHandle.recordLastTurnUsage(usage)
            usageHandle.recordModelCallUsage(
                modelId: modelID,
                usage: usage,
                apiDurationMs: nil,
                costUsdTicks: costUsdTicks
            )
        } else {
            guard await usageHandle.recordUnmeteredModelCall() else {
                throw CLIApplicationError.failed("session usage actor is unavailable")
            }
        }
        try await persistUsageSnapshot()
    }

    func foldSubagentUsage(
        byModel: [(model: String, totals: UsageTotals)],
        parentPromptID: String?,
        incomplete: Bool
    ) async -> Bool {
        guard !byModel.isEmpty || incomplete || parentPromptID == nil else { return true }
        let attributable = parentPromptID != nil && parentPromptID == activeUsagePromptID
        let applied = await usageHandle.recordSubagentUsage(
            byModel: byModel,
            attributeToPrompt: attributable,
            incomplete: incomplete
        )
        guard applied else {
            guard await markUsageIncomplete(prompt: attributable, session: true) else {
                return false
            }
            return false
        }

        var unattributedPromptIDs = record.usageSnapshot?.unattributedPromptIDs ?? []
        if let parentPromptID, !attributable {
            unattributedPromptIDs.append(parentPromptID)
        } else if parentPromptID == nil {
            let marked = await usageHandle.markUsageIncomplete(
                prompt: activeUsagePromptID != nil,
                session: true
            )
            guard marked else { return false }
        }

        do {
            try await persistUsageSnapshot(unattributedPromptIDs: unattributedPromptIDs)
            return true
        } catch {
            guard await markUsageIncomplete(prompt: attributable, session: true) else {
                return false
            }
            return false
        }
    }

    func markUsageIncomplete(
        prompt: Bool = true,
        session: Bool = true
    ) async -> Bool {
        guard await usageHandle.markUsageIncomplete(prompt: prompt, session: session) else {
            return false
        }
        do {
            try await persistUsageSnapshot()
            return true
        } catch {
            return false
        }
    }

    private func persistUsageSnapshot(
        unattributedPromptIDs: [String]? = nil
    ) async throws {
        let result = await usageHandle.tryGetSessionUsage()
        let ledger: UsageLedger
        switch result {
        case .success(let value):
            ledger = value
        case .failure:
            throw CLIApplicationError.failed("session usage actor is unavailable")
        }
        record.usageSnapshot = LiveSessionUsageSnapshot(
            ledger: ledger,
            unattributedPromptIDs: unattributedPromptIDs
                ?? record.usageSnapshot?.unattributedPromptIDs
                ?? []
        )
        record.updatedAt = Date()
        try await store.save(record)
    }

    /// `/rename` (upstream rename.rs:42-53): set the session's stored title
    /// and persist it.
    ///
    /// The write goes through this actor's own record — not a second reader
    /// of the same file — because the turn loop re-saves the whole record on
    /// every commit; a title written around this actor would silently vanish
    /// at the next turn's save.
    func rename(title: String) async throws {
        record.title = title
        record.updatedAt = Date()
        try await store.save(record)
    }

    /// Record a terminal tool-card display state for honest `/resume` seeding.
    /// Persisted on the next `commit` / save of the resident record.
    func recordToolOutcome(
        callID: String,
        state: OpenGrokShellToolState,
        detail: String? = nil
    ) {
        let outcome: ToolCallDisplayOutcome
        switch state {
        case .succeeded: outcome = .succeeded
        case .failed: outcome = .failed
        case .cancelled: outcome = .cancelled
        case .running: outcome = .pending
        }
        recordToolOutcome(callID: callID, outcome: outcome, detail: detail)
    }

    func recordToolOutcome(
        callID: String,
        outcome: ToolCallDisplayOutcome,
        detail: String? = nil
    ) {
        var map = record.toolOutcomes ?? ToolCallOutcomeMap()
        map.upsert(callID: callID, outcome: outcome, detail: detail)
        record.toolOutcomes = map
    }

    var toolOutcomes: ToolCallOutcomeMap { record.toolOutcomes ?? ToolCallOutcomeMap() }
}

private actor LiveSamplingTextEmission {
    private(set) var hasEmitted = false

    func record() {
        hasEmitted = true
    }

    func reset() {
        hasEmitted = false
    }
}

struct LiveShellSamplingDriver: OpenGrokShellSamplingDriver, Sendable {
    /// Owns the sampler rather than holding one, so `/model` can rebuild the
    /// provider stack between turns without replacing the shell.
    let modelSwitch: LiveModelSwitchCoordinator
    let toolExecutor: LiveToolExecutor
    let conversationHistory: LiveConversationHistory
    let systemPrompt: String?
    let skillsListing: String?
    /// The tool list this session advertises. In Code Mode it carries `exec`
    /// and `wait` and, in `code_mode_only`, hides everything the cell can
    /// reach through `tools.*`.
    let toolSurface: LiveCodeModeToolSurface
    /// `nil` in `direct` mode, which leaves the turn loop byte-identical to a
    /// session that has never heard of Code Mode.
    let codeMode: LiveCodeModeCoordinator?
    /// Keeps the conversation under the model's context window. Optional only
    /// so a test can build a driver without a model catalog; a live session
    /// always has one, and without it a long session dies at the wall.
    let compaction: LiveCompactionCoordinator?
    /// Mid-turn interjection buffer, drained between sampler rounds. The
    /// producer is the subagent collaboration quartet (`LiveSubagentHost`'s
    /// root-delivery path); `/btw` stopped producing here when it became a
    /// real side question.
    let interjections: LiveSessionInterjections
    /// Headless `--max-turns` cap. `nil` means unlimited sampler rounds
    /// (subject only to the 16-round safety cap). When set, the first model
    /// call counts as turn 1; after tool results, the next sampler round is
    /// allowed only while `toolTurnCount + 1 <= limit` (turn.rs:2347,3130-3140).
    let maxTurns: UInt32?

    func sample(
        context: OpenGrokShellProviderTurnContext,
        request: OpenGrokShellTurnRequest,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> OpenGrokShellSamplingResult {
        // Open the rewind point around the whole turn, and close it on every
        // exit path — including a thrown error or a cancelled turn, because a
        // turn that died half-way through an edit is precisely the one worth
        // being able to undo. Awaited rather than deferred into a detached
        // task: a `Task { }` in a `defer` is unordered against the *next*
        // turn's `beginPrompt`, which would let a late close swallow the
        // following prompt's point.
        let services = toolExecutor.sessionServices
        await services?.beginPrompt(text: request.text)
        // Interjections may merge into this turn from here on — the port of
        // `current_prompt_id` becoming Some for the Interject arm's
        // running-turn check (run_loop.rs:1968-1974).
        await conversationHistory.beginUsagePrompt(request.promptID)
        await interjections.beginTurn()
        do {
            let result = try await sampleTurn(context: context, request: request, emit: emit)
            // Buffer left intact: entries that raced past the final drain are
            // flushed into prompt turns by the controller (run_loop.rs:432-447).
            await interjections.endTurn()
            // One-shot swarm mode (task/tool trigger) ends with the turn
            // (run_loop.rs:419 → auto_exit_turn); manual mode survives.
            await toolExecutor.swarmMode.autoExitTurn()
            await services?.endPrompt()
            await conversationHistory.endUsagePrompt(request.promptID)
            return result
        } catch {
            if error is CancellationError {
                // Upstream's Cancel arm clears pending interjections — a
                // cancelled turn has nothing to inject into (run_loop.rs:989-991).
                await interjections.cancelTurn()
            } else {
                // A failed turn still flushes stranded interjections into
                // prompt turns, exactly like a completed one — upstream's
                // completion arm handles Err results too (run_loop.rs:416-447).
                await interjections.endTurn()
            }
            // The completion arm runs auto-exit for Err and cancelled
            // resolutions too: a one-shot swarm turn that died must not
            // leave the next unrelated turn in swarm mode.
            await toolExecutor.swarmMode.autoExitTurn()
            await services?.endPrompt()
            await conversationHistory.endUsagePrompt(request.promptID)
            throw error
        }
    }

    private func sampleTurn(
        context: OpenGrokShellProviderTurnContext,
        request: OpenGrokShellTurnRequest,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> OpenGrokShellSamplingResult {
        guard let codeMode else {
            return try await runTurn(context: context, request: request, emit: emit)
        }
        // Nested calls raise their tool cards through this turn's sink, and a
        // cancelled turn (Esc) terminates whatever cells are still running.
        await codeMode.beginTurn(emit: emit)
        do {
            let result = try await withTaskCancellationHandler {
                try await runTurn(context: context, request: request, emit: emit)
            } onCancel: {
                Task { await codeMode.cancelActiveCells() }
            }
            await codeMode.endTurn()
            return result
        } catch {
            await codeMode.cancelActiveCells()
            await codeMode.endTurn()
            throw error
        }
    }

    private func runTurn(
        context: OpenGrokShellProviderTurnContext,
        request: OpenGrokShellTurnRequest,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> OpenGrokShellSamplingResult {
        // One snapshot per turn: a switch that lands mid tool loop applies to
        // the next turn, never to half of this one.
        let active = await modelSwitch.snapshot()
        let sampler = active.sampler
        var items = await conversationHistory.itemsForTurn(
            sessionID: context.sessionID,
            prompt: request.text,
            // Derived from the prompt-id prefix, exactly upstream's
            // `PromptOrigin::from_prompt_id` (session/mod.rs:126-127) — the
            // runtime adapter stamps `scheduler-fired-` on cron turns.
            schedulerFired: request.promptID.hasPrefix(
                OpenGrokPagerInteractiveController.schedulerFiredPromptIDPrefix
            )
        )
        let combinedSystemPrompt = [systemPrompt, skillsListing]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n\n")
        if !combinedSystemPrompt.isEmpty,
           !items.contains(where: {
               if case .system = $0 { return true }
               return false
           }) {
            items.insert(.system(combinedSystemPrompt), at: 0)
        }
        // Memory is injected after the system prompt exists so it has an item
        // to splice into, and before compaction runs so the injected block
        // counts toward the budget like everything else. No-ops on every turn
        // after the first, and on a resumed session whose transcript already
        // carries a `<memory-context>` block.
        let services = toolExecutor.sessionServices
        items = await services?.injectMemoryContext(into: items, prompt: request.text) ?? items

        // Swarm mode's entire turn-behavior payload: the `<system-reminder>`
        // user items the tracker queued (run_loop.rs:676 →
        // `maybe_inject_swarm_reminder`, reminders.rs:579-593) — the exit
        // notice first, then the entry steering text, both persisted with
        // the turn like every other item. Injected before compaction so the
        // reminder counts toward the budget like everything else.
        let swarmReminders = await toolExecutor.swarmMode.takeReminders()
        if swarmReminders.exit {
            items.append(.user(wrapSystemReminder(swarmModeExitReminder)))
        }
        if swarmReminders.inject {
            items.append(.user(wrapSystemReminder(swarmModeReminder)))
        }

        // Structured output coordinator setup matching Rust turn.rs:2370-2396, 2512-2522
        var structuredCoordinator = StructuredOutputTurnCoordinator(
            schema: request.jsonSchema,
            backend: active.configuration.apiBackend,
            codeModeOnly: toolSurface.mode == .codeModeOnly
        )
        let (advertisedTools, structuredReminder, nativeSchema) = structuredCoordinator.prepareRequest(
            tools: toolSurface.modelTools
        )
        if let structuredReminder {
            items.append(.user(wrapSystemReminder(structuredReminder)))
        }

        // Rust acknowledges the user append before the provider request. A
        // failed or interrupted first sample must therefore leave a resumable
        // prompt instead of erasing the turn that the user actually submitted.
        try await conversationHistory.commit(
            sessionID: context.sessionID,
            items: items
        )

        // UserPromptSubmit fires once the user message is staged and before
        // the turn loop starts, matching upstream (turn.rs:919-927). Payload
        // carries the prompt text (event.rs:453-456).
        toolExecutor.fireObserveHook(
            event: .userPromptSubmit,
            promptID: request.promptID,
            payload: ["prompt": .string(request.text)]
        )

        var toolTurnCount = 1
        var toolRoundCount = 0
        var stopHookContinuations = 0
        var stopHookActive = false
        var authRetrySchedule = AuthRetrySchedule()

        do {
            while true {
                try Task.checkCancellation()
                // Mid-turn interjections land at the top of every sampler
                // round. Upstream drains right before each request is built
                // (turn.rs:2413) AND immediately after tool results land
                // (tool_calls.rs:509); in this loop those are the same point,
                // because control re-enters here after `executeToolCalls`.
                // Before compaction on purpose: the injected user item must
                // count toward the budget like everything else.
                items.append(contentsOf: await drainPendingInterjections())
                // Before every sample, not only the first: a tool round can add
                // more to the prompt than the whole preceding turn did, and the
                // request that dies at the context wall is usually the one after a
                // large tool result, not the one that opened the turn.
                items = await compactIfNeeded(
                    items: items,
                    turnID: context.turnID,
                    emit: emit
                )
                if items != (await conversationHistory.items) {
                    try await conversationHistory.commit(
                        sessionID: context.sessionID,
                        items: items
                    )
                }
                let streamedText = LiveSamplingTextEmission()
                var response: OpenGrokLiveSamplingResponse?
                while response == nil {
                    do {
                        await streamedText.reset()
                        let codexPermissions = await toolExecutor.currentCodexPermissions(
                            provider: active.provider
                        )
                        response = try await sampler.sample(OpenGrokLiveSamplingRequest(
                            sessionID: context.sessionID,
                            cacheAffinityID: await conversationHistory.cacheAffinityID,
                            turnID: context.turnID,
                            logicalTurnID: context.turnID,
                            model: active.modelID,
                            prompt: request.text,
                            items: items,
                            tools: advertisedTools,
                            jsonSchema: nativeSchema,
                            codexPermissions: codexPermissions
                        )) { event in
                            switch event {
                            case .output(let text):
                                await streamedText.record()
                                await emit(.assistantText(text))
                            case .status(let status):
                                await emit(.status(status))
                            case .reasoning(let text):
                                await emit(.reasoning(text))
                            case .toolCallDelta(
                                let toolIndex, let id, let name, let argumentsDelta
                            ):
                                await emit(.toolCallDelta(
                                    toolIndex: toolIndex,
                                    id: id,
                                    name: name,
                                    argumentsDelta: argumentsDelta
                                ))
                            case .toolCallArgumentsComplete:
                                // Arguments readiness is not completion: only
                                // the final response can authorize dispatch.
                                break
                            case .retrying(
                                let attempt, let maxRetries, let kind, let reason
                            ):
                                await emit(.retrying(
                                    attempt: attempt,
                                    maxRetries: maxRetries,
                                    kind: kind.asString,
                                    reason: reason
                                ))
                            case .failed(let error):
                                await emit(.samplingFailed(
                                    kind: error.kind.asString,
                                    message: error.message,
                                    isRetryable: error.isRetryable,
                                    statusCode: error.statusCode
                                ))
                            case .backendToolCallStarted(let callId, let name):
                                await emit(.backendToolStarted(
                                    callID: callId,
                                    name: name
                                ))
                            case .backendToolCallCompleted(let callId, let name, let result):
                                let resultText: String?
                                if let result {
                                    resultText = LiveToolResultText.jsonString(result)
                                } else {
                                    resultText = nil
                                }
                                await emit(.backendToolCompleted(
                                    callID: callId,
                                    name: name,
                                    result: resultText
                                ))
                            }
                        }
                        authRetrySchedule.resetOnSuccess()
                } catch let error as SamplingError {
                    guard case .auth(_, let credential) = error else { throw error }
                    switch authRetrySchedule.onRecovered401(credential) {
                    case .unchargedResubmit:
                        await Task.yield()
                    case .backoff(_, let delaySeconds):
                        try await Task.sleep(
                            nanoseconds: UInt64(max(0, delaySeconds) * 1_000_000_000)
                        )
                    case .exhausted, .runawayGuard:
                        // Notification fires on auth-retry exhaustion, the
                        // port's analog of upstream's `RetryState::Exhausted`
                        // (hook_dispatch.rs:80-85 → `agent_error`).
                        toolExecutor.fireNotification(
                            type: "agent_error",
                            message: "authentication retries exhausted",
                            level: "error"
                        )
                        throw error
                    }
                }
                }
                guard let response else { throw CLIApplicationError.failed("sampling produced no response") }
                items.append(contentsOf: response.items)
                try await conversationHistory.commit(
                    sessionID: context.sessionID,
                    items: items
                )
                try await conversationHistory.recordMainUsage(
                    modelID: active.modelID,
                    usage: response.usage,
                    costUsdTicks: response.costUsdTicks
                )
                let emittedText = await streamedText.hasEmitted
                if !emittedText, !response.output.isEmpty {
                    await emit(.assistantText(response.output))
                }

                guard !response.toolCalls.isEmpty else {
                    try Task.checkCancellation()
                    if stopHookContinuations < 8 {
                        let stopResult = await toolExecutor.runStop(
                            promptID: request.promptID,
                            payload: [
                                "reason": .string("end_turn"),
                                "stopHookActive": .boolean(stopHookActive),
                                "lastAssistantMessage": .string(response.output),
                            ]
                        )
                        if stopResult.preventContinuation == nil,
                           stopResult.wantsContinuation {
                            stopHookContinuations += 1
                            stopHookActive = true
                            items.append(.autoContinue(formatLiveStopFeedback(stopResult)))
                            continue
                        }
                    }
                    // Pre-completion drain (turn.rs:2956-2959): an
                    // interjection that arrived during the final sampler
                    // round gets one more round instead of missing the turn.
                    let preCompletion = await drainPendingInterjections()
                    if !preCompletion.isEmpty {
                        items.append(contentsOf: preCompletion)
                        continue
                    }
                    try await conversationHistory.commit(
                        sessionID: context.sessionID,
                        items: items
                    )
                    // Late drain during turn-end bookkeeping
                    // (turn.rs:2968-2973): the commit above is this port's
                    // `finalize_turn_bookkeeping`, and an interjection that
                    // landed during it still merges into THIS turn. The next
                    // commit re-saves the record with the extra items.
                    let late = await drainPendingInterjections()
                    if !late.isEmpty {
                        items.append(contentsOf: late)
                        continue
                    }
                    var structuredVal: JSONValue? = nil
                    var structuredErr: String? = nil
                    if let validation = structuredCoordinator.validateAssistantText(response.output) {
                        switch validation {
                        case .success(let v):
                            structuredVal = v
                        case .failure(let e):
                            structuredErr = e
                        }
                    }
                    return OpenGrokShellSamplingResult(
                        output: response.output,
                        stopReason: response.stopReason,
                        structuredOutput: structuredVal,
                        structuredOutputError: structuredErr
                    )
                }

                // Structured output interception & retry loop (turn.rs:1939-1987)
                let (structuredStep, structuredResults) = structuredCoordinator.handleToolCalls(response.toolCalls)
                for (callID, content) in structuredResults {
                    items.append(ConversationItem.toolResult(ToolResultItem(toolCallId: callID, content: content)))
                }
                if !structuredResults.isEmpty {
                    try await conversationHistory.commit(
                        sessionID: context.sessionID,
                        items: items
                    )
                }

                switch structuredStep {
                case .complete(let result):
                    try await conversationHistory.commit(
                        sessionID: context.sessionID,
                        items: items
                    )
                    let val: JSONValue? = {
                        if case .success(let v) = result { return v }
                        return nil
                    }()
                    let err: String? = {
                        if case .failure(let e) = result { return e }
                        return nil
                    }()
                    return OpenGrokShellSamplingResult(
                        output: response.output,
                        stopReason: response.stopReason,
                        structuredOutput: val,
                        structuredOutputError: err
                    )

                case .retry:
                    continue

                case .proceed(let remainingCalls):
                    if remainingCalls.isEmpty {
                        continue
                    }
                    guard toolRoundCount < 16 else {
                        throw CLIApplicationError.failed(
                            "tool loop exceeded 16 rounds"
                        )
                    }
                    toolRoundCount += 1
                    let toolResults = try await LiveSubagentParentPromptContext.$promptID.withValue(
                        request.promptID
                    ) {
                        try await executeToolCalls(
                            remainingCalls,
                            sessionID: context.sessionID,
                            emit: emit
                        )
                    }
                    items.append(contentsOf: toolResults)
                    try await conversationHistory.commit(
                        sessionID: context.sessionID,
                        items: items
                    )
                    let nextTurn = toolTurnCount + 1
                    if let limit = maxTurns, nextTurn > limit {
                        try await conversationHistory.commit(
                            sessionID: context.sessionID,
                            items: items
                        )
                        return OpenGrokShellSamplingResult(
                            output: response.output,
                            stopReason: "max_turns_reached"
                        )
                    }
                    toolTurnCount = nextTurn
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // StopFailure fires when the turn ends due to an API/turn error
            // rather than a genuine stop, matching upstream (turn.rs:1224-1234).
            // Payload carries the error class, details, and the rendered
            // message (event.rs:376-387). A cancellation is not a failure and
            // is rethrown without firing.
            toolExecutor.fireObserveHook(
                event: .stopFailure,
                promptID: request.promptID,
                payload: [
                    "error": .string(stopFailureKind(for: error)),
                    "errorDetails": .string(String(describing: error)),
                    "lastAssistantMessage": .string(String(describing: error)),
                ]
            )
            throw error
        }
    }

    /// Map a thrown turn error to upstream's `StopFailureKind` snake_case
    /// token (event.rs:294-301). The port does not classify every provider
    /// error yet, so unknown errors map to `unknown` rather than guessing.
    private func stopFailureKind(for error: Error) -> String {
        if error is CancellationError { return "unknown" }
        if let sampling = error as? SamplingError {
            switch sampling {
            case .auth: return "authentication_failed"
            case .api(let status, _, _, _, _, _):
                return status.code == 429 ? "rate_limit" : "server_error"
            default: return "unknown"
            }
        }
        return "unknown"
    }

    /// Drain all pending interjections into synthetic user items — the port
    /// of `drain_pending_interjections` (interjection.rs:290-338): FIFO, one
    /// item per entry, never merged, never appended to tool results, each
    /// wrapped by the shared `formatInterjection` and tagged
    /// `syntheticReason: .interjection` so compaction, replay, and analytics
    /// see the steering text as its own user turn.
    ///
    /// Deliberately narrower than upstream, both recorded divergences:
    /// upstream's image-placeholder sanitizer (interjection.rs:304-305) has
    /// nothing to strip here — this port's interjection path carries no
    /// image placeholders — and the `<skill_information>` expansion for
    /// `/skill` interjections (interjection.rs:239-279) is unported, so a
    /// slash-prefixed interjection reaches the model as bare text.
    private func drainPendingInterjections() async -> [ConversationItem] {
        await interjections.drainAll().map { entry in
            .interjection(formatInterjection(entry.text))
        }
    }

    /// Keep the prompt under the model's context window, reporting what it did.
    ///
    /// Never throws. A session that cannot compact still gets to take its turn
    /// and see the provider's own error — dying here would replace a
    /// recoverable "too long" with an unrecoverable one, which is the failure
    /// this whole path exists to remove.
    private func compactIfNeeded(
        items: [ConversationItem],
        turnID: String,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async -> [ConversationItem] {
        guard let compaction else { return items }
        // No status for the check itself: it runs before every sample, so
        // announcing it would put a line on the status bar for a token count
        // that almost always comes back under the threshold. `willCompact`
        // fires only once the coordinator has decided, which is what makes
        // "Compacting…" true whenever it is on screen. It is the third
        // turn-status label, beside "Thinking…" and "Responding…", matching
        // upstream's `TurnActivity::AutoCompacting` (`views/turn_status.rs:704`)
        // — same ellipsis character, and the renderer already gives a
        // `.status(text)` the spinner and the phase timer.
        switch await compaction.compactIfNeeded(items: items, turnID: turnID, willCompact: {
            // PreCompact fires once the coordinator has decided to compact
            // and before the work begins, matching upstream (compaction.rs:1488).
            // The automatic path's source is "auto" (event.rs:493-496).
            toolExecutor.fireObserveHook(
                event: .preCompact,
                payload: ["source": .string("auto")]
            )
            await emit(.status("Compacting\u{2026}"))
        }) {
        case .notNeeded:
            return items
        case .unableToCompact(let reason):
            await emit(.status("could not compact the conversation: \(reason)"))
            return items
        case .compacted(let replacement, let report):
            // PostCompact fires after a successful compaction, matching
            // upstream (compaction.rs:1081-1089). Source is "auto" here.
            toolExecutor.fireObserveHook(
                event: .postCompact,
                payload: ["source": .string("auto")]
            )
            await emit(.status(report.notice))
            return replacement
        }
    }

    /// Byte-identical copy of the exclusive-batch refusal
    /// (tool_calls.rs:460).
    static let swarmExclusiveBatchError =
        "`agent_swarm` must be the only tool call in its batch. Inspect briefly, "
        + "then make one exclusive agent_swarm call for independent work; use "
        + "ordinary task calls for heterogeneous small work."

    private func executeToolCalls(
        _ calls: [ToolCall],
        sessionID: String,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> [ConversationItem] {
        // Feed the auto-mode classifier the recent conversation (Rust refreshes
        // classifier turns before tool batches — tool_calls.rs:1618-1622).
        if let permissions = await toolExecutor.permissionHandle() {
            let transcript = LiveAutoModeComposition.transcript(
                from: await conversationHistory.items
            )
            await permissions.setClassifierTranscript(transcript)
        }
        // `agent_swarm` must be the only call in its batch
        // (tool_calls.rs:456-468): every call in a violating batch gets the
        // fixed refusal as its tool result and nothing executes.
        let swarmCall = calls.contains { $0.name == LiveSubagentHost.swarmToolName }
        if swarmCall, calls.count != 1 {
            return calls.map {
                ConversationItem.toolResult(ToolResultItem(
                    toolCallId: $0.id,
                    content: Self.swarmExclusiveBatchError
                ))
            }
        }
        if swarmCall {
            // A swarm call while the mode is off enters it with the `tool`
            // trigger (tool_calls.rs:469-475): no reminder is queued — the
            // model already made the call the reminder exists to elicit —
            // and the mode auto-exits at the turn boundary.
            if await !toolExecutor.swarmMode.enabled {
                await toolExecutor.swarmMode.enter(.tool)
            }
        }

        // `exec` and `wait` are transport, not tools: they raise no card and
        // never announce themselves, so the transcript shows only the nested
        // calls the cell made (turn.rs:1998). They also mutate one runtime, so
        // they run in order rather than joining the parallel group.
        var transportResults: [Int: ToolResultItem] = [:]
        if let codeMode {
            for (index, call) in calls.enumerated() where codeMode.isTransportCall(call) {
                try Task.checkCancellation()
                transportResults[index] = await codeMode.handleTransportCall(call)
            }
        }
        let dispatched = calls.enumerated().filter { transportResults[$0.offset] == nil }

        for (_, call) in dispatched {
            try Task.checkCancellation()
            await emit(.tool(OpenGrokShellToolUpdate(
                callID: call.callId,
                name: call.name,
                input: call.arguments,
                state: .running
            )))
            await emit(.status("running tool \(call.name)"))
        }

        let workingDirectory = await toolExecutor.workingDirectory(sessionID: sessionID)
        return try await withThrowingTaskGroup(
            of: (Int, ToolResultItem).self,
            returning: [ConversationItem].self
        ) { group in
            for (index, call) in dispatched {
                group.addTask {
                    let result = await toolExecutor.invoke(
                        sessionID: sessionID,
                        workingDirectory: workingDirectory,
                        call: call,
                        onOutput: { delta in
                            await emit(.tool(OpenGrokShellToolUpdate(
                                callID: delta.callID,
                                name: call.name,
                                input: call.arguments,
                                output: delta.text,
                                state: .running,
                                outputOp: delta.op == .replace ? .replace : .append
                            )))
                        }
                    )
                    let content: String
                    switch result {
                    case .success(let result):
                        content = result.promptText
                        let structuredOutput = LiveToolResultText.structuredOutput(for: result)
                        // Keep the success result (promptText / PostToolUse)
                        // and only flip the *display* state when structured
                        // terminal metadata shows a nonzero exit / timeout /
                        // signal. Do not sniff prompt text for the word
                        // "failed".
                        let displayState = LiveToolResultText.displayState(for: result)
                        await emit(.tool(OpenGrokShellToolUpdate(
                            callID: call.callId,
                            name: call.name,
                            input: call.arguments,
                            output: content,
                            structuredOutput: structuredOutput,
                            state: displayState
                        )))
                        await conversationHistory.recordToolOutcome(
                            callID: call.callId,
                            state: displayState
                        )
                        await emit(.status(
                            displayState == .failed
                                ? "tool \(call.name) failed"
                                : "tool \(call.name) completed"
                        ))
                        toolExecutor.firePostToolUse(call: call, result: result)
                    case .failure(.cancelled):
                        await emit(.tool(OpenGrokShellToolUpdate(
                            callID: call.callId,
                            name: call.name,
                            input: call.arguments,
                            output: "Cancelled",
                            state: .cancelled
                        )))
                        await conversationHistory.recordToolOutcome(
                            callID: call.callId,
                            state: .cancelled
                        )
                        throw CancellationError()
                    case .failure(.denied):
                        // The pipeline refused to authorize the call, so the
                        // tool never ran. `PermissionDenied` already fired at
                        // the gate; `PostToolUseFailure` is for a tool that
                        // executed and errored, so it must not fire here.
                        content = "Tool \(call.name) was not executed: denied"
                        await emit(.tool(OpenGrokShellToolUpdate(
                            callID: call.callId,
                            name: call.name,
                            input: call.arguments,
                            output: content,
                            state: .failed
                        )))
                        await conversationHistory.recordToolOutcome(
                            callID: call.callId,
                            outcome: .denied,
                            detail: content
                        )
                        await emit(.status("tool \(call.name) denied"))
                    case .failure(let error):
                        content = "Tool \(call.name) failed: \(error.description)"
                        await emit(.tool(OpenGrokShellToolUpdate(
                            callID: call.callId,
                            name: call.name,
                            input: call.arguments,
                            output: content,
                            state: .failed
                        )))
                        await conversationHistory.recordToolOutcome(
                            callID: call.callId,
                            state: .failed
                        )
                        await emit(.status("tool \(call.name) failed"))
                        toolExecutor.firePostToolUseFailure(call: call, error: error)
                    }
                    return (index, ToolResultItem(
                        toolCallId: call.callId,
                        content: content
                    ))
                }
            }

            var orderedResults = Array<ToolResultItem?>(repeating: nil, count: calls.count)
            for (index, result) in transportResults {
                orderedResults[index] = result
            }
            for try await (index, result) in group {
                orderedResults[index] = result
            }
            return orderedResults.compactMap { result in
                result.map(ConversationItem.toolResult)
            }
        }
    }

}

private func writeLiveConversationDataAtomically(
    _ data: Data,
    to destination: URL,
    fileManager: FileManager
) throws {
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(
        "\(destination.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).tmp"
    )
    defer { try? fileManager.removeItem(at: temporary) }
    try data.write(to: temporary, options: [.withoutOverwriting])
    try atomicallyReplaceItem(at: destination, with: temporary)
}

/// Helpers for tool-result display state and JSON flattening at the live seam.
enum LiveToolResultText {
    static func structuredOutput(for result: OpenGrokShellToolCallResult) -> String? {
        guard let data = try? JSONEncoder().encode(result.value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Derive pager/shell display state from a successful tool result without
    /// dropping `promptText`. Nonzero exit / timeout / signal → `.failed`.
    static func displayState(
        for result: OpenGrokShellToolCallResult
    ) -> OpenGrokShellToolState {
        // Prefer the executor-stamped display state (A3). Fall back to
        // structured terminal metadata so a result that left the default
        // `.succeeded` but carries exit_code/signal/timeout is still honest.
        // Never sniff prompt text.
        if result.displayState != .succeeded {
            return result.displayState
        }
        guard let object = result.value.objectValue else {
            return .succeeded
        }
        if case .bool(true) = object["cancelled"] {
            return .cancelled
        }
        if case .bool(true) = object["timed_out"] {
            return .failed
        }
        if case .string(let signal) = object["signal"], !signal.isEmpty {
            return .failed
        }
        if let code = object["exit_code"]?.int64Value, code != 0 {
            return .failed
        }
        return .succeeded
    }

    static func jsonString(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
