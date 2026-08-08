// OpenGrokToolsAPITests.swift
//
// Open Grok — Rust-derived tests for xai-grok-tools-api.
//
// Translates:
//   * crates/codegen/xai-grok-tools-api/tests/wire_shape.rs
//   * crates/codegen/xai-grok-tools-api/src/lib.rs (default_client_name)
//   * crates/codegen/xai-grok-tools-api/src/config_validation.rs
//   * crates/codegen/xai-grok-tools-api/src/slash_commands.rs

import Testing
import Foundation
@testable import OpenGrokToolsAPI
import OpenGrokShared
import OpenGrokToolRuntime

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

// MARK: - defaultClientName

@Suite("defaultClientName")
struct DefaultClientNameTests {
    @Test("pins first-colon derivation")
    func pinsFirstColon() {
        #expect(defaultClientName("GrokBuild:grep") == "grep")
        #expect(defaultClientName("ns:a:b") == "a")
        #expect(defaultClientName("bare") == "bare")
        #expect(defaultClientName("") == "")
    }
}

// MARK: - ToolConfigEntry wire

@Suite("ToolConfigEntry wire")
struct ToolConfigEntryWireTests {
    @Test("full entry serializes to pinned shape")
    func fullShape() throws {
        let entry = ToolConfigEntry(
            id: "GrokBuild:grep",
            paramsJson: #"{"max_results":50}"#,
            nameOverride: "search",
            paramsNameOverrides: ["pattern": "query"],
            behaviorVersion: "legacy-0.4.10",
            descriptionOverride: "Search the codebase"
        )
        let value = try JSONValue.encode(entry)
        guard case .object(let obj) = value else {
            Issue.record("expected object"); return
        }
        #expect(obj["id"] == .string("GrokBuild:grep"))
        #expect(obj["params_json"] == .string(#"{"max_results":50}"#))
        #expect(obj["name_override"] == .string("search"))
        #expect(obj["behavior_version"] == .string("legacy-0.4.10"))
        #expect(obj["description_override"] == .string("Search the codebase"))
        if case .object(let overrides) = obj["params_name_overrides"] {
            #expect(overrides["pattern"] == .string("query"))
        } else {
            Issue.record("missing overrides")
        }
    }

    @Test("round trips")
    func roundTrip() throws {
        let entry = ToolConfigEntry(
            id: "GrokBuild:grep",
            paramsJson: #"{"max_results":50}"#,
            nameOverride: "search",
            paramsNameOverrides: ["pattern": "query"],
            behaviorVersion: "legacy-0.4.10",
            descriptionOverride: "Search the codebase"
        )
        let json = try encodeJSON(entry)
        let back = try decodeJSON(ToolConfigEntry.self, json)
        #expect(back == entry)
    }

    @Test("minimal id-only deserializes")
    func minimal() throws {
        let back = try decodeJSON(ToolConfigEntry.self, #"{"id":"GrokBuild:read_file"}"#)
        #expect(back.id == "GrokBuild:read_file")
        #expect(back.paramsJson == nil)
        #expect(back.nameOverride == nil)
        #expect(back.paramsNameOverrides.isEmpty)
        #expect(back.behaviorVersion == nil)
        #expect(back.descriptionOverride == nil)
    }

    @Test("missing id fails")
    func missingId() {
        #expect(throws: DecodingError.self) {
            try decodeJSON(ToolConfigEntry.self, #"{"name_override":"search"}"#)
        }
    }

    @Test("explicit null optional fields deserialize as nil")
    func explicitNulls() throws {
        let back = try decodeJSON(
            ToolConfigEntry.self,
            """
            {"id":"GrokBuild:read_file","params_json":null,"name_override":null,"behavior_version":null,"description_override":null}
            """
        )
        #expect(back.paramsJson == nil)
        #expect(back.nameOverride == nil)
        #expect(back.behaviorVersion == nil)
        #expect(back.descriptionOverride == nil)
    }

    @Test("null params_name_overrides is rejected")
    func nullMapRejected() {
        #expect(throws: DecodingError.self) {
            try decodeJSON(
                ToolConfigEntry.self,
                #"{"id":"GrokBuild:read_file","params_name_overrides":null}"#
            )
        }
    }
}

// MARK: - Config validation

@Suite("Config validation")
struct ConfigValidationTests {
    @Test("unset params is ok nil")
    func unsetParams() {
        if case .success(let v) = parseParamsJson(index: 0, toolId: "GrokBuild:grep", paramsJson: nil) {
            #expect(v == nil)
        } else {
            Issue.record("expected success")
        }
    }

    @Test("valid object is returned")
    func validObject() {
        switch parseParamsJson(index: 0, toolId: "GrokBuild:grep", paramsJson: #"{"max_results":50}"#) {
        case .success(let obj):
            #expect(obj?["max_results"] != nil)
        case .failure(let err):
            Issue.record("unexpected: \(err)")
        }
    }

    @Test("empty string is parse error")
    func emptyString() {
        switch parseParamsJson(index: 3, toolId: "GrokBuild:grep", paramsJson: "") {
        case .failure(let err):
            #expect(err.index == 3)
            #expect(err.fieldPath == "tools[3].params_json")
            if case .paramsJsonParse = err.kind {
                // ok
            } else {
                Issue.record("wrong kind")
            }
        case .success:
            Issue.record("expected failure")
        }
    }

    @Test("invalid json is parse error")
    func invalidJson() {
        switch parseParamsJson(index: 0, toolId: "t", paramsJson: "{not json") {
        case .failure(let err):
            if case .paramsJsonParse(_, let raw) = err.kind {
                #expect(raw == "{not json")
            } else {
                Issue.record("wrong kind")
            }
        case .success:
            Issue.record("expected failure")
        }
    }

    @Test("non-object json is rejected")
    func nonObject() {
        switch parseParamsJson(index: 1, toolId: "t", paramsJson: "[1,2,3]") {
        case .failure(let err):
            if case .paramsJsonNotObject = err.kind {
                // ok
            } else {
                Issue.record("wrong kind")
            }
        case .success:
            Issue.record("expected failure")
        }
    }

    @Test("name_override unset or valid is ok")
    func nameOverrideOk() {
        #expect(validateNameOverride(index: 0, toolId: "GrokBuild:grep", nameOverride: nil).isSuccess)
        for name in ["search", "GrokBuild:grep", "a-b_C9"] {
            #expect(
                validateNameOverride(index: 0, toolId: "GrokBuild:grep", nameOverride: name).isSuccess,
                "name=\(name)"
            )
        }
    }

    @Test("name_override outside charset is rejected")
    func nameOverrideRejected() {
        for name in ["has space", "", "a:b:c", "dot.name"] {
            switch validateNameOverride(index: 2, toolId: "GrokBuild:grep", nameOverride: name) {
            case .failure(let err):
                #expect(err.index == 2)
                #expect(err.fieldPath == "tools[2].name_override")
            case .success:
                Issue.record("expected failure for \(name)")
            }
        }
    }

    @Test("first_unknown_tool_id")
    func firstUnknown() {
        let entries = [
            ToolConfigEntry(id: "GrokBuild:grep"),
            ToolConfigEntry(id: "GrokBuild:nonexistent"),
            ToolConfigEntry(id: "GrokBuild:also_missing"),
        ]
        let allowed: Set<String> = ["GrokBuild:grep", "GrokBuild:read_file"]
        let hit = firstUnknownToolId(entries: entries, allowedIds: allowed)
        #expect(hit?.index == 1)
        #expect(hit?.id == "GrokBuild:nonexistent")
        #expect(firstUnknownToolId(entries: [], allowedIds: allowed) == nil)
        #expect(firstUnknownToolId(
            entries: [ToolConfigEntry(id: "GrokBuild:grep")],
            allowedIds: allowed
        ) == nil)
    }
}

// MARK: - Slash commands

@Suite("Slash commands")
struct SlashCommandTests {
    @Test("imagine_instruction carries prompt verbatim")
    func imagine() {
        let text = imagineInstruction("a golden sunset")
        #expect(text.contains("a golden sunset"))
        #expect(text.contains("image_gen"))
        #expect(text.contains("verbatim"))
    }

    @Test("imagine_video_instruction carries prompt and workflow")
    func imagineVideo() {
        let text = imagineVideoInstruction("a cat playing piano")
        #expect(text.contains("a cat playing piano"))
        #expect(text.contains("image_to_video"))
        #expect(text.contains("FFmpeg"))
    }

    // slash_commands.rs:242-270
    @Test("loop instruction carries args and contract tokens")
    func loop() {
        for mode in [LoopFireMode.detached, .inSession] {
            let text = loopScheduleInstruction("every 30 minutes do x", mode: mode)
            #expect(text.contains("every 30 minutes do x"), "\(mode)")
            #expect(text.contains("<number><unit>"), "\(mode)")
            #expect(text.contains("ask the user how often"), "\(mode)")
            #expect(!text.contains("10m"), "no host-side default interval: \(mode)")
            #expect(
                !text.contains("recurring:"),
                "the retired one-shot flag must not be referenced: \(mode)"
            )
            #expect(text.contains("task_id"), "must teach in-place updates via task_id: \(mode)")
            #expect(
                text.contains("delete and recreate"),
                "must steer away from delete+recreate: \(mode)"
            )
            #expect(
                text.contains("scheduler_delete <task_id>"),
                "every mode must authorize the fire to end the task: \(mode)"
            )
        }
    }

    // slash_commands.rs:272-288
    @Test("each fire mode describes its own runtime")
    func loopFireModes() {
        let detached = loopScheduleInstruction("5m check ci", mode: .detached)
        let inSession = loopScheduleInstruction("5m check ci", mode: .inSession)

        #expect(detached.contains("cannot see this conversation"))
        #expect(!detached.contains("arrives as a new turn in this conversation"))

        #expect(inSession.contains("arrives as a new turn in this conversation"))
        #expect(!inSession.contains("cannot see this conversation"))

        // The two levers the A/B showed carry the behavior are mode-independent.
        for text in [detached, inSession] {
            #expect(text.contains("report it and call"))
            #expect(text.contains("Keep it short and concrete"))
        }
    }

    @Test("goal instruction carries objective and contract tokens")
    func goal() {
        let text = goalInstruction("ship the widget")
        #expect(text.contains("ship the widget"))
        #expect(text.contains("update_goal(completed: true"))
        #expect(text.contains("blocked_reason"))
        #expect(text.contains("If update_goal returns an error"))
        #expect(!text.contains("system-reminder"))
        #expect(goalUsageMessage().contains("Usage: /goal"))
    }

    @Test("loop usage has no default claim")
    func loopUsage() {
        #expect(loopUsageMessage().contains("Usage: /loop"))
        #expect(!loopUsageMessage().contains("10m"))
    }

    @Test("tool name constants")
    func constants() {
        #expect(schedulerCreateToolName == "scheduler_create")
        #expect(imageGenToolName == "image_gen")
        #expect(imageToVideoToolName == "image_to_video")
        #expect(updateGoalToolName == "update_goal")
        #expect(goalReservedSubcommands.contains("status"))
    }
}

// MARK: - ToolCategory

@Suite("ToolCategory")
struct ToolCategoryTests {
    @Test("asStr matches snake_case")
    func asStr() {
        #expect(ToolCategory.file.asStr == "file")
        #expect(ToolCategory.workflow.asStr == "workflow")
        #expect(ToolCategory.unspecified.asStr == "unspecified")
    }

    @Test("protobuf enum raw values match proto")
    func rawValues() {
        #expect(ToolCategory.unspecified.rawValue == 0)
        #expect(ToolCategory.file.rawValue == 1)
        #expect(ToolCategory.search.rawValue == 2)
        #expect(ToolCategory.shell.rawValue == 3)
        #expect(ToolCategory.workflow.rawValue == 4)
        #expect(ToolCategory.external.rawValue == 5)
        #expect(ToolCategory.custom.rawValue == 6)
        #expect(OutputFormat.default.rawValue == 1)
        #expect(OutputFormat.concise.rawValue == 2)
        #expect(StreamDataKind.promptText.rawValue == 1)
        #expect(StreamDataKind.outputJson.rawValue == 2)
        #expect(ToolSource.skill.rawValue == 4)
        #expect(ErrorCode.cancelled.rawValue == 302)
    }
}

// MARK: - Protobuf wire contract

@Suite("Protobuf wire")
struct ProtobufWireTests {
    @Test("ExecuteToolRequest round-trips field numbers")
    func executeToolRequestWire() throws {
        var req = ExecuteToolRequest()
        req.toolName = "grep"
        req.inputJson = #"{"pattern":"x"}"#
        req.callId = "call-1"
        var opts = ExecutionOptions()
        opts.timeoutMs = 5000
        opts.background = true
        opts.outputFormat = .concise
        opts.includeFields = ["path", "lines"]
        opts.streamChunkSize = 1024
        req.options = opts

        let bytes = req.protobufData()
        let back = try ExecuteToolRequest(protobufBytes: bytes)
        #expect(back.toolName == "grep")
        #expect(back.inputJson == #"{"pattern":"x"}"#)
        #expect(back.callId == "call-1")
        #expect(back.options?.timeoutMs == 5000)
        #expect(back.options?.background == true)
        #expect(back.options?.outputFormat == .concise)
        #expect(back.options?.includeFields == ["path", "lines"])
        #expect(back.options?.streamChunkSize == 1024)
    }

    @Test("ToolStreamChunk oneof variants round-trip")
    func streamChunkOneof() throws {
        var dataChunk = ToolStreamChunk()
        dataChunk.callId = "c1"
        dataChunk.chunk = .data(StreamDataChunk(
            kind: .promptText,
            data: Data("hello".utf8),
            offset: 0
        ))
        let backData = try ToolStreamChunk(protobufBytes: dataChunk.protobufData())
        #expect(backData.callId == "c1")
        if case .data(let d) = backData.chunk {
            #expect(d.kind == .promptText)
            #expect(String(data: d.data, encoding: .utf8) == "hello")
        } else {
            Issue.record("expected data chunk")
        }

        var finalChunk = ToolStreamChunk()
        finalChunk.callId = "c1"
        var final = StreamFinalResult()
        final.promptTextSize = 5
        final.outputJsonSize = 0
        var meta = ExecutionMetadata()
        meta.durationMs = 12
        meta.truncated = false
        final.metadata = meta
        finalChunk.chunk = .finalResult(final)

        let backFinal = try ToolStreamChunk(protobufBytes: finalChunk.protobufData())
        if case .finalResult(let f) = backFinal.chunk {
            #expect(f.promptTextSize == 5)
            #expect(f.metadata?.durationMs == 12)
        } else {
            Issue.record("expected final_result chunk")
        }
    }

    @Test("ToolConfigEntry protobuf and JSON wire bridge")
    func toolConfigEntryBridge() throws {
        let jsonEntry = ToolConfigEntry(
            id: "GrokBuild:grep",
            paramsJson: #"{"max_results":50}"#,
            nameOverride: "search",
            paramsNameOverrides: ["pattern": "query"],
            behaviorVersion: "legacy-0.4.10",
            descriptionOverride: "Search"
        )
        let pb = GrokToolsV1.ToolConfigEntry.fromJSONWire(jsonEntry)
        let bytes = pb.protobufData()
        let back = try GrokToolsV1.ToolConfigEntry(protobufBytes: bytes)
        #expect(back.id == "GrokBuild:grep")
        #expect(back.paramsJson == #"{"max_results":50}"#)
        #expect(back.nameOverride == "search")
        #expect(back.paramsNameOverrides["pattern"] == "query")
        #expect(back.jsonWire == jsonEntry)
    }

    @Test("unknown enum values are preserved")
    func unknownEnum() {
        let cat = ToolCategory(rawValue: 99)
        #expect(cat.rawValue == 99)
        if case .UNRECOGNIZED(let v) = cat {
            #expect(v == 99)
        } else {
            Issue.record("expected UNRECOGNIZED")
        }
    }

    @Test("service descriptor paths match package")
    func servicePaths() {
        #expect(GrokToolsServiceDescriptor.serviceName == "xai.grok.tools.v1.GrokToolsService")
        #expect(GrokToolsServiceDescriptor.methodExecuteTool.hasSuffix("/ExecuteTool"))
        #expect(GrokToolsServiceDescriptor.methodExecuteToolStream.hasSuffix("/ExecuteToolStream"))
        #expect(GrokToolsServiceDescriptor.methodListTools.hasSuffix("/ListTools"))
        #expect(GrokToolsServiceDescriptor.methodFinalizeToolConfigRequest.hasSuffix("/FinalizeToolConfigRequest"))
        #expect(grokToolsProtoPackage == "xai.grok.tools.v1")
        #expect(grokToolsServiceRPCNames.contains("ExecuteTool"))
        #expect(grokToolsServiceStreamingRPCs.contains("ExecuteToolStream"))
    }

    @Test("TruncationConfig map field round-trips")
    func truncationConfig() throws {
        var cfg = TruncationConfig()
        cfg.defaultMaxOutputBytes = 40_000
        cfg.perToolMaxOutputBytes = ["grep": 10_000, "bash": 20_000]
        cfg.maxLinesRead = 1000
        let back = try TruncationConfig(protobufBytes: cfg.protobufData())
        #expect(back.defaultMaxOutputBytes == 40_000)
        #expect(back.perToolMaxOutputBytes["grep"] == 10_000)
        #expect(back.perToolMaxOutputBytes["bash"] == 20_000)
        #expect(back.maxLinesRead == 1000)
    }
}

// MARK: - In-process service smoke

private struct StubGrokToolsService: GrokToolsService {
    func executeTool(_ request: ExecuteToolRequest) async throws -> ExecuteToolResponse {
        var resp = ExecuteToolResponse()
        resp.callId = request.callId ?? "generated"
        resp.result = .success(ToolSuccess(outputJson: "{}", promptText: "ok"))
        return resp
    }
    func executeToolStream(_ request: ExecuteToolRequest) async throws -> AsyncThrowingStream<ToolStreamChunk, Error> {
        AsyncThrowingStream { cont in
            var chunk = ToolStreamChunk()
            chunk.callId = request.toolName
            chunk.chunk = .finalResult(StreamFinalResult())
            cont.yield(chunk)
            cont.finish()
        }
    }
    func listTools(_ request: ListToolsRequest) async throws -> ListToolsResponse {
        _ = request
        var r = ListToolsResponse()
        r.totalCount = 0
        return r
    }
    func getToolInfo(_ request: GetToolInfoRequest) async throws -> ToolInfo {
        var info = ToolInfo()
        info.name = request.toolName
        return info
    }
    func finalizeToolConfigRequest(_ request: FinalizeToolServerConfigRequest) async throws -> FinalizeToolServerConfigResponse {
        var r = FinalizeToolServerConfigResponse()
        r.success = true
        r.message = "ok (\(request.tools.count) tools)"
        return r
    }
    func getToolState(_ request: GetToolStateRequest) async throws -> GetToolStateResponse {
        _ = request
        var r = GetToolStateResponse()
        r.stateJson = #"{}"#
        return r
    }
    func enableTool(_ request: EnableToolRequest) async throws -> EnableToolResponse {
        var r = EnableToolResponse(); r.success = true; r.message = request.toolName; return r
    }
    func disableTool(_ request: DisableToolRequest) async throws -> DisableToolResponse {
        var r = DisableToolResponse(); r.success = true; r.message = request.toolName; return r
    }
    func setToolOptions(_ request: SetToolOptionsRequest) async throws -> SetToolOptionsResponse {
        var r = SetToolOptionsResponse(); r.success = true; r.effectiveOptionsJson = request.optionsJson; return r
    }
    func getToolOptions(_ request: GetToolOptionsRequest) async throws -> GetToolOptionsResponse {
        var r = GetToolOptionsResponse(); r.toolName = request.toolName; return r
    }
    func resetToolOptions(_ request: ResetToolOptionsRequest) async throws -> ResetToolOptionsResponse {
        var r = ResetToolOptionsResponse(); r.success = true; r.message = request.toolName; return r
    }
    func setToolOverride(_ request: SetToolOverrideRequest) async throws -> SetToolOverrideResponse {
        var r = SetToolOverrideResponse(); r.success = true; r.message = request.toolName; return r
    }
    func clearToolOverride(_ request: ClearToolOverrideRequest) async throws -> ClearToolOverrideResponse {
        var r = ClearToolOverrideResponse(); r.success = true; r.message = request.toolName; return r
    }
    func setSystemReminders(_ request: SetSystemRemindersRequest) async throws -> SetSystemRemindersResponse {
        var r = SetSystemRemindersResponse(); r.success = true; r.enabled = request.enabled; return r
    }
    func getSystemReminders(_ request: GetSystemRemindersRequest) async throws -> GetSystemRemindersResponse {
        _ = request
        var r = GetSystemRemindersResponse(); r.enabled = false; return r
    }
    func setTruncationConfig(_ request: SetTruncationConfigRequest) async throws -> SetTruncationConfigResponse {
        _ = request
        return SetTruncationConfigResponse()
    }
    func getTruncationConfig(_ request: GetTruncationConfigRequest) async throws -> GetTruncationConfigResponse {
        _ = request
        return GetTruncationConfigResponse()
    }
    func getSystemPrompt(_ request: GetSystemPromptRequest) async throws -> GetSystemPromptResponse {
        var r = GetSystemPromptResponse(); r.systemPrompt = request.variant; return r
    }
    func getAgentInfo(_ request: GetAgentInfoRequest) async throws -> GetAgentInfoResponse {
        _ = request
        return GetAgentInfoResponse()
    }
    func getCompletionState(_ request: GetCompletionStateRequest) async throws -> GetCompletionStateResponse {
        _ = request
        return GetCompletionStateResponse()
    }
    func resetCompletionState(_ request: ResetCompletionStateRequest) async throws -> ResetCompletionStateResponse {
        _ = request
        return ResetCompletionStateResponse()
    }
    func finalizeAgent(_ request: FinalizeAgentRequest) async throws -> FinalizeAgentResponse {
        _ = request
        var r = FinalizeAgentResponse(); r.success = true; return r
    }
}

@Suite("GrokToolsService")
struct GrokToolsServiceTests {
    @Test("stub service implements every RPC family")
    func stubRPCs() async throws {
        let svc = StubGrokToolsService()
        var exec = ExecuteToolRequest()
        exec.toolName = "echo"
        exec.inputJson = "{}"
        let execResp = try await svc.executeTool(exec)
        #expect(execResp.callId == "generated")

        let list = try await svc.listTools(ListToolsRequest())
        #expect(list.totalCount == 0)

        var fin = FinalizeToolServerConfigRequest()
        fin.tools = [GrokToolsV1.ToolConfigEntry(id: "GrokBuild:grep")]
        let finResp = try await svc.finalizeToolConfigRequest(fin)
        #expect(finResp.success)

        let info = try await svc.getToolInfo(GetToolInfoRequest(toolName: "grep"))
        #expect(info.name == "grep")

        var streamCount = 0
        for try await _ in try await svc.executeToolStream(exec) {
            streamCount += 1
        }
        #expect(streamCount == 1)
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
