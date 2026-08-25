import Foundation
import OpenGrokAuth
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokShellSessionSupport

/// The local canonical journal remains authoritative; backend synchronization
/// begins only after that journal has durably accepted an ACP notification.
///
/// Rust: `xai-grok-shell/src/remote/sync.rs:25-31,108-227` and
/// `session/persistence.rs:2309-2318,2391-2455,2966-2985`.
actor LiveSessionWritebackSync {
    enum Mode: String, Sendable, Equatable {
        case local
        case writeback
    }

    static let maximumPending = 512
    static let overflowDropCount = 64
    static let maximumSnapshotRecords = 100_000
    static let maximumSnapshotBytes = 16 * 1_024 * 1_024
    private static let shutdownTimeoutNanoseconds: UInt64 = 2_000_000_000

    private struct AccountIdentity: Sendable, Equatable {
        let userID: String
        let principalID: String?
        let teamID: String?
        let organizationID: String?

        init(_ auth: GrokAuth) {
            userID = auth.userID
            principalID = auth.principalID
            teamID = auth.teamID
            organizationID = auth.organizationID
        }
    }

    private final class ShutdownContinuation: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func finish() {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }
    }

    private let home: URL
    private let environment: [String: String]
    private let sessionID: String
    private let workingDirectory: String
    private let exportBoundary: ExportBoundary
    private let identity: AccountIdentity
    private let remote: any LiveSessionWritebackRemote
    private let agentID: String
    private let documentStore: SessionDocumentStore

    private var metadata: LiveSessionWritebackMetadata
    private var pending: [SessionUpdateEnvelope] = []
    private var cursor = 0
    private var consumedFingerprint = 0
    private var permanentlyClosed = false
    private var requestInFlight = false
    private var shuttingDown = false

    private init(
        home: URL,
        environment: [String: String],
        record: LiveConversationRecord,
        boundary: ExportBoundary,
        identity: AccountIdentity,
        metadata: LiveSessionWritebackMetadata,
        remote: any LiveSessionWritebackRemote
    ) {
        self.home = home.standardizedFileURL
        self.environment = environment
        sessionID = record.sessionID
        workingDirectory = record.workingDirectory
        exportBoundary = boundary
        self.identity = identity
        self.metadata = metadata
        self.remote = remote
        documentStore = SessionDocumentStore(grokHome: home)
        agentID = LiveShareHTTPSupport.cachedAgentID(home: home)
    }

    static func resolveMode(
        cli: String?,
        environment: [String: String]
    ) throws -> Mode {
        if let cli {
            guard let mode = Mode(rawValue: cli) else {
                throw CLIApplicationError.failed(
                    "invalid --storage-mode '\(cli)'; expected 'local' or 'writeback'"
                )
            }
            return mode
        }
        if let configured = environment["GROK_STORAGE_MODE"] {
            guard let mode = Mode(rawValue: configured) else {
                throw CLIApplicationError.failed(
                    "invalid GROK_STORAGE_MODE '\(configured)'; expected 'local' or 'writeback'"
                )
            }
            return mode
        }
        return .local
    }

    static func start(
        mode: Mode,
        home: URL,
        environment: [String: String],
        record: LiveConversationRecord,
        boundary: ExportBoundary,
        transport: any HTTPTransport,
        createdFresh: Bool,
        clientIdentifier: String? = nil,
        clientMode: String = "interactive",
        remote: (any LiveSessionWritebackRemote)? = nil
    ) async throws -> LiveSessionWritebackSync? {
        guard mode == .writeback else { return nil }
        guard record.everUsedNonXAI == false,
              record.currentProvider == .xai,
              boundary.allowsXaiExport
        else {
            throw refusal("the session's first-party xAI provider-export boundary is missing or closed")
        }

        let managed = liveManagedAuthenticationConfiguration(environment: environment)
        let authManager = AuthManager(
            grokHome: home,
            config: managed,
            environment: environment
        )
        guard let known = await authManager.currentOrExpired() else {
            throw refusal("a first-party xAI OAuth account is required")
        }
        guard !known.isZDRTeam else {
            throw refusal("zero-data-retention accounts cannot synchronize session history")
        }
        guard let active = await authManager.current(),
              active.isXAIAuth,
              active.isSessionAuth,
              TokenType.from(auth: active).isRefreshable,
              active.authMode != .oidc
                || active.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              !active.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !active.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw refusal("a current first-party xAI OAuth account with a user identity is required")
        }

        let store = SessionDocumentStore(grokHome: home)
        guard let state = try store.load(sessionID: record.sessionID, cwd: record.workingDirectory) else {
            throw refusal("the canonical durable session has not been published")
        }
        try validateSnapshot(state, expectedRecord: record, sessionID: record.sessionID)

        let client: any LiveSessionWritebackRemote
        if let remote {
            client = remote
        } else {
            client = try LiveSessionWritebackClient(
                home: home,
                environment: environment,
                authManager: authManager,
                exportBoundary: boundary,
                transport: transport,
                clientIdentifier: clientIdentifier,
                clientMode: clientMode
            )
        }

        let sync = LiveSessionWritebackSync(
            home: home,
            environment: environment,
            record: record,
            boundary: boundary,
            identity: AccountIdentity(active),
            metadata: LiveSessionWritebackMetadata(summary: state.summary),
            remote: client
        )
        await sync.prime(snapshot: state, record: record, createdFresh: createdFresh)
        return sync
    }

    /// Called strictly after `LiveConversationStore.save` commits its summary.
    func recordDurableCommit(_ record: LiveConversationRecord) async {
        guard !permanentlyClosed, !shuttingDown else { return }
        guard await authorize(record: record),
              let snapshot = loadValidatedSnapshot(record: record)
        else {
            closePermanently()
            return
        }
        await consume(snapshot: snapshot, record: record)
    }

    /// A different session or a single foreign provider closes this instance
    /// forever; switching the visible model back never reopens its queue.
    func observeRoute(record: LiveConversationRecord) async {
        guard !permanentlyClosed,
              record.sessionID == sessionID,
              record.workingDirectory == workingDirectory,
              record.currentProvider == .xai,
              record.everUsedNonXAI == false,
              exportBoundary.allowsXaiExport
        else {
            if record.currentProvider != .xai || record.everUsedNonXAI != false {
                exportBoundary.sync(everUsedNonXAI: true)
            }
            closePermanently()
            return
        }
        guard await authorize(record: record),
              let snapshot = loadValidatedSnapshot(record: record)
        else {
            closePermanently()
            return
        }

        metadata = LiveSessionWritebackMetadata(summary: snapshot.summary)
        metadata.modelID = record.currentModelID
        metadata.updatedAt = timestamp(Date())
        guard await authorize(record: record) else {
            closePermanently()
            return
        }
        do {
            try await remote.saveSessionData(
                sessionID: sessionID,
                updates: [],
                metadata: metadata
            )
        } catch {
            // Metadata remains in memory for the next ordinary flush.
        }
    }

    func setManualTitle(_ title: String, record: LiveConversationRecord) async {
        guard !permanentlyClosed,
              await authorize(record: record),
              let snapshot = loadValidatedSnapshot(record: record)
        else {
            closePermanently()
            return
        }
        metadata = LiveSessionWritebackMetadata(summary: snapshot.summary)
        metadata.title = title
        metadata.titleIsManual = !title.isEmpty
        metadata.updatedAt = timestamp(Date())

        do {
            try await remote.saveSessionData(
                sessionID: sessionID,
                updates: [],
                metadata: metadata
            )
            guard await authorize(record: record), !permanentlyClosed else {
                closePermanently()
                return
            }
            try await remote.upsertSession(
                sessionID: sessionID,
                metadata: metadata,
                agentID: agentID
            )
        } catch {
            // The local committed title stays authoritative.
        }
    }

    func flush() async {
        guard !permanentlyClosed else { return }
        _ = await flushPending()
    }

    /// A cancellation-hostile transport cannot indefinitely hold CLI teardown.
    func shutdown() async {
        guard !permanentlyClosed, !shuttingDown else { return }
        shuttingDown = true
        await withCheckedContinuation { continuation in
            let gate = ShutdownContinuation(continuation)
            let operation = Task { [weak self] in
                await self?.flush()
                gate.finish()
            }
            Task {
                do {
                    try await Task.sleep(nanoseconds: Self.shutdownTimeoutNanoseconds)
                    operation.cancel()
                    gate.finish()
                } catch {
                    gate.finish()
                }
            }
        }
        closePermanently()
    }

    var pendingCount: Int { pending.count }
    var isPermanentlyClosed: Bool { permanentlyClosed }

    private func prime(
        snapshot: PersistedSessionState,
        record: LiveConversationRecord,
        createdFresh: Bool
    ) async {
        if createdFresh {
            await consume(snapshot: snapshot, record: record)
            if !pending.isEmpty {
                _ = await flushPending()
            }
        } else {
            cursor = snapshot.updates.count
            consumedFingerprint = fingerprint(snapshot.updates)
        }
    }

    private func consume(
        snapshot: PersistedSessionState,
        record: LiveConversationRecord
    ) async {
        let updates = snapshot.updates
        if cursor > updates.count
            || (cursor > 0 && fingerprint(updates.prefix(cursor)) != consumedFingerprint)
        {
            // Rewinds/compaction may rewrite an append-only branch. Replaying a
            // rewritten prefix duplicates backend data, so resume forward-only.
            pending.removeAll()
            cursor = updates.count
            consumedFingerprint = fingerprint(updates)
            metadata = LiveSessionWritebackMetadata(summary: snapshot.summary)
            return
        }

        let safe = LiveExportComposition.privacyFilteredEnvelopes(
            updates,
            knownTransportIDs: Set(record.codeModeTransportCallIDs ?? [])
        )
        let allowed = Set(safe.filter { $0.method == "session/update" })
        pending.removeAll { !allowed.contains($0) }
        metadata = LiveSessionWritebackMetadata(summary: snapshot.summary)

        for envelope in updates.dropFirst(cursor) where allowed.contains(envelope) {
            guard !permanentlyClosed else { return }
            if pending.count >= Self.maximumPending {
                metadata.updatedAt = timestamp(Date())
                if await !flushPending() {
                    let dropped = min(Self.overflowDropCount, pending.count)
                    pending.removeFirst(dropped)
                }
            }
            pending.append(envelope)
        }
        cursor = updates.count
        consumedFingerprint = fingerprint(updates)
    }

    @discardableResult
    private func flushPending() async -> Bool {
        guard !permanentlyClosed, !requestInFlight else { return false }
        guard !pending.isEmpty else { return true }
        guard await authorizeCurrent(), let state = loadValidatedSnapshot(record: nil) else {
            closePermanently()
            return false
        }

        let known = Set(
            state.summary.extra["code_mode_transport_call_ids"]?
                .arrayValue?
                .compactMap(\.stringValue) ?? []
        )
        let safe = Set(LiveExportComposition.privacyFilteredEnvelopes(
            state.updates,
            knownTransportIDs: known
        ).filter { $0.method == "session/update" })
        pending.removeAll { !safe.contains($0) }
        guard !pending.isEmpty else { return true }

        metadata = LiveSessionWritebackMetadata(summary: state.summary)
        metadata.updatedAt = timestamp(Date())
        let outgoing = pending
        requestInFlight = true
        defer { requestInFlight = false }

        do {
            try await remote.saveSessionData(
                sessionID: sessionID,
                updates: outgoing,
                metadata: metadata
            )
        } catch {
            return false
        }

        // POST appends without message identifiers. Remove its committed
        // prefix before PUT so a failed row update can never replay the POST.
        if pending.starts(with: outgoing) {
            pending.removeFirst(outgoing.count)
        }
        guard !permanentlyClosed, await authorizeCurrent() else {
            closePermanently()
            return true
        }
        do {
            try await remote.upsertSession(
                sessionID: sessionID,
                metadata: metadata,
                agentID: agentID
            )
        } catch {
            // Session-row upsert is best effort after the append committed.
        }
        return true
    }

    private func authorize(record: LiveConversationRecord) async -> Bool {
        guard record.sessionID == sessionID,
              record.workingDirectory == workingDirectory,
              record.currentProvider == .xai,
              record.everUsedNonXAI == false
        else { return false }
        return await authorizeCurrent()
    }

    private func authorizeCurrent() async -> Bool {
        guard !permanentlyClosed, exportBoundary.allowsXaiExport else { return false }
        let manager = AuthManager(
            grokHome: home,
            config: liveManagedAuthenticationConfiguration(environment: environment),
            environment: environment
        )
        guard let known = await manager.currentOrExpired(),
              !known.isZDRTeam,
              let current = await manager.current(),
              current.isXAIAuth,
              current.isSessionAuth,
              TokenType.from(auth: current).isRefreshable,
              current.authMode != .oidc
                || current.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              !current.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              AccountIdentity(current) == identity,
              exportBoundary.allowsXaiExport
        else { return false }
        return true
    }

    private func loadValidatedSnapshot(
        record: LiveConversationRecord?
    ) -> PersistedSessionState? {
        do {
            guard let state = try documentStore.load(
                sessionID: sessionID,
                cwd: workingDirectory
            ), state.summary.cwd == workingDirectory else { return nil }
            try Self.validateSnapshot(state, expectedRecord: record, sessionID: sessionID)
            return state
        } catch {
            return nil
        }
    }

    private static func validateSnapshot(
        _ state: PersistedSessionState,
        expectedRecord record: LiveConversationRecord?,
        sessionID: String
    ) throws {
        guard state.summary.sessionID.rawValue == sessionID,
              state.summary.everUsedCodex == false,
              state.summary.extra["swift_legacy_export_boundary_missing"]?.boolValue == false,
              state.summary.extra["current_provider"]?.stringValue == ModelProvider.xai.rawValue
        else {
            throw refusal("the canonical session provider identity or export boundary is unsafe")
        }
        if let record {
            guard state.summary.cwd == record.workingDirectory,
                  record.sessionID == sessionID,
                  record.everUsedNonXAI == false,
                  record.currentProvider == .xai
            else {
                throw refusal("the canonical session identity does not match the active xAI session")
            }
        }
        guard state.updates.count <= maximumSnapshotRecords else {
            throw refusal("the canonical update journal exceeds its bounded record count")
        }

        let encoder = JSONEncoder()
        var bytes = 0
        for envelope in state.updates {
            let encoded = try encoder.encode(envelope)
            bytes += encoded.count
            guard bytes <= maximumSnapshotBytes else {
                throw refusal("the canonical update journal exceeds its bounded byte count")
            }
            if envelope.method == "session/update"
                || envelope.method == "_x.ai/session/update"
            {
                guard let params = envelope.params.objectValue,
                      params["sessionId"]?.stringValue == sessionID,
                      let update = params["update"]?.objectValue,
                      let kind = update["sessionUpdate"]?.stringValue,
                      !kind.isEmpty
                else {
                    throw refusal("the canonical update journal contains a malformed or cross-session envelope")
                }
                if kind == "tool_call" || kind == "tool_call_update" {
                    guard update["toolCallId"]?.stringValue?.isEmpty == false else {
                        throw refusal("the canonical update journal contains a tool call without provenance")
                    }
                }
                if let metadata = params["_meta"] {
                    guard let fields = metadata.objectValue,
                          fields["open-grok/codeModeTransport"] == nil
                            || fields["open-grok/codeModeTransport"]?.boolValue != nil
                    else {
                        throw refusal("the canonical update journal contains malformed Code Mode provenance")
                    }
                }
            }
        }
    }

    private func closePermanently() {
        permanentlyClosed = true
        shuttingDown = false
        pending.removeAll()
    }

    private func fingerprint<S: Sequence>(_ values: S) -> Int
    where S.Element == SessionUpdateEnvelope {
        var hasher = Hasher()
        for value in values { hasher.combine(value) }
        return hasher.finalize()
    }

    private func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func refusal(_ message: String) -> CLIApplicationError {
        .failed("writeback storage refused: \(message)")
    }
}
