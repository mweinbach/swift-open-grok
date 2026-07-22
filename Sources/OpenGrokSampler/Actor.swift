// Actor.swift
//
// Sampler actor: owns global state, spawns per-request tasks.
// Mirrors Rust `actor/mod.rs` + `actor/state.rs`.

import Foundation
import OpenGrokHTTP
import OpenGrokSamplingTypes

/// Spawn result for the sampler actor.
public struct SamplerSpawn: Sendable {
    public let handle: SamplerHandle
    public let events: AsyncStream<SamplingEvent>
}

/// Sampler actor facade. Construct via ``SamplerActor/spawn``.
public enum SamplerActor {
    /// Spawn the actor and return a handle plus the shared event stream.
    public static func spawn(
        config: SamplerConfig,
        retryPolicy: RetryPolicy = .default,
        transport: any HTTPTransport = URLSessionHTTPTransport()
    ) -> SamplerSpawn {
        let commandBox = CommandBox.make()
        let codexTurnState = CodexTurnState()
        let (eventStream, eventContinuation) = AsyncStream<SamplingEvent>.makeStream()

        let handle = SamplerHandle(commandBox: commandBox, codexTurnState: codexTurnState)
        let state = ActorStateBox(config: config, retryPolicy: retryPolicy)

        Task {
            var tasks: [RequestId: Task<Void, Never>] = [:]

            while let cmd = await commandBox.next() {
                switch cmd {
                case .submit(let requestId, let request, let configOverride, let turnState, let completion):
                    let cancelToken = CancellationToken()
                    if let prev = state.register(requestId: requestId, token: cancelToken) {
                        prev.cancel()
                        tasks[requestId]?.cancel()
                    }
                    let effectiveConfig = configOverride ?? state.config
                    let retryPolicy = state.retryPolicy
                    let eventCont = eventContinuation
                    let transport = transport

                    let task = Task {
                        await runRequestTask(
                            requestId: requestId,
                            request: request,
                            config: effectiveConfig,
                            retryPolicy: retryPolicy,
                            transport: transport,
                            eventContinuation: eventCont,
                            cancelToken: cancelToken,
                            completion: completion,
                            codexTurnState: turnState
                        )
                        state.remove(requestId: requestId)
                    }
                    tasks[requestId] = task

                case .cancel(let requestId):
                    if state.cancel(requestId: requestId) {
                        tasks[requestId]?.cancel()
                        tasks[requestId] = nil
                    }

                case .updateConfig(let config):
                    state.updateConfig(config)

                case .isActive(let requestId, let reply):
                    reply.complete(state.isActive(requestId: requestId))

                case .activeCount(let reply):
                    reply.complete(state.activeCount)

                case .shutdown:
                    for (_, token) in state.drain() {
                        token.cancel()
                    }
                    for (_, t) in tasks {
                        t.cancel()
                    }
                    commandBox.close()
                    eventContinuation.finish()
                    return
                }
            }

            for (_, token) in state.drain() {
                token.cancel()
            }
            for (_, t) in tasks {
                t.cancel()
            }
            eventContinuation.finish()
        }

        return SamplerSpawn(handle: handle, events: eventStream)
    }
}

// MARK: - Actor state (thread-safe)

final class ActorStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var activeRequests: [RequestId: CancellationToken] = [:]
    private var _config: SamplerConfig
    private var _retryPolicy: RetryPolicy

    init(config: SamplerConfig, retryPolicy: RetryPolicy) {
        self._config = config
        self._retryPolicy = retryPolicy
    }

    var config: SamplerConfig {
        lock.lock(); defer { lock.unlock() }
        return _config
    }

    var retryPolicy: RetryPolicy {
        lock.lock(); defer { lock.unlock() }
        return _retryPolicy
    }

    func register(requestId: RequestId, token: CancellationToken) -> CancellationToken? {
        lock.lock(); defer { lock.unlock() }
        let prev = activeRequests[requestId]
        activeRequests[requestId] = token
        return prev
    }

    func remove(requestId: RequestId) {
        lock.lock(); defer { lock.unlock() }
        activeRequests.removeValue(forKey: requestId)
    }

    func cancel(requestId: RequestId) -> Bool {
        lock.lock()
        let token = activeRequests.removeValue(forKey: requestId)
        lock.unlock()
        if let token {
            token.cancel()
            return true
        }
        return false
    }

    func updateConfig(_ config: SamplerConfig) {
        lock.lock(); defer { lock.unlock() }
        _config = config
    }

    func isActive(requestId: RequestId) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return activeRequests[requestId] != nil
    }

    var activeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return activeRequests.count
    }

    func drain() -> [RequestId: CancellationToken] {
        lock.lock(); defer { lock.unlock() }
        let out = activeRequests
        activeRequests = [:]
        return out
    }
}
