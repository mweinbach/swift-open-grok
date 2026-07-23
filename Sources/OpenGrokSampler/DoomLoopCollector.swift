// DoomLoopCollector.swift
//
// Per-request transport for server-reported doom-loop signals.
// Mirrors Rust `doom_loop.rs`.

import Foundation
import os
import OpenGrokSamplingTypes

private let logger = os.Logger(subsystem: "OpenGrokSampler", category: "DoomLoopCollector")

/// Cheap-to-clone accumulator shared between the SSE decoder and the
/// stream transform of one request attempt.
public final class DoomLoopSignalCollector: @unchecked Sendable {
    private struct State {
        var signals: [DoomLoopSignal] = []
        var malformedLogged = false
        var policy = DoomLoopRecoveryPolicy()
        var abortDisarmed = false
    }

    private let lock = NSLock()
    private var state = State()

    public init() {}

    /// A fresh, armed collector judging confidence with `policy`.
    public convenience init(policy: DoomLoopRecoveryPolicy) {
        self.init()
        lock.lock()
        state.policy = policy
        lock.unlock()
    }

    /// Stop the mid-stream abort for this attempt; signals keep recording.
    public func disarmAbort() {
        lock.lock()
        state.abortDisarmed = true
        lock.unlock()
    }

    /// While armed: raw labels of confident signals, or `nil`.
    public func abortTriggers() -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        if state.abortDisarmed { return nil }
        let confident = state.policy.confidentTriggers(state.signals)
        return confident.isEmpty ? nil : confident
    }

    /// Inspect a raw SSE frame. Returns `true` when the frame is the
    /// non-standard check event and must be swallowed.
    @discardableResult
    public func absorb(eventName: String, data: String) -> Bool {
        let named = eventName == DOOM_LOOP_CHECK_EVENT_TYPE
        let (signals, swallow): ([DoomLoopSignal], Bool)
        switch peekDoomLoop(data) {
        case .checkEvent(let s):
            signals = s
            swallow = true
        case .responseField(let s):
            signals = s
            swallow = false
        case .none:
            if named { logMalformedOnce() }
            return named
        }
        if signals.isEmpty {
            logMalformedOnce()
        } else {
            record(signals)
        }
        return swallow || named
    }

    /// Drain the recorded signals.
    public func take() -> [DoomLoopSignal] {
        lock.lock()
        defer { lock.unlock() }
        let out = state.signals
        state.signals = []
        return out
    }

    private func record(_ signals: [DoomLoopSignal]) {
        lock.lock()
        defer { lock.unlock() }
        for signal in signals {
            if !state.signals.contains(where: { $0.raw == signal.raw }) {
                state.signals.append(signal)
            }
        }
    }

    private func logMalformedOnce() {
        lock.lock()
        defer { lock.unlock() }
        if !state.malformedLogged {
            state.malformedLogged = true
            logger.debug("doom-loop check payload malformed or empty; ignoring")
        }
    }
}
