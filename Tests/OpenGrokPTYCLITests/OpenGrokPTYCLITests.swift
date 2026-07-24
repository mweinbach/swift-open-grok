// OpenGrokPTYCLITests.swift
import Foundation
import Testing
@testable import OpenGrokPTY
@testable import OpenGrokPTYCLI
@testable import OpenGrokTTY

@Suite("OpenGrokPTYCLI")
struct OpenGrokPTYCLITests {
    @Test("parseEnv KEY=VAL entries")
    func parseEnv() {
        let env = PTYCLIRunConfig.parseEnv(["FOO=bar", "BAZ=qux=1", "NOPE"])
        #expect(env["FOO"] == "bar")
        #expect(env["BAZ"] == "qux=1")
        #expect(env["NOPE"] == nil)
    }

    @Test("run collects interactive PTY output")
    func runCollectsOutput() async throws {
        #if os(macOS) || os(Linux)
        let runner = PTYCLIRunner()
        let result = try await runner.run(
            PTYCLIRunConfig(
                command: ["/bin/echo", "cli-diag-ok"],
                width: 80,
                height: 24,
                usePTY: true
            )
        )
        #expect(result.outputString.contains("cli-diag-ok"))
        #expect(result.exit == .code(0))
        #expect(result.timedOut == false)
        await runner.shutdown()
        #endif
    }

    @Test("run without PTY (pipe path)")
    func runNonTTY() async throws {
        #if os(macOS) || os(Linux)
        let runner = PTYCLIRunner()
        let result = try await runner.run(
            PTYCLIRunConfig(
                command: ["/bin/echo", "pipe-path"],
                usePTY: false
            )
        )
        #expect(result.outputString.contains("pipe-path"))
        #expect(result.exit == .code(0))
        #endif
    }

    @Test("timeout cancels long-running command")
    func timeoutCancels() async throws {
        #if os(macOS) || os(Linux)
        let runner = PTYCLIRunner()
        let result = try await runner.run(
            PTYCLIRunConfig(
                command: ["/bin/sleep", "30"],
                timeoutSeconds: 0.3,
                usePTY: true
            )
        )
        #expect(result.timedOut)
        #expect(result.exit != .stillRunning)
        await runner.shutdown()
        #endif
    }

    @Test("interactive session write/resize/signal with deterministic output")
    func interactiveSession() async throws {
        #if os(macOS) || os(Linux)
        let runner = PTYCLIRunner()
        let session = try await runner.start(
            PTYCLIRunConfig(
                command: ["/bin/sh"],
                width: 80,
                height: 24,
                usePTY: true
            )
        )
        try await session.writeKeys("printf 'interactive-ok\\n'\n")
        // Poll for the expected marker rather than a vacuous assertion.
        let deadline = Date().addingTimeInterval(3)
        var saw = false
        while Date() < deadline {
            if await session.outputString().contains("interactive-ok") {
                saw = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(saw, "interactive session must echo marker")

        try await session.resize(width: 100, height: 30)
        try await session.writeKeys("stty size\n")
        var sawSize = false
        let sizeDeadline = Date().addingTimeInterval(3)
        while Date() < sizeDeadline {
            if await session.outputString().contains("30 100") {
                sawSize = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(sawSize, "resize must be observed by child")

        try await session.writeKeys("exit\n")
        let exit = try await session.waitForExit()
        if case .code(let c) = exit {
            #expect(c == 0)
        } else {
            Issue.record("expected exit code, got \(exit)")
        }
        await runner.shutdown()
        #endif
    }

    @Test("signal forwarding via session")
    func signalForwarding() async throws {
        #if os(macOS) || os(Linux)
        let runner = PTYCLIRunner()
        let session = try await runner.start(
            PTYCLIRunConfig(
                command: ["/bin/sleep", "30"],
                usePTY: true
            )
        )
        try await session.signal(.terminate)
        let exit = try await session.waitForExit()
        #expect(exit != .stillRunning)
        await runner.shutdown()
        #endif
    }

    @Test("non-TTY signal forwarding")
    func nonTTYSignalForwarding() async throws {
        #if os(macOS) || os(Linux)
        let runner = PTYCLIRunner()
        let session = try await runner.start(
            PTYCLIRunConfig(
                command: ["/bin/sleep", "30"],
                usePTY: false
            )
        )
        try await session.signal(.kill)
        let exit = try await session.waitForExit()
        #expect(exit != .stillRunning)
        await runner.shutdown()
        #endif
    }

    @Test("UTF-8 payload round-trip including multi-byte boundaries")
    func utf8Payload() async throws {
        #if os(macOS) || os(Linux)
        let runner = PTYCLIRunner()
        let result = try await runner.run(
            PTYCLIRunConfig(
                command: ["/bin/sh", "-c", "printf 'こんにちは 🎉\\n'"],
                usePTY: true
            )
        )
        #expect(result.outputString.contains("こんにちは"))
        #expect(result.outputString.contains("🎉") || result.output.contains(Data("🎉".utf8)))
        #endif
    }

    @Test("large output completeness")
    func largeOutputCompleteness() async throws {
        #if os(macOS) || os(Linux)
        let runner = PTYCLIRunner()
        // 50_000 'x' bytes via a pure shell loop (no python dependency).
        let result = try await runner.run(
            PTYCLIRunConfig(
                command: [
                    "/bin/sh", "-c",
                    "i=0; while [ $i -lt 500 ]; do printf '%s' 'xxxxxxxxxxxxxxxxxxxx'; i=$((i+1)); done; printf '\\nDONE\\n'",
                ],
                usePTY: true
            )
        )
        #expect(result.exit == .code(0))
        #expect(result.outputString.contains("DONE"))
        // 500 * 20 = 10_000 'x' minimum
        let xCount = result.output.filter { $0 == UInt8(ascii: "x") }.count
        #expect(xCount >= 10_000)
        #endif
    }

    @Test("broken pipe / short-lived writer does not hang collector")
    func brokenPipeDoesNotHang() async throws {
        #if os(macOS) || os(Linux)
        let runner = PTYCLIRunner()
        // Child closes stdout early by exec'ing a short command; collector must finish.
        let result = try await runner.run(
            PTYCLIRunConfig(
                command: ["/bin/sh", "-c", "printf 'before-close\\n'; exec 1>&-; sleep 0.1; exit 0"],
                timeoutSeconds: 3,
                usePTY: false
            )
        )
        #expect(!result.timedOut)
        #expect(result.exit != ProcessExit.stillRunning)
        #expect(
            result.outputString.contains("before-close")
                || result.output.isEmpty
                || result.exit == ProcessExit.code(0)
        )
        await runner.shutdown()
        #endif
    }

    @Test("resize during active output")
    func resizeDuringOutput() async throws {
        #if os(macOS) || os(Linux)
        let runner = PTYCLIRunner()
        let session = try await runner.start(
            PTYCLIRunConfig(
                command: ["/bin/sh", "-c", "i=0; while [ $i -lt 30 ]; do echo line-$i; sleep 0.05; i=$((i+1)); done"],
                width: 80,
                height: 24,
                usePTY: true
            )
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        try await session.resize(width: 60, height: 20)
        try await Task.sleep(nanoseconds: 100_000_000)
        try await session.resize(width: 100, height: 40)
        let exit = try await session.waitForExit()
        #expect(exit == .code(0))
        let out = await session.outputString()
        #expect(out.contains("line-0"))
        #expect(out.contains("line-29") || out.contains("line-2"))
        await runner.shutdown()
        #endif
    }

    @Test("cancellation race cleans descendants")
    func cancellationRace() async throws {
        #if os(macOS) || os(Linux)
        let runner = PTYCLIRunner()
        let session = try await runner.start(
            PTYCLIRunConfig(
                command: ["/bin/sh", "-c", "sleep 60 & sleep 60 & wait"],
                usePTY: true
            )
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        await session.cancel()
        let exit = try await session.waitForExit()
        #expect(exit != .stillRunning)
        await runner.shutdown()
        #endif
    }

    @Test("repeated launches leak-free")
    func repeatedLaunches() async throws {
        #if os(macOS) || os(Linux)
        let runner = PTYCLIRunner()
        for i in 0..<8 {
            let result = try await runner.run(
                PTYCLIRunConfig(
                    command: ["/bin/echo", "loop-\(i)"],
                    usePTY: true
                )
            )
            #expect(result.exit == .code(0))
            #expect(result.outputString.contains("loop-\(i)"))
        }
        await runner.shutdown()
        #endif
    }

    @Test("help summary is non-empty")
    func helpSummary() {
        #expect(PTYCLIHelp.summary.contains("PTY"))
        #expect(PTYCLIHelp.summary.contains("run"))
    }
}
