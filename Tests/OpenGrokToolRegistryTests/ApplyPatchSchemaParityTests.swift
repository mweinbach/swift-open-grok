import Foundation
import Testing
@testable import OpenGrokToolRegistry
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes
import OpenGrokWorkspace

@Suite("apply_patch canonical input schema parity")
struct ApplyPatchSchemaParityTests {
    @Test("built-in and model-facing schemas require exactly the Rust patch field")
    func catalogAdvertisesCanonicalPatchField() throws {
        let observer = ApplyPatchSchemaObserver()
        let toolset = try makeToolset(observer: observer)

        for schema in [
            BuiltinToolCatalog.applyPatchSchema,
            try #require(toolset.topLevelDefinitions().first?.argumentsSchema),
        ] {
            let object = try #require(schema.objectValue)
            let properties = try #require(object["properties"]?.objectValue)
            let required = try #require(object["required"]?.arrayValue)

            #expect(Set(properties.keys) == ["patch"])
            #expect(required == [.string("patch")])
        }
    }

    @Test("canonical and legacy aliases reach hooks and dispatch as patch only")
    func aliasesNormalizeBeforeAuthorization() async throws {
        let patch = "*** Begin Patch\n*** End Patch"
        let validArguments: [JSONValue] = [
            .object(["patch": .string(patch)]),
            .object(["input": .string(patch)]),
            .object(["patch": .string(patch), "input": .string(patch)]),
        ]

        for arguments in validArguments {
            let observer = ApplyPatchSchemaObserver()
            let toolset = try makeToolset(observer: observer)
            let result = await toolset.prepareAndCall(clientName: "apply_patch", args: arguments)

            guard case .success = result else {
                Issue.record("valid apply_patch alias was rejected: \(arguments)")
                continue
            }
            #expect(observer.hooks == ["apply_patch"])
            #expect(observer.arguments == [.object(["patch": .string(patch)])])
        }
    }

    @Test("conflicting aliases are rejected before hooks and dispatch")
    func conflictingAliasesNeverReachAuthorization() async throws {
        let observer = ApplyPatchSchemaObserver()
        let toolset = try makeToolset(observer: observer)

        let result = await toolset.prepareAndCall(
            clientName: "apply_patch",
            args: .object([
                "patch": .string("canonical"),
                "input": .string("conflicting"),
            ])
        )

        guard case .failure(let error) = result else {
            Issue.record("conflicting apply_patch aliases reached dispatch")
            return
        }
        #expect(error.kind == .invalidArguments)
        #expect(error.detail.contains("conflicting"))
        #expect(observer.hooks.isEmpty)
        #expect(observer.arguments.isEmpty)
    }

    @Test("missing and non-string aliases fail before hooks and dispatch")
    func malformedAliasesNeverReachAuthorization() async throws {
        let invalidArguments: [JSONValue] = [
            .object([:]),
            .object(["patch": .null]),
            .object(["input": .number(.int64(3))]),
            .null,
        ]

        for arguments in invalidArguments {
            let observer = ApplyPatchSchemaObserver()
            let toolset = try makeToolset(observer: observer)
            let result = await toolset.prepareAndCall(clientName: "apply_patch", args: arguments)

            guard case .failure(let error) = result else {
                Issue.record("malformed apply_patch arguments reached dispatch: \(arguments)")
                continue
            }
            #expect(error.kind == .invalidArguments)
            #expect(observer.hooks.isEmpty)
            #expect(observer.arguments.isEmpty)
        }
    }

    @Test("configured patch aliases normalize without overwriting conflicting values")
    func configuredAliasesPreserveCanonicalValidation() async throws {
        let patch = "*** Begin Patch\n*** End Patch"
        let observer = ApplyPatchSchemaObserver()
        let toolset = try makeToolset(observer: observer, overrides: ["patch": "body"])

        let schema = try #require(toolset.topLevelDefinitions().first?.argumentsSchema?.objectValue)
        #expect(schema["properties"]?.objectValue?["body"] != nil)
        #expect(schema["required"]?.arrayValue == [.string("body")])

        let accepted = await toolset.prepareAndCall(
            clientName: "apply_patch",
            args: .object(["body": .string(patch), "input": .string(patch)])
        )
        guard case .success = accepted else {
            Issue.record("configured apply_patch alias was rejected")
            return
        }
        #expect(observer.arguments == [.object(["patch": .string(patch)])])

        let rejected = await toolset.prepareAndCall(
            clientName: "apply_patch",
            args: .object(["body": .string(patch), "input": .string("different")])
        )
        guard case .failure(let error) = rejected else {
            Issue.record("conflicting configured apply_patch aliases reached dispatch")
            return
        }
        #expect(error.kind == .invalidArguments)
        #expect(observer.hooks == ["apply_patch"])
        #expect(observer.arguments.count == 1)
    }

    private func makeToolset(
        observer: ApplyPatchSchemaObserver,
        overrides: [String: String]? = nil
    ) throws -> FinalizedToolset {
        let spec = RegisteredToolSpec(
            namespace: .codex,
            id: "apply_patch",
            kind: .edit,
            description: "Apply patch parity fixture",
            inputSchema: BuiltinToolCatalog.applyPatchSchema
        )
        var builder = ToolRegistryBuilder(registerBuiltins: false)
        builder.register(spec: spec, handler: ApplyPatchSchemaHandler(observer: observer))

        let pipeline = PermissionPipeline(
            permissions: PermissionHandle(allowAll: true, shellCwd: NSTemporaryDirectory()),
            hooks: FailOpenPreToolUseHookRunner(inner: ApplyPatchSchemaHook(observer: observer))
        )
        let config = ToolServerConfig(tools: [ToolConfig(
            id: spec.qualifiedId,
            paramsNameOverrides: overrides,
            kind: .edit
        )])

        switch builder.finalize(
            config: config,
            resources: ToolResources(cwd: NSTemporaryDirectory(), permissionPipeline: pipeline)
        ) {
        case .success(let toolset):
            return toolset
        case .failure(let errors):
            throw errors
        }
    }
}

private final class ApplyPatchSchemaObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedHooks: [String] = []
    private var recordedArguments: [JSONValue] = []

    func recordHook(_ name: String) {
        lock.lock()
        recordedHooks.append(name)
        lock.unlock()
    }

    func recordInvocation(_ arguments: JSONValue) {
        lock.lock()
        recordedArguments.append(arguments)
        lock.unlock()
    }

    var hooks: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedHooks
    }

    var arguments: [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return recordedArguments
    }
}

private struct ApplyPatchSchemaHook: PreToolUseHookRunner {
    let observer: ApplyPatchSchemaObserver

    func runPreToolUse(
        toolName: String,
        toolCallId: String,
        access: AccessKind,
        permissionMode: String?
    ) async -> PreToolUseHookDecision {
        observer.recordHook(toolName)
        return .allow
    }
}

private struct ApplyPatchSchemaHandler: ToolHandler {
    let observer: ApplyPatchSchemaObserver

    func invoke(
        clientName: String,
        args: JSONValue,
        ctx: ToolCallContext,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        observer.recordInvocation(args)
        do {
            return .success(TypedToolOutput(
                toolId: try ToolId(clientName),
                value: .object(["arguments": args]),
                modelOutput: [.text(text: "ok")]
            ))
        } catch {
            return .failure(.invalidArguments("invalid parity-fixture tool id"))
        }
    }
}
