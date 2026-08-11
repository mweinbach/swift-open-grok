import Foundation
import OpenGrokConfigTypes

/// Result of the dream gate check.
public enum DreamGate: Equatable, Sendable {
    case open(sessions: [String])
    case disabled
    case tooSoon(hoursSince: UInt64)
    case tooFewSessions(count: Int, required: UInt64)
    case error(String)
}

/// Outcome status for a dream consolidation attempt.
public enum DreamStatus: Equatable, Sendable {
    case skipped(String)
    case completed(charsWritten: Int)
    case nothingToConsolidate
    case failed(String)
}

public struct DreamResult: Equatable, Sendable {
    public var status: DreamStatus
    /// Gate-eligible sessions (including those beyond the input cap).
    public var sessionsEligible: Int
    /// Stems actually removed from disk after success.
    public var cleanedStems: [String]

    public init(status: DreamStatus, sessionsEligible: Int, cleanedStems: [String]) {
        self.status = status
        self.sessionsEligible = sessionsEligible
        self.cleanedStems = cleanedStems
    }
}

public struct DreamMessage: Equatable, Sendable {
    public var content: String
    public var processedStems: [String]

    public init(content: String, processedStems: [String]) {
        self.content = content
        self.processedStems = processedStems
    }
}

public let dreamSystemPrompt = """
You are performing a dream — a reflective pass over memory files. \
Synthesize recent session logs into durable, well-organized memories \
so future sessions orient quickly.

You will receive the contents of recent session logs. \
You may also receive an existing memory document — merge it with new sessions \
rather than discarding prior knowledge. Your job:

1. **Merge** related information into coherent topic summaries
2. **Resolve** contradictions — if a recent session disproves an older fact, keep only the current truth
3. **Convert** relative dates ("yesterday", "last week") to absolute dates
4. **Discard** ephemeral details:
   - Greetings, meta-commentary, tool output noise
   - Message counts and tool-usage statistics
   - 'Current state' and 'Next steps' sections
   - User preferences already in global memory (OS, shell, paths)
   - Session metadata (dates, message counts)
5. **Preserve** decisions, rationale, architecture, preferences, and problem/solution pairs

Respond with a single markdown document. Use ## headers to separate topics. \
Each topic should be self-contained and useful to a future session that knows \
nothing about the current conversation.

If the session logs contain nothing worth persisting, respond with NO_REPLY.
"""

private let maxDreamInputChars = 32_000
private let maxDreamOutputChars = 16_000
private let cleanupRecencyGuardSeconds: UInt64 = 300
private let scaffoldMaxLength = 500
private let scaffoldMarkers = [
    "Auto-populated by dream consolidation",
    "Add project-specific knowledge here",
    "Add any cross-project preferences here",
]

/// Check all dream gates (cheapest first). Does not acquire the lock.
public func checkDreamGates(
    config: MemoryDreamConfig,
    lock: DreamLock,
    sessionsDirectory: URL,
    currentSessionSID8: String?
) -> DreamGate {
    guard config.enabled else { return .disabled }

    let lastAt: Date
    do {
        lastAt = try lock.lastConsolidatedAt() ?? Date(timeIntervalSince1970: 0)
    } catch {
        return .error(error.localizedDescription)
    }

    let elapsed = Date().timeIntervalSince(lastAt)
    let hoursSince = UInt64(max(0, elapsed) / 3600)
    if hoursSince < config.minHours {
        return .tooSoon(hoursSince: hoursSince)
    }

    let sessions: [String]
    do {
        sessions = try sessionsSince(
            sessionsDirectory: sessionsDirectory,
            since: lastAt,
            excludingSessionSID8: currentSessionSID8
        )
    } catch {
        return .error(error.localizedDescription)
    }

    if UInt64(sessions.count) < config.minSessions {
        return .tooFewSessions(count: sessions.count, required: config.minSessions)
    }

    return .open(sessions: sessions)
}

func isScaffoldTemplate(_ content: String) -> Bool {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count < scaffoldMaxLength else { return false }
    return scaffoldMarkers.contains { trimmed.contains($0) }
}

/// Build the user message for the dream model call from session log contents.
public func buildDreamUserMessage(
    sessionsDirectory: URL,
    stems: [String],
    existingMemory: String?
) -> DreamMessage? {
    var buffer = ""
    if let memory = existingMemory {
        let trimmed = memory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !isScaffoldTemplate(trimmed) {
            buffer += "--- Existing Memory (merge with new sessions) ---\n\n"
            let cap = maxDreamInputChars / 2
            if trimmed.count <= cap {
                buffer += trimmed
            } else {
                buffer += String(trimmed.prefix(cap))
            }
        }
    }

    var processedStems: [String] = []
    for stem in stems {
        let fileURL = sessionsDirectory.appendingPathComponent("\(stem).md")
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }

        if !buffer.isEmpty { buffer += "\n\n" }
        buffer += "--- Session: \(stem) ---\n\n"
        buffer += content
        processedStems.append(stem)

        if buffer.count >= maxDreamInputChars { break }
    }

    guard !processedStems.isEmpty else { return nil }
    return DreamMessage(content: buffer, processedStems: processedStems)
}

/// Process the dream model's response. Returns content ready for writing, or nil.
public func processDreamResponse(_ response: String) -> String? {
    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard !isNoReply(trimmed) else { return nil }
    guard hasMarkdownHeaders(trimmed) else { return nil }

    if trimmed.count > maxDreamOutputChars {
        return String(trimmed.prefix(maxDreamOutputChars))
    }
    return trimmed
}

/// Execute the dream lifecycle around a provided model response.
public func executeDream(
    lock: DreamLock,
    storage: MemoryStorage,
    response: String,
    sessionsEligible: Int,
    staleLockSeconds: UInt64,
    sessionsDirectory: URL,
    processedStems: [String]
) -> DreamResult {
    let prior: Date?
    do {
        switch try lock.tryAcquire(staleSeconds: staleLockSeconds) {
        case .acquired(let priorMtime):
            prior = priorMtime
        case .held:
            return DreamResult(
                status: .skipped("lock held by another process"),
                sessionsEligible: 0,
                cleanedStems: []
            )
        }
    } catch {
        return DreamResult(
            status: .failed("lock acquire failed: \(error.localizedDescription)"),
            sessionsEligible: 0,
            cleanedStems: []
        )
    }

    guard let content = processDreamResponse(response) else {
        return DreamResult(
            status: .nothingToConsolidate,
            sessionsEligible: sessionsEligible,
            cleanedStems: []
        )
    }

    do {
        try storage.writeLongTerm(scope: .workspace, content: content)
    } catch {
        try? lock.rollback(prior: prior)
        return DreamResult(
            status: .failed("failed to write MEMORY.md: \(error.localizedDescription)"),
            sessionsEligible: sessionsEligible,
            cleanedStems: []
        )
    }

    let cleanedStems = cleanProcessedSessions(
        sessionsDirectory: sessionsDirectory,
        stems: processedStems
    )
    return DreamResult(
        status: .completed(charsWritten: content.count),
        sessionsEligible: sessionsEligible,
        cleanedStems: cleanedStems
    )
}

/// Run dream consolidation: build the prompt, call the model, write under lock.
public func runDreamConsolidation(
    storage: MemoryStorage,
    lock: DreamLock,
    config: MemoryDreamConfig,
    sessions: [String],
    sample: @Sendable (_ systemPrompt: String, _ userMessage: String) async throws -> String
) async -> DreamResult {
    let existingMemory = try? String(
        contentsOf: storage.workspaceMemoryFile,
        encoding: .utf8
    )
    guard let dreamMessage = buildDreamUserMessage(
        sessionsDirectory: storage.sessionsDir,
        stems: sessions,
        existingMemory: existingMemory
    ) else {
        return DreamResult(
            status: .skipped("no readable session content"),
            sessionsEligible: sessions.count,
            cleanedStems: []
        )
    }

    let modelResponse: String
    do {
        modelResponse = try await sample(dreamSystemPrompt, dreamMessage.content)
    } catch {
        return DreamResult(
            status: .failed("model call failed: \(error.localizedDescription)"),
            sessionsEligible: sessions.count,
            cleanedStems: []
        )
    }

    return executeDream(
        lock: lock,
        storage: storage,
        response: modelResponse,
        sessionsEligible: sessions.count,
        staleLockSeconds: config.staleLockSecs,
        sessionsDirectory: storage.sessionsDir,
        processedStems: dreamMessage.processedStems
    )
}

/// Human-readable status for UI and slash-command output.
public func dreamStatusMessage(for result: DreamResult) -> String {
    switch result.status {
    case .skipped(let reason):
        return "Dream skipped: \(reason)."
    case .completed(let charsWritten):
        return "Dream consolidation complete (\(charsWritten) chars written to MEMORY.md)."
    case .nothingToConsolidate:
        return "Dream ran but found nothing worth consolidating."
    case .failed(let error):
        return "Dream consolidation failed: \(error)."
    }
}

func cleanProcessedSessions(sessionsDirectory: URL, stems: [String]) -> [String] {
    var cleaned: [String] = []
    let now = Date()
    for stem in stems {
        let path = sessionsDirectory.appendingPathComponent("\(stem).md")
        if FileManager.default.fileExists(atPath: path.path) {
            if let values = try? path.resourceValues(forKeys: [.contentModificationDateKey]),
               let mtime = values.contentModificationDate,
               now.timeIntervalSince(mtime) < Double(cleanupRecencyGuardSeconds)
            {
                continue
            }
        }
        do {
            try FileManager.default.removeItem(at: path)
            cleaned.append(stem)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == 4 {
            // Not found — already gone.
            continue
        } catch {
            continue
        }
    }
    return cleaned
}
