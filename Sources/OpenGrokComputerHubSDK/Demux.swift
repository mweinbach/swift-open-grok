// Demux.swift
//
// Inbound frame demultiplexer. Ported from
// `xai-computer-hub-sdk/src/demux.rs`.
//
// Classification (non-blocking):
//   1. response (result/error) → response waiter by id
//   2. tool_call_progress → progress waiter by tool_call_id
//   3. session_id present → session inbox
//   4. method-only connection notification → broadcast
//   5. else → unrouted

import Foundation
import OpenGrokComputerHubCore
import OpenGrokShared
import OpenGrokToolProtocol

/// Frame routed to a session inbox.
public enum InboundFrame: Sendable, Equatable {
    case request(JSONValue)
    case notification(JSONValue)
}

/// Outcome of `Demux.route`.
public enum RouteOutcome: String, Sendable, Equatable {
    case response
    case session
    case progress
    case unknownSession
    case unknownProgress
    case notification
    case unrouted
    case inboxFull
    case sessionDropped
    case progressFull
    case progressDropped
}

/// Hermetic demux for tests and connection actors.
///
/// Waiters are fulfilled via registered closures; session inboxes and
/// progress channels are bounded FIFO queues so slow consumers never
/// block the router.
public final class Demux: @unchecked Sendable {
    public typealias ResponseWaiter = @Sendable (Result<JsonRpcResponse<JSONValue>, ClientError>) -> Void
    public typealias ProgressSink = @Sendable (ToolCallProgressFrame) -> Bool
    public typealias SessionSink = @Sendable (InboundFrame) -> Bool
    public typealias NotificationHandler = @Sendable (JSONValue) -> Void

    private let lock = NSLock()
    private var sessions: [SessionId: SessionSink] = [:]
    private var waiters: [String: ResponseWaiter] = [:]
    private var callSessions: [String: SessionId] = [:]
    private var progress: [ToolCallId: ProgressSink] = [:]
    private var notifications: [NotificationHandler] = []
    /// Progress buffers for simple test registration.
    private var progressBuffers: [ToolCallId: [ToolCallProgressFrame]] = [:]
    private var sessionBuffers: [SessionId: [InboundFrame]] = [:]
    private let sessionCapacity: Int
    private let progressCapacity: Int

    public init(sessionCapacity: Int = 64, progressCapacity: Int = 64) {
        self.sessionCapacity = max(1, sessionCapacity)
        self.progressCapacity = max(1, progressCapacity)
    }

    // MARK: - Registration

    public func registerSessionInbox(_ sessionId: SessionId) {
        lock.lock()
        defer { lock.unlock() }
        sessionBuffers[sessionId] = []
        sessions[sessionId] = { [weak self] frame in
            guard let self else { return false }
            return self.enqueueSession(sessionId, frame)
        }
    }

    public func unregisterSessionInbox(_ sessionId: SessionId) {
        lock.lock()
        defer { lock.unlock() }
        sessions[sessionId] = nil
        sessionBuffers[sessionId] = nil
    }

    public func drainSessionInbox(_ sessionId: SessionId) -> [InboundFrame] {
        lock.lock()
        defer { lock.unlock() }
        let frames = sessionBuffers[sessionId] ?? []
        sessionBuffers[sessionId] = []
        return frames
    }

    public func registerResponseWaiter(
        requestId: String,
        sessionId: SessionId? = nil,
        waiter: @escaping ResponseWaiter
    ) {
        lock.lock()
        defer { lock.unlock() }
        waiters[requestId] = waiter
        if let sessionId {
            callSessions[requestId] = sessionId
        }
    }

    public func takeResponseWaiter(requestId: String) -> ResponseWaiter? {
        lock.lock()
        defer { lock.unlock() }
        callSessions[requestId] = nil
        return waiters.removeValue(forKey: requestId)
    }

    public func registerProgressWaiter(toolCallId: ToolCallId) {
        lock.lock()
        defer { lock.unlock() }
        progressBuffers[toolCallId] = []
        progress[toolCallId] = { [weak self] frame in
            guard let self else { return false }
            return self.enqueueProgress(toolCallId, frame)
        }
    }

    public func unregisterProgressWaiter(toolCallId: ToolCallId) {
        lock.lock()
        defer { lock.unlock() }
        progress[toolCallId] = nil
        progressBuffers[toolCallId] = nil
    }

    public func drainProgress(toolCallId: ToolCallId) -> [ToolCallProgressFrame] {
        lock.lock()
        defer { lock.unlock() }
        let frames = progressBuffers[toolCallId] ?? []
        progressBuffers[toolCallId] = []
        return frames
    }

    public func onNotification(_ handler: @escaping NotificationHandler) {
        lock.lock()
        notifications.append(handler)
        lock.unlock()
    }

    /// Fail every in-flight tool.call waiter bound to `sessionId`.
    @discardableResult
    public func failCallsForSession(
        _ sessionId: SessionId,
        error: ClientError
    ) -> Int {
        lock.lock()
        let ids = callSessions.compactMap { key, sid -> String? in
            sid == sessionId ? key : nil
        }
        var handlers: [ResponseWaiter] = []
        for id in ids {
            callSessions[id] = nil
            if let w = waiters.removeValue(forKey: id) {
                handlers.append(w)
            }
        }
        lock.unlock()
        for h in handlers {
            h(.failure(error))
        }
        return handlers.count
    }

    /// Drain every parked waiter with `error` (reconnect path).
    public func drainWaiters(error: ClientError) {
        lock.lock()
        let handlers = Array(waiters.values)
        waiters.removeAll()
        callSessions.removeAll()
        lock.unlock()
        for h in handlers {
            h(.failure(error))
        }
    }

    /// Drop every parked progress waiter.
    public func drainProgressWaiters() {
        lock.lock()
        progress.removeAll()
        progressBuffers.removeAll()
        lock.unlock()
    }

    // MARK: - Routing

    /// Route a parsed inbound JSON frame. Never blocks.
    @discardableResult
    public func route(_ frame: JSONValue) -> RouteOutcome {
        guard case .object(let map) = frame else { return .unrouted }

        if map["result"] != nil || map["error"] != nil {
            return routeResponse(frame, map: map)
        }
        if case .string(let method) = map["method"],
           method == Method.toolCallProgress.wireString
        {
            return routeProgress(map: map)
        }
        if map["session_id"] != nil {
            return routeSession(frame, map: map)
        }
        if map["method"] != nil {
            lock.lock()
            let handlers = notifications
            lock.unlock()
            for h in handlers { h(frame) }
            return .notification
        }
        return .unrouted
    }

    // MARK: - Private

    private func routeResponse(_ frame: JSONValue, map: [String: JSONValue]) -> RouteOutcome {
        let requestId: String?
        switch map["id"] {
        case .string(let s): requestId = s
        case .number(let n):
            if let i = n.int64Value {
                requestId = String(i)
            } else {
                requestId = String(n.doubleValue)
            }
        default: requestId = nil
        }
        guard let requestId else { return .unrouted }
        guard let waiter = takeResponseWaiter(requestId: requestId) else {
            return .unrouted
        }
        do {
            let resp = try frame.decode(JsonRpcResponse<JSONValue>.self)
            waiter(.success(resp))
        } catch {
            waiter(.failure(.transport("\(error)")))
        }
        return .response
    }

    private func routeProgress(map: [String: JSONValue]) -> RouteOutcome {
        guard let params = map["params"],
              case .object(let pmap) = params,
              case .string(let callIdStr) = pmap["tool_call_id"],
              let toolCallId = try? ToolCallId(callIdStr)
        else {
            return .unrouted
        }
        lock.lock()
        let sink = progress[toolCallId]
        lock.unlock()
        guard let sink else { return .unknownProgress }
        let frame: ToolCallProgressFrame
        do {
            frame = try params.decode(ToolCallProgressFrame.self)
        } catch {
            return .unrouted
        }
        if sink(frame) {
            return .progress
        }
        // Buffer full or dropped.
        lock.lock()
        let stillRegistered = progress[toolCallId] != nil
        if !stillRegistered {
            lock.unlock()
            return .progressDropped
        }
        lock.unlock()
        return .progressFull
    }

    private func routeSession(_ frame: JSONValue, map: [String: JSONValue]) -> RouteOutcome {
        guard case .string(let sidStr) = map["session_id"],
              let sessionId = try? SessionId(sidStr)
        else {
            return .unrouted
        }
        lock.lock()
        let sink = sessions[sessionId]
        lock.unlock()
        guard let sink else { return .unknownSession }
        let kind: InboundFrame = map["id"] != nil
            ? .request(frame)
            : .notification(frame)
        if sink(kind) {
            return .session
        }
        lock.lock()
        let still = sessions[sessionId] != nil
        lock.unlock()
        return still ? .inboxFull : .sessionDropped
    }

    private func enqueueSession(_ sessionId: SessionId, _ frame: InboundFrame) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var buf = sessionBuffers[sessionId] else { return false }
        if buf.count >= sessionCapacity { return false }
        buf.append(frame)
        sessionBuffers[sessionId] = buf
        return true
    }

    private func enqueueProgress(_ toolCallId: ToolCallId, _ frame: ToolCallProgressFrame) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var buf = progressBuffers[toolCallId] else { return false }
        if buf.count >= progressCapacity { return false }
        buf.append(frame)
        progressBuffers[toolCallId] = buf
        return true
    }
}
