// OpenGrokTTYTests.swift
import Foundation
import Testing
@testable import OpenGrokTTY

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("OpenGrokTTY")
struct OpenGrokTTYTests {
    @Test("PlatformTTYAdapter detects TTY and reports identity")
    func platformAdapterBasics() {
        let adapter = PlatformTTYAdapter(fd: 1)
        _ = adapter.isATTY()
        #expect(adapter.identifier == "fd:1")
        let caps = adapter.capabilities()
        #expect(caps.supportsAlternateScreen)
    }

    @Test("BootstrapTTYAdapter delegates to platform adapter")
    func bootstrapDelegates() {
        let adapter = BootstrapTTYAdapter(fd: 1)
        #expect(adapter.identifier == "fd:1")
        _ = adapter.isATTY()
    }

    @Test("enterRawMode on non-TTY throws notATTY")
    func rawModeOnNonTTY() async throws {
        #if os(macOS) || os(Linux)
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        let adapter = PlatformTTYAdapter(fd: fds[0])
        #expect(!adapter.isATTY())
        do {
            _ = try await adapter.enterRawMode()
            Issue.record("expected notATTY")
        } catch TTYError.notATTY {
            // expected
        } catch {
            Issue.record("unexpected: \(error)")
        }
        #endif
    }

    @Test("nested raw-mode leases restore idempotently (inner then outer)")
    func nestedRawModeInnerFirst() async throws {
        #if os(macOS) || os(Linux)
        try await withPTYPair { master, slave in
            _ = master
            let adapter = PlatformTTYAdapter(fd: slave)
            #expect(adapter.isATTY())

            var original = termios()
            #expect(tcgetattr(slave, &original) == 0)

            let lease1 = try await adapter.enterRawMode()
            let lease2 = try await adapter.enterRawMode()
            await lease2.release()
            await lease2.release() // idempotent
            await lease1.release()
            await lease1.release() // idempotent

            var restored = termios()
            #expect(tcgetattr(slave, &restored) == 0)
            #expect(
                termiosMatches(original, restored),
                "original=\(termiosSummary(original)) restored=\(termiosSummary(restored))"
            )
        }
        #endif
    }

    @Test("nested raw-mode outer-first release still restores original cooked termios")
    func nestedRawModeOuterFirst() async throws {
        #if os(macOS) || os(Linux)
        try await withPTYPair { master, slave in
            _ = master
            let adapter = PlatformTTYAdapter(fd: slave)
            #expect(adapter.isATTY())

            var original = termios()
            #expect(tcgetattr(slave, &original) == 0)

            let outer = try await adapter.enterRawMode()
            let inner = try await adapter.enterRawMode()

            // Release OUTER first — previously left the terminal raw when the
            // inner lease later restored its own raw snapshot.
            await outer.release()

            // Terminal must still be raw while the inner lease is live.
            var mid = termios()
            #expect(tcgetattr(slave, &mid) == 0)
            #expect(!termiosMatches(original, mid), "still raw while inner lease holds")

            await inner.release()

            var restored = termios()
            #expect(tcgetattr(slave, &restored) == 0)
            #expect(
                termiosMatches(original, restored),
                "original=\(termiosSummary(original)) restored=\(termiosSummary(restored))"
            )
        }
        #endif
    }

    @Test("raw-mode lease deinit restores original termios")
    func rawModeDeinitRestores() async throws {
        #if os(macOS) || os(Linux)
        try await withPTYPair { master, slave in
            _ = master
            let adapter = PlatformTTYAdapter(fd: slave)
            var original = termios()
            #expect(tcgetattr(slave, &original) == 0)

            var lease: (any RawModeLease)? = try await adapter.enterRawMode()
            #expect(lease != nil)
            lease = nil // deinit release

            // Allow deinit to run.
            try await Task.sleep(nanoseconds: 20_000_000)

            var restored = termios()
            #expect(tcgetattr(slave, &restored) == 0)
            #expect(
                termiosMatches(original, restored),
                "original=\(termiosSummary(original)) restored=\(termiosSummary(restored))"
            )
        }
        #endif
    }

    @Test("TerminalRestore sequences contain required modes")
    func restoreSequences() {
        let full = TerminalRestore.fullRestore
        #expect(full.starts(with: Data([0x1b, 0x5b, 0x3f, 0x32, 0x30, 0x32, 0x36, 0x6c])))
        #expect(full.range(of: Data([0x1b, 0x5b, 0x3c, 0x75])) != nil)
        #expect(full.range(of: Data([0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x39, 0x6c])) != nil)
        let kitty = full.range(of: Data([0x1b, 0x5b, 0x3c, 0x75]))!
        let alt = full.range(of: Data([0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x39, 0x6c]))!
        #expect(kitty.lowerBound < alt.lowerBound)
    }

    @Test("pagerEnvironment has expected keys")
    func pagerEnvKeys() {
        let env = pagerEnvironment()
        #expect(env["PAGER"] != nil)
        #expect(env["GIT_PAGER"] != nil)
        #expect(env["GH_PAGER"] != nil)
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
        #expect(env["GPG_TTY"] == "")
    }

    @Test("ProcessGroupId rejects degenerate and own group")
    func processGroupIdValidation() throws {
        #if os(macOS) || os(Linux)
        do {
            _ = try ProcessGroupId(0)
            Issue.record("pid 0 must be refused")
        } catch { /* expected */ }
        do {
            _ = try ProcessGroupId(1)
            Issue.record("pid 1 must be refused")
        } catch { /* expected */ }
        do {
            _ = try ProcessGroupId(UInt32.max)
            Issue.record("pid > i32.max must be refused")
        } catch { /* expected */ }
        let own = UInt32(getpgrp())
        do {
            _ = try ProcessGroupId(own)
            Issue.record("own group must be refused")
        } catch { /* expected */ }
        let foreign: UInt32 = own == 2 ? 3 : 2
        let id = try ProcessGroupId(foreign)
        #expect(id.rawValue == foreign)
        #endif
    }

    @Test("ProcessScope killAll reaps enrolled children")
    func processScopeKillAll() async throws {
        #if os(macOS) || os(Linux)
        let scope = ProcessScope()
        let p1 = try spawnSleeper()
        let p2 = try spawnSleeper()
        defer {
            kill(p1, SIGKILL)
            kill(p2, SIGKILL)
            var st: Int32 = 0
            _ = waitpid(p1, &st, 0)
            _ = waitpid(p2, &st, 0)
        }
        let g1 = try scope.enroll(pid: UInt32(p1))
        let g2 = try scope.enroll(pid: UInt32(p2))
        #expect(scope.liveCount == 2)
        scope.killAll()
        #expect(await childDied(p1))
        #expect(await childDied(p2))
        _ = g1
        _ = g2
        #endif
    }

    @Test("ProcessScope killAll is idempotent")
    func processScopeIdempotent() async throws {
        #if os(macOS) || os(Linux)
        let scope = ProcessScope()
        let p = try spawnSleeper()
        defer {
            kill(p, SIGKILL)
            var st: Int32 = 0
            _ = waitpid(p, &st, 0)
        }
        let group = try scope.enroll(pid: UInt32(p))
        scope.killAll()
        scope.killAll()
        #expect(await childDied(p))
        _ = group
        #endif
    }

    @Test("ProcessScope skips group whose owner dropped (PID-reuse safety)")
    func processScopeSkipsDroppedOwner() async throws {
        #if os(macOS) || os(Linux)
        let scope = ProcessScope()
        let p = try spawnSleeper()
        defer {
            kill(p, SIGKILL)
            var st: Int32 = 0
            _ = waitpid(p, &st, 0)
        }
        var group: ProcessGroup? = try scope.enroll(pid: UInt32(p))
        #expect(group != nil)
        #expect(scope.liveCount == 1)
        group = nil
        #expect(scope.liveCount == 0)
        scope.killAll()
        #expect(kill(p, 0) == 0)
        #endif
    }

    @Test("register after killAll reaps immediately")
    func registerAfterKillAll() async throws {
        #if os(macOS) || os(Linux)
        let scope = ProcessScope()
        scope.killAll()
        let p = try spawnSleeper()
        defer {
            kill(p, SIGKILL)
            var st: Int32 = 0
            _ = waitpid(p, &st, 0)
        }
        let group = ProcessGroup()
        try group.attach(pid: UInt32(p))
        scope.register(group)
        #expect(scope.liveCount == 0)
        #expect(await childDied(p))
        #endif
    }

    @Test("WSL detection pure helper")
    func wslDetection() {
        #expect(isWSL(environment: ["WSL_DISTRO_NAME": "Ubuntu"], osRelease: nil))
        #expect(isWSL(environment: ["WSL_INTEROP": "/run/WSL/8_interop"], osRelease: nil))
        #expect(isWSL(environment: [:], osRelease: "5.15.167.4-microsoft-standard-WSL2\n"))
        #expect(isWSL(environment: [:], osRelease: "4.4.0-19041-Microsoft\n"))
        #expect(isWSL(environment: [:], osRelease: "WSLg-experimental\n"))
        #expect(!isWSL(environment: [:], osRelease: "6.5.0-21-generic\n"))
        #expect(!isWSL(environment: [:], osRelease: nil))
        #expect(!isWSL(
            environment: ["MY_WSLISH_VAR": "1", "OTHER": "wsl_in_value"],
            osRelease: "6.5.0-21-generic\n"
        ))
    }

    @Test("dupTUIStderr returns writable handle")
    func dupStderrWritable() throws {
        let fh = try dupTUIStderr()
        try fh.write(contentsOf: Data())
    }

    #if os(macOS) || os(Linux)
    /// posix_spawn-based sleeper in its own process group (no fork — unavailable in Swift on Apple).
    private func spawnSleeper() throws -> pid_t {
        var actions = posix_spawn_file_actions_t(bitPattern: 0)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        var attrs = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }

        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attrs, 0)

        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("/bin/sleep"),
            strdup("60"),
            nil,
        ]
        defer {
            for p in argv {
                if let p { free(p) }
            }
        }

        // Minimal env so the child does not inherit interactive TTY prompts.
        var envp: [UnsafeMutablePointer<CChar>?] = [
            strdup("PATH=/usr/bin:/bin"),
            nil,
        ]
        defer {
            for p in envp {
                if let p { free(p) }
            }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/sleep", &actions, &attrs, &argv, &envp)
        guard rc == 0 else {
            throw TTYError.ioFailed("posix_spawn sleep failed: \(String(cString: strerror(rc)))")
        }
        return pid
    }

    private func childDied(_ pid: pid_t) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            var status: Int32 = 0
            let rc = waitpid(pid, &status, WNOHANG)
            if rc == pid { return true }
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    /// Open a PTY pair so raw-mode tests do not require an interactive stdin.
    private func withPTYPair(_ body: (Int32, Int32) async throws -> Void) async throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        // Prefer openpty when present (macOS / libutil).
        #if os(macOS)
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw TTYError.ioFailed("openpty failed: \(String(cString: strerror(errno)))")
        }
        #else
        // Linux: posix_openpt path
        master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0 else {
            if master >= 0 { close(master) }
            throw TTYError.ioFailed("posix_openpt failed")
        }
        guard let name = ptsname(master) else {
            close(master)
            throw TTYError.ioFailed("ptsname failed")
        }
        slave = open(name, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            close(master)
            throw TTYError.ioFailed("open slave failed")
        }
        #endif
        defer {
            close(master)
            close(slave)
        }
        try await body(master, slave)
    }

    private func termiosMatches(_ a: termios, _ b: termios) -> Bool {
        // PENDIN is a kernel-managed status bit and may be set after restoring
        // canonical mode on a PTY even though the configured local flags match.
        let stableLocalMask = ~tcflag_t(PENDIN)
        return a.c_iflag == b.c_iflag
            && a.c_oflag == b.c_oflag
            && a.c_cflag == b.c_cflag
            && (a.c_lflag & stableLocalMask) == (b.c_lflag & stableLocalMask)
    }

    private func termiosSummary(_ value: termios) -> String {
        "iflag=\(value.c_iflag) oflag=\(value.c_oflag) cflag=\(value.c_cflag) lflag=\(value.c_lflag)"
    }
    #endif
}
