import Foundation
import Testing
@testable import OpenGrokShellBase

@Suite("OpenGrok shell quoting and preparation")
struct OpenGrokShellPreparationTests {
    @Test("POSIX quoting preserves apostrophes and empty arguments")
    func posixQuoting() {
        #expect(ShellQuoting.posix("") == "''")
        #expect(ShellQuoting.posix("it's ready") == "'it'\\''s ready'")
    }

    @Test("PowerShell and cmd quoting use their native escape rules")
    func platformQuoting() {
        #expect(ShellQuoting.powerShell("a'b") == "'a''b'")
        #expect(ShellQuoting.cmd("a b") == "\"a b\"")
        #expect(ShellQuoting.cmd("a") == "a")
    }

    #if os(Windows)
    @Test("Windows defaults to PowerShell and resolves it through Path")
    func windowsPowerShellSelection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("powershell.EXE")
        try Data().write(to: executable)
        let environment = [
            "ComSpec": #"C:\Windows\System32\cmd.exe"#,
            "Path": directory.path,
            "PATHEXT": ".EXE;.CMD",
        ]

        #expect(ShellKind.detect(environment: environment) == .powerShell)
        #expect(
            ShellKind.powerShell.binaryPath(environment: environment).lowercased()
                == executable.path.lowercased()
        )
    }
    #endif

    @Test("Preparation resolves relative cwd and applies control environment last")
    func preparation() throws {
        let base = URL(fileURLWithPath: "/workspace/project")
        let prepared = try ShellCommandPreparation.prepare(
            command: "printf '%s' \"$GROK_AGENT\"",
            shell: .bash,
            requestedWorkingDirectory: "Sources",
            baseWorkingDirectory: base,
            inheritedEnvironment: ["PATH": "/bin", "API_TOKEN": "inherited"],
            requestEnvironment: ["GROK_AGENT": "0", "CUSTOM": "value"]
        )

        #expect(URL(fileURLWithPath: prepared.executable).lastPathComponent == "bash")
        #expect(prepared.arguments == ["-lc", "printf '%s' \"$GROK_AGENT\""])
        #expect(prepared.workingDirectory.path == "/workspace/project/Sources")
        #expect(prepared.environment["GROK_AGENT"] == "1")
        #expect(prepared.environment["CUSTOM"] == "value")
        #expect(prepared.environment["TERM"] == "dumb")
    }

    @Test("Environment policy filters secret names case insensitively")
    func environmentPolicy() {
        let policy = ShellEnvironmentPolicy(
            inherit: .core,
            ignoreDefaultExcludes: false,
            exclude: ["AWS_*"]
        )
        let environment = ShellEnvironmentBuilder.make(
            inherited: ["PATH": "/bin", "HOME": "/home/test", "AWS_SECRET": "secret", "OTHER": "value"],
            request: ["aws_region": "us-east-1", "CUSTOM": "value"],
            policy: policy,
            overrides: [:]
        )

        #expect(environment["PATH"] == "/bin")
        #if os(Windows)
        #expect(environment["HOME"] == nil)
        #else
        #expect(environment["HOME"] == "/home/test")
        #endif
        #expect(environment["AWS_SECRET"] == nil)
        #expect(environment["aws_region"] == nil)
        #expect(environment["CUSTOM"] == "value")
    }

    @Test("Working directory rejects NUL and non-directory paths")
    func workingDirectory() throws {
        #expect(throws: ShellWorkingDirectoryError.self) {
            try ShellWorkingDirectory.resolve(requested: "bad\0path", relativeTo: URL(fileURLWithPath: "/tmp"))
        }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("file".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: ShellWorkingDirectoryError.self) {
            try ShellWorkingDirectory.validate(file)
        }
    }
}

@Suite("OpenGrok shell output and lifecycle")
struct OpenGrokShellLifecycleTests {
    @Test("Output accumulator retains the newest bounded UTF-8 bytes")
    func outputAccumulator() {
        var accumulator = ShellOutputAccumulator(limit: 5)
        let event = accumulator.append(Data("one".utf8), channel: .stdout, taskID: "task")
        #expect(event == .output(taskID: "task", channel: .stdout, data: Data("one".utf8), sequence: 0))
        _ = accumulator.append(Data("two".utf8), channel: .stderr, taskID: "task")

        #expect(accumulator.truncated)
        #expect(accumulator.totalBytes == 6)
        #expect(String(decoding: accumulator.combinedData, as: UTF8.self) == "netwo")
        #expect(accumulator.nextSequence == 2)
    }

    @Test("Timeout mapping is deterministic and clears completion status")
    func timeoutMapping() {
        let started = Date(timeIntervalSince1970: 100)
        let ended = Date(timeIntervalSince1970: 125)
        let result = ShellCommandResult(
            combinedOutput: "partial",
            exitCode: 0,
            startedAt: started,
            endedAt: started
        )
        let mapped = ShellResultMapping.applying(.timeout, to: result, endedAt: ended)

        #expect(mapped.exitCode == nil)
        #expect(mapped.timedOut)
        #expect(!mapped.cancelled)
        #expect(mapped.signal == "SIGTERM")
        #expect(mapped.terminationReason == .timeout)
        #expect(mapped.endedAt == ended)
    }

    @Test("Lifecycle stream replays ordered events and completes once")
    func lifecycleStream() async throws {
        let lifecycle = ShellProcessLifecycle()
        let cwd = URL(fileURLWithPath: "/tmp")
        let request = ShellCommandRequest(command: "echo hi", workingDirectory: cwd)
        _ = try await lifecycle.register(request: request, taskID: "task", startedAt: Date(timeIntervalSince1970: 10))
        try await lifecycle.transition(taskID: "task", to: .running)
        try await lifecycle.appendOutput(taskID: "task", channel: .stdout, data: Data("hi\n".utf8), sequence: 0)
        let result = ShellCommandResult(
            combinedOutput: "hi\n",
            stdout: "hi\n",
            exitCode: 0,
            taskID: "task",
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 11)
        )
        try await lifecycle.complete(taskID: "task", result: result)

        let stream = lifecycle.outputStream(taskID: "task")
        var events: [ShellOutputEvent] = []
        for try await event in stream {
            events.append(event)
        }

        #expect(events.count == 6)
        #expect(events.first == .started(taskID: "task", processID: nil, timestamp: Date(timeIntervalSince1970: 10)))
        #expect(events[1] == .stateChanged(taskID: "task", state: .starting))
        #expect(events[2] == .stateChanged(taskID: "task", state: .running))
        #expect(events[3] == .output(taskID: "task", channel: .stdout, data: Data("hi\n".utf8), sequence: 0))
        #expect(events[4] == .stateChanged(taskID: "task", state: .completed))
        #expect(events[5] == .completed(taskID: "task", result: result))
    }

    @Test("Capability seam reports unsupported features explicitly")
    func capabilities() throws {
        let capabilities = ShellCapabilities(platform: "test", supported: [.processExecution])
        #expect(capabilities.supports(.processExecution))
        #expect(!capabilities.supports(.pseudoTerminal))
        #expect(throws: UnsupportedShellCapabilityError.self) {
            try capabilities.require(.pseudoTerminal)
        }
    }
}
