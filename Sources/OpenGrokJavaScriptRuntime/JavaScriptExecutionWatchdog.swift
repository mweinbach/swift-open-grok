// JavaScriptExecutionWatchdog.swift
//
// Bounds how long one JavaScript entry may occupy the runtime thread, and
// makes a CPU-bound cell terminable. Stands in for
// `v8::IsolateHandle::terminate_execution()`, which the Rust cell actor
// calls from `begin_termination`
// (crates/codegen/xai-grok-code-mode/src/cell_actor/mod.rs:592) so a cell
// running `while (true) {}` stops instead of pinning a thread forever. The
// Rust runtime test `terminate_execution_stops_cpu_bound_module`
// (runtime/mod.rs:397) pins that behavior.
//
// Mechanism
// ---------
// JavaScriptCore's public Swift/ObjC surface has no termination entry
// point. Its C API has `JSContextGroupSetExecutionTimeLimit`, which arms a
// watchdog that calls back on the executing thread once the limit elapses
// and terminates execution when the callback returns true. The two
// functions live in `JSContextRefPrivate.h`, which Apple ships in the
// binary but not in the SDK headers, so they are resolved with `dlsym` and
// the facility degrades cleanly when absent.
//
// Measured behavior of that API on current macOS, which shapes the design:
//
//   * The watchdog fires **at most once per VM entry**. Returning false
//     from the callback does not re-arm it, and neither does calling
//     `JSContextGroupSetExecutionTimeLimit` again — from the callback or
//     from another thread — while the entry is still running.
//   * Re-arming *between* entries works, and the context stays usable
//     after an entry has been terminated.
//
// So this is a per-entry ceiling rather than an interrupt: the runtime
// re-arms before every entry, and an entry that exceeds the ceiling is
// terminated. A `terminate` request lands immediately at any host boundary
// (every `await`, tool result, and timer callback ends an entry); a cell
// spinning inside a single entry stops when its ceiling elapses. That is
// the divergence from V8, where `terminate_execution` interrupts
// immediately — recorded in the slice's integration notes.

import Foundation

/// Default ceiling on one uninterrupted JavaScript entry. Code Mode cells
/// are orchestration glue that returns to the host on every `await`, so
/// five seconds of solid computation without touching the host is already
/// pathological — and this is the worst-case latency for terminating such
/// a cell.
public let CODE_MODE_DEFAULT_EXECUTION_CEILING_MS: UInt64 = 5_000

/// Error text for an entry stopped by the ceiling rather than by an
/// explicit terminate.
public let CODE_MODE_EXECUTION_CEILING_ERROR =
    "exec cell exceeded its continuous JavaScript execution budget"

#if canImport(JavaScriptCore)
import JavaScriptCore

/// Shared state between the runtime thread and the C callback.
private final class WatchdogBox {
    private let lock = NSLock()
    private var terminationRequested = false
    private var didFire = false

    var isTerminationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminationRequested
    }

    var hasFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didFire
    }

    func requestTermination() {
        lock.lock()
        terminationRequested = true
        lock.unlock()
    }

    func recordFiring() {
        lock.lock()
        didFire = true
        lock.unlock()
    }

    func clearFiring() {
        lock.lock()
        didFire = false
        lock.unlock()
    }
}

private typealias ShouldTerminateCallback = @convention(c) (
    JSContextRef?, UnsafeMutableRawPointer?
) -> Bool

private typealias SetExecutionTimeLimit = @convention(c) (
    JSContextGroupRef?, Double, ShouldTerminateCallback?, UnsafeMutableRawPointer?
) -> Void

private typealias ClearExecutionTimeLimit = @convention(c) (JSContextGroupRef?) -> Void

/// Lazily resolved private JavaScriptCore entry points.
private enum WatchdogSymbols {
    static let setLimit: SetExecutionTimeLimit? = resolve("JSContextGroupSetExecutionTimeLimit")
    static let clearLimit: ClearExecutionTimeLimit? = resolve("JSContextGroupClearExecutionTimeLimit")

    static var available: Bool { setLimit != nil && clearLimit != nil }

    /// JavaScriptCore's own image is searched first: `RTLD_DEFAULT` does not
    /// reliably reach a private symbol when the caller is itself a loaded
    /// bundle (which is how the test target runs), and silently resolving to
    /// nothing would disable the ceiling without any signal.
    private static func javaScriptCoreHandle() -> UnsafeMutableRawPointer? {
        let path = "/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore"
        // RTLD_NOLOAD: the framework is already linked by this module, so this
        // returns its handle without loading anything new.
        return dlopen(path, RTLD_LAZY | RTLD_NOLOAD) ?? dlopen(path, RTLD_LAZY)
    }

    private static func resolve<T>(_ name: String) -> T? {
        var symbol = javaScriptCoreHandle().flatMap { dlsym($0, name) }
        if symbol == nil {
            // RTLD_DEFAULT: every image already loaded into the process.
            symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
        }
        guard let symbol else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}

/// The watchdog only fires when the ceiling has elapsed, so it always
/// terminates the entry; the box records that it happened so the runtime
/// can tell a ceiling stop from a normal return.
private let shouldTerminate: ShouldTerminateCallback = { _, userData in
    guard let userData else { return true }
    Unmanaged<WatchdogBox>.fromOpaque(userData).takeUnretainedValue().recordFiring()
    return true
}

/// Arms the JavaScriptCore execution ceiling for one context.
final class JavaScriptExecutionWatchdog: @unchecked Sendable {
    private let box = WatchdogBox()
    private let group: JSContextGroupRef?
    private let retainedBox: Unmanaged<WatchdogBox>?
    private let ceilingSeconds: Double

    /// Whether this host can bound a runaway JavaScript entry at all.
    static var supportsExecutionCeiling: Bool { WatchdogSymbols.available }

    init(context: JSContext, ceilingMilliseconds: UInt64) {
        ceilingSeconds = Double(ceilingMilliseconds) / 1_000
        guard WatchdogSymbols.available else {
            group = nil
            retainedBox = nil
            return
        }
        group = JSContextGetGroup(context.jsGlobalContextRef)
        retainedBox = Unmanaged.passRetained(box)
    }

    /// Arm the ceiling for the next VM entry. Must be called on the thread
    /// that owns the context, immediately before entering JavaScript;
    /// JavaScriptCore does not re-arm on its own.
    func armForEntry() {
        guard let group, let setLimit = WatchdogSymbols.setLimit, let retainedBox else { return }
        box.clearFiring()
        setLimit(group, ceilingSeconds, shouldTerminate, retainedBox.toOpaque())
    }

    /// Whether the ceiling stopped the entry that just ran.
    var didStopLastEntry: Bool { box.hasFired }

    /// Ask the runtime to stop. Idempotent and safe from any thread. The
    /// current entry still runs until its ceiling elapses; every later
    /// entry is refused by the runtime loop.
    func requestTermination() {
        box.requestTermination()
    }

    var isTerminationRequested: Bool { box.isTerminationRequested }

    /// Remove the ceiling. Must run on the thread that owns the context,
    /// after JavaScript has stopped executing.
    func dispose() {
        if let group, let clearLimit = WatchdogSymbols.clearLimit {
            clearLimit(group)
        }
        retainedBox?.release()
    }
}

#else

/// Non-JavaScriptCore platforms never construct a runtime; the watchdog
/// exists only to keep the runtime source compiling.
final class JavaScriptExecutionWatchdog: @unchecked Sendable {
    static var supportsExecutionCeiling: Bool { false }
    func armForEntry() {}
    var didStopLastEntry: Bool { false }
    func requestTermination() {}
    var isTerminationRequested: Bool { false }
    func dispose() {}
}

#endif
