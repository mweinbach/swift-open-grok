import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokWorkspace
import Testing
@testable import OpenGrokToolRegistry

private final class InputValidationObserver: @unchecked Sendable {
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

private struct InputValidationHook: PreToolUseHookRunner {
    let observer: InputValidationObserver

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

private struct InputValidationHandler: ToolHandler {
    let observer: InputValidationObserver

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
            return .failure(.invalidArguments("invalid test tool id"))
        }
    }
}

private func validatedToolset(
    schema: JSONValue,
    observer: InputValidationObserver,
    namespace: ProductToolNamespace = .grokBuild,
    id: String = "validation_tool",
    kind: ProductToolKind = .read,
    overrides: [String: String]? = nil
) throws -> FinalizedToolset {
    let spec = RegisteredToolSpec(
        namespace: namespace,
        id: id,
        kind: kind,
        description: "Validation fixture",
        inputSchema: schema
    )
    var builder = ToolRegistryBuilder(registerBuiltins: false)
    builder.register(spec: spec, handler: InputValidationHandler(observer: observer))

    let pipeline = PermissionPipeline(
        permissions: PermissionHandle(allowAll: true, shellCwd: NSTemporaryDirectory()),
        hooks: FailOpenPreToolUseHookRunner(inner: InputValidationHook(observer: observer))
    )
    let config = ToolServerConfig(tools: [ToolConfig(
        id: spec.qualifiedId,
        paramsNameOverrides: overrides,
        kind: kind
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

private func invalidToolError(
    _ outcome: Result<TypedToolOutput, ToolError>
) -> ToolError? {
    guard case .failure(let error) = outcome else {
        Issue.record("expected invalid tool arguments")
        return nil
    }
    #expect(error.kind == .invalidArguments)
    return error
}

@Suite("Tool argument parsing and schema fidelity")
struct ToolInputValidationTests {
    @Test("missing required edit arguments never enter hooks or dispatch")
    func missingRequiredFieldStopsBeforeAuthorization() async throws {
        let observer = InputValidationObserver()
        let set = try validatedToolset(
            schema: .object([
                "type": .string("object"),
                "properties": .object(["file_path": .object(["type": .string("string")])]),
                "required": .array([.string("file_path")]),
            ]),
            observer: observer,
            kind: .edit
        )

        let error = invalidToolError(await set.prepareAndCall(
            clientName: "validation_tool",
            args: .object([:])
        ))

        #expect(error?.detail.contains("missing required field `file_path`") == true)
        #expect(observer.hooks.isEmpty)
        #expect(observer.arguments.isEmpty)
    }

    @Test("built-in calls reject non-object arguments before permission hooks")
    func nonObjectArgumentsAreRejected() async throws {
        let observer = InputValidationObserver()
        let set = try validatedToolset(
            schema: .object(["type": .string("object")]),
            observer: observer
        )

        let error = invalidToolError(await set.prepareAndCall(
            clientName: "validation_tool",
            args: .array([.string("not an object")])
        ))

        #expect(error?.detail.contains("expected object, got array") == true)
        #expect(observer.hooks.isEmpty)
        #expect(observer.arguments.isEmpty)
    }

    @Test("nested arrays and objects report their precise invalid argument path")
    func nestedArgumentPathIsPreserved() async throws {
        let observer = InputValidationObserver()
        let set = try validatedToolset(
            schema: BuiltinToolCatalog.todoWriteSchema,
            observer: observer,
            id: "todo_write"
        )

        let error = invalidToolError(await set.prepareAndCall(
            clientName: "todo_write",
            args: .object([
                "todos": .array([
                    .object(["id": .string("first")]),
                    .object(["id": .number(.int64(2))]),
                ]),
            ])
        ))

        #expect(error?.detail.contains("$.todos[1].id") == true)
        #expect(error?.detail.contains("expected string, got integer") == true)
        #expect(observer.hooks.isEmpty)
        #expect(observer.arguments.isEmpty)
    }

    @Test("array validation preserves existing model-facing repair instructions")
    func arrayErrorRetainsUpstreamCompatibleCopy() async throws {
        let observer = InputValidationObserver()
        let set = try validatedToolset(
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "questions": .object(["type": .string("array")]),
                ]),
                "required": .array([.string("questions")]),
            ]),
            observer: observer,
            id: "ask_user_question"
        )

        let error = invalidToolError(await set.prepareAndCall(
            clientName: "ask_user_question",
            args: .object(["questions": .string("not an array")])
        ))
        #expect(error?.detail.contains("`questions` must be an array") == true)
        #expect(observer.hooks.isEmpty)
        #expect(observer.arguments.isEmpty)
    }

    @Test("nested required fields and enumerated choices fail before dispatch")
    func nestedRequiredAndEnumValidation() async throws {
        let observer = InputValidationObserver()
        let set = try validatedToolset(
            schema: BuiltinToolCatalog.todoWriteSchema,
            observer: observer,
            id: "todo_write"
        )

        let missing = invalidToolError(await set.prepareAndCall(
            clientName: "todo_write",
            args: .object(["todos": .array([.object(["content": .string("missing id")])])])
        ))
        #expect(missing?.detail.contains("$.todos[0]") == true)
        #expect(missing?.detail.contains("missing required field `id`") == true)

        let invalidStatus = invalidToolError(await set.prepareAndCall(
            clientName: "todo_write",
            args: .object([
                "todos": .array([
                    .object(["id": .string("first"), "status": .string("invented")]),
                ]),
            ])
        ))
        #expect(invalidStatus?.detail.contains("$.todos[0].status") == true)
        #expect(invalidStatus?.detail.contains("permitted choices") == true)
        #expect(observer.hooks.isEmpty)
        #expect(observer.arguments.isEmpty)
    }

    @Test("additionalProperties false rejects unknown keys while typed maps validate values")
    func additionalPropertyContracts() async throws {
        let observer = InputValidationObserver()
        let set = try validatedToolset(
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "environment": .object([
                        "type": .string("object"),
                        "additionalProperties": .object(["type": .string("string")]),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ]),
            observer: observer
        )

        let extra = invalidToolError(await set.prepareAndCall(
            clientName: "validation_tool",
            args: .object(["unknown": .bool(true)])
        ))
        #expect(extra?.detail.contains("$.unknown") == true)

        let wrongValue = invalidToolError(await set.prepareAndCall(
            clientName: "validation_tool",
            args: .object([
                "environment": .object(["TOKEN": .number(.int64(4))]),
            ])
        ))
        #expect(wrongValue?.detail.contains("$.environment.TOKEN") == true)
        #expect(observer.hooks.isEmpty)
        #expect(observer.arguments.isEmpty)
    }

    @Test("first-party lenient booleans and numeric strings become typed handler arguments")
    func firstPartyCoercionsMatchRustDeserializers() async throws {
        let observer = InputValidationObserver()
        let set = try validatedToolset(
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "replace_all": .object(["type": .string("boolean")]),
                    "offset": .object(["type": .string("integer")]),
                    "timeout_ms": .object(["type": .string("integer")]),
                ]),
            ]),
            observer: observer
        )

        let outcome = await set.prepareAndCall(
            clientName: "validation_tool",
            args: .object([
                "replace_all": .string(" YES "),
                "offset": .string("-2"),
                "timeout_ms": .string("120000.0"),
            ])
        )
        guard case .success = outcome else {
            Issue.record("expected lenient upstream-compatible arguments, got \(outcome)")
            return
        }

        #expect(observer.hooks == ["validation_tool"])
        #expect(observer.arguments == [.object([
            "replace_all": .bool(true),
            "offset": .number(.int64(-2)),
            "timeout_ms": .number(.int64(120_000)),
        ])])
    }

    @Test("optional first-party null values preserve Rust Option deserialization")
    func optionalNullIsOmittedBeforeDispatch() async throws {
        let observer = InputValidationObserver()
        let set = try validatedToolset(
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")]),
                    "offset": .object(["type": .string("integer")]),
                    "replace_all": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("path")]),
            ]),
            observer: observer
        )

        let outcome = await set.prepareAndCall(
            clientName: "validation_tool",
            args: .object([
                "path": .string("file.swift"),
                "offset": .null,
                "replace_all": .null,
            ])
        )
        guard case .success = outcome else {
            Issue.record("expected optional nulls to match upstream, got \(outcome)")
            return
        }

        #expect(observer.arguments == [.object([
            "path": .string("file.swift"),
            "replace_all": .bool(false),
        ])])
    }

    @Test("invalid scalar forms are rejected instead of silently falling back")
    func invalidLenientScalarsStillFail() async throws {
        let observer = InputValidationObserver()
        let set = try validatedToolset(
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "replace_all": .object(["type": .string("boolean")]),
                    "offset": .object(["type": .string("integer")]),
                ]),
            ]),
            observer: observer
        )

        let boolean = invalidToolError(await set.prepareAndCall(
            clientName: "validation_tool",
            args: .object(["replace_all": .string("sometimes")])
        ))
        #expect(boolean?.detail.contains("$.replace_all") == true)

        let integer = invalidToolError(await set.prepareAndCall(
            clientName: "validation_tool",
            args: .object(["offset": .string("2.5")])
        ))
        #expect(integer?.detail.contains("$.offset") == true)
        #expect(observer.hooks.isEmpty)
        #expect(observer.arguments.isEmpty)
    }

    @Test("MCP arguments use strict server schemas but retain bare/null normalization")
    func mcpStrictSchemaAndLegacyWrapping() async throws {
        let observer = InputValidationObserver()
        let set = try validatedToolset(
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "enabled": .object(["type": .string("boolean")]),
                ]),
            ]),
            observer: observer,
            namespace: .mcp
        )

        let invalid = invalidToolError(await set.prepareAndCall(
            clientName: "validation_tool",
            args: .object(["enabled": .string("true")])
        ))
        #expect(invalid?.detail.contains("$.enabled") == true)
        #expect(observer.hooks.isEmpty)

        let null = await set.prepareAndCall(clientName: "validation_tool", args: .null)
        guard case .success = null else {
            Issue.record("expected null MCP arguments to normalize to an object, got \(null)")
            return
        }

        let bare = await set.prepareAndCall(
            clientName: "validation_tool",
            args: .string("payload")
        )
        guard case .success = bare else {
            Issue.record("expected scalar MCP arguments to preserve wrapping, got \(bare)")
            return
        }

        #expect(observer.arguments == [
            .object([:]),
            .object(["value": .string("payload")]),
        ])
    }

    @Test("background output accepts singular IDs without exposing the wire-only alias")
    func legacyTaskIdentifierAliasesAreCanonicalized() async throws {
        let observer = InputValidationObserver()
        let set = try validatedToolset(
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "task_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("task_ids")]),
                "additionalProperties": .bool(false),
            ]),
            observer: observer,
            id: "get_task_output"
        )

        let singular = await set.prepareAndCall(
            clientName: "get_task_output",
            args: .object(["task_id": .string("task-1")])
        )
        guard case .success = singular else {
            Issue.record("expected singular task_id alias to remain callable, got \(singular)")
            return
        }

        let bare = await set.prepareAndCall(
            clientName: "get_task_output",
            args: .object(["task_ids": .number(.int64(228))])
        )
        guard case .success = bare else {
            Issue.record("expected scalar task_ids to normalize into a list, got \(bare)")
            return
        }

        #expect(observer.arguments == [
            .object(["task_ids": .array([.string("task-1")])]),
            .object(["task_ids": .array([.string("228")])]),
        ])
        let advertised = try #require(set.topLevelDefinitions().first?.argumentsSchema)
        #expect(advertised["properties"]?["task_id"] == nil)
    }

    @Test("client parameter overrides rename both properties and required declarations")
    func advertisedSchemaAndCanonicalDispatchAgree() async throws {
        let observer = InputValidationObserver()
        let canonicalSchema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "file_path": .object(["type": .string("string")]),
                "old_string": .object(["type": .string("string")]),
                "new_string": .object(["type": .string("string")]),
            ]),
            "required": .array([
                .string("file_path"), .string("old_string"), .string("new_string"),
            ]),
        ])
        let set = try validatedToolset(
            schema: canonicalSchema,
            observer: observer,
            overrides: ["old_string": "find", "new_string": "replace_with"]
        )

        let definition = try #require(set.topLevelDefinitions().first)
        let schema = try #require(definition.argumentsSchema?.objectValue)
        let properties = try #require(schema["properties"]?.objectValue)
        #expect(Set(properties.keys) == ["file_path", "find", "replace_with"])
        let required = try #require(schema["required"]?.arrayValue)
        #expect(Set(required.compactMap(\.stringValue)) == ["file_path", "find", "replace_with"])
        #expect(set.tool(named: "validation_tool")?.inputSchema == canonicalSchema)

        let outcome = await set.prepareAndCall(
            clientName: "validation_tool",
            args: .object([
                "file_path": .string("sample.swift"),
                "find": .string("before"),
                "replace_with": .string("after"),
            ])
        )
        guard case .success = outcome else {
            Issue.record("expected renamed model arguments to dispatch, got \(outcome)")
            return
        }

        #expect(observer.arguments == [.object([
            "file_path": .string("sample.swift"),
            "old_string": .string("before"),
            "new_string": .string("after"),
        ])])
    }

    @Test("numeric bounds and collection size limits are enforced with field paths")
    func scalarAndCollectionBounds() async throws {
        let observer = InputValidationObserver()
        let set = try validatedToolset(
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "minLength": .number(.int64(2)),
                    ]),
                    "timeout_ms": .object([
                        "type": .string("integer"),
                        "minimum": .number(.int64(0)),
                        "maximum": .number(.int64(100)),
                    ]),
                    "tasks": .object([
                        "type": .string("array"),
                        "minItems": .number(.int64(1)),
                        "maxItems": .number(.int64(2)),
                    ]),
                ]),
            ]),
            observer: observer
        )

        for (arguments, expectedPath) in [
            (JSONValue.object(["name": .string("x")]), "$.name"),
            (.object(["timeout_ms": .number(.int64(-1))]), "$.timeout_ms"),
            (.object(["timeout_ms": .number(.int64(101))]), "$.timeout_ms"),
            (.object(["tasks": .array([])]), "$.tasks"),
            (.object(["tasks": .array([.null, .null, .null])]), "$.tasks"),
        ] {
            let error = invalidToolError(await set.prepareAndCall(
                clientName: "validation_tool",
                args: arguments
            ))
            #expect(error?.detail.contains(expectedPath) == true)
        }

        #expect(observer.hooks.isEmpty)
        #expect(observer.arguments.isEmpty)
    }

    @Test("local schema references and nullable type unions remain usable")
    func referencedSchemasAndNullableTypes() async throws {
        let observer = InputValidationObserver()
        let set = try validatedToolset(
            schema: .object([
                "type": .string("object"),
                "$defs": .object([
                    "item": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object([
                                "type": .array([.string("string"), .string("null")]),
                            ]),
                        ]),
                        "required": .array([.string("name")]),
                    ]),
                ]),
                "properties": .object([
                    "item": .object(["$ref": .string("#/$defs/item")]),
                ]),
                "required": .array([.string("item")]),
            ]),
            observer: observer,
            namespace: .mcp
        )

        let valid = await set.prepareAndCall(
            clientName: "validation_tool",
            args: .object(["item": .object(["name": .null])])
        )
        guard case .success = valid else {
            Issue.record("expected nullable reference to validate, got \(valid)")
            return
        }

        let invalid = invalidToolError(await set.prepareAndCall(
            clientName: "validation_tool",
            args: .object(["item": .object([:])])
        ))
        #expect(invalid?.detail.contains("$.item") == true)
        #expect(observer.arguments.count == 1)
    }

    @Test("schema alternatives enforce anyOf and oneOf semantics")
    func schemaCombinators() async throws {
        let observer = InputValidationObserver()
        let set = try validatedToolset(
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "mode": .object([
                        "anyOf": .array([
                            .object(["const": .string("read")]),
                            .object(["const": .string("write")]),
                        ]),
                    ]),
                    "identifier": .object([
                        "oneOf": .array([
                            .object(["type": .string("string")]),
                            .object(["type": .string("integer")]),
                        ]),
                    ]),
                ]),
            ]),
            observer: observer,
            namespace: .mcp
        )

        let invalid = invalidToolError(await set.prepareAndCall(
            clientName: "validation_tool",
            args: .object(["mode": .string("execute")])
        ))
        #expect(invalid?.detail.contains("$.mode") == true)

        let valid = await set.prepareAndCall(
            clientName: "validation_tool",
            args: .object([
                "mode": .string("read"),
                "identifier": .number(.int64(4)),
            ])
        )
        guard case .success = valid else {
            Issue.record("expected schema alternatives to validate, got \(valid)")
            return
        }
        #expect(observer.arguments.count == 1)
    }

    @Test("nested Code Mode calls traverse the same pre-permission validation gate")
    func nestedCallsCannotBypassValidation() async throws {
        let observer = InputValidationObserver()
        let set = try validatedToolset(
            schema: .object([
                "type": .string("object"),
                "properties": .object(["file_path": .object(["type": .string("string")])]),
                "required": .array([.string("file_path")]),
            ]),
            observer: observer,
            kind: .edit
        )

        let error = invalidToolError(await set.callNested(
            clientName: "validation_tool",
            args: .object([:])
        ))
        #expect(error?.detail.contains("file_path") == true)
        #expect(observer.hooks.isEmpty)
        #expect(observer.arguments.isEmpty)
    }

    @Test("missing schema metadata preserves legacy handler compatibility")
    func absentSchemaDefersToHandler() async throws {
        let observer = InputValidationObserver()
        let set = try validatedToolset(schema: .null, observer: observer)

        let outcome = await set.prepareAndCall(
            clientName: "validation_tool",
            args: .string("legacy payload")
        )
        guard case .success = outcome else {
            Issue.record("expected an absent schema to defer to its handler, got \(outcome)")
            return
        }
        #expect(observer.arguments == [.string("legacy payload")])
    }
}
