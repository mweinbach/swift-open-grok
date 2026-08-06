// LinuxChildNetworkRestrictionTests.swift
//
// Unit and behavioral coverage for real Linux child network denial.
//
// The behavioral test observes a spawned child failing to reach a listener
// in the parent network namespace. It is guarded by `.enabled(if:)` — not by
// an early return, so an unsupported host reports a *skip* in the run output
// instead of a silent green. The guard probes the real mechanism (an
// `unshare` re-exec of `/bin/sh`) plus the availability of a connect-probe
// program; a capable host runs the test, an incapable one skips visibly.

import Foundation
import Testing
@testable import OpenGrokSandbox

#if os(Linux)
import Glibc
#endif

@Suite("LinuxChildNetworkRestriction")
struct LinuxChildNetworkRestrictionTests {
    @Test("wrap builds the unshare re-exec argv verbatim")
    func wrapBuildsUnshareReexec() {
        let restriction = ChildNetworkRestriction(
            unsharePath: "/usr/bin/unshare",
            prefixArguments: ["--user", "--map-current-user", "--net", "--"]
        )
        let (exe, args) = LinuxChildNetworkRestriction.wrap(
            executable: "/usr/bin/curl",
            arguments: ["--flag with space", "https://example.com"],
            restriction: restriction
        )
        #expect(exe == "/usr/bin/unshare")
        #expect(args == [
            "--user", "--map-current-user", "--net", "--",
            "/usr/bin/curl", "--flag with space", "https://example.com",
        ])
    }

    @Test("child network restriction never arms off Linux")
    func neverArmsOffLinux() {
        #if os(Linux)
        #expect(restrictNetworkAtKnownLinuxLaunches(applied: true, configured: true))
        #expect(!restrictNetworkAtKnownLinuxLaunches(applied: false, configured: true))
        #expect(!restrictNetworkAtKnownLinuxLaunches(applied: true, configured: false))
        #else
        // macOS/Windows keep process-level provider network access; the
        // per-child launch restriction must never arm there even when the
        // sandbox applied and the resolved profile restricts network.
        #expect(!restrictNetworkAtKnownLinuxLaunches(applied: true, configured: true))
        #expect(!restrictNetworkAtKnownLinuxLaunches(applied: false, configured: false))
        #endif
    }

    @Test("launch transform passes through untouched when restriction is not armed")
    func launchPassthroughWhenNotArmed() throws {
        // Nothing in this test process installed a sandbox, so the global
        // flag is false and the launch must come back byte-identical on every
        // platform. This is the reachability control for the armed path: if
        // the flag ever defaulted true, unwrapped spawns would silently start
        // paying the unshare re-exec.
        #expect(!shouldRestrictChildNetwork())
        let (exe, args) = try childNetworkRestrictedLaunch(
            executable: "/bin/echo",
            arguments: ["hi"]
        )
        #expect(exe == "/bin/echo")
        #expect(args == ["hi"])
    }

    #if !os(Linux)
    @Test("wrappedCommand is typed unsupported off Linux")
    func wrappedCommandUnsupportedOffLinux() {
        #expect(throws: SandboxError.self) {
            try LinuxChildNetworkRestriction.wrappedCommand(
                executable: "/bin/echo",
                arguments: ["hi"]
            )
        }
        do {
            _ = try LinuxChildNetworkRestriction.wrappedCommand(
                executable: "/bin/echo",
                arguments: ["hi"]
            )
            Issue.record("off-Linux wrappedCommand must not report success")
        } catch let error as SandboxError {
            guard case .unsupported = error else {
                Issue.record("expected .unsupported, got \(error)")
                return
            }
        } catch {
            Issue.record("expected SandboxError, got \(error)")
        }
    }
    #endif

    #if os(Linux)
    @Test("probe honesty: capability report and wrapping outcome agree")
    func probeHonesty() {
        // Whichever branch this host is on, the capability report must match
        // the outcome: a nil probe with a succeeding wrap would be silent
        // non-enforcement, and a non-nil probe with a throwing wrap would be
        // a false capability claim.
        if LinuxChildNetworkRestriction.probeHost() != nil {
            #expect(throws: Never.self) {
                try LinuxChildNetworkRestriction.wrappedCommand(
                    executable: "/bin/echo",
                    arguments: ["hi"]
                )
            }
        } else {
            #expect(throws: SandboxError.self) {
                try LinuxChildNetworkRestriction.wrappedCommand(
                    executable: "/bin/echo",
                    arguments: ["hi"]
                )
            }
        }
    }

    @Test("a bogus unshare path fails closed with typed unsupported")
    func bogusUnsharePathFailsClosed() {
        let bogus = "/nonexistent/unshare-\(UUID().uuidString)"
        #expect(LinuxChildNetworkRestriction.probeHost(unsharePath: bogus) == nil)
        #expect(throws: SandboxError.self) {
            try LinuxChildNetworkRestriction.wrappedCommand(
                executable: "/bin/echo",
                arguments: ["hi"],
                unsharePath: bogus
            )
        }
    }
    #endif
}

#if os(Linux)
@Suite("LinuxChildNetworkRestriction behavior")
struct LinuxChildNetworkRestrictionBehaviorTests {
    @Test(
        "a wrapped child cannot reach the network",
        .enabled(
            if: LinuxChildNetworkBehaviorSupport.isRunnableOnThisHost,
            "requires util-linux unshare with user+network namespace support and a connect-probe program (bash or python3); unsupported hosts skip here rather than passing silently"
        )
    )
    func wrappedChildCannotReachNetwork() throws {
        let restriction = try #require(
            LinuxChildNetworkRestriction.probeHost(),
            "the plan-time guard probed this host capable; a nil now means capability flipped mid-run"
        )
        let probe = try #require(
            NetworkProbeProgram.discover(),
            "the plan-time guard found a connect-probe program"
        )

        let listener = try LoopbackListener()
        defer { listener.close() }

        // CONTROL: the same probe, unwrapped, must connect. A control failure
        // means the probe mechanics or the listener are broken on this host —
        // that is a test-environment defect and must fail loudly, never skip.
        let probeLaunch = probe.launch(port: listener.port)
        let control = runChild(
            executable: probeLaunch.executable,
            arguments: probeLaunch.arguments
        )
        #expect(
            control.exitStatus == 0,
            "control probe must connect when unrestricted: \(control.stderr)"
        )
        #expect(
            listener.awaitConnection(timeoutSeconds: 3),
            "listener must observe the control connection"
        )

        // EXPERIMENT: the identical probe wrapped through the restriction.
        let wrapped = LinuxChildNetworkRestriction.wrap(
            executable: probeLaunch.executable,
            arguments: probeLaunch.arguments,
            restriction: restriction
        )
        let denied = runChild(
            executable: wrapped.executable,
            arguments: wrapped.arguments
        )
        let status = try #require(
            denied.exitStatus,
            "wrapped probe must run to completion (timeout or spawn failure): \(denied.stderr)"
        )
        #expect(
            status != 0,
            "wrapped probe must fail to connect, exited 0: \(denied.stderr)"
        )
        // The denial must happen inside the child, not in the wrapper: an
        // "unshare:" stderr prefix would mean the namespace re-exec itself
        // failed and the probe program never ran.
        #expect(
            !denied.stderr.contains("unshare:"),
            "denial must come from the probe's connect attempt, not an unshare launch failure: \(denied.stderr)"
        )
        #expect(
            denied.stderr.range(
                of: "unreachable|not permitted|no route",
                options: [.regularExpression, .caseInsensitive]
            ) != nil,
            "expected a network-layer denial in probe stderr: \(denied.stderr)"
        )
        #expect(
            !listener.awaitConnection(timeoutSeconds: 2),
            "the network-denied child must not reach the parent listener"
        )
    }
}

// MARK: - Behavioral test support

enum LinuxChildNetworkBehaviorSupport {
    /// Plan-time guard for the behavioral test: the real enforcement probe
    /// plus a connect-probe program must both exist. Evaluated on the test
    /// host; a false here marks the test *skipped* in the report.
    static var isRunnableOnThisHost: Bool {
        LinuxChildNetworkRestriction.probeHost() != nil
            && NetworkProbeProgram.discover() != nil
    }
}

/// A program on the host that attempts one TCP connect and reports the
/// outcome on stderr. bash's `/dev/tcp` redirection is preferred (present in
/// every distribution bash); python3 is the fallback.
enum NetworkProbeProgram {
    case bashDevTcp(path: String)
    case python3(path: String)

    static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> NetworkProbeProgram? {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: "/bin/bash") {
            return .bashDevTcp(path: "/bin/bash")
        }
        for fixed in ["/usr/bin/python3", "/usr/local/bin/python3", "/bin/python3"]
        where fm.isExecutableFile(atPath: fixed) {
            return .python3(path: fixed)
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(directory)/python3"
            if fm.isExecutableFile(atPath: candidate) {
                return .python3(path: candidate)
            }
        }
        return nil
    }

    func launch(port: UInt16) -> (executable: String, arguments: [String]) {
        switch self {
        case .bashDevTcp(let path):
            return (path, ["-c", "exec 3<>/dev/tcp/127.0.0.1/\(port)"])
        case .python3(let path):
            return (
                path,
                [
                    "-c",
                    "import socket; s = socket.create_connection(('127.0.0.1', \(port)), 3); s.close()",
                ]
            )
        }
    }
}

/// A TCP listener on 127.0.0.1 in the test process's own network namespace.
/// Raw Glibc sockets keep the behavioral test free of Network.framework
/// (Apple-only) and of any OpenGrokTestSupport dependency.
private final class LoopbackListener {
    let fd: Int32
    let port: UInt16

    init() throws {
        let sock = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard sock >= 0 else {
            throw SandboxError.enforcementFailed(
                "test listener socket failed: \(String(cString: strerror(errno)))"
            )
        }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        // INADDR_LOOPBACK (127.0.0.1) as a literal: the macro's Glibc
        // overlay import is not verifiable from the macOS build host.
        addr.sin_addr = in_addr(s_addr: htonl(0x7F00_0001))
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard bound == 0 else {
            let message = String(cString: strerror(errno))
            Glibc.close(sock)
            throw SandboxError.enforcementFailed("test listener bind failed: \(message)")
        }
        guard Glibc.listen(sock, 8) == 0 else {
            let message = String(cString: strerror(errno))
            Glibc.close(sock)
            throw SandboxError.enforcementFailed("test listener listen failed: \(message)")
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let named = withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.getsockname(sock, $0, &length)
            }
        }
        guard named == 0 else {
            let message = String(cString: strerror(errno))
            Glibc.close(sock)
            throw SandboxError.enforcementFailed("test listener getsockname failed: \(message)")
        }
        self.fd = sock
        self.port = UInt16(bigEndian: actual.sin_port)
    }

    /// True when a connection arrives within the window. A pending
    /// connection is accepted and closed so a later observation starts from
    /// an empty queue — `poll` is level-triggered, so without the accept the
    /// control connection would mask the experiment's negative window.
    func awaitConnection(timeoutSeconds: Int32) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = Glibc.poll(&descriptor, 1, timeoutSeconds * 1000)
        guard ready > 0, (descriptor.revents & Int16(POLLIN)) != 0 else {
            return false
        }
        let connection = Glibc.accept(fd, nil, nil)
        if connection >= 0 {
            Glibc.close(connection)
        }
        return true
    }

    func close() {
        Glibc.close(fd)
    }
}

private struct ChildOutcome {
    let exitStatus: Int32?
    let stderr: String
}

/// Run a child to completion with a bounded wait, capturing stderr.
/// `terminationHandler` bridged to a semaphore — never `waitUntilExit()`,
/// which can park forever when the child beats the run loop to the death
/// notification; timeout escalates SIGTERM -> SIGKILL.
private func runChild(
    executable: String,
    arguments: [String],
    timeoutSeconds: TimeInterval = 15
) -> ChildOutcome {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    process.standardOutput = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    let status = LockedChildStatus()
    process.terminationHandler = { child in
        status.set(child.terminationStatus)
        finished.signal()
    }
    do {
        try process.run()
    } catch {
        process.terminationHandler = nil
        return ChildOutcome(exitStatus: nil, stderr: "spawn failed: \(error)")
    }
    if finished.wait(timeout: .now() + timeoutSeconds) == .timedOut {
        process.terminate()
        if finished.wait(timeout: .now() + 1) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 2)
        }
        return ChildOutcome(exitStatus: nil, stderr: "probe timed out")
    }
    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    return ChildOutcome(
        exitStatus: status.get(),
        stderr: String(data: data, encoding: .utf8) ?? ""
    )
}

private final class LockedChildStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?

    func set(_ newValue: Int32) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
#endif
