import Foundation
import OpenGrokACPRuntime

enum LiveLeaderRosterBridgeError: Error, Sendable, Equatable {
    case alreadyStarted
}

enum LiveLeaderRosterEvent: Sendable, Hashable {
    case snapshot([ACPLeaderRosterEntry])
    case changed(sessions: [ACPLeaderRosterEntry], delta: ACPLeaderRosterChanged)
}

/// Reconciles the leader's initial roster snapshot with its typed change
/// channel. The change subscription is installed before the snapshot request,
/// so a session created while the request is in flight is queued and applied
/// after the snapshot rather than silently missed.
///
/// Rust reference: `crates/codegen/xai-grok-shell/src/agent/roster.rs:3-13`
/// and `crates/codegen/xai-grok-pager/src/app/acp_handler/settings.rs:415-430`.
actor LiveLeaderRosterBridge {
    private let client: ACPLeaderClient
    private var entries: [String: ACPLeaderRosterEntry] = [:]
    private var task: Task<Void, Never>?
    private var started = false

    init(client: ACPLeaderClient) {
        self.client = client
    }

    func events() async throws -> AsyncThrowingStream<LiveLeaderRosterEvent, Error> {
        guard !started else { throw LiveLeaderRosterBridgeError.alreadyStarted }
        started = true
        let changes: AsyncThrowingStream<ACPLeaderRosterChanged, Error>
        let snapshot: ACPLeaderRosterListResponse
        do {
            changes = try await client.rosterEvents()
            snapshot = try await client.rosterSnapshot()
        } catch {
            started = false
            throw error
        }
        entries = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.sessionId, $0) })

        let (stream, continuation) = AsyncThrowingStream<LiveLeaderRosterEvent, Error>.makeStream()
        continuation.yield(.snapshot(sortedEntries()))
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.stop() }
        }
        task = Task { [weak self] in
            do {
                for try await delta in changes {
                    guard !Task.isCancelled else { return }
                    await self?.apply(delta, continuation: continuation)
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            await self?.finished()
        }
        return stream
    }

    func stop() {
        task?.cancel()
        task = nil
        started = false
    }

    private func apply(
        _ delta: ACPLeaderRosterChanged,
        continuation: AsyncThrowingStream<LiveLeaderRosterEvent, Error>.Continuation
    ) {
        for entry in delta.upserted {
            entries[entry.sessionId] = entry
        }
        for sessionId in delta.removed {
            entries.removeValue(forKey: sessionId)
        }
        continuation.yield(.changed(sessions: sortedEntries(), delta: delta))
    }

    private func sortedEntries() -> [ACPLeaderRosterEntry] {
        entries.values.sorted {
            if $0.lastChangeUnixMs == $1.lastChangeUnixMs {
                return $0.sessionId < $1.sessionId
            }
            return $0.lastChangeUnixMs > $1.lastChangeUnixMs
        }
    }

    private func finished() {
        task = nil
        started = false
    }
}
