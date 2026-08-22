import Foundation
import OpenGrokCompaction
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokPaths
import OpenGrokShared
import OpenGrokShellSessionSupport

/// The durable, Rust-compatible documents belonging to one Open Grok session.
///
/// `summary.json` is the publication marker: directories containing only image,
/// checkpoint, or compatibility sidecars are never considered resumable.
/// Upstream: `xai-grok-shell/src/session/persistence.rs:444-449` and
/// `xai-grok-shell/src/session/storage/jsonl/mod.rs:554-609` at `650c1db7`.
public struct SessionDocumentStore: Sendable {
    public static let summaryFileName = "summary.json"
    public static let chatHistoryFileName = "chat_history.jsonl"
    public static let updatesFileName = "updates.jsonl"
    public static let eventsFileName = "events.jsonl"
    public static let auxiliaryStateFileName = "state.json"

    public let grokHome: URL

    public init(grokHome: URL) {
        self.grokHome = grokHome.standardizedFileURL
    }

    /// Resolve `$OPENGROK_HOME/sessions/<encoded-cwd>/<session-id>`.
    public func sessionDirectory(sessionID: String, cwd: String) throws -> URL {
        try Self.validateSessionID(sessionID)
        try RelocationFS.validateCWD(field: "session cwd", value: cwd)
        return RelocationFS.sessionDirAt(
            grokHome: grokHome,
            cwd: cwd,
            sessionID: sessionID
        ).standardizedFileURL
    }

    /// Atomically publish the canonical session documents.
    ///
    /// Existing unknown summary fields and append-only updates survive a stale
    /// snapshot. The summary is replaced last so an interrupted initial save
    /// never publishes a directory without its conversation history.
    public func save(_ state: PersistedSessionState) throws {
        var state = state
        let directory = try sessionDirectory(
            sessionID: state.summary.sessionID.rawValue,
            cwd: state.summary.cwd
        )
        _ = try OpenGrokConfig.ensureSessionsCwdDir(
            state.summary.cwd,
            environment: ["OPENGROK_HOME": grokHome.path]
        )
        try RelocationFS.createDirectoryDurable(directory)

        let summaryURL = directory.appendingPathComponent(Self.summaryFileName)
        let summaryLock = try AdvisoryFileLock.acquire(
            at: directory.appendingPathComponent("\(Self.summaryFileName).lock")
        )
        defer { summaryLock.release() }

        if FileManager.default.fileExists(atPath: summaryURL.path) {
            let existing = try readSummary(at: summaryURL)
            guard existing.sessionID == state.summary.sessionID else {
                throw SessionDocumentStoreError.corruptDocument(
                    path: summaryURL.path,
                    reason: "session ID does not match its directory"
                )
            }
            state.summary.extra = existing.extra.merging(state.summary.extra) { _, new in new }
        }

        if state.summary.extra["cache_affinity_id"]?.stringValue?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty != false {
            let inherited = state.summary.extra["fork_context_source"]?.stringValue == "forked_verbatim"
                ? state.summary.parentSessionID
                : nil
            state.summary.extra["cache_affinity_id"] = .string(
                inherited ?? state.summary.sessionID.rawValue
            )
        }

        let historyURL = directory.appendingPathComponent(Self.chatHistoryFileName)
        try withJSONLLock(at: historyURL) {
            try writeJSONLines(state.chatHistory, to: historyURL)
        }

        let updatesURL = directory.appendingPathComponent(Self.updatesFileName)
        try withJSONLLock(at: updatesURL) {
            let existing = try readUpdates(at: updatesURL).values
            state.updates = mergeUpdates(existing: existing, incoming: state.updates)
            try writeJSONLines(state.updates, to: updatesURL)
        }

        state.summary.messageCount = UInt64(state.updates.count)
        state.summary.chatMessageCount = UInt64(state.chatHistory.count)

        let auxiliaryURL = directory.appendingPathComponent(Self.auxiliaryStateFileName)
        try RelocationFS.writeAtomicDurable(
            path: auxiliaryURL,
            data: makeEncoder(prettyPrinted: false).encode(state)
        )
        try RelocationFS.writeAtomicDurable(
            path: summaryURL,
            data: encodeSummary(state.summary)
        )
    }

    /// Load a canonical session, falling back to the former flat state sidecar.
    ///
    /// `cwd` receives priority but never hides a session relocated to a different
    /// workspace. Malformed JSONL lines are skipped without discarding later
    /// valid records; damaged chat history is preserved beside the healed file.
    public func load(sessionID: String, cwd: String? = nil) throws -> PersistedSessionState? {
        try loadRecovering(sessionID: sessionID, cwd: cwd)?.state
    }

    public func load(
        sessionID: SessionID,
        cwd: String? = nil
    ) throws -> PersistedSessionState? {
        try load(sessionID: sessionID.rawValue, cwd: cwd)
    }

    /// Load a session and expose corruption recovery instead of hiding it.
    public func loadRecovering(
        sessionID: String,
        cwd: String? = nil
    ) throws -> SessionDocumentLoadResult? {
        try Self.validateSessionID(sessionID)

        if let directory = try findSessionDirectory(sessionID: sessionID, preferredCWD: cwd) {
            return try readCanonicalSession(at: directory, expectedSessionID: sessionID)
        }

        let legacy = grokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent(Self.auxiliaryStateFileName)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return nil }
        let state: PersistedSessionState
        do {
            state = try makeDecoder().decode(PersistedSessionState.self, from: Data(contentsOf: legacy))
        } catch {
            throw SessionDocumentStoreError.corruptDocument(
                path: legacy.path,
                reason: String(describing: error)
            )
        }
        guard state.summary.sessionID.rawValue == sessionID else {
            throw SessionDocumentStoreError.corruptDocument(
                path: legacy.path,
                reason: "session ID does not match its directory"
            )
        }
        return SessionDocumentLoadResult(state: state)
    }

    /// Enumerate only published canonical sessions, newest first.
    public func list(cwd: String? = nil) throws -> [SessionSummary] {
        let directories = try canonicalSessionDirectories(cwd: cwd)
        var summaries: [SessionSummary] = []
        for directory in directories {
            let summaryURL = directory.appendingPathComponent(Self.summaryFileName)
            do {
                let summary = try readSummary(at: summaryURL)
                guard summary.sessionID.rawValue == directory.lastPathComponent else { continue }
                if let cwd, summary.cwd != cwd { continue }
                let hidden = summary.extra["hidden"]?.boolValue
                    ?? summary.sessionKind?.hasPrefix("subagent")
                    ?? false
                if hidden { continue }
                summaries.append(summary)
            } catch {
                // A corrupt sibling must not make otherwise healthy sessions
                // undiscoverable. Direct load still reports the exact error.
                continue
            }
        }
        return summaries.sorted {
            let leftActivity = lastActivityDate(for: $0)
            let rightActivity = lastActivityDate(for: $1)
            if leftActivity == rightActivity {
                return $0.sessionID.rawValue < $1.sessionID.rawValue
            }
            return leftActivity > rightActivity
        }
    }

    /// Append one provider-neutral conversation item without rewriting history.
    public func appendChatItem(
        _ item: JSONValue,
        sessionID: String,
        cwd: String
    ) throws {
        let directory = try publishedSessionDirectory(sessionID: sessionID, cwd: cwd)
        let file = directory.appendingPathComponent(Self.chatHistoryFileName)
        try appendJSONLine(item, to: file)
        try mutateSummary(in: directory) { summary in
            if summary.chatMessageCount < .max {
                summary.chatMessageCount += 1
            }
            summary.updatedAt = Date()
        }
    }

    /// Append an ACP/xAI notification to the replay transcript.
    public func appendUpdate(
        _ update: SessionUpdateEnvelope,
        sessionID: String,
        cwd: String
    ) throws {
        let directory = try publishedSessionDirectory(sessionID: sessionID, cwd: cwd)
        let file = directory.appendingPathComponent(Self.updatesFileName)
        try appendJSONLine(update, to: file)
        try mutateSummary(in: directory) { summary in
            if summary.messageCount < .max {
                summary.messageCount += 1
            }
            summary.updatedAt = Date()
        }
    }

    /// Events are opt-in upstream; this file exists only after an explicit append.
    public func appendEvent(
        _ event: JSONValue,
        sessionID: String,
        cwd: String
    ) throws {
        let directory = try publishedSessionDirectory(sessionID: sessionID, cwd: cwd)
        try appendJSONLine(event, to: directory.appendingPathComponent(Self.eventsFileName))
    }

    public func readEvents(sessionID: String, cwd: String) throws -> [JSONValue] {
        let directory = try publishedSessionDirectory(sessionID: sessionID, cwd: cwd)
        return try readJSONLines(
            JSONValue.self,
            from: directory.appendingPathComponent(Self.eventsFileName)
        ).values
    }

    /// Persist the exact compaction artifact consumed by cross-compaction rewind.
    @discardableResult
    public func persistCheckpoint(
        _ checkpoint: CompactionCheckpointFile,
        sessionID: String,
        cwd: String
    ) throws -> URL {
        try Self.validateSessionID(checkpoint.checkpointID)
        let directory = try publishedSessionDirectory(sessionID: sessionID, cwd: cwd)
        let checkpointURL = directory
            .appendingPathComponent("compaction_checkpoints", isDirectory: true)
            .appendingPathComponent("\(checkpoint.checkpointID).json")
        try RelocationFS.writeAtomicDurable(
            path: checkpointURL,
            data: makeEncoder(prettyPrinted: true).encode(checkpoint)
        )
        return checkpointURL
    }

    /// Fork the conversation, notifications, and genuine checkpoint files.
    @discardableResult
    public func copySession(
        from sourceSessionID: String,
        sourceCWD: String,
        to destinationSessionID: String,
        destinationCWD: String
    ) throws -> PersistedSessionState {
        try Self.validateSessionID(sourceSessionID)
        try Self.validateSessionID(destinationSessionID)
        guard sourceSessionID != destinationSessionID else {
            throw SessionDocumentStoreError.invalidSessionID(destinationSessionID)
        }
        guard var state = try load(sessionID: sourceSessionID, cwd: sourceCWD) else {
            throw SessionDocumentStoreError.sessionNotFound(sourceSessionID)
        }
        let destination = try sessionDirectory(
            sessionID: destinationSessionID,
            cwd: destinationCWD
        )
        guard !FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(Self.summaryFileName).path
        ) else {
            throw SessionDocumentStoreError.sessionAlreadyExists(destinationSessionID)
        }

        state.summary.sessionID = SessionID(destinationSessionID)
        state.summary.cwd = destinationCWD
        state.summary.parentSessionID = sourceSessionID
        state.summary.createdAt = Date()
        state.summary.updatedAt = state.summary.createdAt
        state.summary.extra["cache_affinity_id"] = .string(
            state.summary.extra["cache_affinity_id"]?.stringValue ?? sourceSessionID
        )
        state.updates = try state.updates.map { update in
            try SessionUpdateEnvelope(
                timestamp: update.timestamp,
                method: update.method,
                params: rewriteSessionID(
                    in: update.params,
                    oldID: sourceSessionID,
                    newID: destinationSessionID
                )
            )
        }

        do {
            try save(state)
            let source = try sessionDirectory(sessionID: sourceSessionID, cwd: sourceCWD)
            try copyCheckpoints(from: source, to: destination)
            guard let saved = try load(sessionID: destinationSessionID, cwd: destinationCWD) else {
                throw SessionDocumentStoreError.sessionNotFound(destinationSessionID)
            }
            return saved
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    // MARK: - Session publication and discovery

    private func publishedSessionDirectory(sessionID: String, cwd: String) throws -> URL {
        let directory = try sessionDirectory(sessionID: sessionID, cwd: cwd)
        let summary = directory.appendingPathComponent(Self.summaryFileName)
        guard FileManager.default.fileExists(atPath: summary.path) else {
            throw SessionDocumentStoreError.sessionNotFound(sessionID)
        }
        return directory
    }

    private func findSessionDirectory(
        sessionID: String,
        preferredCWD: String?
    ) throws -> URL? {
        if let preferredCWD {
            let exact = try sessionDirectory(sessionID: sessionID, cwd: preferredCWD)
            if FileManager.default.fileExists(
                atPath: exact.appendingPathComponent(Self.summaryFileName).path
            ) {
                return exact
            }
        }
        return try canonicalSessionDirectories(cwd: nil).first {
            $0.lastPathComponent == sessionID
        }
    }

    private func canonicalSessionDirectories(cwd: String?) throws -> [URL] {
        let root = RelocationFS.sessionsDir(grokHome: grokHome)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let workspaceDirectories: [URL]
        if let cwd {
            try RelocationFS.validateCWD(field: "session cwd", value: cwd)
            workspaceDirectories = [root.appendingPathComponent(
                RelocationFS.encodeCwdDirname(cwd),
                isDirectory: true
            )]
        } else {
            workspaceDirectories = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        var sessions: [URL] = []
        for workspace in workspaceDirectories {
            guard try isRealDirectory(workspace) else { continue }
            let children = try FileManager.default.contentsOfDirectory(
                at: workspace,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            for child in children {
                guard try isRealDirectory(child) else { continue }
                let summary = child.appendingPathComponent(Self.summaryFileName)
                if FileManager.default.fileExists(atPath: summary.path) {
                    sessions.append(child)
                }
            }
        }
        return sessions
    }

    private func isRealDirectory(_ url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    // MARK: - Rust summary compatibility

    private func encodeSummary(_ summary: SessionSummary) throws -> Data {
        let encoded = try makeEncoder(prettyPrinted: false).encode(summary)
        guard case .object(var object) = try makeDecoder().decode(JSONValue.self, from: encoded) else {
            throw SessionDocumentStoreError.corruptDocument(
                path: Self.summaryFileName,
                reason: "summary must encode as a JSON object"
            )
        }
        object.removeValue(forKey: "session_id")
        object.removeValue(forKey: "cwd")
        object["info"] = .object([
            "id": .string(summary.sessionID.rawValue),
            "cwd": .string(summary.cwd),
        ])
        return try makeEncoder(prettyPrinted: true).encode(JSONValue.object(object))
    }

    private func readSummary(at url: URL) throws -> SessionSummary {
        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else {
                throw SessionDocumentStoreError.corruptDocument(
                    path: url.path,
                    reason: "summary.json is empty"
                )
            }
            guard case .object(var object) = try makeDecoder().decode(JSONValue.self, from: data) else {
                throw SessionDocumentStoreError.corruptDocument(
                    path: url.path,
                    reason: "summary must contain a JSON object"
                )
            }
            if let info = object.removeValue(forKey: "info")?.objectValue {
                guard let sessionID = info["id"]?.stringValue,
                      let cwd = info["cwd"]?.stringValue else {
                    throw SessionDocumentStoreError.corruptDocument(
                        path: url.path,
                        reason: "summary info must contain id and cwd"
                    )
                }
                object["session_id"] = .string(sessionID)
                object["cwd"] = .string(cwd)
            }
            let normalized = try makeEncoder(prettyPrinted: false).encode(JSONValue.object(object))
            return try makeDecoder().decode(SessionSummary.self, from: normalized)
        } catch let error as SessionDocumentStoreError {
            throw error
        } catch {
            throw SessionDocumentStoreError.corruptDocument(
                path: url.path,
                reason: String(describing: error)
            )
        }
    }

    private func mutateSummary(
        in directory: URL,
        update: (inout SessionSummary) -> Void
    ) throws {
        let lock = try AdvisoryFileLock.acquire(
            at: directory.appendingPathComponent("\(Self.summaryFileName).lock")
        )
        defer { lock.release() }
        let url = directory.appendingPathComponent(Self.summaryFileName)
        var summary = try readSummary(at: url)
        update(&summary)
        try RelocationFS.writeAtomicDurable(path: url, data: encodeSummary(summary))
    }

    private func readCanonicalSession(
        at directory: URL,
        expectedSessionID: String
    ) throws -> SessionDocumentLoadResult {
        let summaryURL = directory.appendingPathComponent(Self.summaryFileName)
        let summary = try readSummary(at: summaryURL)
        guard summary.sessionID.rawValue == expectedSessionID else {
            throw SessionDocumentStoreError.corruptDocument(
                path: summaryURL.path,
                reason: "session ID does not match its directory"
            )
        }

        let updates = try readUpdates(at: directory.appendingPathComponent(Self.updatesFileName))
        let historyURL = directory.appendingPathComponent(Self.chatHistoryFileName)
        var history = try readJSONLines(JSONValue.self, from: historyURL)
        if history.values.isEmpty,
           history.originalBytes.isEmpty,
           !updates.values.isEmpty,
           chatHistoryMayBeRebuilt(chatFormatVersion: summary.chatFormatVersion) {
            var reducer = SessionChatHistoryRecovery()
            let recovered = try reducer.recover(from: updates.values)
            if !recovered.isEmpty {
                try withJSONLLock(at: historyURL) {
                    try writeJSONLines(recovered, to: historyURL)
                }
                history = JSONLReadResult(
                    values: recovered,
                    skippedLines: 0,
                    originalBytes: Data()
                )
            }
        } else if history.skippedLines > 0 {
            try preserveAndHealHistory(history, at: historyURL)
        }
        let auxiliary = directory.appendingPathComponent(Self.auxiliaryStateFileName)

        var state: PersistedSessionState
        if FileManager.default.fileExists(atPath: auxiliary.path),
           let decoded = try? makeDecoder().decode(
               PersistedSessionState.self,
               from: Data(contentsOf: auxiliary)
           ) {
            state = decoded
            state.summary = summary
            state.chatHistory = history.values
            state.updates = updates.values
        } else {
            state = PersistedSessionState(
                summary: summary,
                chatHistory: history.values,
                updates: updates.values
            )
        }

        return SessionDocumentLoadResult(
            state: state,
            skippedChatHistoryLines: history.skippedLines,
            skippedUpdateLines: updates.skippedLines
        )
    }

    // MARK: - Durable, corruption-tolerant JSONL

    private func withJSONLLock<T>(at path: URL, perform body: () throws -> T) throws -> T {
        let lock = try AdvisoryFileLock.acquire(
            at: path.deletingLastPathComponent().appendingPathComponent(
                "\(path.lastPathComponent).lock"
            )
        )
        defer { lock.release() }
        return try body()
    }

    private func writeJSONLines<T: Encodable>(_ values: [T], to path: URL) throws {
        let encoder = makeEncoder(prettyPrinted: false)
        var bytes = Data()
        for value in values {
            bytes.append(try encoder.encode(value))
            bytes.append(0x0A)
        }
        try RelocationFS.writeAtomicDurable(path: path, data: bytes)
    }

    private func appendJSONLine<T: Encodable>(_ value: T, to path: URL) throws {
        try RelocationFS.createDirectoryDurable(path.deletingLastPathComponent())
        try withJSONLLock(at: path) {
            if !FileManager.default.fileExists(atPath: path.path) {
                guard FileManager.default.createFile(
                    atPath: path.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw SessionDocumentStoreError.io(
                        path: path.path,
                        reason: "failed to create journal"
                    )
                }
            }

            let handle = try FileHandle(forUpdating: path)
            defer { try? handle.close() }
            let original = try Data(contentsOf: path)
            if let last = original.last, last != 0x0A {
                let boundary = original.lastIndex(of: 0x0A)
                let tailStart = boundary.map { original.index(after: $0) } ?? original.startIndex
                let tail = original[tailStart...]
                if (try? makeDecoder().decode(JSONValue.self, from: Data(tail))) == nil {
                    try handle.truncate(atOffset: UInt64(tailStart))
                } else {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data([0x0A]))
                }
            }
            try handle.seekToEnd()
            var line = try makeEncoder(prettyPrinted: false).encode(value)
            line.append(0x0A)
            try handle.write(contentsOf: line)
            try handle.synchronize()
            try RelocationFS.syncDirectory(path.deletingLastPathComponent())
        }
    }

    private func readJSONLines<T: Decodable>(
        _ type: T.Type,
        from path: URL
    ) throws -> JSONLReadResult<T> {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return JSONLReadResult(values: [], skippedLines: 0, originalBytes: Data())
        }
        let data = try Data(contentsOf: path)
        var values: [T] = []
        var skipped = 0
        for raw in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let line = trimASCIIWhitespace(raw)
            guard !line.isEmpty else { continue }
            do {
                values.append(try makeDecoder().decode(type, from: Data(line)))
            } catch {
                skipped += 1
            }
        }
        return JSONLReadResult(values: values, skippedLines: skipped, originalBytes: data)
    }

    private func readUpdates(at path: URL) throws -> JSONLReadResult<SessionUpdateEnvelope> {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return JSONLReadResult(values: [], skippedLines: 0, originalBytes: Data())
        }
        let data = try Data(contentsOf: path)
        var values: [SessionUpdateEnvelope] = []
        var skipped = 0
        for raw in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let line = trimASCIIWhitespace(raw)
            guard !line.isEmpty else { continue }
            do {
                let value = try makeDecoder().decode(JSONValue.self, from: Data(line))
                guard case .object(let object) = value else {
                    skipped += 1
                    continue
                }
                if let method = object["method"]?.stringValue,
                   let params = object["params"] {
                    values.append(try SessionUpdateEnvelope(
                        timestamp: object["timestamp"]?.uint64Value ?? 0,
                        method: method,
                        params: params
                    ))
                } else {
                    // Pre-envelope Rust sessions stored ACP notification
                    // payloads directly; preserve them as session/update.
                    values.append(try SessionUpdateEnvelope(
                        timestamp: 0,
                        method: "session/update",
                        params: value
                    ))
                }
            } catch {
                skipped += 1
            }
        }
        return JSONLReadResult(values: values, skippedLines: skipped, originalBytes: data)
    }

    private func preserveAndHealHistory(
        _ history: JSONLReadResult<JSONValue>,
        at path: URL
    ) throws {
        try withJSONLLock(at: path) {
            let backup = path.deletingLastPathComponent().appendingPathComponent(
                "\(path.lastPathComponent).corrupt"
            )
            if !FileManager.default.fileExists(atPath: backup.path) {
                try RelocationFS.writeAtomicDurable(path: backup, data: history.originalBytes)
            }
            try writeJSONLines(history.values, to: path)
        }
    }

    private func mergeUpdates(
        existing: [SessionUpdateEnvelope],
        incoming: [SessionUpdateEnvelope]
    ) -> [SessionUpdateEnvelope] {
        guard !existing.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return existing }
        if incoming.starts(with: existing) { return incoming }
        if existing.starts(with: incoming) { return existing }
        let existingSet = Set(existing)
        return existing + incoming.filter { !existingSet.contains($0) }
    }

    private func trimASCIIWhitespace(_ bytes: Data.SubSequence) -> Data.SubSequence {
        var start = bytes.startIndex
        var end = bytes.endIndex
        while start < end, isASCIIWhitespace(bytes[start]) {
            start = bytes.index(after: start)
        }
        while end > start {
            let previous = bytes.index(before: end)
            guard isASCIIWhitespace(bytes[previous]) else { break }
            end = previous
        }
        return bytes[start..<end]
    }

    private func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x09, 0x0A, 0x0D, 0x20:
            return true
        default:
            return false
        }
    }

    // MARK: - Fork sidecars and codecs

    private func copyCheckpoints(from source: URL, to destination: URL) throws {
        let sourceDirectory = source.appendingPathComponent(
            "compaction_checkpoints",
            isDirectory: true
        )
        guard try isRealDirectory(sourceDirectory) else { return }
        let destinationDirectory = destination.appendingPathComponent(
            "compaction_checkpoints",
            isDirectory: true
        )
        try RelocationFS.createDirectoryDurable(destinationDirectory)
        let entries = try FileManager.default.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries where entry.pathExtension == "json" {
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try RelocationFS.writeAtomicDurable(
                path: destinationDirectory.appendingPathComponent(entry.lastPathComponent),
                data: Data(contentsOf: entry)
            )
        }
    }

    private func rewriteSessionID(in value: JSONValue, oldID: String, newID: String) -> JSONValue {
        switch value {
        case .array(let values):
            return .array(values.map { rewriteSessionID(in: $0, oldID: oldID, newID: newID) })
        case .object(let object):
            var rewritten: [String: JSONValue] = [:]
            for (key, child) in object {
                if (key == "sessionId" || key == "session_id"), child.stringValue == oldID {
                    rewritten[key] = .string(newID)
                } else {
                    rewritten[key] = rewriteSessionID(in: child, oldID: oldID, newID: newID)
                }
            }
            return .object(rewritten)
        default:
            return value
        }
    }

    private func makeEncoder(prettyPrinted: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let timestamp = date.timeIntervalSince1970
            var integral = floor(timestamp)
            var nanoseconds = Int(((timestamp - integral) * 1_000_000_000).rounded())
            if nanoseconds == 1_000_000_000 {
                integral += 1
                nanoseconds = 0
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let whole = formatter.string(from: Date(timeIntervalSince1970: integral))
            let formatted = String(whole.dropLast())
                + String(format: ".%09dZ", nanoseconds)
            var container = encoder.singleValueContainer()
            try container.encode(formatted)
        }
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let timestamp = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: timestamp)
            }
            let value = try container.decode(String.self)
            if let date = Self.parseRFC3339(value) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid RFC3339 session timestamp: \(value)"
            )
        }
        return decoder
    }

    private func lastActivityDate(for summary: SessionSummary) -> Date {
        guard let raw = summary.extra["last_active_at"]?.stringValue,
              let date = Self.parseRFC3339(raw) else { return summary.updatedAt }
        return date
    }

    private static func parseRFC3339(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let separator = value.firstIndex(of: ".") else {
            return formatter.date(from: value)
        }

        let suffix = value[value.index(after: separator)...]
        let digits = suffix.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let zone = suffix.dropFirst(digits.count)
        guard !zone.isEmpty else { return nil }
        let integral = String(value[..<separator]) + String(zone)
        guard let base = formatter.date(from: integral),
              let fraction = Double("0.\(digits.prefix(9))") else { return nil }
        return base.addingTimeInterval(fraction)
    }

    private static func validateSessionID(_ sessionID: String) throws {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        )
        guard !sessionID.isEmpty,
              sessionID.utf8.count <= 128,
              sessionID != ".",
              sessionID != "..",
              sessionID.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw SessionDocumentStoreError.invalidSessionID(sessionID)
        }
    }

}

/// Recovery details returned explicitly by `loadRecovering`.
public struct SessionDocumentLoadResult: Sendable, Equatable {
    public let state: PersistedSessionState
    public let skippedChatHistoryLines: Int
    public let skippedUpdateLines: Int

    public init(
        state: PersistedSessionState,
        skippedChatHistoryLines: Int = 0,
        skippedUpdateLines: Int = 0
    ) {
        self.state = state
        self.skippedChatHistoryLines = skippedChatHistoryLines
        self.skippedUpdateLines = skippedUpdateLines
    }
}

public enum SessionDocumentStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidSessionID(String)
    case sessionNotFound(String)
    case sessionAlreadyExists(String)
    case corruptDocument(path: String, reason: String)
    case io(path: String, reason: String)

    public var description: String {
        switch self {
        case .invalidSessionID(let id):
            return "invalid session ID: \(id)"
        case .sessionNotFound(let id):
            return "session not found: \(id)"
        case .sessionAlreadyExists(let id):
            return "session already exists: \(id)"
        case .corruptDocument(let path, let reason):
            return "corrupt session document \(path): \(reason)"
        case .io(let path, let reason):
            return "session document I/O failed at \(path): \(reason)"
        }
    }
}

private struct JSONLReadResult<Value> {
    let values: [Value]
    let skippedLines: Int
    let originalBytes: Data
}
