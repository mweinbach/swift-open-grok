import Foundation
import OpenGrokShared
import OpenGrokToolRuntime
import OpenGrokWorkspace
@testable import OpenGrokToolRegistry
import Testing

private actor NestedMCPProgressLog {
    private var recorded: [ToolProgress] = []

    func append(_ value: ToolProgress) {
        recorded.append(value)
    }

    func values() -> [ToolProgress] {
        recorded
    }
}

private struct NestedStreamingMCPProvider: MCPToolProviding {
    let serverName = "streaming"
    let progress: [ToolProgress]

    func listBridgedTools() async throws -> [MCPBridgedTool] {
        [MCPBridgedTool(name: "inspect", description: "real provider progress")]
    }

    func callBridgedTool(name: String, arguments: JSONValue) async throws -> MCPBridgedCallResult {
        MCPBridgedCallResult(text: "terminal result")
    }

    func callBridgedTool(
        name: String,
        arguments: JSONValue,
        onProgress: @escaping ToolProgressHandler
    ) async throws -> MCPBridgedCallResult {
        for item in progress {
            await onProgress(item)
        }
        return MCPBridgedCallResult(text: "terminal result")
    }
}

@Suite("Nested MCP progress preserves typed provider events and authorization")
struct NestedMCPProgressTests {
    private func toolset(permissionPipeline: PermissionPipeline?) -> FinalizedToolset {
        FinalizedToolset(
            tools: [],
            resources: ToolResources(cwd: NSTemporaryDirectory(), permissionPipeline: permissionPipeline),
            codeModeNamespaces: [:],
            options: .unrestricted
        )
    }

    @Test("only genuine provider-originated typed progress reaches an opted-in caller")
    func providerProgressReachesAuthorizedNestedCall() async {
        let expected: [ToolProgress] = [
            .text(text: "actual status"),
            .content(blocks: [.text(text: "actual content")]),
            .custom(subkind: "server_update", payload: .object(["delta": .string("actual delta")])),
        ]
        let provider = NestedStreamingMCPProvider(progress: expected)
        let permissions = PermissionPipeline(permissions: PermissionHandle(
            allowAll: true,
            shellCwd: NSTemporaryDirectory()
        ))
        let active = toolset(permissionPipeline: permissions)
        let registration = await MCPToolBridge.register(provider: provider, into: active)
        #expect(registration.registeredNames == ["streaming__inspect"])

        let log = NestedMCPProgressLog()
        let result = await active.callNested(
            clientName: "streaming__inspect",
            args: .object([:]),
            viewerContext: WorkspaceViewerContext(streamToolProgress: true),
            onProgress: { await log.append($0) }
        )

        guard case .success(let terminal) = result else {
            Issue.record("authorized MCP call must retain its terminal result")
            return
        }
        #expect(terminal.value["content"] == .string("terminal result"))
        #expect(await log.values() == expected)
    }

    @Test("viewer opt-out and absent permission pipeline cannot emit provider progress")
    func optOutAndDeniedCallsEmitNothing() async {
        let provider = NestedStreamingMCPProvider(progress: [.text(text: "must stay hidden")])
        let permissions = PermissionPipeline(permissions: PermissionHandle(
            allowAll: true,
            shellCwd: NSTemporaryDirectory()
        ))
        let active = toolset(permissionPipeline: permissions)
        let activeRegistration = await MCPToolBridge.register(provider: provider, into: active)
        #expect(activeRegistration.registeredNames == ["streaming__inspect"])

        let log = NestedMCPProgressLog()
        let optedOut = await active.callNested(
            clientName: "streaming__inspect",
            args: .object([:]),
            viewerContext: WorkspaceViewerContext(streamToolProgress: false),
            onProgress: { await log.append($0) }
        )
        guard case .success = optedOut else {
            Issue.record("opting out of progress must preserve terminal MCP output")
            return
        }

        let ungated = toolset(permissionPipeline: nil)
        let deniedRegistration = await MCPToolBridge.register(provider: provider, into: ungated)
        #expect(deniedRegistration.registeredNames == ["streaming__inspect"])
        let denied = await ungated.callNested(
            clientName: "streaming__inspect",
            args: .object([:]),
            viewerContext: WorkspaceViewerContext(streamToolProgress: true),
            onProgress: { await log.append($0) }
        )
        guard case .failure(let error) = denied else {
            Issue.record("missing permission pipeline must deny remote dispatch")
            return
        }
        #expect(error.kind == .permissionDenied)
        #expect(await log.values().isEmpty)
    }
}
