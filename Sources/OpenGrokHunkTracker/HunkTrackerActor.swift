// HunkTrackerActor.swift
//
// Actor-based hunk tracking with explicit agent/external attribution.
// Filesystem notifications are NEVER accepted as authorship evidence —
// only `recordAgentWrite` creates `.agentEdit` sources.
// Port of xai-hunk-tracker HunkTrackerActor.

import Foundation

struct FileHunkState {
    var baseline: FileContentState
    var currentContent: FileContentState
    var hunks: [Hunk]
    var isAgentFile: Bool
    var baselineAccepted: Bool
}

/// Actor that owns all hunk tracking state.
public actor HunkTrackerActor {
    private let sessionId: String
    private let workingDir: String
    private let defaultAgentId: String
    private var fileStates: [String: FileHunkState] = [:]
    private var turnIndex: [Int: Set<HunkId>] = [:]
    private var mode: TrackingMode
    private var sessionStats = SessionStats()
    private var eventContinuations: [UUID: AsyncStream<HunkEvent>.Continuation] = [:]
    private var cancelled = false
    private var persistencePath: String?

    public init(
        sessionId: String,
        workingDir: String,
        mode: TrackingMode = .agentOnly,
        defaultAgentId: String = "agent",
        persistencePath: String? = nil
    ) {
        self.sessionId = sessionId
        self.workingDir = workingDir
        self.mode = mode
        self.defaultAgentId = defaultAgentId
        self.persistencePath = persistencePath
    }

    public var currentSessionId: String { sessionId }

    /// Subscribe to hunk events.
    public func events() -> AsyncStream<HunkEvent> {
        AsyncStream { continuation in
            let id = UUID()
            self.eventContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func send(_ event: HunkEvent) {
        for cont in eventContinuations.values {
            cont.yield(event)
        }
    }

    public func cancel() {
        cancelled = true
        for cont in eventContinuations.values {
            cont.finish()
        }
        eventContinuations.removeAll()
    }

    public func setMode(_ mode: TrackingMode) {
        self.mode = mode
    }

    // MARK: - Mutations

    /// Record that an agent tool wrote to a file. This is the **only** path
    /// that attributes `.agentEdit` authorship.
    ///
    /// - Important: Attribution is recorded only when `writeSucceeded` is true
    ///   (or when `result.succeeded` is true). Failed writes never create hunks.
    ///   Filesystem notifications must never call this method.
    public func recordAgentWrite(
        path: String,
        content: String,
        promptIndex: Int,
        previousContent: String? = nil,
        agentId: String? = nil,
        writeSucceeded: Bool = true
    ) {
        guard writeSucceeded else { return }
        let result = AgentWriteResult.success(
            path: path,
            content: content,
            previousContent: previousContent
        )
        recordAgentWrite(
            result: result,
            promptIndex: promptIndex,
            agentId: agentId ?? defaultAgentId
        )
    }

    /// Record a structured write result. No-ops when `result.succeeded` is false.
    public func recordAgentWrite(
        result: AgentWriteResult,
        promptIndex: Int,
        agentId: String? = nil
    ) {
        guard !cancelled else { return }
        guard result.succeeded else { return }
        let absPath = absolute(result.path)
        let content = result.content
        let previousContent = result.previousContent
        let source = HunkSource.agentEdit(
            promptIndex: promptIndex,
            sessionId: sessionId,
            agentId: agentId ?? defaultAgentId
        )
        let currentState = classifyString(content)

        if !currentState.isDiffable {
            if fileStates[absPath] == nil {
                let baseline: FileContentState
                if let prev = previousContent {
                    baseline = classifyString(prev)
                } else {
                    baseline = readBaseline(absPath)
                }
                fileStates[absPath] = FileHunkState(
                    baseline: baseline,
                    currentContent: currentState,
                    hunks: [],
                    isAgentFile: true,
                    baselineAccepted: false
                )
                send(.fileAdded(path: absPath, isAgentFile: true))
            } else {
                fileStates[absPath]?.isAgentFile = true
                fileStates[absPath]?.currentContent = currentState
                fileStates[absPath]?.hunks = []
            }
            persistIfConfigured()
            return
        }

        let isNew = fileStates[absPath] == nil
        if isNew {
            let baseline: FileContentState
            let gitBaseline = readBaseline(absPath)
            if case .missing = gitBaseline {
                baseline = previousContent.map(classifyString) ?? .missing
            } else {
                baseline = gitBaseline
            }
            fileStates[absPath] = FileHunkState(
                baseline: baseline,
                currentContent: currentState,
                hunks: [],
                isAgentFile: true,
                baselineAccepted: false
            )
            send(.fileAdded(path: absPath, isAgentFile: true))
        } else {
            fileStates[absPath]?.isAgentFile = true
        }
        recomputeHunks(path: absPath, newCurrent: currentState, source: source)
        persistIfConfigured()
    }

    /// Handle a filesystem notification. Never creates `.agentEdit` sources.
    public func handleFileChange(path: String) {
        guard !cancelled else { return }
        let absPath = absolute(path)
        let isTracked = fileStates[absPath] != nil
        if mode == .agentOnly && !isTracked { return }

        let currentState = readFileBounded(absPath)
        let isAgent = fileStates[absPath]?.isAgentFile ?? false
        let source: HunkSource = isAgent ? .externalEditOnAgentFile : .external

        if !isTracked {
            let baseline = readBaseline(absPath)
            fileStates[absPath] = FileHunkState(
                baseline: baseline,
                currentContent: currentState,
                hunks: [],
                isAgentFile: false,
                baselineAccepted: false
            )
            send(.fileAdded(path: absPath, isAgentFile: false))
        }

        // If baseline was accepted and disk now matches git HEAD, refresh baseline.
        if let state = fileStates[absPath], state.baselineAccepted {
            let gitBaseline = readBaseline(absPath)
            if case .full(let git) = gitBaseline,
               case .full(let cur) = currentState,
               stripTrailingNewline(git) == stripTrailingNewline(cur) {
                fileStates[absPath]?.baseline = gitBaseline
                fileStates[absPath]?.baselineAccepted = false
                send(.baselineUpdated(path: absPath))
            }
        }

        recomputeHunks(path: absPath, newCurrent: currentState, source: source)
    }

    public func handleFileDeleted(path: String) {
        guard !cancelled else { return }
        let absPath = absolute(path)
        let isTracked = fileStates[absPath] != nil
        if mode == .agentOnly && !isTracked { return }

        let isAgent = fileStates[absPath]?.isAgentFile ?? false
        let source: HunkSource = isAgent ? .externalEditOnAgentFile : .external

        if !isTracked {
            let baseline = readBaseline(absPath)
            if case .missing = baseline { return }
            fileStates[absPath] = FileHunkState(
                baseline: baseline,
                currentContent: .missing,
                hunks: [],
                isAgentFile: false,
                baselineAccepted: false
            )
            send(.fileAdded(path: absPath, isAgentFile: false))
        }
        recomputeHunks(path: absPath, newCurrent: .missing, source: source)
    }

    // MARK: - Actions

    public func hunkAction(hunkId: HunkId, action: HunkAction) throws {
        guard let (path, idx) = findHunk(hunkId) else {
            throw HunkActionError.hunkNotFound(hunkId)
        }
        switch action {
        case .accept:
            try acceptHunk(path: path, index: idx)
        case .reject:
            try rejectHunk(path: path, index: idx)
        }
    }

    public func fileAction(path: String, action: HunkAction) throws -> [HunkId] {
        let absPath = absolute(path)
        guard let state = fileStates[absPath] else { return [] }
        let ids = state.hunks.map(\.id)
        // Process in reverse order so line positions stay stable for reject.
        for hunk in state.hunks.reversed() {
            try hunkAction(hunkId: hunk.id, action: action)
        }
        return ids
    }

    public func allAction(action: HunkAction) throws -> [HunkId] {
        var ids: [HunkId] = []
        for path in fileStates.keys.sorted() {
            ids.append(contentsOf: try fileAction(path: path, action: action))
        }
        return ids
    }

    public func turnAction(promptIndex: Int, action: HunkAction) throws -> [HunkId] {
        let ids = Array(turnIndex[promptIndex] ?? [])
        for id in ids {
            try? hunkAction(hunkId: id, action: action)
        }
        return ids
    }

    private func acceptHunk(path: String, index: Int) throws {
        guard var state = fileStates[path], index < state.hunks.count else {
            throw HunkActionError.hunkNotFound(HunkId("unknown"))
        }
        let hunk = state.hunks[index]
        // Patch baseline to include this change.
        if case .full(let baseline) = state.baseline {
            let patched: String
            if hunk.lineInfo.oldCount == 0 && hunk.lineInfo.oldStart == 0 {
                // whole file created
                patched = hunk.newText
            } else {
                patched = patchLines(
                    content: baseline,
                    startLine: max(hunk.lineInfo.oldStart, 1),
                    removeCount: hunk.lineInfo.oldCount,
                    insertText: hunk.newText
                )
            }
            state.baseline = .full(patched)
            state.baselineAccepted = true
        } else if case .missing = state.baseline {
            state.baseline = .full(hunk.newText)
            state.baselineAccepted = true
        }
        sessionStats.acceptedHunks += 1
        sessionStats.acceptedLinesAdded += hunk.lineInfo.newCount
        sessionStats.acceptedLinesRemoved += hunk.lineInfo.oldCount
        removeFromTurnIndex(hunk)
        state.hunks.remove(at: index)
        fileStates[path] = state
        send(.hunkRemoved(path: path, hunkId: hunk.id, reason: .accepted))
        // Recompute remaining against new baseline.
        if let current = state.currentContent.asString,
           let baseline = state.baseline.asString {
            recomputeHunks(path: path, newCurrent: .full(current), source: hunk.source)
            _ = baseline
        } else {
            recomputeHunks(path: path, newCurrent: state.currentContent, source: hunk.source)
        }
    }

    private func rejectHunk(path: String, index: Int) throws {
        guard var state = fileStates[path], index < state.hunks.count else {
            throw HunkActionError.hunkNotFound(HunkId("unknown"))
        }
        let hunk = state.hunks[index]
        // Revert file content for this hunk.
        if case .full(let current) = state.currentContent {
            let reverted: String
            if hunk.lineInfo.newCount == 0 && hunk.lineInfo.newStart == 0 {
                // whole file deleted — restore
                reverted = hunk.oldText ?? ""
            } else if hunk.lineInfo.oldCount == 0 && hunk.lineInfo.oldStart == 0
                        && state.hunks.count == 1 {
                // sole create hunk — delete file
                try? FileManager.default.removeItem(atPath: path)
                sessionStats.rejectedHunks += 1
                sessionStats.rejectedLinesAdded += hunk.lineInfo.newCount
                sessionStats.rejectedLinesRemoved += hunk.lineInfo.oldCount
                removeFromTurnIndex(hunk)
                state.hunks.removeAll()
                state.currentContent = .missing
                fileStates[path] = state
                send(.hunkRemoved(path: path, hunkId: hunk.id, reason: .rejected))
                return
            } else {
                reverted = patchLines(
                    content: current,
                    startLine: max(hunk.lineInfo.newStart, 1),
                    removeCount: hunk.lineInfo.newCount,
                    insertText: hunk.oldText ?? ""
                )
            }
            do {
                try reverted.write(toFile: path, atomically: true, encoding: .utf8)
            } catch {
                throw HunkActionError.writeError(path: path, message: String(describing: error))
            }
            state.currentContent = .full(reverted)
        }
        sessionStats.rejectedHunks += 1
        sessionStats.rejectedLinesAdded += hunk.lineInfo.newCount
        sessionStats.rejectedLinesRemoved += hunk.lineInfo.oldCount
        removeFromTurnIndex(hunk)
        state.hunks.remove(at: index)
        fileStates[path] = state
        send(.hunkRemoved(path: path, hunkId: hunk.id, reason: .rejected))
        recomputeHunks(path: path, newCurrent: state.currentContent, source: hunk.source)
    }

    // MARK: - Queries

    public func getAllHunks() -> [Hunk] {
        fileStates.values.flatMap(\.hunks).sorted {
            ($0.path, $0.lineInfo.newStart) < ($1.path, $1.lineInfo.newStart)
        }
    }

    public func getHunksForPath(_ path: String) -> [Hunk] {
        fileStates[absolute(path)]?.hunks ?? []
    }

    public func getFileHunkData(_ path: String) -> FileHunkData {
        let absPath = absolute(path)
        guard let state = fileStates[absPath] else {
            return FileHunkData()
        }
        return FileHunkData(
            hunks: state.hunks,
            baseline: state.baseline.asView(),
            current: state.currentContent.asView()
        )
    }

    public func getHunksBySource(_ filter: HunkSourceFilter) -> [Hunk] {
        getAllHunks().filter { h in
            switch filter {
            case .agent: return h.source.isAgentEdit
            case .external: return h.source.isExternal
            }
        }
    }

    public func getHunk(_ id: HunkId) -> Hunk? {
        for state in fileStates.values {
            if let h = state.hunks.first(where: { $0.id == id }) { return h }
        }
        return nil
    }

    public func isAgentFile(_ path: String) -> Bool {
        fileStates[absolute(path)]?.isAgentFile ?? false
    }

    public func getAllTrackedPaths() -> [String] {
        Array(fileStates.keys).sorted()
    }

    public func getSessionSummary() -> SessionSummary {
        var turns: [Int: TurnSummary] = [:]
        var agentFiles = Set<String>()
        var pendingAgent = 0
        var pendingAdd = 0
        var pendingRem = 0
        var unattributed = 0

        for (path, state) in fileStates {
            for hunk in state.hunks {
                if let idx = hunk.source.promptIndex {
                    var t = turns[idx] ?? TurnSummary(
                        promptIndex: idx, files: [], pendingHunks: [],
                        linesAdded: 0, linesRemoved: 0
                    )
                    if !t.files.contains(path) { t.files.append(path) }
                    t.pendingHunks.append(hunk)
                    t.linesAdded += hunk.lineInfo.newCount
                    t.linesRemoved += hunk.lineInfo.oldCount
                    turns[idx] = t
                    agentFiles.insert(path)
                    pendingAgent += 1
                    pendingAdd += hunk.lineInfo.newCount
                    pendingRem += hunk.lineInfo.oldCount
                } else {
                    unattributed += 1
                }
            }
        }

        return SessionSummary(
            stats: sessionStats,
            turns: turns.values.sorted { $0.promptIndex < $1.promptIndex },
            filesModified: agentFiles.count,
            filesWithPending: agentFiles.count,
            pendingHunks: pendingAgent,
            pendingLinesAdded: pendingAdd,
            pendingLinesRemoved: pendingRem,
            unattributedPending: unattributed
        )
    }

    public func getTurnHunks(promptIndex: Int) -> [Hunk] {
        let ids = turnIndex[promptIndex] ?? []
        return getAllHunks().filter { ids.contains($0.id) }
    }

    public func resetStats() {
        sessionStats = SessionStats()
    }

    public func resetBaseline(path: String) {
        let absPath = absolute(path)
        let baseline = readBaseline(absPath)
        let current = readFileBounded(absPath)
        if fileStates[absPath] == nil {
            fileStates[absPath] = FileHunkState(
                baseline: baseline,
                currentContent: current,
                hunks: [],
                isAgentFile: false,
                baselineAccepted: false
            )
        } else {
            fileStates[absPath]?.baseline = baseline
            fileStates[absPath]?.baselineAccepted = false
            fileStates[absPath]?.currentContent = current
        }
        send(.baselineUpdated(path: absPath))
        let source: HunkSource = (fileStates[absPath]?.isAgentFile == true)
            ? .externalEditOnAgentFile : .external
        recomputeHunks(path: absPath, newCurrent: current, source: source)
    }

    public func snapshotState() -> HunkTrackerSnapshot {
        var snap: [String: FileHunkStateSnapshot] = [:]
        for (path, state) in fileStates {
            snap[path] = FileHunkStateSnapshot(
                baseline: state.baseline,
                currentContent: state.currentContent,
                hunks: state.hunks,
                isAgentFile: state.isAgentFile,
                baselineAccepted: state.baselineAccepted
            )
        }
        return HunkTrackerSnapshot(
            schemaVersion: hunkTrackerSnapshotSchemaVersion,
            sessionId: sessionId,
            fileStates: snap,
            turnIndex: turnIndex,
            sessionStats: sessionStats
        )
    }

    /// Persist snapshot atomically to `path` (or configured persistence path).
    public func persist(to path: String? = nil) throws {
        let target = path ?? persistencePath
        guard let target else {
            throw HunkActionError.writeError(path: "", message: "no persistence path configured")
        }
        try HunkTrackerStore.save(snapshotState(), to: target)
    }

    /// Load snapshot from disk and restore in-memory state.
    public func restoreFromDisk(path: String? = nil) throws {
        let target = path ?? persistencePath
        guard let target else {
            throw HunkActionError.readError(path: "", message: "no persistence path configured")
        }
        let snap = try HunkTrackerStore.load(from: target)
        restoreState(snap)
    }

    public func setPersistencePath(_ path: String?) {
        persistencePath = path
    }

    private func persistIfConfigured() {
        guard let path = persistencePath else { return }
        try? HunkTrackerStore.save(snapshotState(), to: path)
    }

    public func snapshotTurnDelta(promptIndex: Int) -> HunkTurnDelta {
        let ids = turnIndex[promptIndex] ?? []
        var files: [String: FileHunkStateSnapshot] = [:]
        for (path, state) in fileStates {
            if state.hunks.contains(where: { ids.contains($0.id) }) {
                files[path] = FileHunkStateSnapshot(
                    baseline: state.baseline,
                    currentContent: state.currentContent,
                    hunks: state.hunks,
                    isAgentFile: state.isAgentFile,
                    baselineAccepted: state.baselineAccepted
                )
            }
        }
        return HunkTurnDelta(promptIndex: promptIndex, fileStates: files, hunkIds: ids)
    }

    public func restoreState(_ snapshot: HunkTrackerSnapshot) {
        fileStates = [:]
        for (path, s) in snapshot.fileStates {
            fileStates[path] = FileHunkState(
                baseline: s.baseline,
                currentContent: s.currentContent,
                hunks: s.hunks,
                isAgentFile: s.isAgentFile,
                baselineAccepted: s.baselineAccepted
            )
        }
        turnIndex = snapshot.turnIndex
        sessionStats = snapshot.sessionStats
    }

    // MARK: - Recompute

    private func recomputeHunks(path: String, newCurrent: FileContentState, source: HunkSource) {
        guard var state = fileStates[path] else { return }
        let oldHunks = state.hunks
        state.currentContent = newCurrent

        var newHunks: [Hunk] = []
        switch (state.baseline, state.currentContent) {
        case (.full(let baseline), .full(let current)):
            newHunks = computeHunks(path: path, baseline: baseline, current: current, source: source)
        case (.full(let baseline), .missing):
            if !baseline.isEmpty {
                newHunks = [Hunk.fileDeleted(path: path, content: baseline, source: source)]
            }
        case (.missing, .full(let current)):
            if !current.isEmpty {
                newHunks = [Hunk.fileCreated(path: path, content: current, source: source)]
            }
        default:
            newHunks = []
        }

        // Preserve IDs and agent attribution across external edits.
        var claimed = Set<HunkId>()
        for i in newHunks.indices {
            if let match = findMatchingOldHunk(newHunk: newHunks[i], oldHunks: oldHunks),
               !claimed.contains(match.id) {
                claimed.insert(match.id)
                newHunks[i].id = match.id
                if newHunks[i].source.isExternal && match.source.isAgentEdit {
                    newHunks[i].source = match.source
                }
            }
        }

        // Update turn index.
        for h in oldHunks {
            if let idx = h.source.promptIndex {
                turnIndex[idx]?.remove(h.id)
            }
        }
        for h in newHunks {
            if let idx = h.source.promptIndex {
                turnIndex[idx, default: []].insert(h.id)
            }
        }

        state.hunks = newHunks
        fileStates[path] = state
        emitDiff(path: path, oldHunks: oldHunks, newHunks: newHunks, trigger: source)
    }

    private func emitDiff(path: String, oldHunks: [Hunk], newHunks: [Hunk], trigger: HunkSource) {
        for old in oldHunks {
            let hasOverlap = newHunks.contains {
                hunksOverlap(old, $0) || hunksMatchContent(old, $0)
            }
            if !hasOverlap {
                send(.hunkRemoved(path: path, hunkId: old.id, reason: .superseded))
            }
        }
        for newH in newHunks {
            if let old = oldHunks.first(where: { hunksMatchContent($0, newH) }) {
                if hunkMoved(old, newH) {
                    send(.hunkMoved(path: path, hunkId: old.id, newLineInfo: newH.lineInfo))
                }
            } else {
                let hasOverlap = oldHunks.contains { hunksOverlap($0, newH) }
                if !hasOverlap {
                    send(.hunkAdded(path: path, hunk: newH))
                } else {
                    let prev = oldHunks.first(where: { $0.id == newH.id })
                        ?? oldHunks.first(where: { hunksOverlap($0, newH) })
                    send(.hunkContentChanged(
                        path: path,
                        hunk: newH,
                        triggerSource: trigger,
                        prevLinesAdded: prev?.lineInfo.newCount ?? 0,
                        prevLinesRemoved: prev?.lineInfo.oldCount ?? 0
                    ))
                }
            }
        }
    }

    // MARK: - Helpers

    private func absolute(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return (workingDir as NSString).appendingPathComponent(path)
    }

    /// Baseline from git HEAD via pure file read of blob is out of scope
    /// without object store; fall back to: if file exists at tracker start
    /// without prior write, use empty/missing. For tests, baselines are set
    /// via previousContent or initial disk content when first seen as agent.
    private func readBaseline(_ path: String) -> FileContentState {
        // Best-effort: if we already have a baseline, keep it; else missing
        // (callers pass previousContent for new files outside git).
        if let existing = fileStates[path]?.baseline {
            return existing
        }
        // Try reading a `.git` sibling baseline marker — pure path: if the
        // path is tracked we cannot get HEAD without object store; return
        // missing so previousContent / empty baseline is used.
        return .missing
    }

    private func findHunk(_ id: HunkId) -> (String, Int)? {
        for (path, state) in fileStates {
            if let idx = state.hunks.firstIndex(where: { $0.id == id }) {
                return (path, idx)
            }
        }
        return nil
    }

    private func removeFromTurnIndex(_ hunk: Hunk) {
        if let idx = hunk.source.promptIndex {
            turnIndex[idx]?.remove(hunk.id)
        }
    }
}

private func stripTrailingNewline(_ s: String) -> String {
    if s.hasSuffix("\r\n") { return String(s.dropLast(2)) }
    if s.hasSuffix("\n") { return String(s.dropLast()) }
    return s
}

// MARK: - Handle

/// Cheap handle to communicate with HunkTrackerActor.
public struct HunkTrackerHandle: Sendable {
    private let actor: HunkTrackerActor

    public init(actor: HunkTrackerActor) {
        self.actor = actor
    }

    public static func spawn(
        sessionId: String,
        workingDir: String,
        mode: TrackingMode = .agentOnly,
        defaultAgentId: String = "agent",
        persistencePath: String? = nil
    ) -> HunkTrackerHandle {
        HunkTrackerHandle(actor: HunkTrackerActor(
            sessionId: sessionId,
            workingDir: workingDir,
            mode: mode,
            defaultAgentId: defaultAgentId,
            persistencePath: persistencePath
        ))
    }

    public func recordAgentWrite(
        path: String,
        content: String,
        promptIndex: Int,
        previousContent: String? = nil,
        agentId: String? = nil,
        writeSucceeded: Bool = true
    ) async {
        await actor.recordAgentWrite(
            path: path,
            content: content,
            promptIndex: promptIndex,
            previousContent: previousContent,
            agentId: agentId,
            writeSucceeded: writeSucceeded
        )
    }

    public func recordAgentWrite(
        result: AgentWriteResult,
        promptIndex: Int,
        agentId: String? = nil
    ) async {
        await actor.recordAgentWrite(
            result: result,
            promptIndex: promptIndex,
            agentId: agentId
        )
    }

    public func handleFileChange(path: String) async {
        await actor.handleFileChange(path: path)
    }

    public func handleFileDeleted(path: String) async {
        await actor.handleFileDeleted(path: path)
    }

    public func getAllHunks() async -> [Hunk] {
        await actor.getAllHunks()
    }

    public func getHunksForPath(_ path: String) async -> [Hunk] {
        await actor.getHunksForPath(path)
    }

    public func getFileHunkData(_ path: String) async -> FileHunkData {
        await actor.getFileHunkData(path)
    }

    public func hunkAction(hunkId: HunkId, action: HunkAction) async throws {
        try await actor.hunkAction(hunkId: hunkId, action: action)
    }

    public func fileAction(path: String, action: HunkAction) async throws -> [HunkId] {
        try await actor.fileAction(path: path, action: action)
    }

    public func allAction(action: HunkAction) async throws -> [HunkId] {
        try await actor.allAction(action: action)
    }

    public func isAgentFile(_ path: String) async -> Bool {
        await actor.isAgentFile(path)
    }

    public func getAllTrackedPaths() async -> [String] {
        await actor.getAllTrackedPaths()
    }

    public func getSessionSummary() async -> SessionSummary {
        await actor.getSessionSummary()
    }

    public func getTurnHunks(promptIndex: Int) async -> [Hunk] {
        await actor.getTurnHunks(promptIndex: promptIndex)
    }

    public func snapshotState() async -> HunkTrackerSnapshot {
        await actor.snapshotState()
    }

    public func restoreState(_ snapshot: HunkTrackerSnapshot) async {
        await actor.restoreState(snapshot)
    }

    public func persist(to path: String? = nil) async throws {
        try await actor.persist(to: path)
    }

    public func restoreFromDisk(path: String? = nil) async throws {
        try await actor.restoreFromDisk(path: path)
    }

    public func setPersistencePath(_ path: String?) async {
        await actor.setPersistencePath(path)
    }

    public func sessionId() async -> String {
        await actor.currentSessionId
    }

    public func setMode(_ mode: TrackingMode) async {
        await actor.setMode(mode)
    }

    public func events() async -> AsyncStream<HunkEvent> {
        await actor.events()
    }

    public func cancel() async {
        await actor.cancel()
    }

    public func resetBaseline(path: String) async {
        await actor.resetBaseline(path: path)
    }

    public func resetStats() async {
        await actor.resetStats()
    }
}
