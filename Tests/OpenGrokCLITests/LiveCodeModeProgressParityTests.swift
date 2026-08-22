#if canImport(JavaScriptCore)

import Foundation
import OpenGrokCodeMode
import OpenGrokCodeModeProtocol
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import Testing

@testable import OpenGrokCLI

private struct CodeModeProgressWorkspace {
    let root: URL
    let environment: [String: String]

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-code-mode-progress-\(UUID().uuidString)")
        root = base.appendingPathComponent("workspace", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        let openGrokHome = home.appendingPathComponent(".opengrok", isDirectory: true)
        for directory in [root, home, openGrokHome] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": openGrokHome.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

private actor CodeModeProgressUpdateRecorder {
    private var updates: [OpenGrokShellTurnUpdateKind] = []

    func append(_ update: OpenGrokShellTurnUpdateKind) {
        updates.append(update)
    }

    func toolUpdates() -> [OpenGrokShellToolUpdate] {
        updates.compactMap { update in
            guard case .tool(let tool) = update else { return nil }
            return tool
        }
    }
}

private func codeModeProgressExecCall(source: String) throws -> ToolCall {
    let arguments = try JSONEncoder().encode(JSONValue.object(["source": .string(source)]))
    return ToolCall(
        id: "outer-code-mode-progress",
        name: "exec",
        arguments: String(decoding: arguments, as: UTF8.self)
    )
}

@Suite("Live Code Mode nested-tool progress parity", .serialized)
struct LiveCodeModeProgressParityTests {
    @Test("real terminal output reaches JavaScript handlers and nested running cards")
    func terminalProgressTraversesTheLiveDispatchPipeline() async throws {
        let workspace = try CodeModeProgressWorkspace()
        defer { workspace.cleanup() }

        let backend = LocalShellProcessBackend(inheritedEnvironment: workspace.environment)
        let executor = try await LiveToolExecutor(
            processBackend: backend,
            sessionID: "live-code-mode-progress",
            workingDirectory: workspace.root,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: workspace.environment,
            permissionOptions: CLIPermissionOptions(allowRules: ["Bash"])
        )
        let coordinator = LiveCodeModeCoordinator(
            surface: LiveCodeModeToolSurface(mode: .codeMode, baseTools: executor.tools),
            toolExecutor: executor,
            sessionID: "live-code-mode-progress",
            workingDirectory: workspace.root
        )
        let updates = CodeModeProgressUpdateRecorder()
        await coordinator.beginTurn { update in
            await updates.append(update)
        }

        let result = await coordinator.handleTransportCall(
            try codeModeProgressExecCall(source: """
                const pieces = [];
                const pending = tools.run_terminal_cmd({
                  command: "printf 'first\\n'; printf 'second\\n'"
                });
                pending.onProgress((chunk) => pieces.push(chunk.text));
                const result = await pending;
                text(JSON.stringify({ streamed: pieces.join(""), exitCode: result.exit_code }));
                """)
        )

        #expect(result.content.contains(#""streamed":"first\nsecond\n""#))
        #expect(result.content.contains(#""exitCode":0"#))

        let toolUpdates = await updates.toolUpdates()
        #expect(toolUpdates.allSatisfy { $0.name == "run_terminal_cmd" })
        let chunks = toolUpdates.filter { $0.state == .running && $0.output != nil }
        #expect(!chunks.isEmpty)
        #expect(chunks.map { $0.output ?? "" }.joined() == "first\nsecond\n")
        #expect(chunks.allSatisfy { $0.outputOp == .append })
        #expect(toolUpdates.last?.state == .succeeded)

        await coordinator.shutdown()
        await executor.shutdown()
        await backend.killAllBackgroundTasks()
    }

    @Test("denied nested shell commands emit no progress and never bypass authorization")
    func deniedCommandsCannotEmitProgress() async throws {
        let workspace = try CodeModeProgressWorkspace()
        defer { workspace.cleanup() }

        let backend = LocalShellProcessBackend(inheritedEnvironment: workspace.environment)
        let executor = try await LiveToolExecutor(
            processBackend: backend,
            sessionID: "live-code-mode-denied",
            workingDirectory: workspace.root,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: workspace.environment,
            permissionOptions: CLIPermissionOptions(denyRules: ["Bash"])
        )
        let coordinator = LiveCodeModeCoordinator(
            surface: LiveCodeModeToolSurface(mode: .codeMode, baseTools: executor.tools),
            toolExecutor: executor,
            sessionID: "live-code-mode-denied",
            workingDirectory: workspace.root
        )
        let updates = CodeModeProgressUpdateRecorder()
        await coordinator.beginTurn { update in
            await updates.append(update)
        }

        let result = await coordinator.handleTransportCall(
            try codeModeProgressExecCall(source: """
                const pending = tools.run_terminal_cmd({ command: "printf forbidden" });
                pending.onProgress((chunk) => text("LEAK:" + chunk.text));
                try {
                  await pending;
                } catch (error) {
                  text(String(error));
                }
                """)
        )

        #expect(!result.content.contains("LEAK:"))
        #expect(result.content.contains("run_terminal_cmd"))
        let toolUpdates = await updates.toolUpdates()
        #expect(toolUpdates.map(\.state) == [.running, .failed])
        #expect(toolUpdates.filter { $0.state == .running }.allSatisfy { $0.output == nil })

        await coordinator.shutdown()
        await executor.shutdown()
        await backend.killAllBackgroundTasks()
    }
}

#endif
