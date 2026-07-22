// Handle.swift
//
// Public handle for talking to the sampler actor.
// Mirrors Rust `handle.rs`.

import Foundation
import OpenGrokSamplingTypes

/// One-shot completion box for `submitAndCollect`.
final class CompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<(ConversationResponse, InferenceLatencyStats), SamplingError>, Never>?
    private var result: Result<(ConversationResponse, InferenceLatencyStats), SamplingError>?

    func setContinuation(_ cont: CheckedContinuation<Result<(ConversationResponse, InferenceLatencyStats), SamplingError>, Never>) {
        lock.lock()
        if let result {
            lock.unlock()
            cont.resume(returning: result)
        } else {
            continuation = cont
            lock.unlock()
        }
    }

    func complete(_ result: Result<(ConversationResponse, InferenceLatencyStats), SamplingError>) {
        lock.lock()
        if let cont = continuation {
            continuation = nil
            lock.unlock()
            cont.resume(returning: result)
        } else {
            self.result = result
            lock.unlock()
        }
    }
}

/// One-shot bool reply box.
final class BoolReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var value: Bool?

    func setContinuation(_ cont: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if let value {
            lock.unlock()
            cont.resume(returning: value)
        } else {
            continuation = cont
            lock.unlock()
        }
    }

    func complete(_ value: Bool) {
        lock.lock()
        if let cont = continuation {
            continuation = nil
            lock.unlock()
            cont.resume(returning: value)
        } else {
            self.value = value
            lock.unlock()
        }
    }
}

/// One-shot int reply box.
final class IntReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int, Never>?
    private var value: Int?

    func setContinuation(_ cont: CheckedContinuation<Int, Never>) {
        lock.lock()
        if let value {
            lock.unlock()
            cont.resume(returning: value)
        } else {
            continuation = cont
            lock.unlock()
        }
    }

    func complete(_ value: Int) {
        lock.lock()
        if let cont = continuation {
            continuation = nil
            lock.unlock()
            cont.resume(returning: value)
        } else {
            self.value = value
            lock.unlock()
        }
    }
}

/// Commands sent from a ``SamplerHandle`` to the actor task.
enum SamplerCommand: Sendable {
    case submit(
        requestId: RequestId,
        request: ConversationRequest,
        config: SamplerConfig?,
        codexTurnState: CodexTurnStateCell,
        completion: CompletionBox?
    )
    case cancel(requestId: RequestId)
    case updateConfig(SamplerConfig)
    case isActive(requestId: RequestId, reply: BoolReplyBox)
    case activeCount(reply: IntReplyBox)
    case shutdown
}

/// Cheaply-cloneable handle to the sampler actor.
public final class SamplerHandle: @unchecked Sendable {
    private let commandBox: CommandBox
    private let codexTurnState: CodexTurnState

    init(commandBox: CommandBox, codexTurnState: CodexTurnState) {
        self.commandBox = commandBox
        self.codexTurnState = codexTurnState
    }

    /// Create a no-op handle that discards all commands.
    public static func noop() -> SamplerHandle {
        SamplerHandle(commandBox: CommandBox.noop(), codexTurnState: CodexTurnState())
    }

    /// Start a new logical user turn for Codex sticky routing.
    public func beginCodexTurn() {
        codexTurnState.beginTurn()
    }

    /// Snapshot the current turn's sticky-routing cell.
    public func codexTurnStateSnapshot() -> CodexTurnStateCell {
        codexTurnState.snapshot()
    }

    /// Submit a sampling request. Results arrive via the shared event stream.
    public func submit(requestId: RequestId, request: ConversationRequest) {
        commandBox.send(.submit(
            requestId: requestId,
            request: request,
            config: nil,
            codexTurnState: codexTurnState.snapshot(),
            completion: nil
        ))
    }

    /// Submit with an explicit per-request config override.
    public func submitWithConfig(
        requestId: RequestId,
        request: ConversationRequest,
        config: SamplerConfig
    ) {
        commandBox.send(.submit(
            requestId: requestId,
            request: request,
            config: config,
            codexTurnState: codexTurnState.snapshot(),
            completion: nil
        ))
    }

    /// Cancel an in-flight request. No-op if unknown.
    public func cancel(requestId: RequestId) {
        commandBox.send(.cancel(requestId: requestId))
    }

    /// Update the default sampling config.
    public func updateConfig(_ config: SamplerConfig) {
        commandBox.send(.updateConfig(config))
    }

    /// Query whether a request is still in flight.
    public func isActive(requestId: RequestId) async -> Bool {
        let box = BoolReplyBox()
        return await withCheckedContinuation { cont in
            box.setContinuation(cont)
            commandBox.send(.isActive(requestId: requestId, reply: box))
        }
    }

    /// Query the number of in-flight requests.
    public func activeCount() async -> Int {
        let box = IntReplyBox()
        return await withCheckedContinuation { cont in
            box.setContinuation(cont)
            commandBox.send(.activeCount(reply: box))
        }
    }

    /// Submit a request and await its completion. Events still flow to the
    /// shared channel for live UI updates.
    public func submitAndCollect(
        requestId: RequestId,
        request: ConversationRequest
    ) async -> Result<(ConversationResponse, InferenceLatencyStats), SamplingError> {
        let box = CompletionBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                box.setContinuation(cont)
                commandBox.send(.submit(
                    requestId: requestId,
                    request: request,
                    config: nil,
                    codexTurnState: codexTurnState.snapshot(),
                    completion: box
                ))
            }
        } onCancel: {
            commandBox.send(.cancel(requestId: requestId))
        }
    }
}

// MARK: - Command mailbox

final class CommandBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [SamplerCommand] = []
    private var waiters: [CheckedContinuation<SamplerCommand?, Never>] = []
    private var closed = false
    private let isNoop: Bool

    private init(isNoop: Bool) {
        self.isNoop = isNoop
    }

    static func make() -> CommandBox { CommandBox(isNoop: false) }
    static func noop() -> CommandBox { CommandBox(isNoop: true) }

    func send(_ command: SamplerCommand) {
        if isNoop { return }
        let waiter: CheckedContinuation<SamplerCommand?, Never>? = {
            lock.lock()
            defer { lock.unlock() }
            if closed { return nil }
            if !waiters.isEmpty {
                return waiters.removeFirst()
            }
            buffer.append(command)
            return nil
        }()
        waiter?.resume(returning: command)
    }

    func next() async -> SamplerCommand? {
        if isNoop { return nil }
        return await withCheckedContinuation { cont in
            lock.lock()
            if !buffer.isEmpty {
                let cmd = buffer.removeFirst()
                lock.unlock()
                cont.resume(returning: cmd)
            } else if closed {
                lock.unlock()
                cont.resume(returning: nil)
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
    }

    func close() {
        let waiters: [CheckedContinuation<SamplerCommand?, Never>] = {
            lock.lock()
            defer { lock.unlock() }
            closed = true
            let w = self.waiters
            self.waiters = []
            return w
        }()
        for w in waiters {
            w.resume(returning: nil)
        }
    }
}
