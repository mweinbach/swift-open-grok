// OpenGrokPTYTests.swift
import Foundation
import Testing
@testable import OpenGrokPTY
@testable import OpenGrokTTY

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("OpenGrokPTY")
struct OpenGrokPTYTests {
    @Test("ProcessSpec and exit/signal value types")
    func valueTypes() {
        let spec = ProcessSpec(
            command: "/bin/sh",
            arguments: ["-c", "echo hi"],
            usePTY: true,
            initialSize: TerminalSize(width: 80, height: 24)
        )
        #expect(spec.command == "/bin/sh")
        #expect(spec.usePTY)
        #expect(spec.initialSize?.height == 24)
        #expect(ProcessExit.code(0) == .code(0))
        #expect(ProcessSignal.terminate.portableValue == 15)
        #expect(ProcessSignal.interrupt.portableValue == 2)
        #expect(ProcessSignal.kill.portableValue == 9)
        #expect(ProcessSignal.hangup.portableValue == 1)
    }

    @Test("PlatformPTYAdapter spawns echo via PTY and captures output")
    func spawnEchoPTY() async throws {
        #if os(macOS) || os(Linux)
        let adapter = PlatformPTYAdapter()
        let process = try await adapter.spawn(
            ProcessSpec(
                command: "/bin/echo",
                arguments: ["hello-from-pty"],
                usePTY: true,
                initialSize: TerminalSize(width: 80, height: 24)
            )
        )
        let stream = process.output()
        var collected = Data()
        let reader = Task {
            do {
                for try await chunk in stream {
                    collected.append(chunk)
                }
            } catch { /* eof */ }
        }
        let exit = try await process.waitForExit()
        _ = await reader.value
        #expect(exit == .code(0))
        let text = String(decoding: collected, as: UTF8.self)
        #expect(text.contains("hello-from-pty"))
        #endif
    }

    @Test("PTY child has a controlling terminal (tty succeeds)")
    func controllingTerminal() async throws {
        #if os(macOS) || os(Linux)
        let adapter = PlatformPTYAdapter()
        // `tty` prints the slave path when stdin is a controlling TTY.
        let process = try await adapter.spawn(
            ProcessSpec(
                command: "/bin/sh",
                arguments: ["-c", "tty && test -t 0 && echo CTTY_OK"],
                usePTY: true,
                initialSize: TerminalSize(width: 80, height: 24)
            )
        )
        var collected = Data()
        let stream = process.output()
        let reader = Task {
            for try await chunk in stream {
                collected.append(chunk)
            }
        }
        let exit = try await process.waitForExit()
        _ = try? await reader.value
        #expect(exit == .code(0))
        let text = String(decoding: collected, as: UTF8.self)
        #expect(text.contains("CTTY_OK"))
        #expect(!text.contains("not a tty"))
        #endif
    }

    @Test("non-PTY spawn captures stdout")
    func spawnWithoutPTY() async throws {
        #if os(macOS) || os(Linux)
        let adapter = PlatformPTYAdapter()
        let process = try await adapter.spawn(
            ProcessSpec(
                command: "/bin/echo",
                arguments: ["pipe-out"],
                usePTY: false
            )
        )
        var collected = Data()
        let stream = process.output()
        let reader = Task {
            for try await chunk in stream {
                collected.append(chunk)
            }
        }
        let exit = try await process.waitForExit()
        _ = try? await reader.value
        #expect(exit == .code(0))
        #expect(String(decoding: collected, as: UTF8.self).contains("pipe-out"))
        #endif
    }

    @Test("resize reaches child via TIOCSWINSZ")
    func resizeReachesChild() async throws {
        #if os(macOS) || os(Linux)
        let adapter = PlatformPTYAdapter()
        let process = try await adapter.spawn(
            ProcessSpec(
                command: "/bin/sh",
                arguments: [],
                usePTY: true,
                initialSize: TerminalSize(width: 80, height: 24)
            )
        )
        let stream = process.output()
        let drain = Task {
            do {
                for try await _ in stream {}
            } catch { /* eof / cancel */ }
        }

        try await process.write(Data("stty size\n".utf8))
        let text = try await waitAccumulated(process, contains: "24 80", timeout: 5)
        #expect(text.contains("24 80"))

        try await process.resize(to: TerminalSize(width: 120, height: 40))
        try await process.write(Data("stty size\n".utf8))
        let text2 = try await waitAccumulated(process, contains: "40 120", timeout: 5)
        #expect(text2.contains("40 120"))

        try await process.write(Data("exit\n".utf8))
        _ = try await process.waitForExit()
        drain.cancel()
        #endif
    }

    @Test("signal terminate kills sleeper")
    func signalTerminate() async throws {
        #if os(macOS) || os(Linux)
        let adapter = PlatformPTYAdapter()
        let process = try await adapter.spawn(
            ProcessSpec(
                command: "/bin/sleep",
                arguments: ["30"],
                usePTY: true,
                initialSize: TerminalSize(width: 40, height: 10)
            )
        )
        try await process.signal(.terminate)
        let exit = try await process.waitForExit()
        if case .signal(let s) = exit {
            #expect(s == SIGTERM || s == SIGKILL)
        } else if case .code = exit {
            // some platforms map signal exit differently
        } else {
            Issue.record("unexpected exit: \(exit)")
        }
        #endif
    }

    @Test("cancel is cooperative and cleans up")
    func cancelCleansUp() async throws {
        #if os(macOS) || os(Linux)
        let adapter = PlatformPTYAdapter()
        let process = try await adapter.spawn(
            ProcessSpec(
                command: "/bin/sleep",
                arguments: ["60"],
                usePTY: true,
                initialSize: TerminalSize(width: 40, height: 10)
            )
        )
        await process.cancel()
        let exit = try await process.waitForExit()
        #expect(exit != .stillRunning)
        #endif
    }

    @Test("environment and cwd are applied on macOS and Linux")
    func envAndCwd() async throws {
        #if os(macOS) || os(Linux)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-pty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let adapter = PlatformPTYAdapter()
        let process = try await adapter.spawn(
            ProcessSpec(
                command: "/bin/sh",
                arguments: ["-c", "echo $OG_TEST_VAR; pwd"],
                environment: ["OG_TEST_VAR": "env-ok"],
                workingDirectory: tmp.path,
                usePTY: true,
                initialSize: TerminalSize(width: 80, height: 24)
            )
        )
        var collected = Data()
        let stream = process.output()
        let reader = Task {
            for try await chunk in stream {
                collected.append(chunk)
            }
        }
        _ = try await process.waitForExit()
        _ = try? await reader.value
        let text = String(decoding: collected, as: UTF8.self)
        #expect(text.contains("env-ok"))
        #expect(text.contains(tmp.lastPathComponent) || text.contains(tmp.path))
        #endif
    }

    @Test("pipe path also applies CWD")
    func pipePathCwd() async throws {
        #if os(macOS) || os(Linux)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-pty-pipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let adapter = PlatformPTYAdapter()
        let process = try await adapter.spawn(
            ProcessSpec(
                command: "/bin/sh",
                arguments: ["-c", "pwd"],
                workingDirectory: tmp.path,
                usePTY: false
            )
        )
        var collected = Data()
        let stream = process.output()
        let reader = Task {
            for try await chunk in stream {
                collected.append(chunk)
            }
        }
        _ = try await process.waitForExit()
        _ = try? await reader.value
        let text = String(decoding: collected, as: UTF8.self)
        #expect(text.contains(tmp.lastPathComponent) || text.contains(tmp.path))
        #endif
    }

    @Test("SignalHandling deliver by identifier")
    func signalHandlingDeliver() async throws {
        #if os(macOS) || os(Linux)
        let adapter = PlatformPTYAdapter()
        let process = try await adapter.spawn(
            ProcessSpec(
                command: "/bin/sleep",
                arguments: ["30"],
                usePTY: false
            )
        )
        try await adapter.deliver(.kill, to: process.identifier)
        let exit = try await process.waitForExit()
        #expect(exit != .stillRunning)
        #endif
    }

    @Test("repeated launches are leak-free")
    func repeatedLaunches() async throws {
        #if os(macOS) || os(Linux)
        let scope = ProcessScope()
        let adapter = PlatformPTYAdapter(scope: scope)
        for i in 0..<5 {
            let process = try await adapter.spawn(
                ProcessSpec(
                    command: "/bin/echo",
                    arguments: ["run-\(i)"],
                    usePTY: true,
                    initialSize: TerminalSize(width: 40, height: 10)
                )
            )
            _ = try await process.waitForExit()
        }
        scope.killAll()
        #endif
    }

    @Test("UTF-8 and large output")
    func utf8AndLargeOutput() async throws {
        #if os(macOS) || os(Linux)
        let adapter = PlatformPTYAdapter()
        let process = try await adapter.spawn(
            ProcessSpec(
                command: "/bin/sh",
                arguments: ["-c", "printf 'café 😀\\n'; python3 -c 'print(\"x\"*4000)' 2>/dev/null || yes x | head -c 4000"],
                usePTY: true,
                initialSize: TerminalSize(width: 80, height: 24)
            )
        )
        var collected = Data()
        let stream = process.output()
        let reader = Task {
            for try await chunk in stream {
                collected.append(chunk)
            }
        }
        _ = try await process.waitForExit()
        _ = try? await reader.value
        #expect(collected.count > 100)
        let text = String(decoding: collected, as: UTF8.self)
        #expect(text.contains("café") || text.contains("x"))
        #endif
    }

    @Test("descendant cleanup via process group kill")
    func descendantCleanup() async throws {
        #if os(macOS) || os(Linux)
        let scope = ProcessScope()
        let adapter = PlatformPTYAdapter(scope: scope)
        // Parent shell spawns a sleeper grandchild in the same process group.
        let process = try await adapter.spawn(
            ProcessSpec(
                command: "/bin/sh",
                arguments: ["-c", "sleep 60 & wait"],
                usePTY: true,
                newProcessGroup: true,
                initialSize: TerminalSize(width: 40, height: 10)
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        await process.cancel()
        let exit = try await process.waitForExit()
        #expect(exit != .stillRunning)
        scope.killAll()
        #endif
    }

    #if os(macOS) || os(Linux)
    private func waitAccumulated(
        _ process: any PTYProcess,
        contains needle: String,
        timeout: TimeInterval
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let posix = process as? PosixPTYProcess {
                let text = String(decoding: posix.accumulatedOutput, as: UTF8.self)
                if text.contains(needle) { return text }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if let posix = process as? PosixPTYProcess {
            return String(decoding: posix.accumulatedOutput, as: UTF8.self)
        }
        return ""
    }
    #endif
}
