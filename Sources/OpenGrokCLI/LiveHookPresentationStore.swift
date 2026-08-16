import OpenGrokHooks
import OpenGrokHooksPluginTypes
import OpenGrokPagerRender

struct LiveHookPresentationSnapshot: Sendable {
    var toolHooks: [String: [PagerHookRun]]
    var lifecycleBlocks: [PagerLifecycleBlock]
    var stopHooks: [String: [PagerHookRun]]
}

actor LiveHookPresentationStore {
    private var toolHooks: [String: [PagerHookRun]] = [:]
    private var lifecycleBlocks: [String: PagerLifecycleBlock] = [:]
    private var stopHooks: [String: [PagerHookRun]] = [:]
    private var fallbackLifecycleSequence: UInt64 = 0

    func record(event: HookEvent, id: String?, records: [HookRunRecord]) {
        guard !records.isEmpty else { return }
        switch event {
        case .preToolUse:
            guard let id else { return }
            toolHooks[id, default: []].append(contentsOf: rows(records, phase: .pre))
        case .postToolUse, .postToolUseFailure, .permissionDenied:
            guard let id else { return }
            toolHooks[id, default: []].append(contentsOf: rows(records, phase: .post))
        case .sessionStart:
            lifecycleBlocks["lifecycle-session-start"] = PagerLifecycleBlock(
                id: "lifecycle-session-start",
                kind: .sessionStart,
                state: aggregateState(records),
                hooks: rows(records, phase: .pre)
            )
        case .userPromptSubmit:
            fallbackLifecycleSequence &+= 1
            let stableID = id.map { "lifecycle-prompt-\($0)" }
                ?? "lifecycle-prompt-fallback-\(fallbackLifecycleSequence)"
            lifecycleBlocks[stableID] = PagerLifecycleBlock(
                id: stableID,
                kind: .userPromptSubmit,
                state: aggregateState(records),
                hooks: rows(records, phase: .pre)
            )
        case .stop, .stopFailure:
            guard let id else { return }
            stopHooks[id, default: []].append(contentsOf: rows(records, phase: .stop))
        case .sessionEnd, .notification, .subagentStart, .subagentStop,
             .preCompact, .postCompact:
            break
        }
    }

    func snapshot() -> LiveHookPresentationSnapshot {
        LiveHookPresentationSnapshot(
            toolHooks: toolHooks,
            lifecycleBlocks: lifecycleBlocks.values.sorted { $0.id < $1.id },
            stopHooks: stopHooks
        )
    }

    private func rows(_ records: [HookRunRecord], phase: PagerHookPhase) -> [PagerHookRun] {
        records.map { record in
            PagerHookRun(
                name: record.hookName,
                phase: phase,
                state: activityState(record.state),
                output: record.detail
            )
        }
    }

    private func aggregateState(_ records: [HookRunRecord]) -> PagerActivityState {
        if records.contains(where: { $0.state == .failed || $0.state == .blocked }) {
            return .failed
        }
        return .succeeded
    }

    private func activityState(_ state: HookExecutionState) -> PagerActivityState {
        switch state {
        case .success: return .succeeded
        case .skipped: return .cancelled
        case .blocked, .failed: return .failed
        }
    }
}
