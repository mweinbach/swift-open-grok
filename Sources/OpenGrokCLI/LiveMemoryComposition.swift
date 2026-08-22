// LiveMemoryComposition.swift
//
// Makes `OpenGrokMemory` reachable.
//
// `Sources/OpenGrokMemory/` is a complete six-file implementation — chunker,
// index, hybrid search, storage — that until now had zero non-test importers,
// and `Sources/OpenGrokConfigTypes/Memory.swift` is a complete config schema
// that had zero consumers. So a user could write `[memory]` settings into
// `config.toml`, watch them parse cleanly, and have them do nothing. That is
// worse than an unimplemented feature: it is a setting that lies.
//
// This file is the missing call site. It resolves the config, opens the index,
// and exposes the three surfaces Rust exposes:
//
//   * **First-turn injection** — one `<memory-context>` block prepended to the
//     system item on the first turn of a session
//     (`xai-grok-shell/src/session/turn.rs:1784 first_turn_memory_reminder`,
//     formatting in `helpers/memory_context.rs`).
//   * **Tools** — `memory_search` and `memory_get`, the only two memory tools
//     Rust gives the model
//     (`xai-grok-tools/src/implementations/memory/`). There is deliberately no
//     write tool: `/remember` is a user command, not something the model can
//     call on its own.
//   * **Commands** — `/remember`, `/recall`, `/flush`. Their handler bodies are
//     here so the pager only has to call them.
//
// Scoring is *not* reimplemented here. `hybridSearch` in
// `Sources/OpenGrokMemory/Search.swift` already ports the whole formula —
// FTS+vector merge, temporal decay, source weights, access boost, MMR — and
// reads its knobs off `MemorySearchConfig`. This file's only job on that front
// is to make sure the config the user wrote actually reaches it.

import Foundation
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokFileUtils
import OpenGrokMemory
import OpenGrokSamplingTypes
import OpenGrokShared

// MARK: - Configuration

/// The `[memory]` settings this session actually runs with.
///
/// Resolution order matches every other live gate in this port: built-in
/// defaults, then `config.toml`, then the environment. Memory is **off by
/// default** — Rust gates it behind `--experimental-memory` and reports
/// "Memory is not enabled. Use --experimental-memory to enable." from the tool
/// when it is off, so a session that never opted in must not start writing to
/// the user's home directory.
struct LiveMemoryConfiguration: Sendable, Equatable {
    var enabled: Bool
    var search: MemorySearchConfig
    var initialInjection: MemoryInitialInjectionConfig
    var index: MemoryIndexConfig
    var session: MemorySessionConfig
    /// Vector dimensions, or 0 when no embedding model is configured. The
    /// index treats 0 as "text search only", which is the only mode that works
    /// without an embedding provider — and this port has no embedding
    /// provider, so 0 is what it always resolves to today.
    var embeddingDimensions: Int
    var dream: MemoryDreamConfig
    var flush: MemoryFlushConfig

    static let disabled = LiveMemoryConfiguration(
        enabled: false,
        search: MemorySearchConfig(),
        initialInjection: MemoryInitialInjectionConfig(),
        index: MemoryIndexConfig(),
        session: MemorySessionConfig(),
        embeddingDimensions: 0,
        dream: MemoryDreamConfig(),
        flush: MemoryFlushConfig()
    )

    /// Read `[memory]` out of the resolved config document.
    ///
    /// Each key is read individually rather than by decoding the whole table,
    /// because there is no `MemoryConfig` aggregate type in this port — the
    /// leaf structs live in `ConfigTypes` and the aggregate was left in the
    /// shell, which was never ported. Reading leaf-by-leaf also means an
    /// unknown key under `[memory]` cannot fail the whole resolution.
    static func resolve(
        document: TOMLValue,
        environment: [String: String]
    ) -> LiveMemoryConfiguration {
        var config = LiveMemoryConfiguration.disabled

        if let enabled = document[path: ["memory", "enabled"]]?.boolValue {
            config.enabled = enabled
        }
        // The environment wins, so `OPENGROK_MEMORY=0` can switch off a
        // config-enabled memory for one run without editing the file.
        if let raw = environment["OPENGROK_MEMORY"], !raw.isEmpty {
            config.enabled = raw == "1" || raw.lowercased() == "true"
        }

        if let table = document[path: ["memory", "search"]] {
            var search = MemorySearchConfig()
            if let value = table["max_results"]?.int64Value { search.maxResults = Int(value) }
            if let value = table["min_score"]?.doubleValue { search.minScore = Float(value) }
            if let value = table["vector_weight"]?.doubleValue { search.vectorWeight = Float(value) }
            if let value = table["text_weight"]?.doubleValue { search.textWeight = Float(value) }
            if let value = table["recency_decay"]?.doubleValue { search.recencyDecay = Float(value) }
            if let decay = table["temporal_decay"] {
                if let enabled = decay["enabled"]?.boolValue { search.temporalDecay.enabled = enabled }
                if let halfLife = decay["half_life_days"]?.doubleValue {
                    search.temporalDecay.halfLifeDays = halfLife
                }
            }
            if let mmr = table["mmr"] {
                if let enabled = mmr["enabled"]?.boolValue { search.mmr.enabled = enabled }
                if let lambda = mmr["lambda"]?.doubleValue { search.mmr.lambda = lambda }
            }
            if let weights = table["source_weights"]?.table {
                for (key, value) in weights.pairs {
                    guard let weight = value.doubleValue else { continue }
                    search.sourceWeights[key] = Float(weight)
                }
            }
            config.search = search
        }

        // `memory_search_max_results` / `memory_search_min_score` are the
        // remote-settings spellings (`RemoteSettings.swift:464-465`). They were
        // decoded and dropped; honouring them here is the whole point.
        if let value = document[path: ["memory_search_max_results"]]?.int64Value {
            config.search.maxResults = Int(value)
        }
        if let value = document[path: ["memory_search_min_score"]]?.doubleValue {
            config.search.minScore = Float(value)
        }

        if let table = document[path: ["memory", "initial_injection"]] {
            var injection = MemoryInitialInjectionConfig()
            if let enabled = table["enabled"]?.boolValue { injection.enabled = enabled }
            if let minScore = table["min_score"]?.doubleValue { injection.minScore = Float(minScore) }
            config.initialInjection = injection
        }

        if let table = document[path: ["memory", "index"]] {
            var index = MemoryIndexConfig()
            if let value = table["max_chunk_chars"]?.int64Value { index.maxChunkChars = Int(value) }
            if let value = table["chunk_overlap_chars"]?.int64Value { index.chunkOverlapChars = Int(value) }
            config.index = index
        }

        if let table = document[path: ["memory", "session"]] {
            var session = MemorySessionConfig()
            if let saveOnEnd = table["save_on_end"]?.boolValue {
                session.saveOnEnd = saveOnEnd
            }
            config.session = session
        }

        // Vectors need an embedding provider. This port has none, so a
        // configured model still resolves to 0 dimensions and the index runs
        // text-only rather than pretending to score against embeddings it
        // never computed.
        config.embeddingDimensions = 0

        if let table = document[path: ["memory", "dream"]] {
            var dream = MemoryDreamConfig()
            if let enabled = table["enabled"]?.boolValue { dream.enabled = enabled }
            if let minHours = table["min_hours"]?.int64Value { dream.minHours = UInt64(minHours) }
            if let minSessions = table["min_sessions"]?.int64Value {
                dream.minSessions = UInt64(minSessions)
            }
            if let staleLockSecs = table["stale_lock_secs"]?.int64Value {
                dream.staleLockSecs = UInt64(staleLockSecs)
            }
            if let checkInterval = table["check_interval_secs"]?.int64Value {
                dream.checkIntervalSecs = UInt64(checkInterval)
            }
            config.dream = dream
        }

        if let table = document[path: ["compaction", "memory_flush"]] {
            if let enabled = table["enabled"]?.boolValue { config.flush.enabled = enabled }
            if let model = table["flush_model"]?.stringValue { config.flush.flushModel = model }
            if let limit = table["max_flush_write_chars"]?.int64Value {
                config.flush.maxFlushWriteChars = max(1, Int(limit))
            }
        }

        return config
    }
}

typealias LiveMemoryAuxiliaryRoute = @Sendable (String?) async -> (
    configuration: OpenGrokLiveSamplingConfiguration,
    sampler: OpenGrokLiveSampler
)

enum LiveMemoryFlushError: Error, CustomStringConvertible, Sendable, Equatable {
    case rejected(String)

    var description: String {
        switch self {
        case .rejected(let message): message
        }
    }
}

enum LiveMemoryFlushOutcome: Sendable, Equatable {
    case written(path: String)
    case nothingToStore
    case duplicate
    case alreadyInProgress

    var resultName: String {
        switch self {
        case .written: "written"
        case .nothingToStore: "nothing_to_store"
        case .duplicate: "duplicate"
        case .alreadyInProgress: "already_in_progress"
        }
    }
}

struct LiveMemoryFlushCoordinator: Sendable {
    let ownerSessionID: String
    let history: LiveConversationHistory
    let backend: LiveMemoryBackend?
    let auxiliaryRoute: LiveMemoryAuxiliaryRoute

    private static let systemPrompt = """
    You are a memory assistant. Extract ALL useful information from this conversation that would help you be more effective in future sessions with this user. Write a concise markdown summary with ## headers covering:

    - **Decisions & rationale** — what was chosen and why
    - **Technical context** — architecture, APIs, patterns, tools, file paths discussed
    - **Debugging techniques & tools** — external APIs, CLI commands, query patterns, investigation workflows, or services discovered or used during debugging
    - **Problems & solutions** — bugs found, how they were fixed, workarounds

    Omit any section where there is nothing substantive to report. Do NOT include user preferences like OS, shell, or editor — these belong in global memory. Do NOT include an ephemeral progress section — transient status is not useful for future sessions.

    Respond with NO_REPLY if nothing genuinely useful was learned — a routine task that followed standard patterns, brief Q&A, or sessions with no novel decisions or discoveries are not worth persisting. Only write content that a future session would concretely benefit from.
    """

    private static let rewritePrompt = """
    You are a memory note formatter. Rewrite the user's note into well-structured markdown suitable for a persistent MEMORY.md file. The note should be:
    - Concise but complete
    - Start with a descriptive ## heading
    - Include enough context to be useful months later
    - Reference specific files, decisions, or patterns when relevant
    - Use bullet points for multiple items
    - Do NOT include timestamps or session IDs
    - Do NOT add information that is not present in the original note

    Return ONLY the formatted markdown, no explanations.
    """

    private func authorizedRecord() async throws -> LiveConversationRecord {
        guard let backend else {
            throw LiveMemoryFlushError.rejected("memory is not enabled")
        }
        let record = await history.snapshot()
        guard record.sessionID == ownerSessionID else {
            throw LiveMemoryFlushError.rejected("memory session does not match its owner")
        }
        guard record.sessionKind != "subagent", record.parentSessionID == nil else {
            throw LiveMemoryFlushError.rejected("subagent sessions cannot export memory")
        }
        let boundary = await history.sharedExportBoundary
        guard record.currentProvider == .xai,
              record.everUsedNonXAI == false,
              boundary.allowsXaiExport
        else {
            throw LiveMemoryFlushError.rejected("provider privacy boundary prevents memory export")
        }
        let recordedWorkspace = URL(fileURLWithPath: record.workingDirectory)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let ownedWorkspace = (await backend.workspacePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        guard !(await backend.isEphemeralWorkspace),
              recordedWorkspace == ownedWorkspace
        else {
            throw LiveMemoryFlushError.rejected("memory workspace does not match its owner")
        }
        return record
    }

    func flush(
        trigger: String = "slash_command",
        beforeSampling: (@Sendable () async throws -> Void)? = nil,
        beforePersist: (@Sendable () async throws -> Void)? = nil
    ) async throws -> LiveMemoryFlushOutcome {
        guard let backend else {
            throw LiveMemoryFlushError.rejected("memory is not enabled")
        }
        let record = try await authorizedRecord()
        guard await backend.beginGeneratedFlush() else { return .alreadyInProgress }
        do {
            try await beforeSampling?()
            let previous = await backend.previousGeneratedFlush
            let system = previous.map {
                "You are a memory assistant performing an incremental update. Extract ONLY useful information NEW since the previous flush. Use ## headings or respond NO_REPLY.\n\n--- Previous flush content ---\n\($0)"
            } ?? Self.systemPrompt
            let transportIDs = Set(record.codeModeTransportCallIDs ?? [])
            let conversation = record.items.compactMap { item -> ConversationItem? in
                switch item {
                case .system, .reasoning, .backendToolCall:
                    return nil
                case .user(let user):
                    return user.syntheticReason == nil ? item : nil
                case .assistant(var assistant):
                    assistant.toolCalls.removeAll { transportIDs.contains($0.id) }
                    return assistant.content.isEmpty && assistant.toolCalls.isEmpty
                        ? nil : .assistant(assistant)
                case .toolResult(let result):
                    return transportIDs.contains(result.toolCallId) ? nil : item
                case .customToolOutput(let result):
                    return transportIDs.contains(result.callId) ? nil : item
                }
            }
            let closer = "Now write the memory summary as described in the system prompt."
            let items = [.system(system)] + Array(conversation.suffix(20)) + [.user(closer)]
            let route = await auxiliaryRoute(backend.configuration.flush.flushModel)
            guard route.configuration.provider == record.currentProvider else {
                throw LiveMemoryFlushError.rejected("memory model provider crosses the privacy boundary")
            }
            let response = try await route.sampler.sample(
                OpenGrokLiveSamplingRequest(
                    sessionID: ownerSessionID,
                    turnID: "xai-flush-\(UUID().uuidString)",
                    model: route.configuration.model,
                    prompt: closer,
                    items: items,
                    tools: []
                )
            ) { _ in }
            let content = response.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let stripped = content.trimmingCharacters(in: .punctuationCharacters)
            if content.isEmpty || stripped.caseInsensitiveCompare("NO_REPLY") == .orderedSame {
                await backend.finishGeneratedFlush()
                return .nothingToStore
            }
            guard content.split(whereSeparator: \.isNewline).contains(where: {
                $0.hasPrefix("# ") || $0.hasPrefix("## ")
            }) else {
                throw LiveMemoryFlushError.rejected("memory summary does not contain a markdown heading")
            }
            let limited = String(content.prefix(max(1, backend.configuration.flush.maxFlushWriteChars)))
            try await beforePersist?()
            _ = try await authorizedRecord()
            guard let path = try await backend.persistGeneratedFlush(
                sessionID: ownerSessionID,
                trigger: trigger,
                content: limited
            ) else {
                await backend.finishGeneratedFlush()
                return .duplicate
            }
            await backend.finishGeneratedFlush()
            return .written(path: path.path)
        } catch {
            await backend.finishGeneratedFlush()
            throw error
        }
    }

    func rewrite(rawText: String, contextSummary: String) async throws -> String {
        let combinedBytes = rawText.utf8.count + contextSummary.utf8.count
        guard combinedBytes <= 32 * 1024 else {
            throw LiveMemoryFlushError.rejected(
                "memory note input too large (\(combinedBytes) bytes, max 32768)"
            )
        }
        let record = try await authorizedRecord()
        guard let backend else { throw LiveMemoryFlushError.rejected("memory is not enabled") }
        let route = await auxiliaryRoute(backend.configuration.flush.flushModel)
        guard route.configuration.provider == record.currentProvider else {
            throw LiveMemoryFlushError.rejected("memory model provider crosses the privacy boundary")
        }
        let user = "Session context:\n\(contextSummary)\n\nRewrite this note as a memory entry:\n\n\(rawText)"
        let response = try await route.sampler.sample(
            OpenGrokLiveSamplingRequest(
                sessionID: ownerSessionID,
                turnID: "xai-memory-rewrite-\(UUID().uuidString)",
                model: route.configuration.model,
                prompt: user,
                items: [.system(Self.rewritePrompt), .user(user)],
                tools: []
            )
        ) { _ in }
        _ = try await authorizedRecord()
        guard !response.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LiveMemoryFlushError.rejected("LLM returned empty response")
        }
        guard response.output.utf8.count > 32 * 1024 else { return response.output }
        let suffix = "\n\n<!-- Open Grok truncated an oversized memory rewrite. -->"
        let budget = 32 * 1024 - suffix.utf8.count
        var output = ""
        for scalar in response.output.unicodeScalars {
            let next = String(scalar)
            guard output.utf8.count + next.utf8.count <= budget else { break }
            output.append(next)
        }
        return output + suffix
    }
}

// MARK: - Backend

/// Owns the memory index for one session.
///
/// An actor because `MemoryIndex` is a mutable `final class` with no internal
/// synchronization: it is safe exactly as long as one isolation domain holds
/// it, which is what this provides.
actor LiveMemoryBackend {
    let configuration: LiveMemoryConfiguration
    private let storage: MemoryStorage
    private var index: MemoryIndex?
    /// Set once the first search has forced a reindex, so a session with many
    /// searches walks the memory tree once rather than per call.
    private var didReindex = false
    private var completedSessionPaths: [String: String] = [:]
    private var flushInFlight = false
    private var previousFlushContent: String?

    /// Returns nil when memory is switched off, so every seam can hold an
    /// optional backend and a disabled session allocates nothing.
    init?(
        configuration: LiveMemoryConfiguration,
        workingDirectory: URL,
        environment: [String: String]
    ) {
        guard configuration.enabled else { return nil }
        self.configuration = configuration
        self.storage = MemoryStorage(cwd: workingDirectory, environment: environment)
    }

    /// Open the index lazily and reindex the memory tree once per session.
    ///
    /// Failures are swallowed into `nil` on purpose: memory is an enhancement,
    /// and a corrupt index must degrade the session to "no memory results", not
    /// fail the turn that happened to search.
    private func openIndex() -> MemoryIndex? {
        if let index { return index }
        guard !storage.isEphemeral else { return nil }
        try? storage.ensureInitialized()
        let indexURL = storage.workspaceDir.appendingPathComponent("index.json")
        guard let opened = try? MemoryIndex.openOrCreate(
            indexURL: indexURL,
            storage: storage,
            config: configuration.index,
            embeddingDimensions: configuration.embeddingDimensions
        ) else { return nil }
        index = opened
        return opened
    }

    private func reindexIfNeeded(_ index: MemoryIndex) {
        guard !didReindex else { return }
        didReindex = true
        guard let files = try? storage.listMemoryFiles() else { return }
        for file in files {
            _ = try? index.reindexFile(path: file, source: storage.classifySource(file))
        }
    }

    /// Hybrid search over the memory tree.
    func search(
        query: String,
        maxResults: Int? = nil,
        minScore: Float? = nil
    ) -> [MemorySearchResult] {
        guard let index = openIndex() else { return [] }
        reindexIfNeeded(index)
        var config = configuration.search
        if let maxResults { config.maxResults = max(0, maxResults) }
        if let minScore { config.minScore = minScore }
        return (try? index.hybridSearch(query, config: config)) ?? []
    }

    /// Read a memory file back. `from` is 1-based, matching Rust's
    /// `memory_get`, which also treats 0 as 1.
    func read(path: String, from: Int = 1, lines: Int? = nil) throws -> String {
        let url = URL(fileURLWithPath: path)
        return try storage.readFile(path: url, from: max(0, from - 1), lines: lines)
    }

    /// Append a note to long-term memory. Backs `/remember`.
    ///
    /// The note is given a dated heading and kept as **body** text. That shape
    /// is load-bearing, not cosmetic: `normalizeMemoryContent` turns a bare
    /// one-line note into `## <the note>` — a heading — and the search side's
    /// `isStructurallyEmpty` treats headings as structure rather than content,
    /// so a note stored that way is indexed and then discarded as scaffolding.
    /// The two halves of the memory library disagree about whether a heading is
    /// information, and a single-line `/remember` lands exactly on the seam.
    ///
    /// Both behaviours are pinned by ported tests (`normalizeMemoryContent`
    /// returning `"## single note"`, and heading-only chunks being dropped as
    /// templates), so neither is the thing to change. Emitting a heading plus a
    /// body satisfies both: the entry has real body text to match on, and
    /// genuine scaffolding still has none. Passing a string that already starts
    /// with `#` also makes `normalizeMemoryContent` a no-op, so the shape below
    /// is exactly what gets written.
    func remember(_ text: String, scope: MemoryScope = .workspace) throws {
        try storage.ensureInitialized()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let entry = """
        ## Note — \(formatter.string(from: Date()))

        \(text.trimmingCharacters(in: .whitespacesAndNewlines))
        """
        try storage.appendToMemory(scope: scope, content: entry)
        // Drop the index so the next search re-reads the file that just grew.
        // Cheaper and less error-prone than incrementally patching chunks.
        index = nil
        didReindex = false
    }

    /// Append an explicit, user-supplied note to today's session log.
    /// Model-generated `/flush` summaries use `persistGeneratedFlush`.
    func writeSessionLog(sessionID: String, content: String) throws {
        try storage.ensureInitialized()
        // `writeDailyLog` builds its filename from these three components and
        // rejects anything that is not a safe path component, so the slug is
        // derived rather than taken from user text.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let slug = slugify(storage.workspacePath.lastPathComponent, maxLength: 40)
        let today = formatter.string(from: Date())
        // Heading plus body, for the same reason `remember` does it: a
        // single-line flush would otherwise normalize to a bare `## <line>`
        // and be dropped from search as scaffolding.
        let entry = """
        ## Session \(sessionID) — \(today)

        \(content.trimmingCharacters(in: .whitespacesAndNewlines))
        """
        _ = try storage.writeDailyLog(
            date: today,
            slug: slug.isEmpty ? "session" : slug,
            sessionID: sessionID,
            content: entry,
            append: true
        )
        index = nil
        didReindex = false
    }

    func beginGeneratedFlush() -> Bool {
        guard !flushInFlight else { return false }
        flushInFlight = true
        return true
    }

    func finishGeneratedFlush() {
        flushInFlight = false
    }

    var previousGeneratedFlush: String? { previousFlushContent }

    func persistGeneratedFlush(sessionID: String, trigger: String, content: String) throws -> URL? {
        try LiveConversationStore.validateSessionID(sessionID)
        guard trigger == "slash_command" || trigger == "user_requested" else {
            throw LiveMemoryFlushError.rejected("invalid memory flush trigger")
        }
        guard !storage.isEphemeral else {
            throw LiveMemoryFlushError.rejected("workspace memory is not available")
        }
        guard content != previousFlushContent else { return nil }

        try LiveSessionBusPresenceStore.ensureSecureDirectory(storage.globalDir)
        try LiveSessionBusPresenceStore.ensureSecureDirectory(storage.workspaceDir)
        try LiveSessionBusPresenceStore.ensureSecureDirectory(storage.sessionsDir)
        try storage.ensureInitialized()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let path = storage.sessionsDir.appendingPathComponent(
            "\(formatter.string(from: Date()))-\(trigger)-\(sessionID.prefix(8)).md"
        )
        let output: String
        if FileManager.default.fileExists(atPath: path.path) {
            try SecureFile.ensureOwnerOnlyPermissions(at: path)
            output = try String(contentsOf: path, encoding: .utf8) + "\n\n---\n\n" + content
        } else {
            output = content
        }
        try SecureFile.write(at: path, contents: output)
        guard try SecureFile.isOwnerOnly(at: path) else {
            throw LiveMemoryFlushError.rejected("session memory log is not owner-private")
        }
        guard let index = openIndex() else {
            throw LiveMemoryLifecycleError.indexUnavailable(path.path)
        }
        let result = try index.reindexFile(path: path, source: storage.classifySource(path))
        let alreadyIndexed: Bool
        if result.added > 0 || result.updated > 0 {
            alreadyIndexed = true
        } else {
            alreadyIndexed = try index.allIndexedPaths().contains(path.path)
        }
        guard alreadyIndexed else {
            throw LiveMemoryLifecycleError.summaryWasNotIndexed(path.path)
        }
        previousFlushContent = content
        return path
    }

    /// Saves the upstream's local-only, structured shutdown summary exactly
    /// once per backend lifetime and makes it searchable before returning.
    func saveSessionSummary(
        sessionID: String,
        conversation: [ConversationItem],
        realQueries: [String],
        date: Date = Date()
    ) throws -> LiveMemorySessionEndResult {
        if let existingPath = completedSessionPaths[sessionID] {
            return .alreadySaved(path: existingPath)
        }

        let path = try LiveMemorySessionStorage.writeSummary(
            storage: storage,
            sessionID: sessionID,
            conversation: conversation,
            realQueries: realQueries,
            date: date
        )
        guard let index = openIndex() else {
            throw LiveMemoryLifecycleError.indexUnavailable(path.path)
        }
        let result = try index.reindexFile(path: path, source: storage.classifySource(path))
        let alreadyIndexed: Bool
        if result.added > 0 || result.updated > 0 {
            alreadyIndexed = true
        } else {
            alreadyIndexed = try index.allIndexedPaths().contains(path.path)
        }
        guard alreadyIndexed else {
            throw LiveMemoryLifecycleError.summaryWasNotIndexed(path.path)
        }
        completedSessionPaths[sessionID] = path.path
        return .written(path: path.path)
    }

    var workspacePath: URL { storage.workspacePath }

    var memoryFilePaths: [String] {
        ((try? storage.listMemoryFiles()) ?? []).map(\.path)
    }

    var isEphemeralWorkspace: Bool { storage.isEphemeral }

    /// Manual `/dream` — bypasses time/session gates, consolidates eligible logs.
    func runDream(
        sessionID: String,
        dreamConfig: MemoryDreamConfig,
        sample: @Sendable (_ systemPrompt: String, _ userMessage: String) async throws -> String
    ) async -> DreamResult {
        let lock = DreamLock(workspaceDirectory: storage.workspaceDir)
        let sid8 = String(sessionID.prefix(8))
        let sessions: [String]
        do {
            sessions = try sessionsSince(
                sessionsDirectory: storage.sessionsDir,
                since: Date(timeIntervalSince1970: 0),
                excludingSessionSID8: sid8
            )
        } catch {
            return DreamResult(
                status: .failed("failed to list sessions: \(error.localizedDescription)"),
                sessionsEligible: 0,
                cleanedStems: []
            )
        }
        guard !sessions.isEmpty else {
            return DreamResult(
                status: .skipped("no session logs found"),
                sessionsEligible: 0,
                cleanedStems: []
            )
        }
        try? storage.ensureInitialized()
        return await runDreamConsolidation(
            storage: storage,
            lock: lock,
            config: dreamConfig,
            sessions: sessions,
            sample: sample
        )
    }
}

// MARK: - Formatting

enum LiveMemoryFormatting {
    /// How much of a chunk the injected block and the tool output show. Rust
    /// truncates at 500 characters and appends an ellipsis.
    static let snippetLimit = 500

    /// Render results the way Rust's `memory_context.rs` does, so a session
    /// that has seen memory before sees the identical shape.
    static func resultsBlock(_ results: [MemorySearchResult]) -> String {
        var lines: [String] = []
        for (offset, result) in results.enumerated() {
            let score = String(format: "%.2f", result.score)
            lines.append("### Result \(offset + 1) (score: \(score), source: \(result.source))")
            lines.append("**File:** \(result.path) (lines \(result.startLine)-\(result.endLine))")
            lines.append("```")
            lines.append(truncate(result.snippet))
            lines.append("```")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func truncate(_ text: String) -> String {
        guard text.count > snippetLimit else { return text }
        return String(text.prefix(snippetLimit)) + "..."
    }

    /// The wrapper the first-turn injection puts around the results.
    ///
    /// The `<memory-context>` tag is load-bearing rather than decorative: the
    /// injection is idempotent because it looks for this exact tag in the
    /// existing system item and replaces in place. Without it a resumed session
    /// would stack a fresh block on every launch.
    static let contextOpenTag = "<memory-context>"
    static let contextCloseTag = "</memory-context>"

    static func memoryContext(_ results: [MemorySearchResult]) -> String? {
        guard !results.isEmpty else { return nil }
        return """
        \(contextOpenTag)
        ## Relevant Memory from Past Sessions

        \(resultsBlock(results))\(contextCloseTag)
        """
    }

    /// Tool output. Rust's `memory_search` prints a count line then the same
    /// per-result shape as the injection.
    static func toolOutput(_ results: [MemorySearchResult]) -> String {
        guard !results.isEmpty else {
            return "No memory results found for query."
        }
        return "Found \(results.count) memory result(s):\n\n" + resultsBlock(results)
    }
}

// MARK: - Injection

enum LiveMemoryInjection {
    /// Prompts too short or too generic to search with.
    ///
    /// Rust keeps this list because searching memory for "hi" returns whatever
    /// happens to contain the letters, which then displaces real context in
    /// the system prompt. Trailing punctuation is stripped before the compare.
    private static let greetings: Set<String> = [
        "hi", "hey", "hello", "howdy", "yo", "sup",
        "continue", "start", "begin", "go", "ok", "okay",
        "good morning", "good afternoon", "good evening",
    ]

    /// The literal query used when the real prompt is unusable.
    static let fallbackQuery = "project conventions preferences architecture"

    /// How many results the first-turn block carries. Rust hardcodes 6
    /// independently of `[memory.search].max_results`, which governs the tool.
    static let injectionResultCount = 6

    /// Pick the query for first-turn injection.
    static func query(forPrompt prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count >= 20 else { return fallbackQuery }
        let normalized = trimmed
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
        guard !greetings.contains(normalized) else { return fallbackQuery }
        return trimmed
    }

    /// Splice a memory block into the conversation's system item.
    ///
    /// Idempotent: an existing `<memory-context>` block is replaced rather than
    /// appended to, which is what lets a resumed session keep its prompt cache
    /// instead of growing a new block per launch.
    ///
    /// Returns `items` unchanged when there is nothing to inject, so the caller
    /// can assign unconditionally.
    static func inject(
        _ block: String,
        into items: [ConversationItem]
    ) -> [ConversationItem] {
        var updated = items
        guard let systemIndex = updated.firstIndex(where: {
            if case .system = $0 { return true }
            return false
        }) else {
            updated.insert(.system(SystemItem(content: block)), at: 0)
            return updated
        }
        guard case .system(var system) = updated[systemIndex] else { return updated }
        system.content = replaceBlock(in: system.content, with: block)
        updated[systemIndex] = .system(system)
        return updated
    }

    /// Whether this conversation already carries an injected block, which is
    /// the signal that first-turn injection has already happened for it —
    /// including in a previous process, for a resumed session.
    static func alreadyInjected(_ items: [ConversationItem]) -> Bool {
        for item in items {
            guard case .system(let system) = item else { continue }
            if system.content.contains(LiveMemoryFormatting.contextOpenTag) { return true }
        }
        return false
    }

    private static func replaceBlock(in content: String, with block: String) -> String {
        let open = LiveMemoryFormatting.contextOpenTag
        let close = LiveMemoryFormatting.contextCloseTag
        guard let start = content.range(of: open),
              let end = content.range(of: close, range: start.upperBound..<content.endIndex)
        else {
            return block + "\n\n" + content
        }
        return content.replacingCharacters(in: start.lowerBound..<end.upperBound, with: block)
    }
}

// MARK: - Tools

/// The two memory tools Rust exposes to the model.
///
/// There is no write tool by design: `/remember` is a user command. A model
/// that could write its own memory would be able to persist instructions to
/// itself across sessions, which is a much larger trust decision than "the
/// model can read what the user chose to save".
enum LiveMemoryTools {
    static let searchToolName = "memory_search"
    static let getToolName = "memory_get"

    static var toolNames: Set<String> { [searchToolName, getToolName] }

    /// Only advertised when a memory backend exists. Rust injects these into the
    /// default toolset only when `memory_backend.is_some()`
    /// (`xai-grok-agent/builder.rs:745-752`) and strips them afterward when it
    /// is none (`builder.rs:805-817`).
    static func toolSpecs(configuration: LiveMemoryConfiguration) -> [ToolSpec] {
        guard configuration.enabled else { return [] }
        return [
            ToolSpec(
                name: searchToolName,
                description: """
                Search long-term memory from past sessions for relevant context. \
                Returns scored excerpts with their source file and line range.
                """,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("What to look for in memory."),
                        ]),
                        "max_results": .object([
                            "type": .string("integer"),
                            "description": .string(
                                "Maximum results to return (default \(configuration.search.maxResults))."
                            ),
                        ]),
                        "min_score": .object([
                            "type": .string("number"),
                            "description": .string(
                                "Minimum relevance score, 0-1 (default \(configuration.search.minScore))."
                            ),
                        ]),
                    ]),
                    "required": .array([.string("query")]),
                ])
            ),
            ToolSpec(
                name: getToolName,
                description: """
                Read a memory file returned by memory_search, optionally a line range of it.
                """,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Memory file path, as reported by memory_search."),
                        ]),
                        "from": .object([
                            "type": .string("integer"),
                            "description": .string("First line to read, 1-based."),
                        ]),
                        "lines": .object([
                            "type": .string("integer"),
                            "description": .string("How many lines to read."),
                        ]),
                    ]),
                    "required": .array([.string("path")]),
                ])
            ),
        ]
    }

    /// Names the model may call. Matches `toolSpecs` — empty when memory is off.
    static func advertisedToolNames(configuration: LiveMemoryConfiguration) -> Set<String> {
        Set(toolSpecs(configuration: configuration).map(\.name))
    }

    /// Run one memory tool call. Returns the prompt text the model sees.
    static func invoke(
        name: String,
        arguments: JSONValue,
        backend: LiveMemoryBackend?
    ) async -> String {
        guard let backend else {
            // Rust's exact wording when memory is off.
            return "Memory is not enabled. Use --experimental-memory to enable."
        }
        guard case .object(let fields) = arguments else {
            return "memory tool arguments must be a JSON object"
        }
        switch name {
        case searchToolName:
            guard case .string(let query)? = fields["query"], !query.isEmpty else {
                return "memory_search requires a non-empty 'query'."
            }
            // An ephemeral workspace (a cwd under /tmp or the system temp dir)
            // never gets written to and has no index to read, so a search there
            // would report "no results" — indistinguishable from a working
            // memory that happens to be empty. Naming the reason is the same
            // fix as the config keys that used to parse and do nothing: the
            // failure has to be legible, or it reads as a working feature.
            if await backend.isEphemeralWorkspace {
                return """
                Memory is inactive here: this workspace is a temporary \
                directory, so nothing is indexed or persisted for it.
                """
            }
            let maxResults = fields["max_results"].flatMap(intValue)
            let minScore = fields["min_score"].flatMap(doubleValue).map(Float.init)
            let results = await backend.search(
                query: query,
                maxResults: maxResults,
                minScore: minScore
            )
            return LiveMemoryFormatting.toolOutput(results)
        case getToolName:
            guard case .string(let path)? = fields["path"], !path.isEmpty else {
                return "memory_get requires a 'path'."
            }
            let from = fields["from"].flatMap(intValue) ?? 1
            let lines = fields["lines"].flatMap(intValue)
            do {
                return try await backend.read(path: path, from: from, lines: lines)
            } catch {
                return "memory_get failed: \(error)"
            }
        default:
            return "unknown memory tool '\(name)'"
        }
    }

    private static func intValue(_ value: JSONValue) -> Int? {
        if case .number(let number) = value { return Int(number.doubleValue) }
        if case .string(let text) = value { return Int(text) }
        return nil
    }

    private static func doubleValue(_ value: JSONValue) -> Double? {
        if case .number(let number) = value { return number.doubleValue }
        if case .string(let text) = value { return Double(text) }
        return nil
    }
}

// MARK: - Dream sampling

/// Injectable auxiliary model call for dream consolidation tests and live wiring.
struct LiveMemoryDreamSampler: Sendable {
    let sample: @Sendable (_ systemPrompt: String, _ userMessage: String) async throws -> String

    init(
        sample: @escaping @Sendable (_ systemPrompt: String, _ userMessage: String) async throws -> String
    ) {
        self.sample = sample
    }
}

// MARK: - Commands

/// Handler bodies for `/remember`, `/recall`, `/flush`, and `/dream`.
///
/// They return plain strings rather than touching the pager, so the interactive
/// controller only has to print what it gets back. That keeps the command
/// surface owned by whoever owns the controller while the behaviour stays here.
enum LiveMemoryCommands {
    static func remember(
        _ argument: String,
        backend: LiveMemoryBackend?
    ) async -> String {
        guard let backend else {
            return "Memory is not enabled. Set `memory.enabled = true` in config.toml or OPENGROK_MEMORY=1."
        }
        let text = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return "Usage: /remember <something worth keeping across sessions>"
        }
        if await backend.isEphemeralWorkspace {
            return "This workspace is a temporary directory, so memory writes are skipped."
        }
        do {
            try await backend.remember(text)
            return "Saved to workspace memory."
        } catch {
            return "Could not save to memory: \(error)"
        }
    }

    static func recall(
        _ argument: String,
        backend: LiveMemoryBackend?
    ) async -> String {
        guard let backend else {
            return "Memory is not enabled. Set `memory.enabled = true` in config.toml or OPENGROK_MEMORY=1."
        }
        let query = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return "Usage: /recall <query>"
        }
        let results = await backend.search(query: query)
        guard !results.isEmpty else {
            return "Nothing in memory matched \"\(query)\"."
        }
        return LiveMemoryFormatting.toolOutput(results)
    }

    /// Legacy `/flush <notes>` — preserve the explicit user-supplied variant.
    /// Bare `/flush` is routed through the live model-backed coordinator.
    static func flush(
        _ argument: String,
        sessionID: String,
        backend: LiveMemoryBackend?
    ) async -> String {
        guard let backend else {
            return "Memory is not enabled. Set `memory.enabled = true` in config.toml or OPENGROK_MEMORY=1."
        }
        let text = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return "Usage: /flush <notes to persist for this session>"
        }
        do {
            try await backend.writeSessionLog(sessionID: sessionID, content: text)
            return "Wrote to today's session memory log."
        } catch {
            return "Could not write session memory: \(error)"
        }
    }

    /// `/dream` — run memory consolidation now.
    ///
    /// Bypasses automatic gate checks (time and session count) but still requires
    /// `[memory.dream] enabled = true` and an auxiliary sampler from the caller.
    static func dream(
        backend: LiveMemoryBackend?,
        dreamConfig: MemoryDreamConfig,
        sessionID: String,
        sampler: LiveMemoryDreamSampler?
    ) async -> String {
        guard let backend else {
            return "Memory is not enabled. Set `memory.enabled = true` in config.toml or OPENGROK_MEMORY=1."
        }
        guard dreamConfig.enabled else {
            return "Dream consolidation is disabled. Set `memory.dream.enabled = true` in config.toml."
        }
        if await backend.isEphemeralWorkspace {
            return "This workspace is a temporary directory, so dream consolidation is skipped."
        }
        guard let sampler else {
            return "Dream consolidation is not wired for this session (no auxiliary sampler)."
        }
        let result = await backend.runDream(
            sessionID: sessionID,
            dreamConfig: dreamConfig,
            sample: sampler.sample
        )
        return dreamStatusMessage(for: result)
    }
}

enum LiveMemoryClearScope: Sendable, Equatable {
    case workspace
    case global
    case all
}

enum LiveMemoryComposition {
    private struct ClearTarget: Sendable {
        let label: String
        let path: URL
        let isDirectory: Bool
        let clear: @Sendable (MemoryStorage) throws -> Bool
    }

    @discardableResult
    static func runClear(
        scope: LiveMemoryClearScope,
        skipConfirmation: Bool,
        workingDirectory: URL,
        environment: [String: String],
        confirmation: @Sendable () -> String?,
        output: @Sendable (String) -> Void,
        error errorOutput: @Sendable (String) -> Void
    ) -> Int32 {
        let storage = MemoryStorage(
            cwd: workingDirectory.standardizedFileURL,
            environment: environment
        )
        let workspace = ClearTarget(
            label: "workspace memory",
            path: storage.workspaceDir,
            isDirectory: true,
            clear: { try $0.clearWorkspace() }
        )
        let global = ClearTarget(
            label: "global MEMORY.md",
            path: storage.globalMemoryFile,
            isDirectory: false,
            clear: { try $0.clearGlobal() }
        )
        let targets: [ClearTarget]
        switch scope {
        case .workspace: targets = [workspace]
        case .global: targets = [global]
        case .all: targets = [workspace, global]
        }

        let existing = targets.filter {
            FileManager.default.fileExists(atPath: $0.path.path)
        }
        guard !existing.isEmpty else {
            output("Nothing to clear — no memory files found.\n")
            return CLIRunner.ExitCode.success.rawValue
        }

        do {
            for target in existing {
                try LiveMemorySessionStorage.validateClearTarget(
                    target.path,
                    root: storage.globalDir,
                    isDirectory: target.isDirectory
                )
            }
        } catch {
            errorOutput("Failed to clear memory:\n  \(error)\n")
            return CLIRunner.ExitCode.failure.rawValue
        }

        output("The following will be deleted:\n")
        for target in existing {
            output("  \(target.label): \(target.path.path)\n")
        }

        if !skipConfirmation {
            output("\nAre you sure? [y/N] ")
            guard let reply = confirmation()?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased(),
                  reply == "y" || reply == "yes"
            else {
                output("Cancelled.\n")
                return CLIRunner.ExitCode.success.rawValue
            }
        }

        var cleared = false
        var failures: [String] = []
        for target in targets {
            do {
                if FileManager.default.fileExists(atPath: target.path.path) {
                    try LiveMemorySessionStorage.validateClearTarget(
                        target.path,
                        root: storage.globalDir,
                        isDirectory: target.isDirectory
                    )
                }
                if try target.clear(storage) {
                    cleared = true
                    output("  Cleared: \(target.label)\n")
                }
            } catch {
                failures.append("\(target.label): \(error)")
            }
        }

        if cleared, failures.isEmpty {
            output("Memory cleared.\n")
        } else if cleared {
            output("Memory partially cleared. Errors:\n")
            for failure in failures {
                errorOutput("  \(failure)\n")
            }
        } else if !failures.isEmpty {
            errorOutput("Failed to clear memory:\n")
            for failure in failures {
                errorOutput("  \(failure)\n")
            }
            return CLIRunner.ExitCode.failure.rawValue
        }

        return CLIRunner.ExitCode.success.rawValue
    }
}
