// OpenGrokSystemPower.swift
//
// Cross-platform power surface:
//   1. Sleep/wake notifications (`xai-system-power` parity) for OIDC token-
//      refresh sleep gating.
//   2. Power-inhibition leases (IOPM assertions / systemd-inhibit /
//      SetThreadExecutionState) required by long-running agent turns.
//
// Platform seams:
//   - macOS: IOKit system-power notifications + IOPMAssertionCreateWithName
//   - Linux: logind PrepareForSleep (best-effort busctl) + systemd-inhibit
//   - Windows: PowerRegisterSuspendResumeNotification + SetThreadExecutionState

import Foundation

#if canImport(Darwin)
import Darwin
#endif

#if os(macOS)
import IOKit
import IOKit.pwr_mgt
import CoreFoundation
#endif

// MARK: - Errors

/// Power-inhibition errors.
public enum PowerError: Error, Equatable, Sendable {
    case acquireFailed(String)
    case unsupported(String)
    case released
}

// MARK: - Sleep / wake events (xai-system-power)

/// A system power transition.
public enum PowerEvent: Sendable, Equatable {
    /// The system is about to sleep (or, on macOS, is negotiating idle sleep).
    /// Handlers may block briefly to hold off suspend.
    case willSleep
    /// The system resumed, or a previously announced sleep was cancelled.
    case didWake
}

/// Coarse, synchronously-queryable system power state.
public enum PowerState: Sendable, Equatable {
    /// Full / user wake: display capability present.
    case fullWake
    /// Dark wake: CPU up for maintenance, display off.
    case darkWake
    /// State could not be determined.
    case unknown
}

/// Boxed user callback invoked on each `PowerEvent`.
public typealias PowerCallback = @Sendable (PowerEvent) -> Void

/// Query the current system power state synchronously.
///
/// Cheap, non-blocking. Returns `.unknown` on platforms without a real
/// implementation or when the platform query fails.
public func currentPowerState() -> PowerState {
    #if os(macOS)
    return MacOSPower.currentState()
    #elseif os(Linux)
    return LinuxPower.currentState()
    #elseif os(Windows)
    return WindowsPower.currentState()
    #else
    return .unknown
    #endif
}

/// A running system-power listener. Dropping it stops the listener (macOS /
/// Windows). On Linux the worker may outlive the handle (logind signal park).
public final class SystemPowerListener: @unchecked Sendable {
    private var stop: (() -> Void)?

    /// Internal constructible handle; prefer `start(_:)`.
    init(stop: @escaping () -> Void) {
        self.stop = stop
    }

    deinit {
        stop?()
        stop = nil
    }

    /// Explicitly stop the listener (idempotent).
    public func invalidate() {
        stop?()
        stop = nil
    }

    /// Start listening for system sleep/wake events.
    ///
    /// Returns `nil` when the platform mechanism is unavailable. Callers should
    /// treat `nil` as "no power notifications" and degrade gracefully.
    public static func start(_ callback: @escaping PowerCallback) -> SystemPowerListener? {
        #if os(macOS)
        return MacOSPower.startListener(callback)
        #elseif os(Linux)
        return LinuxPower.startListener(callback)
        #elseif os(Windows)
        return WindowsPower.startListener(callback)
        #else
        _ = callback
        return nil
        #endif
    }
}

// MARK: - Power inhibition leases

/// The kind of power inhibition a lease requests.
public enum PowerLeaseKind: Sendable, Equatable, Codable {
    case preventSystemSleep
    case preventDisplaySleep
}

/// A power-inhibition lease. Releasing (or deinitializing) restores the prior
/// system power policy.
public protocol PowerLease: AnyObject, Sendable {
    var kind: PowerLeaseKind { get }
    var reason: String { get }
    func release() async
}

/// Power-inhibition adapter.
public protocol PowerAdapter: Sendable {
    func acquire(kind: PowerLeaseKind, reason: String) async throws -> any PowerLease
}

// MARK: - macOS

#if os(macOS)

private final class IOPMPowerLease: PowerLease, @unchecked Sendable {
    let kind: PowerLeaseKind
    let reason: String
    private var assertionID: IOPMAssertionID
    private let lock = NSLock()
    private var released = false

    init(kind: PowerLeaseKind, reason: String, assertionID: IOPMAssertionID) {
        self.kind = kind
        self.reason = reason
        self.assertionID = assertionID
    }

    deinit {
        releaseNow()
    }

    func release() async {
        releaseNow()
    }

    nonisolated private func releaseNow() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        IOPMAssertionRelease(assertionID)
    }
}

/// macOS IOPM assertion adapter.
public struct MacOSPowerAdapter: PowerAdapter, Sendable {
    public init() {}

    public func acquire(kind: PowerLeaseKind, reason: String) async throws -> any PowerLease {
        let type: CFString
        switch kind {
        case .preventSystemSleep:
            type = kIOPMAssertionTypeNoIdleSleep as CFString
        case .preventDisplaySleep:
            type = kIOPMAssertionTypeNoDisplaySleep as CFString
        }
        var assertionID = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        guard status == kIOReturnSuccess else {
            throw PowerError.acquireFailed("IOPMAssertionCreateWithName failed: \(status)")
        }
        return IOPMPowerLease(kind: kind, reason: reason, assertionID: assertionID)
    }
}

public typealias PlatformPowerAdapter = MacOSPowerAdapter

/// macOS sleep/wake + dark-wake helpers (public for unit tests / pure mapping).
public enum MacOSPower {
    // IOPM capability bits (SPI; see xai-system-power macos.rs).
    private static let capabilityCPU: UInt32 = 0x1
    private static let capabilityVideo: UInt32 = 0x2

    /// Classify raw IOPM capability bits (pure, unit-testable).
    public static func classifyCapabilities(_ caps: UInt32) -> PowerState {
        if caps & capabilityCPU == 0 {
            return .unknown
        }
        if caps & capabilityVideo != 0 {
            return .fullWake
        }
        return .darkWake
    }

    static func currentState() -> PowerState {
        typealias Fn = @convention(c) () -> UInt32
        guard let handle = dlopen(
            "/System/Library/Frameworks/IOKit.framework/IOKit",
            RTLD_LAZY
        ) else {
            return .unknown
        }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "IOPMConnectionGetSystemCapabilities") else {
            return .unknown
        }
        let fn = unsafeBitCast(sym, to: Fn.self)
        return classifyCapabilities(fn())
    }

    // IOKit message types
    private static let canSystemSleep: UInt32 = 0xe000_0270
    private static let systemWillSleep: UInt32 = 0xe000_0280
    private static let systemWillNotSleep: UInt32 = 0xe000_0290
    private static let systemHasPoweredOn: UInt32 = 0xe000_0300

    /// Map IOKit power message → (event?, needsAck).
    public static func mapPowerMessage(_ messageType: UInt32) -> (PowerEvent?, Bool) {
        switch messageType {
        case canSystemSleep: return (.willSleep, true)
        case systemWillSleep: return (.willSleep, true)
        case systemWillNotSleep: return (.didWake, false)
        case systemHasPoweredOn: return (.didWake, false)
        default: return (nil, false)
        }
    }

    /// Register for system power via IORegisterForSystemPower on a dedicated
    /// CFRunLoop thread. Returns nil if registration fails.
    static func startListener(_ callback: @escaping PowerCallback) -> SystemPowerListener? {
        MacOSPowerListenerHandle.start(callback)
    }
}

// MARK: macOS IOKit listener

/// Context pointed to by the IOKit refcon. Touched only on the run-loop thread
/// after registration completes.
private final class MacOSPowerContext: @unchecked Sendable {
    let callback: PowerCallback
    var rootPort: io_connect_t = 0
    let stopLock = NSLock()
    var stopRequested = false

    init(callback: @escaping PowerCallback) {
        self.callback = callback
    }

    func requestStop() {
        stopLock.lock()
        stopRequested = true
        stopLock.unlock()
    }

    var shouldStop: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopRequested
    }
}

/// Global storage so the C-compatible IOKit callback can recover the context.
/// Only one process-lifetime listener is expected (matches Rust usage).
/// Access is guarded by `lock` (IOKit callback / start / stop paths).
private enum MacOSPowerListenerGlobals {
    static let lock = NSLock()
    nonisolated(unsafe) static var activeContext: MacOSPowerContext?
}

private let macOSPowerInterestCallback: IOServiceInterestCallback = {
    refcon, service, messageType, messageArgument in
    _ = service
    guard let refcon else { return }
    let context = Unmanaged<MacOSPowerContext>.fromOpaque(refcon).takeUnretainedValue()
    let (event, needsAck) = MacOSPower.mapPowerMessage(UInt32(messageType))
    if let event {
        // Ack only after the callback returns so a bounded WillSleep handler
        // can hold off suspend (Rust / xai-system-power parity).
        context.callback(event)
    }
    if needsAck {
        IOAllowPowerChange(context.rootPort, Int(bitPattern: messageArgument))
    }
}

private enum MacOSPowerListenerHandle {
    static func start(_ callback: @escaping PowerCallback) -> SystemPowerListener? {
        let started = DispatchSemaphore(value: 0)
        // Box mutable registration state for the worker thread.
        final class StartState: @unchecked Sendable {
            var ok = false
            var runLoop: CFRunLoop?
            var context: MacOSPowerContext?
            let lock = NSLock()
        }
        let state = StartState()

        let thread = Thread {
            var notifier: io_object_t = 0
            var notifyPortRef: IONotificationPortRef?
            let ctx = MacOSPowerContext(callback: callback)
            let ctxPtr = Unmanaged.passRetained(ctx)

            MacOSPowerListenerGlobals.lock.lock()
            MacOSPowerListenerGlobals.activeContext = ctx
            MacOSPowerListenerGlobals.lock.unlock()

            let rootPort = IORegisterForSystemPower(
                ctxPtr.toOpaque(),
                &notifyPortRef,
                macOSPowerInterestCallback,
                &notifier
            )

            if rootPort == 0 || notifyPortRef == nil {
                MacOSPowerListenerGlobals.lock.lock()
                MacOSPowerListenerGlobals.activeContext = nil
                MacOSPowerListenerGlobals.lock.unlock()
                ctxPtr.release()
                state.lock.lock()
                state.ok = false
                state.lock.unlock()
                started.signal()
                return
            }
            ctx.rootPort = rootPort

            guard let rl = CFRunLoopGetCurrent() else {
                var notifierMut = notifier
                IODeregisterForSystemPower(&notifierMut)
                if let port = notifyPortRef {
                    IONotificationPortDestroy(port)
                }
                IOServiceClose(rootPort)
                MacOSPowerListenerGlobals.lock.lock()
                MacOSPowerListenerGlobals.activeContext = nil
                MacOSPowerListenerGlobals.lock.unlock()
                ctxPtr.release()
                state.lock.lock()
                state.ok = false
                state.lock.unlock()
                started.signal()
                return
            }

            if let port = notifyPortRef,
               let unmanaged = IONotificationPortGetRunLoopSource(port)
            {
                CFRunLoopAddSource(rl, unmanaged.takeUnretainedValue(), CFRunLoopMode.commonModes)
            }

            state.lock.lock()
            state.ok = true
            state.runLoop = rl
            state.context = ctx
            state.lock.unlock()
            started.signal()

            while !ctx.shouldStop {
                _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 5.0, false)
            }

            var notifierMut = notifier
            IODeregisterForSystemPower(&notifierMut)
            if let port = notifyPortRef {
                IONotificationPortDestroy(port)
            }
            IOServiceClose(rootPort)
            MacOSPowerListenerGlobals.lock.lock()
            MacOSPowerListenerGlobals.activeContext = nil
            MacOSPowerListenerGlobals.lock.unlock()
            ctxPtr.release()
        }
        thread.name = "opengrok-power-listener"
        thread.qualityOfService = QualityOfService.utility
        thread.start()

        started.wait()
        state.lock.lock()
        let ok = state.ok
        let rl = state.runLoop
        let ctx = state.context
        state.lock.unlock()

        guard ok, let rl, let ctx else {
            return nil
        }

        return SystemPowerListener {
            ctx.requestStop()
            CFRunLoopStop(rl)
        }
    }
}

#elseif os(Linux)

// MARK: - Linux

/// Linux power-inhibition via `systemd-inhibit` subprocess when available.
private final class SystemdInhibitLease: PowerLease, @unchecked Sendable {
    let kind: PowerLeaseKind
    let reason: String
    private var process: Process?
    private let lock = NSLock()
    private var released = false

    init(kind: PowerLeaseKind, reason: String, process: Process) {
        self.kind = kind
        self.reason = reason
        self.process = process
    }

    deinit {
        releaseNow()
    }

    func release() async {
        releaseNow()
    }

    nonisolated private func releaseNow() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        process?.terminate()
        process = nil
    }
}

public struct LinuxPowerAdapter: PowerAdapter, Sendable {
    public init() {}

    public func acquire(kind: PowerLeaseKind, reason: String) async throws -> any PowerLease {
        let what: String
        switch kind {
        case .preventSystemSleep: what = "sleep"
        case .preventDisplaySleep: what = "idle"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/systemd-inhibit")
        process.arguments = [
            "--what=\(what)",
            "--who=open-grok",
            "--why=\(reason)",
            "--mode=block",
            "sleep",
            "infinity",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw PowerError.acquireFailed("systemd-inhibit unavailable: \(error)")
        }
        return SystemdInhibitLease(kind: kind, reason: reason, process: process)
    }
}

public typealias PlatformPowerAdapter = LinuxPowerAdapter

/// Linux logind PrepareForSleep listener (best-effort via busctl monitor).
public enum LinuxPower {
    static func currentState() -> PowerState {
        // No dark-wake equivalent; fall back to the listener path.
        .unknown
    }

    /// Start a logind PrepareForSleep watcher. Returns nil when the system bus
    /// / logind / busctl is unavailable (containers, non-systemd hosts).
    static func startListener(_ callback: @escaping PowerCallback) -> SystemPowerListener? {
        // Probe: does busctl exist and can we talk to logind?
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/busctl")
        probe.arguments = [
            "--system", "call",
            "org.freedesktop.login1",
            "/org/freedesktop/login1",
            "org.freedesktop.DBus.Peer",
            "Ping",
        ]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
            probe.waitUntilExit()
        } catch {
            return nil
        }
        if probe.terminationStatus != 0 {
            return nil
        }

        // Long-lived monitor process. Dropping the handle terminates it.
        // Message parsing is best-effort: look for PrepareForSleep boolean.
        let monitor = Process()
        monitor.executableURL = URL(fileURLWithPath: "/usr/bin/busctl")
        monitor.arguments = [
            "--system", "--match",
            "type='signal',sender='org.freedesktop.login1',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'",
            "monitor",
        ]
        let pipe = Pipe()
        monitor.standardOutput = pipe
        monitor.standardError = FileHandle.nullDevice

        do {
            try monitor.run()
        } catch {
            return nil
        }

        let queue = DispatchQueue(label: "opengrok.linux.power")
        let handle = pipe.fileHandleForReading
        queue.async {
            var buffer = Data()
            while monitor.isRunning {
                let chunk = handle.availableData
                if chunk.isEmpty {
                    // EOF or no data — brief pause.
                    Thread.sleep(forTimeInterval: 0.1)
                    if !monitor.isRunning { break }
                    continue
                }
                buffer.append(chunk)
                // Scan complete lines.
                while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = buffer[..<nl]
                    buffer = Data(buffer[buffer.index(after: nl)...])
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    // busctl monitor lines include the member and body; look for true/false.
                    if line.contains("PrepareForSleep") {
                        if line.contains("true") || line.contains(" boolean true") {
                            callback(.willSleep)
                        } else if line.contains("false") || line.contains(" boolean false") {
                            callback(.didWake)
                        }
                    }
                }
            }
        }

        return SystemPowerListener {
            if monitor.isRunning {
                monitor.terminate()
            }
        }
    }
}

#elseif os(Windows)

// MARK: - Windows

#if canImport(WinSDK)
import WinSDK
#endif

/// Windows SetThreadExecutionState lease.
private final class WindowsExecutionStateLease: PowerLease, @unchecked Sendable {
    let kind: PowerLeaseKind
    let reason: String
    private let lock = NSLock()
    private var released = false

    init(kind: PowerLeaseKind, reason: String) {
        self.kind = kind
        self.reason = reason
    }

    deinit { releaseNow() }
    func release() async { releaseNow() }

    private func releaseNow() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        WindowsPower.clearExecutionState()
    }
}

public struct WindowsPowerAdapter: PowerAdapter, Sendable {
    public init() {}

    public func acquire(kind: PowerLeaseKind, reason: String) async throws -> any PowerLease {
        guard WindowsPower.setExecutionState(kind: kind) else {
            throw PowerError.acquireFailed(
                "SetThreadExecutionState is unavailable (kind=\(kind), reason=\(reason))."
            )
        }
        return WindowsExecutionStateLease(kind: kind, reason: reason)
    }
}

public typealias PlatformPowerAdapter = WindowsPowerAdapter

/// Context for PowerRegisterSuspendResumeNotification.
private final class WindowsPowerContext: @unchecked Sendable {
    let callback: PowerCallback
    init(callback: @escaping PowerCallback) { self.callback = callback }
}

/// Windows suspend/resume + execution-state helpers.
public enum WindowsPower {
    // ES flags (winbase.h)
    private static let esSystemRequired: UInt32 = 0x0000_0001
    private static let esDisplayRequired: UInt32 = 0x0000_0002
    private static let esContinuous: UInt32 = 0x8000_0000

    // Power broadcast types
    private static let pbtAPMSuspend: UInt32 = 0x0004
    private static let pbtAPMResumeSuspend: UInt32 = 0x0007
    private static let pbtAPMResumeAutomatic: UInt32 = 0x0012

    static func currentState() -> PowerState { .unknown }

    static func setExecutionState(kind: PowerLeaseKind) -> Bool {
        #if canImport(WinSDK)
        var flags = esContinuous
        switch kind {
        case .preventSystemSleep: flags |= esSystemRequired
        case .preventDisplaySleep: flags |= esSystemRequired | esDisplayRequired
        }
        let prev = SetThreadExecutionState(EXECUTION_STATE(flags))
        return prev != 0
        #else
        _ = kind
        return false
        #endif
    }

    static func clearExecutionState() {
        #if canImport(WinSDK)
        _ = SetThreadExecutionState(EXECUTION_STATE(esContinuous))
        #endif
    }

    static func startListener(_ callback: @escaping PowerCallback) -> SystemPowerListener? {
        #if canImport(WinSDK)
        let ctx = WindowsPowerContext(callback: callback)
        let ctxPtr = Unmanaged.passRetained(ctx)
        var params = DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS(
            Callback: { context, eventType, _ in
                guard let context else { return 0 }
                let c = Unmanaged<WindowsPowerContext>.fromOpaque(context).takeUnretainedValue()
                switch eventType {
                case WindowsPower.pbtAPMSuspend:
                    c.callback(.willSleep)
                case WindowsPower.pbtAPMResumeSuspend, WindowsPower.pbtAPMResumeAutomatic:
                    c.callback(.didWake)
                default:
                    break
                }
                return 0
            },
            Context: ctxPtr.toOpaque()
        )
        var handle: HPOWERNOTIFY?
        let status = PowerRegisterSuspendResumeNotification(
            DWORD(DEVICE_NOTIFY_CALLBACK),
            &params,
            &handle
        )
        guard status == 0, let handle else {
            ctxPtr.release()
            return nil
        }
        return SystemPowerListener {
            PowerUnregisterSuspendResumeNotification(handle)
            ctxPtr.release()
        }
        #else
        _ = callback
        return nil
        #endif
    }
}

#else

/// Fallback adapter that reports unsupported.
public struct UnsupportedPowerAdapter: PowerAdapter, Sendable {
    public init() {}
    public func acquire(kind: PowerLeaseKind, reason: String) async throws -> any PowerLease {
        throw PowerError.unsupported(
            "Power inhibition is not available on this platform (kind=\(kind), reason=\(reason))."
        )
    }
}

public typealias PlatformPowerAdapter = UnsupportedPowerAdapter

#endif

// MARK: - Bootstrap

/// Bootstrap adapter retained for call sites that previously expected
/// fail-closed behavior. Now delegates to the platform adapter.
public struct BootstrapPowerAdapter: PowerAdapter {
    private let inner = PlatformPowerAdapter()
    public init() {}
    public func acquire(kind: PowerLeaseKind, reason: String) async throws -> any PowerLease {
        try await inner.acquire(kind: kind, reason: reason)
    }
}
