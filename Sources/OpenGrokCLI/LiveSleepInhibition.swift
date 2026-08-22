import Foundation
import OpenGrokSystemPower

final class LiveSleepInhibition: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        var enabled: Bool
        var busy: Bool
        var suspended: Bool
        var shutdown: Bool
        var active: Bool
        var platformUnavailable: Bool
    }

    private struct State {
        var busy = false
        var suspended = false
        var shutdown = false
        var platformUnavailable = false
        var lease: (any PowerLease)?
        var workerRunning = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private enum Action {
        case acquire
        case release(any PowerLease)
        case finished([CheckedContinuation<Void, Never>])
    }

    private let enabled: Bool
    private let adapter: any PowerAdapter
    private let failureReporter: @Sendable (String) -> Void
    private let lock = NSLock()
    private var state = State()

    init(
        enabled: Bool,
        adapter: any PowerAdapter = PlatformPowerAdapter(),
        failureReporter: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.enabled = enabled
        self.adapter = adapter
        self.failureReporter = failureReporter
    }

    var snapshot: Snapshot {
        withState { state in
            Snapshot(
                enabled: enabled,
                busy: state.busy,
                suspended: state.suspended,
                shutdown: state.shutdown,
                active: state.lease != nil,
                platformUnavailable: state.platformUnavailable
            )
        }
    }

    func synchronize(anyAgentBusy: Bool) {
        schedule { state in
            guard !state.shutdown else { return false }
            guard state.busy != anyAgentBusy else { return false }
            state.busy = anyAgentBusy
            return true
        }
    }

    func suspend() {
        schedule { state in
            guard !state.shutdown, !state.suspended else { return false }
            state.suspended = true
            return true
        }
    }

    func resume(anyAgentBusy: Bool) {
        schedule { state in
            guard !state.shutdown else { return false }
            guard state.suspended || state.busy != anyAgentBusy else { return false }
            state.suspended = false
            state.busy = anyAgentBusy
            return true
        }
    }

    func shutdown() {
        schedule { state in
            guard !state.shutdown else { return false }
            state.shutdown = true
            state.busy = false
            return true
        }
    }

    func waitUntilSettled() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = withState { state in
                guard state.workerRunning else { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    private func schedule(_ update: (inout State) -> Bool) {
        let shouldStartWorker = withState { state in
            guard update(&state), enabled, !state.workerRunning else { return false }
            state.workerRunning = true
            return true
        }
        guard shouldStartWorker else { return }
        Task { [self] in
            await drain()
        }
    }

    private func drain() async {
        while true {
            let action = withState { state -> Action in
                let shouldInhibit = state.busy
                    && !state.suspended
                    && !state.shutdown
                    && !state.platformUnavailable
                if shouldInhibit, state.lease == nil {
                    return .acquire
                }
                if !shouldInhibit, let lease = state.lease {
                    state.lease = nil
                    return .release(lease)
                }
                state.workerRunning = false
                let waiters = state.waiters
                state.waiters.removeAll()
                return .finished(waiters)
            }

            switch action {
            case .acquire:
                do {
                    let lease = try await adapter.acquire(
                        kind: .preventSystemSleep,
                        reason: "open-grok: agent turn in progress"
                    )
                    withState { state in
                        state.lease = lease
                    }
                } catch {
                    let shouldReport = withState { state in
                        guard !state.platformUnavailable else { return false }
                        state.platformUnavailable = true
                        return true
                    }
                    if shouldReport {
                        failureReporter(String(describing: error))
                    }
                }
            case .release(let lease):
                await lease.release()
            case .finished(let waiters):
                for waiter in waiters {
                    waiter.resume()
                }
                return
            }
        }
    }

    private func withState<Value>(_ operation: (inout State) -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation(&state)
    }
}
