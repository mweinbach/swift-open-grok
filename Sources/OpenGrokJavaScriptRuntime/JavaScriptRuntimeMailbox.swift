// JavaScriptRuntimeMailbox.swift
//
// Blocking FIFO used between the async cell actor and the synchronous
// runtime thread. Stands in for Rust's `std::sync::mpsc` channels in
// `crates/codegen/xai-grok-code-mode/src/runtime/mod.rs`, including the
// `try_recv` / `recv` split that `next_runtime_command` (mod.rs:280)
// depends on and the "sender dropped ⇒ recv returns None" close semantics
// that ends the runtime loop.

import Foundation

final class JavaScriptRuntimeMailbox<Message: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var messages: [Message] = []
    private var closed = false

    /// Enqueue a message. Ignored once the mailbox is closed (matches a
    /// send on a channel whose receiver has gone away).
    func send(_ message: Message) {
        condition.lock()
        defer { condition.unlock() }
        guard !closed else { return }
        messages.append(message)
        condition.signal()
    }

    /// Non-blocking take. Mirrors `Receiver::try_recv`.
    func tryTake() -> Message? {
        condition.lock()
        defer { condition.unlock() }
        guard !messages.isEmpty else { return nil }
        return messages.removeFirst()
    }

    /// Blocking take. Returns `nil` once the mailbox is closed and drained,
    /// mirroring `Receiver::recv` after every sender has dropped.
    func take() -> Message? {
        condition.lock()
        defer { condition.unlock() }
        while messages.isEmpty && !closed {
            condition.wait()
        }
        guard !messages.isEmpty else { return nil }
        return messages.removeFirst()
    }

    /// Wake every blocked receiver and refuse further sends. Queued
    /// messages stay drainable so a `terminate` already in flight is still
    /// observed.
    func close() {
        condition.lock()
        defer { condition.unlock() }
        closed = true
        condition.broadcast()
    }
}
