import Foundation
import Testing
@testable import OpenGrokShellBase

@Suite("Local shell process backend")
struct LocalShellProcessBackendTests {
    @Test("foreground execution captures bounded output, environment, and output file")
    func foregroundExecution() async throws {
        #if os(Windows)
        let command = "echo stdout & echo stderr 1>&2 & echo %GROK_TEST_VALUE%"
        let shell: ShellKind = .cmd
        #else
        let command = "printf 'stdout'; printf 'stderr' >&2; printf '%s' \"$GROK_TEST_VALUE\""
        let shell: ShellKind = .sh
        #endif

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputFile = directory.appendingPathComponent("foreground.output")
        let backend = LocalShellProcessBackend()
        let result = try await backend.run(
            ShellCommandRequest(
                command: command,
                workingDirectory: directory,
                environment: ["GROK_TEST_VALUE": "environment-value"],
                outputByteLimit: 8,
                outputFile: outputFile,
                shell: shell
            )
        )

        #expect(result.exitCode == 0)
        #expect(result.truncated)
        #expect(result.totalBytes >= 8)
        #expect(result.outputFile == outputFile)
        #expect(result.combinedOutput.utf8.count <= 8)
        #expect(String(decoding: try Data(contentsOf: outputFile), as: UTF8.self).contains("stdout"))
    }

    @Test("background execution lists, streams, waits, and records ownership")
    func backgroundLifecycle() async throws {
        #if os(Windows)
        return
        #else
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = LocalShellProcessBackend()
        let handle = try await backend.runBackground(
            ShellCommandRequest(
                command: "printf 'background-output'",
                workingDirectory: directory,
                toolCallID: "call-background",
                ownerSessionID: "owner-a",
                shell: .sh
            )
        )

        let processHandle = await backend.processHandle(for: handle.taskID)
        #expect(processHandle != nil)
        let eventTask = Task<[ShellOutputEvent], Never> {
            guard let processHandle else { return [] }
            var events: [ShellOutputEvent] = []
            do {
                for try await event in processHandle.output() {
                    events.append(event)
                }
            } catch {
                return events
            }
            return events
        }

        let snapshot = await backend.waitForCompletion(handle.taskID, timeout: .seconds(5))
        let events = await eventTask.value
        #expect(snapshot?.completed == true)
        #expect(snapshot?.ownerSessionID == "owner-a")
        #expect(snapshot?.blockWaited == true)
        #expect(snapshot?.output == "background-output")
        #expect(events.contains { event in
            if case .output(taskID: handle.taskID, channel: .stdout, data: Data("background-output".utf8), sequence: 0) = event {
                return true
            }
            return false
        })
        #expect(await backend.killTask(handle.taskID) == .alreadyExited)
        #expect(await backend.listTasks().contains { $0.taskID == handle.taskID })
        #endif
    }

    @Test("rapid background exits always complete their lifecycle")
    func rapidBackgroundExitLifecycle() async throws {
        #if os(Windows)
        return
        #else
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = LocalShellProcessBackend(
            launchTransform: { executable, arguments in
                (executable, arguments)
            }
        )

        for index in 0..<32 {
            let handle = try await backend.runBackground(
                ShellCommandRequest(
                    command: "exit 0",
                    workingDirectory: directory,
                    toolCallID: "call-rapid-exit-\(index)",
                    shell: .sh
                )
            )
            let snapshot = await backend.waitForCompletion(handle.taskID, timeout: .seconds(2))
            #expect(snapshot?.completed == true)
            #expect(snapshot?.exitCode == 0)
        }
        #endif
    }

    @Test("owner cleanup kills only matching background tasks")
    func ownerCleanup() async throws {
        #if os(Windows)
        return
        #else
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = LocalShellProcessBackend()
        let owned = try await backend.runBackground(
            ShellCommandRequest(
                command: "sleep 30",
                workingDirectory: directory,
                ownerSessionID: "owner-a",
                shell: .sh
            )
        )
        let sibling = try await backend.runBackground(
            ShellCommandRequest(
                command: "sleep 30",
                workingDirectory: directory,
                ownerSessionID: "owner-b",
                shell: .sh
            )
        )

        await backend.killAllBackgroundTasks(ownerSessionID: "owner-a")
        let ownedSnapshot = await backend.waitForCompletion(owned.taskID, timeout: .seconds(5))
        let siblingSnapshot = await backend.getTask(sibling.taskID)
        #expect(ownedSnapshot?.completed == true)
        #expect(ownedSnapshot?.explicitlyKilled == true)
        #expect(siblingSnapshot?.completed == false)

        await backend.killAllBackgroundTasks()
        _ = await backend.waitForCompletion(sibling.taskID, timeout: .seconds(5))
        #expect(await backend.getTask(sibling.taskID)?.completed == true)
        #endif
    }

    @Test("foreground cancellation terminates the process and reports cancellation")
    func foregroundCancellation() async throws {
        #if os(Windows)
        return
        #else
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = LocalShellProcessBackend()
        let task = Task {
            try await backend.run(
                ShellCommandRequest(
                    command: "sleep 30",
                    workingDirectory: directory,
                    toolCallID: "call-cancel",
                    ownerSessionID: "owner-cancel",
                    shell: .sh
                )
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("cancelled foreground execution returned normally")
        } catch ShellError.cancelled {
        }

        let completed = await waitForTask(
            backend,
            ownerSessionID: "owner-cancel",
            timeout: .seconds(5)
        )
        #expect(completed?.completed == true)
        #expect(completed?.signal == "SIGTERM" || completed?.signal == "SIGKILL")
        #endif
    }

    @Test("foreground block budget moves work into the background")
    func foregroundAutoBackground() async throws {
        #if os(Windows)
        return
        #else
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = LocalShellProcessBackend()

        // The child blocks on a sentinel file this test creates rather than on
        // a fixed `sleep`. With a timed child, "still running when we snapshot
        // it" was a race the test lost whenever scheduling slipped past the
        // sleep — a load-sensitive flake. Gating on the sentinel makes the
        // still-running window last until the test chooses to end it, so the
        // `completed == false` assertion below proves what it always meant to:
        // the work really was handed to the background, not run to completion
        // in the foreground. The bounded loop is a safety net so a regression
        // fails the request timeout instead of hanging.
        let release = directory.appendingPathComponent("release")
        let command = """
            for _ in $(seq 1 400); do
              [ -f '\(release.path)' ] && break
              sleep 0.05
            done
            printf 'finished'
            """
        let result = try await backend.run(
            ShellCommandRequest(
                command: command,
                workingDirectory: directory,
                timeout: .seconds(30),
                toolCallID: "call-auto-background",
                autoBackgroundOnTimeout: true,
                foregroundBlockBudget: .milliseconds(50),
                ownerSessionID: "owner-background",
                shell: .sh
            )
        )

        #expect(result.backgrounded)
        #expect(result.taskID != nil)
        guard let taskID = result.taskID else { return }
        let running = await backend.getTask(taskID)
        #expect(running?.isBackgrounded == true)
        #expect(running?.completed == false)

        try Data().write(to: release)
        let completed = await backend.waitForCompletion(taskID, timeout: .seconds(30))
        #expect(completed?.completed == true)
        #expect(completed?.output == "finished")
        #endif
    }

    @Test("missing process capability fails closed")
    func unsupportedCapability() async throws {
        let backend = LocalShellProcessBackend(
            capabilities: ShellCapabilities(platform: "test", supported: [])
        )
        await #expect(throws: UnsupportedShellCapabilityError.self) {
            try await backend.run(ShellCommandRequest(command: "echo unavailable"))
        }
    }

    @Test("the process backend applies the sandbox launch transform")
    func appliesLaunchTransform() async throws {
        #if os(Windows)
        return
        #else
        let backend = LocalShellProcessBackend(
            launchTransform: { _, _ in
                ("/bin/sh", ["-c", "printf 'wrapped-launch'"])
            }
        )
        let result = try await backend.run(
            ShellCommandRequest(command: "printf 'unwrapped-launch'", shell: .sh)
        )
        #expect(result.combinedOutput == "wrapped-launch")
        #endif
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenGrokShellProcessBackend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitForTask(
        _ backend: LocalShellProcessBackend,
        ownerSessionID: String,
        timeout: ShellDuration
    ) async -> ShellTaskSnapshot? {
        let deadline = Date().addingTimeInterval(timeout.timeInterval)
        while Date() < deadline {
            if let snapshot = await backend.listTasks().first(where: {
                $0.ownerSessionID == ownerSessionID && $0.completed
            }) {
                return snapshot
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await backend.listTasks().first(where: { $0.ownerSessionID == ownerSessionID })
    }
}
