import Foundation
import OpenGrokHooksPluginTypes

public enum HookExecutionState: Sendable, Equatable {
    case success
    case skipped
    case blocked
    case failed
}

public struct HookRunRecord: Sendable, Equatable {
    public var hookName: String
    public var state: HookExecutionState
    public var detail: String?
    public var elapsedMs: UInt64
    public var httpInfo: HookHTTPInfo?

    public init(hookName: String, state: HookExecutionState, detail: String? = nil, elapsedMs: UInt64 = 0, httpInfo: HookHTTPInfo? = nil) {
        self.hookName = hookName
        self.state = state
        self.detail = detail
        self.elapsedMs = elapsedMs
        self.httpInfo = httpInfo
    }
}

public struct PreToolUseDispatchResult: Sendable, Equatable {
    public var decision: HookDecision
    public var results: [HookRunRecord]

    public init(decision: HookDecision = .allow, results: [HookRunRecord] = []) {
        self.decision = decision
        self.results = results
    }
}

public struct StopBlock: Sendable, Equatable {
    public var hookName: String
    public var reason: String
    public init(hookName: String, reason: String) { self.hookName = hookName; self.reason = reason }
}

public struct StopDispatchResult: Sendable, Equatable {
    public var blocks: [StopBlock]
    public var additionalContext: [String]
    public var preventContinuation: StopBlock?
    public var results: [HookRunRecord]

    public init(blocks: [StopBlock] = [], additionalContext: [String] = [], preventContinuation: StopBlock? = nil, results: [HookRunRecord] = []) {
        self.blocks = blocks
        self.additionalContext = additionalContext
        self.preventContinuation = preventContinuation
        self.results = results
    }

    public var wantsContinuation: Bool {
        preventContinuation == nil && (!blocks.isEmpty || !additionalContext.isEmpty)
    }

    fileprivate mutating func absorb(hookName: String, outcome: StopHookOutcome) {
        if let forceStop = outcome.forceStop, preventContinuation == nil {
            preventContinuation = StopBlock(hookName: hookName, reason: forceStop.reason ?? "stopped by hook")
        }
        if let reason = outcome.blockReason {
            blocks.append(StopBlock(hookName: hookName, reason: reason))
        }
        if let context = outcome.additionalContext {
            additionalContext.append(context)
        }
    }
}

public struct HookDispatcher: Sendable {
    public let registry: HookRegistry
    public let disabledNames: Set<String>

    public init(registry: HookRegistry, disabledNames: Set<String>? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.registry = registry
        self.disabledNames = disabledNames ?? disabledHookNames(environment: environment)
    }

    public func dispatchPreToolUse(envelope: HookEventEnvelope, context: HookRunContext) async -> PreToolUseDispatchResult {
        var records: [HookRunRecord] = []
        for spec in registry.hooks(for: .preToolUse) {
            guard eligible(spec, envelope: envelope, records: &records) else { continue }
            let invocation = await HookRunner.run(spec: spec, envelope: envelope, context: context, mode: .tool)
            switch invocation.result {
            case .decision(.deny(let reason, _)):
                records.append(HookRunRecord(hookName: spec.name, state: .blocked, detail: "denied: \(reason)", elapsedMs: invocation.elapsedMs, httpInfo: invocation.httpInfo))
                return PreToolUseDispatchResult(decision: .deny(reason: reason, hookName: spec.name), results: records)
            case .decision(.allow), .success, .stop:
                records.append(HookRunRecord(hookName: spec.name, state: .success, elapsedMs: invocation.elapsedMs, httpInfo: invocation.httpInfo))
            case .failed(let error):
                records.append(HookRunRecord(hookName: spec.name, state: .failed, detail: error, elapsedMs: invocation.elapsedMs, httpInfo: invocation.httpInfo))
            }
        }
        return PreToolUseDispatchResult(results: records)
    }

    public func dispatchStop(event: HookEvent, envelope: HookEventEnvelope, context: HookRunContext) async -> StopDispatchResult {
        guard event == .stop || event == .subagentStop else { return StopDispatchResult() }
        var output = StopDispatchResult()
        for spec in registry.hooksForCanonical(event) {
            guard eligible(spec, envelope: envelope, records: &output.results) else { continue }
            let invocation = await HookRunner.run(spec: spec, envelope: envelope, context: context, mode: .stop)
            switch invocation.result {
            case .stop(let outcome):
                let blocked = outcome.forceStop != nil || outcome.blockReason != nil
                output.results.append(HookRunRecord(hookName: spec.name, state: blocked ? .blocked : .success, detail: stopDetail(outcome), elapsedMs: invocation.elapsedMs, httpInfo: invocation.httpInfo))
                output.absorb(hookName: spec.name, outcome: outcome)
            case .failed(let error):
                output.results.append(HookRunRecord(hookName: spec.name, state: .failed, detail: error, elapsedMs: invocation.elapsedMs, httpInfo: invocation.httpInfo))
            case .success, .decision:
                output.results.append(HookRunRecord(hookName: spec.name, state: .success, elapsedMs: invocation.elapsedMs, httpInfo: invocation.httpInfo))
            }
        }
        return output
    }

    public func dispatchNonBlocking(event: HookEvent, envelope: HookEventEnvelope, context: HookRunContext) async -> [HookRunRecord] {
        guard event.gateKind == .observe else { return [] }
        var records: [HookRunRecord] = []
        for spec in registry.hooksForCanonical(event) {
            guard eligible(spec, envelope: envelope, records: &records) else { continue }
            let invocation = await HookRunner.run(spec: spec, envelope: envelope, context: context, mode: .observe)
            switch invocation.result {
            case .failed(let error): records.append(HookRunRecord(hookName: spec.name, state: .failed, detail: error, elapsedMs: invocation.elapsedMs, httpInfo: invocation.httpInfo))
            default: records.append(HookRunRecord(hookName: spec.name, state: .success, elapsedMs: invocation.elapsedMs, httpInfo: invocation.httpInfo))
            }
        }
        return records
    }

    private func eligible(_ spec: HookSpec, envelope: HookEventEnvelope, records: inout [HookRunRecord]) -> Bool {
        if !spec.enabled || disabledNames.contains(spec.name) {
            records.append(HookRunRecord(hookName: spec.name, state: .skipped))
            return false
        }
        guard let matcher = spec.matcher else { return true }
        return envelope.matchValue.map(matcher.isMatch) ?? true
    }

    private func stopDetail(_ outcome: StopHookOutcome) -> String? {
        if let forceStop = outcome.forceStop {
            return "prevented continuation: \(forceStop.reason ?? "stopped by hook")"
        }
        if let reason = outcome.blockReason { return "blocked stop: \(reason)" }
        return nil
    }
}
