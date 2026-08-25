import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes
import OpenGrokWorkspace
import Testing
@testable import OpenGrokToolRegistry

private final class WebRunRegistrationObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AccessKind] = []
    private var count = 0

    func record(_ access: AccessKind) {
        lock.lock()
        values.append(access)
        lock.unlock()
    }

    func recordInvocation() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var accesses: [AccessKind] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private struct WebRunRegistrationHook: PreToolUseHookRunner {
    let observer: WebRunRegistrationObserver

    func runPreToolUse(
        toolName: String,
        toolCallId: String,
        access: AccessKind,
        permissionMode: String?
    ) async -> PreToolUseHookDecision {
        observer.record(access)
        return .allow
    }
}

private struct WebRunRegistrationHandler: ToolHandler {
    let observer: WebRunRegistrationObserver

    func invoke(
        clientName: String,
        args: JSONValue,
        ctx: ToolCallContext,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        observer.recordInvocation()
        guard let id = try? ToolId(clientName) else {
            return .failure(.invalidArguments("invalid web-run fixture tool id"))
        }
        return .success(TypedToolOutput(
            toolId: id,
            value: .object(["output": .string("search result")]),
            modelOutput: [.text(text: "search result")]
        ))
    }
}

private func webRunRegistrationToolset(
    observer: WebRunRegistrationObserver,
    permissions: PermissionHandle? = nil
) throws -> FinalizedToolset {
    var builder = ToolRegistryBuilder(registerBuiltins: false)
    builder.register(
        spec: BuiltinToolCatalog.webRunTools[0],
        handler: WebRunRegistrationHandler(observer: observer)
    )
    let pipeline = PermissionPipeline(
        permissions: permissions ?? PermissionHandle(
            allowAll: true,
            shellCwd: NSTemporaryDirectory()
        ),
        hooks: FailOpenPreToolUseHookRunner(inner: WebRunRegistrationHook(observer: observer))
    )
    let config = ToolServerConfig(tools: [
        ToolConfig.fromId(BuiltinToolCatalog.webRunQualifiedId, kind: .webSearch),
    ])
    let bridge = try ToolBridge.finalize(
        builder: builder,
        config: config,
        resources: ToolResources(
            cwd: NSTemporaryDirectory(),
            permissionPipeline: pipeline
        ),
        options: FinalizeOptions(capabilityMode: .readOnly)
    )
    return bridge.toolset
}

@Suite("Codex standalone web.run tool registration")
struct WebRunToolRegistrationTests {
    @Test("standalone tool is independently catalogued without expanding legacy web tools")
    func catalogAndPresetIsolation() {
        let builder = ToolRegistryBuilder()
        #expect(BuiltinToolCatalog.webTools.count == 3)
        #expect(BuiltinToolCatalog.webRunTools.count == 1)
        #expect(BuiltinToolCatalog.webRunTools[0].id == "web__run")
        #expect(BuiltinToolCatalog.webRunTools[0].kind == .webSearch)
        #expect(builder.hasToolId(BuiltinToolCatalog.webRunQualifiedId))

        for preset in NamedToolsetPreset.allCases {
            let configuration = toolServerConfig(
                for: preset,
                catalogKinds: builder.knownToolKinds()
            )
            #expect(!configuration.tools.contains {
                $0.id == BuiltinToolCatalog.webRunQualifiedId
            })
        }
    }

    @Test("schema preserves every operation, required field, enum, and unsigned range")
    func completeOperationSchema() throws {
        let root = try #require(BuiltinToolCatalog.webRunSchema.objectValue)
        let operations = try #require(root["properties"]?.objectValue)
        #expect(Set(operations.keys) == [
            "search_query", "image_query", "open", "click", "find", "screenshot",
            "finance", "weather", "sports", "time", "response_length",
        ])
        #expect(root["required"] == nil)

        let expectedRequired: [String: Set<String>] = [
            "search_query": ["q"],
            "image_query": ["q"],
            "open": ["ref_id"],
            "click": ["ref_id", "id"],
            "find": ["ref_id", "pattern"],
            "screenshot": ["ref_id", "pageno"],
            "finance": ["ticker", "type"],
            "weather": ["location"],
            "sports": ["fn", "league"],
            "time": ["utc_offset"],
        ]
        for (operation, expected) in expectedRequired {
            let schema = try #require(operations[operation]?.objectValue?["items"]?.objectValue)
            let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            #expect(Set(required) == expected)
        }

        let finance = try #require(
            operations["finance"]?.objectValue?["items"]?.objectValue?["properties"]?.objectValue
        )
        #expect(finance["type"]?.objectValue?["enum"]?.arrayValue == [
            .string("equity"), .string("fund"), .string("crypto"), .string("index"),
        ])

        let sports = try #require(
            operations["sports"]?.objectValue?["items"]?.objectValue?["properties"]?.objectValue
        )
        #expect(sports["tool"]?.objectValue?["enum"]?.arrayValue == [.string("sports")])
        #expect(sports["fn"]?.objectValue?["enum"]?.arrayValue == [
            .string("schedule"), .string("standings"),
        ])
        #expect(sports["league"]?.objectValue?["enum"]?.arrayValue == [
            .string("nba"), .string("wnba"), .string("nfl"), .string("nhl"),
            .string("mlb"), .string("epl"), .string("ncaamb"), .string("ncaawb"),
            .string("ipl"),
        ])
        #expect(operations["response_length"]?.objectValue?["enum"]?.arrayValue == [
            .string("short"), .string("medium"), .string("long"),
        ])

        let search = try #require(
            operations["search_query"]?.objectValue?["items"]?.objectValue?["properties"]?.objectValue
        )
        #expect(search["recency"]?.objectValue?["minimum"] == .number(.uint64(0)))
    }

    @Test("model instructions preserve upstream browsing, citation, and copyright contracts")
    func modelVisibleDescription() {
        let description = BuiltinToolCatalog.webRunDescription
        #expect(description.contains("## Decision boundary"))
        #expect(description.contains("<situations_where_you_must_browse_the_internet>"))
        #expect(description.contains("Results from `web__run` include internal reference IDs"))
        #expect(description.contains("## Word limits"))
        #expect(description.contains("The summarization limit N is a maximum for each source."))
        #expect(description.hasSuffix("\n"))
    }

    @Test("explicit top-level and nested nulls are rejected before hooks or dispatch")
    func optionalNullsFailClosed() async throws {
        for arguments: JSONValue in [
            .object(["search_query": .null]),
            .object(["search_query": .array([
                .object(["q": .string("query"), "recency": .null]),
            ])]),
            .object(["response_length": .null]),
        ] {
            let observer = WebRunRegistrationObserver()
            let toolset = try webRunRegistrationToolset(observer: observer)
            let result = await toolset.prepareAndCall(clientName: "web__run", args: arguments)
            guard case .failure(let error) = result else {
                Issue.record("explicit null reached standalone search dispatch")
                continue
            }
            #expect(error.kind == .invalidArguments)
            #expect(observer.accesses.isEmpty)
            #expect(observer.invocationCount == 0)
        }
    }

    @Test("standalone search uses upstream's read permission for direct and nested calls")
    func directAndNestedPermissionClassification() async throws {
        let observer = WebRunRegistrationObserver()
        let toolset = try webRunRegistrationToolset(observer: observer)
        let arguments: JSONValue = .object([
            "search_query": .array([.object(["q": .string("swift concurrency")])]),
        ])

        for nested in [false, true] {
            let result = await toolset.prepareAndCall(
                clientName: "web__run",
                args: arguments,
                nested: nested
            )
            guard case .success(let output) = result else {
                Issue.record("standalone search did not dispatch through its permission pipeline")
                continue
            }
            #expect(output.value == .object(["output": .string("search result")]))
        }

        #expect(observer.accesses == [.read(nil), .read(nil)])
        #expect(observer.invocationCount == 2)
    }

    @Test("read deny rules fail closed for standalone search")
    func denyRuleRemainsAuthoritative() async throws {
        let observer = WebRunRegistrationObserver()
        let permissions = PermissionHandle(
            config: PermissionConfig(
                rules: [PermissionRule(action: .deny, tool: .read, source: .synthetic)],
                promptPolicy: .deny
            ),
            allowAll: false,
            shellCwd: NSTemporaryDirectory(),
            prompter: HeadlessPermissionPrompter()
        )
        let toolset = try webRunRegistrationToolset(
            observer: observer,
            permissions: permissions
        )
        let result = await toolset.prepareAndCall(
            clientName: "web__run",
            args: .object(["search_query": .array([
                .object(["q": .string("sensitive query")]),
            ])])
        )

        guard case .failure(let error) = result else {
            Issue.record("denied standalone search reached its backend")
            return
        }
        #expect(error.kind == .permissionDenied)
        #expect(observer.invocationCount == 0)
    }
}
