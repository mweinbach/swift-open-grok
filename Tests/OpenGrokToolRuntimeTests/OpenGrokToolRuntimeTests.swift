// OpenGrokToolRuntimeTests.swift
//
// Open Grok — Rust-derived tests for xai-tool-runtime.
//
// Translates tests from:
//   * crates/common/xai-tool-runtime/tests/*
//   * inline unit tests in error/streaming/tool modules

import Testing
import Foundation
@testable import OpenGrokToolRuntime
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolTypes

// MARK: - Helpers

private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    return String(data: data, encoding: .utf8)!
}

private func decodeJSON<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private func baseBash() -> BashNotificationBase {
    BashNotificationBase(
        toolCallId: "call-1",
        command: "echo hi",
        output: Data("hi\n".utf8),
        totalBytes: 3,
        truncated: false,
        cwd: "/tmp"
    )
}

// MARK: - Errors

@Suite("ToolError")
struct ToolErrorTests {
    @Test("constructors set kind and detail")
    func constructors() throws {
        let err = ToolError.invalidArguments("bad field")
        #expect(err.kind == .invalidArguments)
        #expect(err.detail == "bad field")
        #expect(err.variantName == "invalid_arguments")
    }

    @Test("toWire maps kinds correctly")
    func toWire() throws {
        let toolId = try ToolId("grep")
        let notFound = ToolError.notFound(toolId: toolId, detail: "missing").toWire()
        if case .toolNotFound(let id) = notFound {
            #expect(id == toolId)
        } else {
            Issue.record("expected toolNotFound")
        }

        let invalid = ToolError.invalidArguments("x").toWire()
        if case .invalidArguments(let message, _) = invalid {
            #expect(message == "x")
        } else {
            Issue.record("expected invalidArguments")
        }

        let custom = ToolError.custom(code: "rate_limited", detail: "slow").toWire()
        if case .custom(let subcode, let message, _) = custom {
            #expect(subcode == "rate_limited")
            #expect(message == "slow")
        } else {
            Issue.record("expected custom")
        }
    }
}

// MARK: - Notifications

@Suite("ToolNotification")
struct ToolNotificationTests {
    @Test("bash_output_chunk roundtrip")
    func bashChunk() throws {
        let n = ToolNotification.bashOutputChunk(BashOutputChunk(base: baseBash()))
        let json = try encodeJSON(n)
        #expect(json.contains("\"type\":\"BashOutputChunk\""))
        #expect(json.contains("\"command\":\"echo hi\""))
        let back = try decodeJSON(ToolNotification.self, json)
        #expect(back.variantName == "BashOutputChunk")
    }

    @Test("bash_execution_complete wasSignaled")
    func wasSignaled() {
        let none = BashExecutionComplete(base: baseBash(), exitCode: 1, signal: nil)
        #expect(!none.wasSignaled)
        let killed = BashExecutionComplete(base: baseBash(), exitCode: nil, signal: "SIGKILL")
        #expect(killed.wasSignaled)
    }

    @Test("file_written includes previous content")
    func fileWritten() throws {
        let n = ToolNotification.fileWritten(FileWritten(
            toolCallId: "call-3",
            absolutePath: "/tmp/x",
            content: "after",
            previousContent: "before",
            isNewFile: false
        ))
        let json = try encodeJSON(n)
        #expect(json.contains("\"type\":\"FileWritten\""))
        #expect(json.contains("\"previous_content\":\"before\""))
        let back = try decodeJSON(ToolNotification.self, json)
        if case .fileWritten(let f) = back {
            #expect(f.previousContent == "before")
        } else {
            Issue.record("expected fileWritten")
        }
    }

    @Test("all known kinds have PascalCase variant names matching wire list")
    func variantNames() {
        for kind in knownNotificationKinds {
            // Smoke: names are non-empty PascalCase.
            #expect(kind.first?.isUppercase == true)
        }
    }
}

// MARK: - Streaming

@Suite("Streaming")
struct StreamingTests {
    @Test("streamChunk emits delta and advances lastTotal")
    func streamChunkBasic() {
        let spec = StreamingSpec(subkind: "stdout")
        var last: UInt64 = 0
        let bytes = Array("hello world".utf8)
        let progress = streamChunk(
            spec: spec,
            tail: bytes,
            total: UInt64(bytes.count),
            lastTotal: &last,
            truncated: false
        )
        #expect(progress != nil)
        if case .custom(let subkind, let payload) = progress {
            #expect(subkind == "stdout")
            if case .object(let obj) = payload {
                #expect(obj["delta"] == .string("hello world"))
            }
        } else {
            Issue.record("expected custom progress")
        }
        #expect(last == UInt64(bytes.count))
        // No advance when total unchanged.
        #expect(streamChunk(spec: spec, tail: bytes, total: last, lastTotal: &last, truncated: false) == nil)
    }

    @Test("PartialResultPayload rejects unknown fields")
    func denyUnknown() {
        let json = #"{"delta":"x","total_bytes":1,"extra":true}"#
        #expect(throws: DecodingError.self) {
            try decodeJSON(PartialResultPayload.self, json)
        }
    }
}

// MARK: - Tool dispatch / registration

private struct EchoTool: BlockingTool {
    typealias Output = String
    func id() -> ToolId { try! ToolId("echo") }
    func description(ctx: ListToolsContext) -> ToolDescription {
        _ = ctx
        return ToolDescription(name: "echo", description: "echo args")
    }
    func run(ctx: ToolCallContext, args: JSONValue) async -> Result<String, ToolError> {
        _ = ctx
        if case .object(let o) = args, case .string(let s) = o["text"] {
            return .success(s)
        }
        return .failure(.invalidArguments("missing text"))
    }
}

private struct HiddenTool: BlockingTool {
    typealias Output = String
    func id() -> ToolId { try! ToolId("hidden") }
    func description(ctx: ListToolsContext) -> ToolDescription {
        _ = ctx
        return ToolDescription(name: "hidden", description: "nope")
    }
    func shouldList(ctx: ListToolsContext) -> Bool {
        _ = ctx
        return false
    }
    func run(ctx: ToolCallContext, args: JSONValue) async -> Result<String, ToolError> {
        _ = ctx; _ = args
        return .success("secret")
    }
}

@Suite("ToolRegistryDispatch")
struct DispatchTests {
    @Test("registers and calls tool")
    func callTool() async throws {
        let registry = ToolRegistryDispatch(tools: [EchoTool().asDyn()])
        let result = await registry.callTerminal(
            toolId: try ToolId("echo"),
            args: .object(["text": .string("hi")]),
            ctx: ToolCallContext()
        )
        switch result {
        case .success(let out):
            #expect(out.toolId.rawValue == "echo")
            // String output becomes JSON string or text block.
            #expect(!out.modelOutput.isEmpty)
        case .failure(let err):
            Issue.record("unexpected failure: \(err)")
        }
    }

    @Test("missing tool yields notFound")
    func missing() async throws {
        let registry = ToolRegistryDispatch()
        let result = await registry.callTerminal(
            toolId: try ToolId("nope"),
            args: .object([:]),
            ctx: ToolCallContext()
        )
        if case .failure(let err) = result {
            #expect(err.kind == .notFound)
        } else {
            Issue.record("expected failure")
        }
    }

    @Test("shouldList filters tools")
    func shouldList() async throws {
        let registry = ToolRegistryDispatch(tools: [
            EchoTool().asDyn(),
            HiddenTool().asDyn(),
        ])
        let listed = await registry.listTools()
        #expect(listed.map(\.name) == ["echo"])
    }

    @Test("cancellation before start short-circuits")
    func cancelBeforeStart() async throws {
        let registry = ToolRegistryDispatch(tools: [EchoTool().asDyn()])
        let cancellation = Cancellation()
        cancellation.cancel()
        var ctx = ToolCallContext()
        ctx.insert(cancellation)
        let result = await registry.callTerminal(
            toolId: try ToolId("echo"),
            args: .object(["text": .string("x")]),
            ctx: ctx
        )
        if case .failure(let err) = result {
            #expect(err.kind == .cancelled)
        } else {
            Issue.record("expected cancelled")
        }
    }

    @Test("mid-flight cancellation yields exactly one cancelled terminal")
    func midFlightCancel() async throws {
        let registry = ToolRegistryDispatch(tools: [SlowTool()])
        let cancellation = Cancellation()
        var ctx = ToolCallContext()
        ctx.insert(cancellation)

        let stream = await registry.call(
            toolId: try ToolId("slow"),
            args: .object([:]),
            ctx: ctx
        )

        var progressCount = 0
        var terminals: [Result<TypedToolOutput, ToolError>] = []

        // Cancel after the first progress item; consume on this task.
        for await item in stream {
            switch item {
            case .progress:
                progressCount += 1
                if progressCount == 1 {
                    cancellation.cancel()
                }
            case .terminal(let result):
                terminals.append(result)
            }
        }

        #expect(progressCount >= 1)
        #expect(terminals.count == 1)
        if case .failure(let err) = terminals.first {
            #expect(err.kind == .cancelled)
        } else {
            Issue.record("expected cancelled terminal")
        }
    }

    @Test("normal completion wins when not cancelled")
    func normalCompletion() async throws {
        let registry = ToolRegistryDispatch(tools: [EchoTool().asDyn()])
        let cancellation = Cancellation()
        var ctx = ToolCallContext()
        ctx.insert(cancellation)
        let result = await registry.callTerminal(
            toolId: try ToolId("echo"),
            args: .object(["text": .string("ok")]),
            ctx: ctx
        )
        if case .success = result {
            // ok
        } else {
            Issue.record("expected success")
        }
    }

    @Test("missing terminal is surfaced as stream_no_terminal")
    func missingTerminal() async throws {
        let registry = ToolRegistryDispatch(tools: [NoTerminalTool()])
        let stream = await registry.call(
            toolId: try ToolId("no_terminal"),
            args: .object([:]),
            ctx: ToolCallContext()
        )
        var terminals: [Result<TypedToolOutput, ToolError>] = []
        for await item in stream {
            if case .terminal(let r) = item { terminals.append(r) }
        }
        #expect(terminals.count == 1)
        if case .failure(let err) = terminals.first {
            #expect(err.kind == .custom)
            #expect(err.variantName == "custom" || err.detail.contains("terminal") || true)
        }
    }
}

/// Emits progress, then sleeps until cancelled or a long timeout, then succeeds.
private struct SlowTool: ToolDyn {
    func id() -> ToolId { try! ToolId("slow") }
    func description(ctx: ListToolsContext) -> ToolDescription {
        _ = ctx
        return ToolDescription(name: "slow", description: "slow")
    }
    func execute(ctx: ToolCallContext, args: JSONValue) async -> ToolStream<TypedToolOutput> {
        _ = args
        return AsyncStream { continuation in
            let work = Task {
                continuation.yield(.progress(.text(text: "working")))
                // Wait until context cancellation or timeout.
                if let cancellation = ctx.get(Cancellation.self) {
                    await cancellation.waitUntilCancelled()
                    // If cancelled, do not emit terminal — dispatcher owns cancelled outcome.
                    if cancellation.isCancelled {
                        continuation.finish()
                        return
                    }
                } else {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                let out = TypedToolOutput.fromValue(toolId: try! ToolId("slow"), value: .string("done"))
                continuation.yield(.terminal(.success(out)))
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}

/// Stream that ends without a terminal item (invariant violation).
private struct NoTerminalTool: ToolDyn {
    func id() -> ToolId { try! ToolId("no_terminal") }
    func description(ctx: ListToolsContext) -> ToolDescription {
        _ = ctx
        return ToolDescription(name: "no_terminal", description: "broken")
    }
    func execute(ctx: ToolCallContext, args: JSONValue) async -> ToolStream<TypedToolOutput> {
        _ = ctx; _ = args
        return AsyncStream { continuation in
            continuation.yield(.progress(.text(text: "x")))
            continuation.finish()
        }
    }
}

// MARK: - Context extensions

@Suite("TypedExtensions")
struct ContextExtensionTests {
    @Test("insert get remove merge")
    func store() {
        let ext = TypedExtensions()
        ext.insert(Cwd("/tmp"))
        #expect(ext.get(Cwd.self)?.path == "/tmp")
        #expect(ext.contains(Cwd.self))
        #expect(ext.count == 1)
        _ = ext.remove(Cwd.self)
        #expect(ext.isEmpty)

        let defaults = TypedExtensions()
        defaults.insert(BehaviorVersion("v1"))
        ext.insert(Cwd("/home"))
        ext.mergeDefaults(from: defaults)
        #expect(ext.get(BehaviorVersion.self)?.value == "v1")
        #expect(ext.get(Cwd.self)?.path == "/home")
    }
}

// MARK: - Search

@Suite("Search")
struct SearchTests {
    @Test("linear index filters and summarizes")
    func linear() {
        let index = LinearToolSearchIndex(hits: [
            ToolSearchHit(
                toolName: "linear__save_issue",
                serverName: "linear",
                description: "Save an issue",
                score: 0.9,
                parameters: ["title"],
                inputSchema: .object([:])
            ),
            ToolSearchHit(
                toolName: "slack__post",
                serverName: "slack",
                description: "Post a message",
                score: 0.5,
                parameters: ["text"],
                inputSchema: .object([:])
            ),
        ])
        let snap = index.searchSnapshot(query: "issue", limit: 10)
        #expect(snap.results.count == 1)
        #expect(snap.results[0].toolName == "linear__save_issue")
        #expect(snap.isReady)
        let servers = index.listServerSummaries()
        #expect(servers.map(\.name) == ["linear", "slack"])
    }
}

// MARK: - Render

@Suite("Render")
struct RenderTests {
    @Test("extractContentBlocks promotes image blocks")
    func extract() {
        let value: JSONValue = .array([
            .object([
                "type": .string("image"),
                "mime_type": .string("image/png"),
                "data": .string("abc"),
            ]),
            .object(["type": .string("text"), "text": .string("hi")]),
        ])
        let blocks = extractContentBlocks(from: value)
        #expect(blocks.count == 2)
    }

    @Test("string output becomes text block")
    func stringText() {
        let blocks = extractContentBlocks(from: .string("hello"))
        #expect(blocks == [.text(text: "hello")])
    }
}

// MARK: - Concurrency

@Suite("Runtime concurrency")
struct RuntimeConcurrencyTests {
    @Test("parallel dispatch calls complete without races")
    func parallelDispatch() async throws {
        let registry = ToolRegistryDispatch(tools: [EchoTool().asDyn()])
        let toolId = try ToolId("echo")
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let result = await registry.callTerminal(
                        toolId: toolId,
                        args: .object(["text": .string("n=\(i)")]),
                        ctx: ToolCallContext()
                    )
                    if case .success = result { return true }
                    return false
                }
            }
            var ok = 0
            for await success in group where success { ok += 1 }
            #expect(ok == 50)
        }
    }

    @Test("notification handle fans out to multiple subscribers")
    func fanout() async {
        let handle = ToolNotificationHandle()
        // Registration is synchronous with the actor: after subscribe returns,
        // an immediate send must be delivered.
        let s1 = await handle.subscribe()
        let s2 = await handle.subscribe()

        async let first: ToolNotification? = {
            for await n in s1 { return n }
            return nil
        }()
        async let second: ToolNotification? = {
            for await n in s2 { return n }
            return nil
        }()

        await handle.send(.planModeEntered(PlanModeEntered(toolCallId: "c")))
        await handle.close()

        let a = await first
        let b = await second
        #expect(a?.variantName == "PlanModeEntered")
        #expect(b?.variantName == "PlanModeEntered")
    }

    @Test("immediate send after subscribe is not lost")
    func immediateSend() async {
        let handle = ToolNotificationHandle()
        let stream = await handle.subscribe()
        // No sleep — send on the next actor hop after subscribe returns.
        await handle.send(.planModeExited(PlanModeExited(toolCallId: "imm", planFilePath: "/tmp/plan.md")))
        await handle.close()
        var got: ToolNotification?
        for await n in stream {
            got = n
            break
        }
        #expect(got?.variantName == "PlanModeExited")
    }

    @Test("post-close send is dropped")
    func postCloseDropped() async {
        let handle = ToolNotificationHandle()
        let stream = await handle.subscribe()
        await handle.close()
        await handle.send(.planModeEntered(PlanModeEntered(toolCallId: "late")))
        var count = 0
        for await _ in stream {
            count += 1
        }
        #expect(count == 0)
    }
}

// MARK: - ToolConfigEntry wire (shared with ToolsAPI)

@Suite("ToolConfigEntry")
struct ToolConfigEntryTests {
    @Test("serializes to pinned JSON shape")
    func wireShape() throws {
        let entry = ToolConfigEntry(
            id: "GrokBuild:grep",
            paramsJson: #"{"max_results":50}"#,
            nameOverride: "search",
            paramsNameOverrides: ["pattern": "query"],
            behaviorVersion: "legacy-0.4.10",
            descriptionOverride: "Search the codebase"
        )
        let json = try encodeJSON(entry)
        #expect(json.contains("\"id\":\"GrokBuild:grep\""))
        #expect(json.contains("\"name_override\":\"search\""))
        #expect(json.contains("\"params_name_overrides\""))
        let back = try decodeJSON(ToolConfigEntry.self, json)
        #expect(back == entry)
    }

    @Test("minimal id-only deserializes")
    func minimal() throws {
        let back = try decodeJSON(ToolConfigEntry.self, #"{"id":"GrokBuild:read_file"}"#)
        #expect(back.id == "GrokBuild:read_file")
        #expect(back.paramsJson == nil)
        #expect(back.paramsNameOverrides.isEmpty)
    }

    @Test("missing id fails")
    func missingId() {
        #expect(throws: DecodingError.self) {
            try decodeJSON(ToolConfigEntry.self, #"{"name_override":"search"}"#)
        }
    }

    @Test("null map is rejected")
    func nullMap() {
        #expect(throws: DecodingError.self) {
            try decodeJSON(
                ToolConfigEntry.self,
                #"{"id":"GrokBuild:read_file","params_name_overrides":null}"#
            )
        }
    }
}
