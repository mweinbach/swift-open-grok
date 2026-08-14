// DiagHandle.swift
//
// Cloneable/Sendable handle publishing hub lifecycle transitions to the server.
// Swift port of `xai-grok-diag-server`.

import Foundation

/// Truncate error detail to maximum bytes, respecting UTF-8 character boundaries.
public func truncateErrorDetail(_ detail: String, limit: Int = MAX_ERROR_DETAIL_BYTES) -> String {
    let utf8 = Array(detail.utf8)
    if utf8.count <= limit {
        return detail
    }
    var end = limit
    while end > 0 && (utf8[end] & 0xC0) == 0x80 {
        end -= 1
    }
    return String(decoding: utf8[0..<end], as: UTF8.self)
}

/// Current timestamp in milliseconds since UNIX epoch.
public func currentDiagTimeMs() -> UInt64 {
    let seconds = Date().timeIntervalSince1970
    if seconds > 0 {
        return UInt64(seconds * 1000)
    }
    return 0
}

/// Target OS name string matching Rust `std::env::consts::OS`.
public var currentPlatformOS: String {
    #if os(macOS)
    return "macos"
    #elseif os(Linux)
    return "linux"
    #elseif os(Windows)
    return "windows"
    #else
    return "unknown"
    #endif
}

/// Cloneable handle publishing hub lifecycle transitions to the server.
public final class DiagHandle: @unchecked Sendable {
    public let launchId: String?
    public let version: String

    private struct Inner {
        var state: DiagState
        var connectedAt: UInt64?
        var stateChangedAt: UInt64
        var shuttingDown: Bool
        var errorClass: ErrorClass?
        var errorDetail: String?
        var lastCloseCode: UInt16?
        var imageCapabilities: [String]
        var imageCapabilitiesDeclared: Bool

        var isFailed: Bool {
            state == .failed
        }
    }

    private let lock = NSLock()
    private var inner: Inner

    /// `launchId` is the caller-minted per-spawn nonce, echoed verbatim on
    /// `/ready` (`nil` for nonce-less local launches).
    public init(
        launchId: String? = nil,
        version: String = ProcessInfo.processInfo.environment["GROK_VERSION"] ?? "1.0.0"
    ) {
        self.launchId = launchId
        self.version = version
        self.inner = Inner(
            state: .starting,
            connectedAt: nil,
            stateChangedAt: currentDiagTimeMs(),
            shuttingDown: false,
            errorClass: nil,
            errorDetail: nil,
            lastCloseCode: nil,
            imageCapabilities: [],
            imageCapabilitiesDeclared: false
        )
    }

    /// Initial hello completed, or a reconnect's serve replay settled.
    /// No-op after `setShuttingDown()` or `setFailed(...)`, and
    /// while a terminal close code is latched: a stale reconnect settle must
    /// not clear `lastCloseCode` or republish connected. Terminal closes do
    /// not reconnect on this handle.
    public func setConnected() {
        lock.lock()
        defer { lock.unlock() }
        if inner.shuttingDown || inner.isFailed || inner.lastCloseCode != nil {
            return
        }
        inner.state = .connected
        let now = currentDiagTimeMs()
        if inner.connectedAt == nil {
            inner.connectedAt = now
        }
        inner.stateChangedAt = now
        inner.lastCloseCode = nil
    }

    /// Server socket dropped. No-op after `setFailed(...)`.
    /// Does not clear `lastCloseCode`: the SDK fires this after a terminal
    /// close, and the sandbox gate still needs the code.
    public func setDisconnected() {
        lock.lock()
        defer { lock.unlock() }
        if inner.isFailed {
            return
        }
        inner.state = .disconnected
        inner.stateChangedAt = currentDiagTimeMs()
    }

    /// Hub sent a terminal close (4100–4199). Latches disconnected and records
    /// the code on `/ready`. `setDisconnected()` must not clear it —
    /// the SDK also fires `on_disconnect` after this callback.
    public func setTerminalClose(_ code: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        if inner.isFailed {
            return
        }
        inner.state = .disconnected
        inner.lastCloseCode = code
        inner.stateChangedAt = currentDiagTimeMs()
    }

    /// Latch disconnected for process shutdown; later `setConnected` no-ops.
    /// No-op after `setFailed(...)`. Leaves `lastCloseCode` so a drain
    /// after hub CLEANUP still reports 4103 to the reconnect gate.
    public func setShuttingDown() {
        lock.lock()
        defer { lock.unlock() }
        if inner.isFailed {
            return
        }
        inner.shuttingDown = true
        inner.state = .disconnected
        inner.stateChangedAt = currentDiagTimeMs()
    }

    /// Terminal connect failure on `/ready`. Sticky; callers dwell before exit.
    /// Clears `lastCloseCode`: failed is its own class, not a hub close.
    public func setFailed(errorClass: ErrorClass, errorDetail: String) {
        lock.lock()
        defer { lock.unlock() }
        inner.state = .failed
        inner.errorClass = errorClass
        inner.errorDetail = truncateErrorDetail(errorDetail)
        inner.lastCloseCode = nil
        inner.stateChangedAt = currentDiagTimeMs()
    }

    /// Publish the owner's advisory image capability snapshot on `/statusz`.
    /// `declared = false` is UNKNOWN, not "declares nothing". Publish before
    /// the socket binds so `/statusz` never serves the unpublished default;
    /// taking the snapshot before any guest can write the declaration
    /// directory is the caller's responsibility.
    public func setImageCapabilities(_ tokens: [String], declared: Bool) {
        lock.lock()
        defer { lock.unlock() }
        inner.imageCapabilities = tokens
        inner.imageCapabilitiesDeclared = declared
    }

    public func readyBody() -> ReadyBody {
        lock.lock()
        defer { lock.unlock() }
        return readyBodyLocked(inner: inner)
    }

    private func readyBodyLocked(inner: Inner) -> ReadyBody {
        let failed = inner.isFailed
        return ReadyBody(
            launchId: launchId,
            state: inner.state,
            pid: UInt32(ProcessInfo.processInfo.processIdentifier),
            connectedAt: inner.connectedAt,
            stateChangedAt: inner.stateChangedAt,
            version: version,
            errorClass: failed ? inner.errorClass : nil,
            errorDetail: failed ? inner.errorDetail : nil,
            lastCloseCode: (inner.state == .disconnected) ? inner.lastCloseCode : nil
        )
    }

    public func statuszBody() -> StatuszBody {
        lock.lock()
        defer { lock.unlock() }
        return StatuszBody(
            ready: readyBodyLocked(inner: inner),
            os: currentPlatformOS,
            imageCapabilities: inner.imageCapabilities,
            imageCapabilitiesDeclared: inner.imageCapabilitiesDeclared
        )
    }
}
