import Foundation
import OpenGrokCodeMode
import OpenGrokCodeModeProtocol
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import Testing

@testable import OpenGrokCLI

@Suite("Live Codex Code Mode provider and nested-tool parity")
struct LiveCodexCodeModeParityTests {
    private func tool(_ name: String, description: String = "tool") -> ToolSpec {
        ToolSpec(
            name: name,
            description: description,
            parameters: .object(["type": .string("object")])
        )
    }

    @Test("Codex publishes native custom exec while xAI keeps the JSON function envelope")
    func providerNativeCodeModeSurfaces() throws {
        let ordinary = [tool("read_file"), tool("swarm_wait"), tool("apply_patch")]
        let codex = LiveCodeModeToolSurface(mode: .codeModeOnly, baseTools: ordinary, provider: .codex)
        let xai = LiveCodeModeToolSurface(mode: .codeModeOnly, baseTools: ordinary, provider: .xai)

        #expect(codex.modelTools.map(\.name) == ["swarm_wait", "wait"])
        #expect(codex.hostedTools.count == 1)
        guard case .clientCustom(let native)? = codex.hostedTools.first else {
            Issue.record("Codex must expose a native custom exec tool")
            return
        }
        #expect(native.name == "exec")
        #expect(native.format == .grammar)
        #expect(native.description?.contains("Accepts raw JavaScript source text, not JSON") == true)
        #expect(native.description?.contains("swarm_wait") == false)
        #expect(native.description?.contains("apply_patch(input: string)") == true)

        #expect(xai.modelTools.map(\.name) == ["swarm_wait", "exec", "wait"])
        #expect(xai.hostedTools.isEmpty)
        let function = try #require(xai.modelTools.first { $0.name == "exec" })
        #expect(function.parameters["required"] == .array([.string("source")]))
        #expect(function.description?.contains("Accepts raw JavaScript source text, not JSON") == false)
        #expect(function.description?.contains(#"`{"source":"<raw JavaScript>"}`"#) == true)
    }

    @Test("normalized JavaScript names deduplicate stably and retain the original dispatch key")
    func normalizedCollisionKeepsFirstRegisteredTool() throws {
        let first = tool("foo-bar", description: "FIRST_COLLISION_WINNER")
        let second = tool("foo_bar", description: "SECOND_COLLISION_SHADOW")

        for mode in [ToolModePreference.codeMode, .codeModeOnly] {
            let surface = LiveCodeModeToolSurface(mode: mode, baseTools: [first, second], provider: .codex)
            #expect(surface.snapshot.tools.count == 1)
            #expect(surface.snapshot.tools[0].name == "foo_bar")
            #expect(surface.snapshot.tools[0].toolName.name == "foo-bar")
            #expect(surface.snapshot.tools[0].description == "FIRST_COLLISION_WINNER")
            #expect(surface.snapshot.globalNames == ["foo_bar"])

            if mode == .codeModeOnly,
               case .clientCustom(let native)? = surface.hostedTools.first {
                #expect(native.description?.contains("FIRST_COLLISION_WINNER") == true)
                #expect(native.description?.contains("SECOND_COLLISION_SHADOW") == false)
            }
        }

        let reversed = LiveCodeModeToolSurface(
            mode: .codeModeOnly,
            baseTools: [second, first],
            provider: .codex
        )
        #expect(reversed.snapshot.tools[0].toolName.name == "foo_bar")
        #expect(reversed.snapshot.tools[0].description == "SECOND_COLLISION_SHADOW")
    }

    @Test("exec accepts only the active provider's native or function call shape")
    func execRejectsCrossProviderTransportShapes() throws {
        let source = "const answer = 40 + 2;\ntext(answer);"
        let native = ToolCall.custom(
            callId: "call-exec",
            itemId: "ctc-exec",
            name: "exec",
            input: source
        )
        let encoded = try JSONEncoder().encode(JSONValue.object(["source": .string(source)]))
        let function = ToolCall(
            id: "call-function",
            name: "exec",
            arguments: String(decoding: encoded, as: UTF8.self)
        )

        #expect(LiveCodeModeCoordinator.execSource(native, provider: .codex) == source)
        #expect(LiveCodeModeCoordinator.execSource(function, provider: .codex) == nil)
        #expect(LiveCodeModeCoordinator.execSource(function, provider: .xai) == source)
        #expect(LiveCodeModeCoordinator.execSource(native, provider: .xai) == nil)
    }

    @Test("freeform apply_patch retains its exact raw payload in the canonical function envelope")
    func freeformPatchArgumentsUseCanonicalSchema() throws {
        let raw = "*** Begin Patch\n*** Add File: example.txt\n+hello\n*** End Patch"
        let invocation = CodeModeNestedToolCall(
            cellId: CellId("cell"),
            runtimeToolCallId: "nested",
            toolName: .plain("apply_patch"),
            toolKind: .freeform,
            input: .string(raw)
        )

        let encoded = try LiveCodeModeNestedExecutor.argumentsJSON(for: invocation).get()
        let arguments = try JSONDecoder().decode(JSONValue.self, from: Data(encoded.utf8))
        #expect(arguments == .object(["patch": .string(raw)]))
    }

    @Test("freeform and function calls reject incompatible argument shapes")
    func malformedNestedArgumentsFailClosed() {
        let malformedPatch = CodeModeNestedToolCall(
            cellId: CellId("cell"),
            runtimeToolCallId: "nested",
            toolName: .plain("apply_patch"),
            toolKind: .freeform,
            input: .object(["patch": .string("should stay a bare string")])
        )
        let malformedFunction = CodeModeNestedToolCall(
            cellId: CellId("cell"),
            runtimeToolCallId: "nested",
            toolName: .plain("read_file"),
            toolKind: .function,
            input: .string("not an object")
        )

        guard case .failure(let patchError) = LiveCodeModeNestedExecutor.argumentsJSON(for: malformedPatch),
              case .failure(let functionError) = LiveCodeModeNestedExecutor.argumentsJSON(for: malformedFunction) else {
            Issue.record("incompatible nested inputs must fail before dispatch")
            return
        }
        #expect(patchError.message.contains("expects a string"))
        #expect(functionError.message.contains("expects a JSON object"))
    }
}

#if canImport(JavaScriptCore)

private struct CodexCodeModeWorkspace {
    let root: URL
    let environment: [String: String]

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-codex-code-mode-\(UUID().uuidString)")
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

@Suite("Live freeform apply_patch traverses the real authorization gate", .serialized)
struct LiveCodeModeFreeformPatchExecutionTests {
    private func execCall(_ source: String) throws -> ToolCall {
        let encoded = try JSONEncoder().encode(JSONValue.object(["source": .string(source)]))
        return ToolCall(id: "outer-patch", name: "exec", arguments: String(decoding: encoded, as: UTF8.self))
    }

    private func javascriptString(_ value: String) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    @Test("a live Codex coordinator executes raw custom input and rejects a function-shaped exec")
    func codexNativeExecRunsThroughThePersistentRuntime() async throws {
        let workspace = try CodexCodeModeWorkspace()
        defer { workspace.cleanup() }
        let backend = LocalShellProcessBackend(inheritedEnvironment: workspace.environment)
        let executor = try await LiveToolExecutor(
            processBackend: backend,
            sessionID: "codex-live-native-exec",
            workingDirectory: workspace.root,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: workspace.environment
        )
        let coordinator = LiveCodeModeCoordinator(
            surface: LiveCodeModeToolSurface(
                mode: .codeMode,
                baseTools: executor.currentToolSpecs(),
                provider: .codex
            ),
            toolExecutor: executor,
            sessionID: "codex-live-native-exec",
            workingDirectory: workspace.root
        )
        await coordinator.beginTurn { _ in }

        let native = await coordinator.handleTransportCall(ToolCall.custom(
            callId: "codex-native-call",
            itemId: "codex-native-item",
            name: "exec",
            input: "text('NATIVE_OK:' + (40 + 2))"
        ))
        #expect(native.toolCallId == "codex-native-call")
        #expect(native.content.contains("NATIVE_OK:42"))

        let wrongTransport = await coordinator.handleTransportCall(
            try execCall("text('FUNCTION_MUST_NOT_EXECUTE')")
        )
        #expect(wrongTransport.content.contains("native custom call"))
        #expect(!wrongTransport.content.contains("FUNCTION_MUST_NOT_EXECUTE"))

        await coordinator.shutdown()
        await executor.shutdown()
        await backend.killAllBackgroundTasks()
    }

    @Test("authorized raw apply_patch creates the requested file through the live registry")
    func authorizedFreeformPatchChangesDisk() async throws {
        let workspace = try CodexCodeModeWorkspace()
        defer { workspace.cleanup() }
        let backend = LocalShellProcessBackend(inheritedEnvironment: workspace.environment)
        let executor = try await LiveToolExecutor(
            processBackend: backend,
            sessionID: "codex-live-freeform-patch",
            workingDirectory: workspace.root,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: workspace.environment
        )
        let surface = LiveCodeModeToolSurface(mode: .codeMode, baseTools: executor.currentToolSpecs())
        let definition = try #require(surface.snapshot.tools.first { $0.toolName.name == "apply_patch" })
        #expect(definition.kind == .freeform)
        #expect(definition.inputSchema == nil)

        let coordinator = LiveCodeModeCoordinator(
            surface: surface,
            toolExecutor: executor,
            sessionID: "codex-live-freeform-patch",
            workingDirectory: workspace.root
        )
        await coordinator.beginTurn { _ in }
        let patch = "*** Begin Patch\n*** Add File: authorized.txt\n+created by nested code\n*** End Patch"
        let source = "const result = await tools.apply_patch(\(try javascriptString(patch))); text(JSON.stringify(result));"
        let result = await coordinator.handleTransportCall(try execCall(source))

        let written = try String(
            contentsOf: workspace.root.appendingPathComponent("authorized.txt"),
            encoding: .utf8
        )
        #expect(written == "created by nested code\n")
        #expect(result.content.contains("authorized.txt"))

        await coordinator.shutdown()
        await executor.shutdown()
        await backend.killAllBackgroundTasks()
    }

    @Test("permission-denied raw apply_patch never writes outside the gate")
    func deniedFreeformPatchCannotModifyDisk() async throws {
        let workspace = try CodexCodeModeWorkspace()
        defer { workspace.cleanup() }
        let backend = LocalShellProcessBackend(inheritedEnvironment: workspace.environment)
        let executor = try await LiveToolExecutor(
            processBackend: backend,
            sessionID: "codex-denied-freeform-patch",
            workingDirectory: workspace.root,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .denyMutations,
            environment: workspace.environment
        )
        let coordinator = LiveCodeModeCoordinator(
            surface: LiveCodeModeToolSurface(mode: .codeMode, baseTools: executor.currentToolSpecs()),
            toolExecutor: executor,
            sessionID: "codex-denied-freeform-patch",
            workingDirectory: workspace.root
        )
        await coordinator.beginTurn { _ in }
        let patch = "*** Begin Patch\n*** Add File: forbidden.txt\n+not allowed\n*** End Patch"
        let source = "try { await tools.apply_patch(\(try javascriptString(patch))); text('UNEXPECTED'); } "
            + "catch (error) { text('DENIED:' + String(error)); }"
        let result = await coordinator.handleTransportCall(try execCall(source))

        #expect(result.content.contains("DENIED:"))
        #expect(!result.content.contains("UNEXPECTED"))
        #expect(!FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("forbidden.txt").path))

        await coordinator.shutdown()
        await executor.shutdown()
        await backend.killAllBackgroundTasks()
    }
}

#endif
