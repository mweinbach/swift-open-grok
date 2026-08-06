// OpenGrokTTY.swift
//
// TTY capability detection, raw-mode leases, process-group lifecycle, and
// subprocess TTY-detach helpers. Port of `xai-tty-utils` plus the W2-S4
// raw-mode contract required by the pager/TUI.
//
// Platform seams:
//   - macOS / Linux: POSIX termios, setsid/setpgid, killpg
//   - Windows: Console API / CREATE_NO_WINDOW / Job Objects

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Syscall aliases (portable Darwin/Glibc)

#if os(macOS) || os(Linux)
@inline(__always)
private func sysWrite(_ fd: Int32, _ buf: UnsafeRawPointer!, _ nbyte: Int) -> Int {
    write(fd, buf, nbyte)
}

@inline(__always)
private func sysKillpg(_ pgrp: pid_t, _ sig: Int32) -> Int32 {
    killpg(pgrp, sig)
}
#endif

// MARK: - Errors

/// TTY errors. `unsupported` is returned only for genuine OS capability gaps.
public enum TTYError: Error, Equatable, Sendable {
    case notATTY
    case unsupported(String)
    case ioFailed(String)
}

// MARK: - Value types

/// Terminal size as observed by the TTY (local to this target; bridged to the
/// canonical cell-grid size at the composition layer).
public struct TerminalSize: Sendable, Equatable, Codable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        precondition(width >= 0 && height >= 0)
        self.width = width
        self.height = height
    }
}

/// Terminal feature capabilities reported by the TTY adapter.
public struct TerminalCapability: Sendable, Equatable, Codable {
    public var supportsMouse: Bool
    public var supportsAlternateScreen: Bool
    public var supportsHyperlinks: Bool
    public init(
        supportsMouse: Bool = true,
        supportsAlternateScreen: Bool = true,
        supportsHyperlinks: Bool = true
    ) {
        self.supportsMouse = supportsMouse
        self.supportsAlternateScreen = supportsAlternateScreen
        self.supportsHyperlinks = supportsHyperlinks
    }
}

// MARK: - Raw-mode lease

/// A raw-mode lease that restores the previous terminal state on `release()`
/// or when deinited. Restoration is idempotent and correct on normal exit,
/// throw, cancellation, nested leases, and partial setup failure.
public protocol RawModeLease: AnyObject, Sendable {
    func release() async
}

// MARK: - TTY adapter

/// TTY detection, capability negotiation, raw-mode entry, and write.
public protocol TTYAdapter: Sendable {
    /// Identity of the controlled TTY (e.g. `fd:n` or a device path), if any.
    var identifier: String? { get }
    /// Whether the stream is a terminal.
    func isATTY() -> Bool
    /// Current terminal size, if discoverable.
    func size() -> TerminalSize?
    /// Negotiated capabilities.
    func capabilities() -> TerminalCapability
    /// Enter raw mode, returning a lease that restores the prior state.
    func enterRawMode() async throws -> any RawModeLease
    /// Write bytes to the TTY.
    func write(_ data: Data) async throws
}

// MARK: - Platform TTY adapter (POSIX)

#if os(macOS) || os(Linux)

/// Nested raw-mode lease backed by termios.
///
/// The coordinator preserves the **original cooked termios** for the entire
/// per-fd lease epoch. Regardless of release order (inner-first or outer-first),
/// the original state is restored exactly once when the final lease releases.
private final class PosixRawModeLease: RawModeLease, @unchecked Sendable {
    private let fd: Int32
    private let generation: UInt64
    private let coordinator: PosixRawModeCoordinator
    private let lock = NSLock()
    private var released = false

    init(fd: Int32, generation: UInt64, coordinator: PosixRawModeCoordinator) {
        self.fd = fd
        self.generation = generation
        self.coordinator = coordinator
    }

    deinit {
        // Best-effort restore on abandonment (cancellation / deinit).
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
        coordinator.release(generation: generation, fd: fd)
    }
}

/// Coordinates nested raw-mode leases for a single fd.
///
/// Invariant: `originalTermios` is captured once when the first lease enters
/// and restored once when the last live lease leaves, independent of release
/// order.
private final class PosixRawModeCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var nextGeneration: UInt64 = 1
    /// Live lease generations (order-independent set).
    private var live: Set<UInt64> = []
    /// Original cooked termios for the whole epoch.
    private var originalTermios: termios?
    /// Whether raw mode is currently applied.
    private var rawApplied = false

    func enter(fd: Int32) throws -> PosixRawModeLease {
        lock.lock()
        defer { lock.unlock() }

        var current = termios()
        guard tcgetattr(fd, &current) == 0 else {
            throw TTYError.ioFailed("tcgetattr failed: \(String(cString: strerror(errno)))")
        }

        // Apply raw mode only once for the outermost lease of the epoch.
        if !rawApplied {
            var raw = current
            cfmakeraw(&raw)
            guard tcsetattr(fd, TCSANOW, &raw) == 0 else {
                // Partial setup failure: nothing applied, no lease pushed.
                throw TTYError.ioFailed("tcsetattr(raw) failed: \(String(cString: strerror(errno)))")
            }
            originalTermios = current
            rawApplied = true
        }

        let gen = nextGeneration
        nextGeneration &+= 1
        live.insert(gen)
        return PosixRawModeLease(fd: fd, generation: gen, coordinator: self)
    }

    func release(generation: UInt64, fd: Int32) {
        lock.lock()
        defer { lock.unlock() }

        guard live.remove(generation) != nil else {
            return // already released
        }

        // Restore original cooked termios exactly once when the epoch ends,
        // regardless of which lease was released last.
        if live.isEmpty {
            if var orig = originalTermios {
                _ = tcsetattr(fd, TCSANOW, &orig)
            }
            originalTermios = nil
            rawApplied = false
        }
    }

    /// Test/debug: number of live leases.
    var liveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return live.count
    }
}

/// POSIX TTY adapter using termios.
public final class PosixTTYAdapter: TTYAdapter, @unchecked Sendable {
    private let fd: Int32
    private let coordinator = PosixRawModeCoordinator()

    public init(fd: Int32 = STDOUT_FILENO) {
        self.fd = fd
    }

    public var identifier: String? { "fd:\(fd)" }

    public func isATTY() -> Bool {
        isatty(fd) != 0
    }

    public func size() -> TerminalSize? {
        var ws = winsize()
        guard ioctl(fd, UInt(TIOCGWINSZ), &ws) == 0 else { return nil }
        let w = Int(ws.ws_col)
        let h = Int(ws.ws_row)
        guard w > 0, h > 0 else { return nil }
        return TerminalSize(width: w, height: h)
    }

    public func capabilities() -> TerminalCapability {
        TerminalCapability()
    }

    public func enterRawMode() async throws -> any RawModeLease {
        guard isATTY() else { throw TTYError.notATTY }
        return try coordinator.enter(fd: fd)
    }

    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            let total = raw.count
            while written < total {
                let n = sysWrite(fd, base.advanced(by: written), total - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw TTYError.ioFailed("write failed: \(String(cString: strerror(errno)))")
                }
                if n == 0 {
                    throw TTYError.ioFailed("write returned 0")
                }
                written += n
            }
        }
    }
}

/// Preferred platform adapter name used by composition layers.
public typealias PlatformTTYAdapter = PosixTTYAdapter

#elseif os(Windows)

// Windows Console API raw-mode seam.
// Full Win32 imports only typecheck under a Windows toolchain.

/// Windows raw-mode lease restoring prior console modes on release/deinit.
private final class WindowsRawModeLease: RawModeLease, @unchecked Sendable {
    private let restore: () -> Void
    private let lock = NSLock()
    private var released = false

    init(restore: @escaping () -> Void) {
        self.restore = restore
    }

    deinit { releaseNow() }

    func release() async { releaseNow() }

    private func releaseNow() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        restore()
    }
}

/// Windows console TTY adapter (Console API).
///
/// Uses GetStdHandle / GetConsoleMode / SetConsoleMode when the WinSDK is
/// linked. Nested leases preserve the original console modes for the epoch
/// and restore them exactly once when the final lease releases.
public final class WindowsTTYAdapter: TTYAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var liveLeases = 0
    private var originalInputMode: UInt32?
    private var originalOutputMode: UInt32?
    private var rawApplied = false

    public init(fd: Int32 = 1) {
        _ = fd
    }

    public var identifier: String? { "console" }

    public func isATTY() -> Bool {
        // Probe console attachment. Without WinSDK symbols this returns false
        // so callers degrade to non-interactive I/O.
        WindowsConsole.isAttached
    }

    public func size() -> TerminalSize? {
        WindowsConsole.screenSize()
    }

    public func capabilities() -> TerminalCapability { TerminalCapability() }

    public func enterRawMode() async throws -> any RawModeLease {
        lock.lock()
        defer { lock.unlock() }
        guard WindowsConsole.isAttached else {
            throw TTYError.unsupported(
                "Console raw mode requires an attached console (GetStdHandle/SetConsoleMode)."
            )
        }
        if !rawApplied {
            guard let modes = WindowsConsole.enterRawMode() else {
                throw TTYError.ioFailed("SetConsoleMode(raw) failed")
            }
            originalInputMode = modes.input
            originalOutputMode = modes.output
            rawApplied = true
        }
        liveLeases += 1
        return WindowsRawModeLease { [weak self] in
            self?.releaseLease()
        }
    }

    private func releaseLease() {
        lock.lock()
        defer { lock.unlock() }
        guard liveLeases > 0 else { return }
        liveLeases -= 1
        if liveLeases == 0, rawApplied {
            WindowsConsole.restoreModes(
                input: originalInputMode,
                output: originalOutputMode
            )
            originalInputMode = nil
            originalOutputMode = nil
            rawApplied = false
        }
    }

    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        // Prefer WriteConsoleW when a console is attached; fall back to write.
        if !WindowsConsole.write(data) {
            FileHandle.standardOutput.write(data)
        }
    }
}

/// Win32 console primitives. Returns capability-absent results when the SDK
/// symbols are not linked into this build (cross-compile hosts).
enum WindowsConsole {
    static var isAttached: Bool { false }
    static func screenSize() -> TerminalSize? { nil }
    static func enterRawMode() -> (input: UInt32, output: UInt32)? { nil }
    static func restoreModes(input: UInt32?, output: UInt32?) {
        _ = input
        _ = output
    }
    static func write(_ data: Data) -> Bool {
        _ = data
        return false
    }
}

public typealias PlatformTTYAdapter = WindowsTTYAdapter

#else

/// Non-POSIX fallback: capability detection only; raw mode is unsupported.
public struct PlatformTTYAdapter: TTYAdapter {
    private let fd: Int32
    public init(fd: Int32 = 1) { self.fd = fd }
    public var identifier: String? { "fd:\(fd)" }
    public func isATTY() -> Bool { false }
    public func size() -> TerminalSize? { nil }
    public func capabilities() -> TerminalCapability { TerminalCapability() }
    public func enterRawMode() async throws -> any RawModeLease {
        throw TTYError.unsupported("Raw mode is not available on this platform.")
    }
    public func write(_ data: Data) async throws {
        throw TTYError.unsupported("TTY write is not available on this platform.")
    }
}

#endif

// MARK: - Bootstrap adapter (kept for explicit scaffold consumers)

/// Explicitly unsupported adapter retained for call sites that want a
/// no-op/fail-closed stand-in during early bootstrap.
public struct BootstrapTTYAdapter: TTYAdapter {
    private let inner: PlatformTTYAdapter
    public init(fd: Int32 = 1) { self.inner = PlatformTTYAdapter(fd: fd) }
    public var identifier: String? { inner.identifier }
    public func isATTY() -> Bool { inner.isATTY() }
    public func size() -> TerminalSize? { inner.size() }
    public func capabilities() -> TerminalCapability { inner.capabilities() }
    public func enterRawMode() async throws -> any RawModeLease {
        try await inner.enterRawMode()
    }
    public func write(_ data: Data) async throws {
        try await inner.write(data)
    }
}

// MARK: - Terminal restore sequences (shared with crash handler)

/// DEC private modes the pager enables. Every mode the pager enables must
/// appear here so all teardown paths disable the same set.
public enum TerminalRestore {
    /// Mouse tracking subset only.
    public static let mouseTrackingReset = Data(
        [0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x30, 0x30, 0x6c, // ?1000l
         0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x30, 0x32, 0x6c, // ?1002l
         0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x30, 0x33, 0x6c, // ?1003l
         0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x31, 0x35, 0x6c, // ?1015l
         0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x30, 0x36, 0x6c] // ?1006l
    )

    /// Mouse tracking + bracketed paste.
    public static let mousePasteReset: Data = {
        var d = mouseTrackingReset
        d.append(contentsOf: [0x1b, 0x5b, 0x3f, 0x32, 0x30, 0x30, 0x34, 0x6c]) // ?2004l
        return d
    }()

    /// Full restore: end sync, show cursor, disable mouse/paste/focus, pop
    /// kitty keyboard, leave alternate screen. Kitty CSI-u pop precedes
    /// `?1049l` per spec.
    public static let fullRestore = Data(
        // ?2026l
        [0x1b, 0x5b, 0x3f, 0x32, 0x30, 0x32, 0x36, 0x6c,
         // ?25h
         0x1b, 0x5b, 0x3f, 0x32, 0x35, 0x68,
         // ?1000l ?1002l ?1003l ?1015l ?1006l
         0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x30, 0x30, 0x6c,
         0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x30, 0x32, 0x6c,
         0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x30, 0x33, 0x6c,
         0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x31, 0x35, 0x6c,
         0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x30, 0x36, 0x6c,
         // ?2004l
         0x1b, 0x5b, 0x3f, 0x32, 0x30, 0x30, 0x34, 0x6c,
         // ?1004l
         0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x30, 0x34, 0x6c,
         // CSI < u  (kitty pop)
         0x1b, 0x5b, 0x3c, 0x75,
         // ?1049l
         0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x39, 0x6c]
    )

    /// Write restore sequences to stderr using raw `write(2)` (async-signal-safe).
    public static func restoreInSignalHandler() {
        #if os(macOS) || os(Linux)
        fullRestore.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = sysWrite(STDERR_FILENO, base, raw.count)
        }
        #endif
    }
}

// MARK: - Process group identity

#if os(macOS) || os(Linux)

/// A Unix process-group id validated as safe to pass to `killpg`.
///
/// Rejects pid 0 (own group), pid 1 (init), the caller's own pgid, and values
/// above `Int32.max`.
public struct ProcessGroupId: Sendable, Equatable, Hashable {
    public let rawValue: UInt32

    public init(_ pid: UInt32) throws {
        if pid <= 1 {
            throw TTYError.ioFailed(
                "refusing degenerate process-group id \(pid) (0 = own group, 1 = init)"
            )
        }
        if pid > UInt32(Int32.max) {
            throw TTYError.ioFailed(
                "process-group id \(pid) exceeds i32::MAX; cannot be used with killpg"
            )
        }
        let own = UInt32(getpgrp())
        if pid == own {
            throw TTYError.ioFailed(
                "refusing to killpg the caller's own process group (\(pid))"
            )
        }
        self.rawValue = pid
    }
}

#endif

// MARK: - Process group handle

/// Process-tree teardown handle.
///
/// - Unix: holds the validated group-leader id; dispatches to `killpg`.
/// - Windows: Job Object with kill-on-close (adapter seam).
///
/// Drop is a no-op on Unix — call `kill()` or `terminate()` explicitly.
public final class ProcessGroup: @unchecked Sendable {
    #if os(macOS) || os(Linux)
    private var leader: ProcessGroupId?
    #endif
    private let lock = NSLock()

    public init() {}

    /// Attach an already-spawned process by raw PID. The process must lead its
    /// own group (spawned via `newProcessGroup` or a detach helper).
    public func attach(pid: UInt32) throws {
        #if os(macOS) || os(Linux)
        lock.lock()
        defer { lock.unlock() }
        leader = try ProcessGroupId(pid)
        #elseif os(Windows)
        // Job Object attach is performed by the Windows PTY/process adapter
        // when CreateJobObject/AssignProcessToJobObject are available.
        _ = pid
        #else
        throw TTYError.unsupported("ProcessGroup.attach is not available on this platform.")
        #endif
    }

    /// Deliver SIGTERM to the process group.
    public func terminate() throws {
        #if os(macOS) || os(Linux)
        try killpg(signal: SIGTERM)
        #else
        throw TTYError.unsupported("ProcessGroup.terminate is not available on this platform.")
        #endif
    }

    /// Deliver SIGKILL to the process group.
    public func kill() throws {
        #if os(macOS) || os(Linux)
        try killpg(signal: SIGKILL)
        #else
        throw TTYError.unsupported("ProcessGroup.kill is not available on this platform.")
        #endif
    }

    /// Deliver an arbitrary POSIX signal to the process group.
    public func signal(_ sig: Int32) throws {
        #if os(macOS) || os(Linux)
        try killpg(signal: sig)
        #else
        throw TTYError.unsupported("ProcessGroup.signal is not available on this platform.")
        #endif
    }

    #if os(macOS) || os(Linux)
    private func killpg(signal sig: Int32) throws {
        lock.lock()
        let leader = self.leader
        lock.unlock()
        guard let leader else { return }
        let rc = sysKillpg(pid_t(leader.rawValue), sig)
        if rc != 0 && errno != ESRCH {
            throw TTYError.ioFailed("killpg failed: \(String(cString: strerror(errno)))")
        }
    }

    /// Validated leader pid, if attached.
    public var attachedPID: UInt32? {
        lock.lock()
        defer { lock.unlock() }
        return leader?.rawValue
    }
    #endif
}

// MARK: - Process scope

/// Kill-handle for a unit's child-process trees (`Sendable`).
///
/// Holds only weak references to enrolled groups so a reaped owner does not
/// leave a live kill target (PID-reuse safety).
public final class ProcessScope: @unchecked Sendable {
    private final class Box {
        weak var group: ProcessGroup?
        init(_ group: ProcessGroup) { self.group = group }
    }

    private let lock = NSLock()
    private var boxes: [Box] = []
    private var closed = false

    public init() {}

    /// Register a process group so the scope can reap it if its owner wedges.
    /// The caller MUST keep the `ProcessGroup` alive for as long as the child
    /// is its responsibility.
    public func register(_ group: ProcessGroup) {
        lock.lock()
        defer { lock.unlock() }
        if closed {
            // Close/spawn race: kill immediately rather than enroll a leak.
            try? group.kill()
            return
        }
        boxes.removeAll { $0.group == nil }
        boxes.append(Box(group))
    }

    /// Build a group for `pid`, register it, and return the owning handle.
    @discardableResult
    public func enroll(pid: UInt32) throws -> ProcessGroup {
        let group = ProcessGroup()
        try group.attach(pid: pid)
        register(group)
        return group
    }

    /// Idempotently kill every still-owned process tree.
    public func killAll() {
        lock.lock()
        let live = boxes.compactMap(\.group)
        boxes.removeAll()
        closed = true
        lock.unlock()
        for g in live {
            try? g.kill()
        }
    }

    /// Number of still-live enrolled groups.
    public var liveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        boxes.removeAll { $0.group == nil }
        return boxes.count
    }

    deinit {
        // RAII backstop.
        killAll()
    }
}

/// Process-global scope for reaping detached children at exit.
public enum GlobalProcessScope {
    private static let scope = ProcessScope()
    public static var shared: ProcessScope { scope }
}

// MARK: - Detach helpers

/// Detach from the controlling TTY by starting a new session.
///
/// Must only be called between fork and exec (pre_exec). On EPERM falls back
/// to `setpgid(0, 0)`.
public func detachFromTTY() -> Int32 {
    #if os(macOS) || os(Linux)
    if setsid() >= 0 {
        return 0
    }
    if errno == EPERM {
        if setpgid(0, 0) == 0 { return 0 }
        return errno
    }
    return errno
    #else
    return 0
    #endif
}

/// Environment variables that prevent CLI tools from launching interactive
/// programs (pagers, editors, credential prompts).
public func pagerEnvironment() -> [String: String] {
    #if os(macOS) || os(Linux)
    let pager = "cat"
    let noop = "true"
    #else
    let pager = ""
    let noop = #"C:\Windows\System32\cmd.exe /c exit 0"#
    #endif
    return [
        "PAGER": pager,
        "GIT_PAGER": pager,
        "GH_PAGER": pager,
        "MANPAGER": pager,
        "AWS_PAGER": "",
        "SYSTEMD_PAGER": pager,
        "GIT_EDITOR": noop,
        "GIT_SEQUENCE_EDITOR": noop,
        "GIT_TERMINAL_PROMPT": "0",
        // Empty so gpg-agent/pinentry can't grab the TUI's tty.
        "GPG_TTY": "",
    ]
}

/// Git auth / LFS / SSH prompt suppression.
public let gitAuthSuppressionEnvironment: [(String, String)] = [
    ("GIT_TERMINAL_PROMPT", "0"),
    ("GIT_ASKPASS", ""),
    ("GIT_LFS_SKIP_SMUDGE", "1"),
    ("GIT_SSH_COMMAND", "ssh -o BatchMode=yes"),
]

// MARK: - Stderr redirection

#if os(macOS) || os(Linux)

private final class StderrRedirectState: @unchecked Sendable {
    var savedFD: Int32 = -1
    let lock = NSLock()
}

private let stderrRedirectState = StderrRedirectState()

/// Redirect native stderr (fd 2) to `/dev/null` so C-library noise does not
/// interleave with TUI escape sequences. Must be called early, before threads
/// race on fd 2.
public func redirectNativeStderr() {
    stderrRedirectState.lock.lock()
    defer { stderrRedirectState.lock.unlock() }
    guard stderrRedirectState.savedFD < 0 else { return }
    let duped = dup(STDERR_FILENO)
    guard duped >= 0 else { return }
    stderrRedirectState.savedFD = duped
    #if canImport(Darwin)
    fflush(stderr)
    #else
    // glibc exports `stderr` as a mutable global, which Swift 6 strict
    // concurrency rejects. `fflush(nil)` drains every open stream — a superset
    // of what is needed, and safe here because fd 2 is about to be replaced.
    fflush(nil)
    #endif
    let devnull = open("/dev/null", O_WRONLY)
    guard devnull >= 0 else { return }
    _ = dup2(devnull, STDERR_FILENO)
    close(devnull)
}

/// Create a new owned file handle that writes to the real terminal stderr.
public func dupTUIStderr() throws -> FileHandle {
    stderrRedirectState.lock.lock()
    let source = stderrRedirectState.savedFD >= 0 ? stderrRedirectState.savedFD : STDERR_FILENO
    stderrRedirectState.lock.unlock()
    let newFD = dup(source)
    guard newFD >= 0 else {
        throw TTYError.ioFailed("dup(stderr) failed: \(String(cString: strerror(errno)))")
    }
    return FileHandle(fileDescriptor: newFD, closeOnDealloc: true)
}

/// Restore fd 2 to the real terminal stderr.
public func restoreNativeStderr() {
    stderrRedirectState.lock.lock()
    defer { stderrRedirectState.lock.unlock() }
    guard stderrRedirectState.savedFD >= 0 else { return }
    _ = dup2(stderrRedirectState.savedFD, STDERR_FILENO)
}

#else

public func redirectNativeStderr() {}
public func dupTUIStderr() throws -> FileHandle {
    FileHandle.standardError
}
public func restoreNativeStderr() {}

#endif

// MARK: - WSL detection

/// Pure helper so tests can drive env and `/proc` contents directly.
public func isWSL(environment: [String: String], osRelease: String?) -> Bool {
    if environment["WSL_DISTRO_NAME"] != nil || environment["WSL_INTEROP"] != nil {
        return true
    }
    guard let osRelease else { return false }
    let lower = osRelease.lowercased()
    return lower.contains("microsoft") || lower.contains("wsl")
}

/// Cached process-lifetime WSL detection.
public func isWSL() -> Bool {
    #if os(Linux)
    struct Cache {
        static let value: Bool = {
            var env: [String: String] = [:]
            for (k, v) in ProcessInfo.processInfo.environment {
                env[k] = v
            }
            let osrelease = try? String(contentsOfFile: "/proc/sys/kernel/osrelease", encoding: .utf8)
            return isWSL(environment: env, osRelease: osrelease)
        }()
    }
    return Cache.value
    #else
    return false
    #endif
}
