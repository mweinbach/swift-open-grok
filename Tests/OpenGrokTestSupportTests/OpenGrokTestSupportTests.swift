// OpenGrokTestSupportTests.swift
//
// Target-scoped Swift Testing suites for the W0-S2 `OpenGrokTestSupport`
// target. Ports the deterministic tests from `xai-grok-test-support`'s
// `sse.rs` and `mock_server.rs` (the byte-exactness pins, the scripted FIFO
// precedence, the required-auth gate, the request-log capture) and adds
// focused coverage for the W0-S2 acceptance primitive: every helper that
// spawns a subprocess or creates a temp directory does so via `HermeticEnv`
// (isolated HOME / USERPROFILE / OPENGROK_HOME, refusal of the real
// `~/.opengrok`).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenGrokTestSupport
import OpenGrokTestUtilities
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Cross-platform `SOCK_STREAM` value: on Darwin it is already `Int32`,
/// on Linux/Windows it is a struct with a `.rawValue` Int32 member. Used
/// by the BSD-socket test helpers below.
private var sockStreamType: Int32 {
    #if canImport(Darwin)
    return SOCK_STREAM
    #else
    return Int32(SOCK_STREAM.rawValue)
    #endif
}

@Suite("OpenGrokTestSupport")
struct OpenGrokTestSupportTests {
    // MARK: - SseEvents byte-exactness pins

    /// The mermaid-fence text the Rust byte-exactness pins use.
    private static let mermaidText =
        "Here is a flow:\n\n```mermaid\nflowchart TD\n  A --> B\n  B --> C\n```\n\nDone rendering.\n"

    @Test("chat completion deltas reconstruct multiline response byte-for-byte")
    func chatDeltasByteExact() throws {
        let events = SseEvents.chatCompletionEventsExact(text: Self.mermaidText, model: "m")
        // Concatenate the content deltas from each chunk's `choices[0].delta.content`.
        let reconstructed = events.compactMap { event -> String? in
            guard event.data != "[DONE]" else { return nil }
            guard let value = try? JSONValue.decode(event.data) else { return nil }
            return value["choices"][0]["delta"]["content"].stringValue
        }.joined()
        #expect(reconstructed == Self.mermaidText)
        // The fence survives as a newline-delimited code block.
        #expect(reconstructed.contains("```mermaid\nflowchart TD\n"))
    }

    @Test("responses API deltas reconstruct multiline response byte-for-byte")
    func responsesDeltasByteExact() throws {
        let events = SseEvents.responsesApiEventsExact(text: Self.mermaidText, model: "m")
        let reconstructed = events.compactMap { event -> String? in
            guard event.data != "[DONE]" else { return nil }
            guard let value = try? JSONValue.decode(event.data) else { return nil }
            guard value["type"].stringValue == "response.output_text.delta" else { return nil }
            return value["delta"].stringValue
        }.joined()
        #expect(reconstructed == Self.mermaidText)
    }

    @Test("chat completion deltas preserve runs of whitespace")
    func chatDeltasWhitespaceRuns() throws {
        let text = "a  b\tc\n"
        let events = SseEvents.chatCompletionEventsExact(text: text, model: "m")
        let reconstructed = events.compactMap { event -> String? in
            guard event.data != "[DONE]" else { return nil }
            guard let value = try? JSONValue.decode(event.data) else { return nil }
            return value["choices"][0]["delta"]["content"].stringValue
        }.joined()
        #expect(reconstructed == text)
    }

    @Test("responses API deltas preserve runs of whitespace")
    func responsesDeltasWhitespaceRuns() throws {
        let text = "a  b\tc\n"
        let events = SseEvents.responsesApiEventsExact(text: text, model: "m")
        let reconstructed = events.compactMap { event -> String? in
            guard event.data != "[DONE]" else { return nil }
            guard let value = try? JSONValue.decode(event.data) else { return nil }
            guard value["type"].stringValue == "response.output_text.delta" else { return nil }
            return value["delta"].stringValue
        }.joined()
        #expect(reconstructed == text)
    }

    // MARK: - SseEvents shape guards

    @Test("reasoning-only events carry reasoning and no output text")
    func reasoningOnlyShape() throws {
        let events = SseEvents.responsesApiReasoningOnlyEvents(reasoning: "alpha beta gamma", model: "m")
        #expect(events.last?.data == "[DONE]")
        let parsed = events.filter { $0.data != "[DONE]" }.compactMap { try? JSONValue.decode($0.data) }
        let types = parsed.compactMap { $0["type"].stringValue }
        let reasoningDelta = parsed.first { $0["type"].stringValue == "response.reasoning_summary_text.delta" }
        #expect(reasoningDelta != nil)
        #expect(reasoningDelta?["delta"].stringValue?.isEmpty == false)
        #expect(!types.contains("response.output_text.delta"))
        let completed = parsed.first { $0["type"].stringValue == "response.completed" }
        let output = completed?["response"]["output"].arrayValue
        #expect(output != nil)
        #expect(output?.contains { $0["type"].stringValue == "reasoning" } == true)
        #expect(output?.contains { $0["type"].stringValue == "message" } == false)
    }

    @Test("reasoning+text events carry both items in order")
    func reasoningAndTextShape() throws {
        let events = SseEvents.responsesApiReasoningAndTextEvents(reasoning: "alpha beta", text: "the answer", model: "m")
        #expect(events.last?.data == "[DONE]")
        let parsed = events.filter { $0.data != "[DONE]" }.compactMap { try? JSONValue.decode($0.data) }
        let types = parsed.compactMap { $0["type"].stringValue }
        let firstReasoning = types.firstIndex(of: "response.reasoning_summary_text.delta")
        let firstText = types.firstIndex(of: "response.output_text.delta")
        #expect(firstReasoning != nil)
        #expect(firstText != nil)
        #expect(firstReasoning! < firstText!)
        let completed = parsed.first { $0["type"].stringValue == "response.completed" }
        let output = completed?["response"]["output"].arrayValue
        #expect(output?[0]["summary"][0]["text"].stringValue == "alpha beta")
        #expect(output?[1]["content"][0]["text"].stringValue == "the answer")
    }

    @Test("reasoning-then-tool-call events carry reasoning and function_call")
    func reasoningThenToolCallShape() throws {
        let events = SseEvents.responsesApiReasoningThenToolCallEvents(
            reasoning: "alpha beta", callId: "call_1", name: "read_file",
            arguments: "{\"target_file\":\"a.rs\"}", model: "m"
        )
        #expect(events.last?.data == "[DONE]")
        let parsed = events.filter { $0.data != "[DONE]" }.compactMap { try? JSONValue.decode($0.data) }
        let types = parsed.compactMap { $0["type"].stringValue }
        let firstReasoning = types.firstIndex(of: "response.reasoning_summary_text.delta")
        let argsDelta = types.firstIndex(of: "response.function_call_arguments.delta")
        #expect(firstReasoning! < argsDelta!)
        #expect(!types.contains("response.output_text.delta"))
        let completed = parsed.first { $0["type"].stringValue == "response.completed" }
        let output = completed?["response"]["output"].arrayValue
        #expect(output?[0]["summary"][0]["text"].stringValue == "alpha beta")
        #expect(output?[1]["type"].stringValue == "function_call")
        #expect(output?[1]["call_id"].stringValue == "call_1")
        #expect(output?[1]["name"].stringValue == "read_file")
        #expect(output?.contains { $0["type"].stringValue == "message" } == false)
    }

    @Test("chat-completions reasoning-then-tool-call events finish with finish_reason=tool_calls")
    func chatReasoningThenToolCallShape() throws {
        let events = SseEvents.chatCompletionsReasoningThenToolCallEvents(
            reasoning: "alpha beta", callId: "call_1", name: "read_file",
            arguments: "{\"target_file\":\"a.rs\"}", model: "m"
        )
        #expect(events.last?.data == "[DONE]")
        let parsed = events.filter { $0.data != "[DONE]" }.compactMap { try? JSONValue.decode($0.data) }
        let deltaAt: (JSONValue) -> JSONValue = { $0["choices"][0]["delta"] }
        let firstReasoning = parsed.firstIndex { !deltaAt($0)["reasoning_content"].isNull }
        let toolCall = parsed.firstIndex { !deltaAt($0)["tool_calls"].isNull }
        #expect(firstReasoning! < toolCall!)
        let call = deltaAt(parsed[toolCall!])["tool_calls"][0]
        #expect(call["id"].stringValue == "call_1")
        #expect(call["function"]["name"].stringValue == "read_file")
        #expect(parsed.contains { $0["choices"][0]["finish_reason"].stringValue == "tool_calls" })
    }

    // MARK: - Doom-loop check trio

    @Test("doom-loop check events send growing named frames and terminal field")
    func doomLoopCheckShape() throws {
        let triggers = ["tail_repetition:4@response", "tail_repetition:2@response"]
        let events = SseEvents.responsesApiDoomLoopCheckEvents(triggers: triggers, reasoning: "looping thought", model: "m")
        #expect(events.last?.data == "[DONE]")
        let frames = events.filter { $0.event == SseEvents.doomLoopCheckEvent }
        #expect(frames.count == 2) // one frame per cumulative prefix
        let first = try JSONValue.decode(frames[0].data)
        #expect(first["type"].stringValue == SseEvents.doomLoopCheckEvent)
        #expect(first["doom_loop_check"]["triggers"].arrayValue?.count == 1)
        let second = try JSONValue.decode(frames[1].data)
        #expect(second["doom_loop_check"]["triggers"].arrayValue?.count == 2)
        // Terminal completed event carries the full trigger set.
        let completed = events.filter { $0.data != "[DONE]" }
            .compactMap { try? JSONValue.decode($0.data) }
            .first { $0["type"].stringValue == "response.completed" }
        #expect(completed?["response"]["doom_loop_check"]["triggers"].arrayValue?.count == 2)
        // Reasoning-only: no message item.
        let output = completed?["response"]["output"].arrayValue
        #expect(output?.contains { $0["type"].stringValue == "message" } == false)
    }

    @Test("doom-loop terminal-only events carry field without mid-stream frame")
    func doomLoopTerminalOnlyShape() throws {
        let events = SseEvents.responsesApiDoomLoopTerminalOnlyEvents(
            triggers: ["low_logprob@thinking"], reasoning: "brief thought", text: "the answer", model: "m"
        )
        #expect(events.allSatisfy { $0.event == nil }) // no named check frame
        let completed = events.filter { $0.data != "[DONE]" }
            .compactMap { try? JSONValue.decode($0.data) }
            .first { $0["type"].stringValue == "response.completed" }
        #expect(completed?["response"]["doom_loop_check"]["triggers"].arrayValue?.count == 1)
        let output = completed?["response"]["output"].arrayValue
        #expect(output?.contains { $0["type"].stringValue == "message" } == true)
        #expect(output?.contains { $0["type"].stringValue == "reasoning" } == true)
    }

    @Test("with-doom-loop-frame splices the payload verbatim right after response.created")
    func doomLoopSpliceShape() throws {
        let payload = #"{"type":"response.doom_loop_check","doom_loop_check":{"triggers":42}}"#
        let events = SseEvents.responsesApiWithDoomLoopFrame(
            checkFrameData: payload, reasoning: "hm", text: "hi", model: "m"
        )
        #expect(events[1].event == SseEvents.doomLoopCheckEvent)
        #expect(events[1].data == payload)
        let created = try JSONValue.decode(events[0].data)
        #expect(created["type"].stringValue == "response.created")
    }

    // MARK: - ScriptedResponse validation

    @Test("ScriptedResponse.validate rejects invalid status codes")
    func scriptedInvalidStatus() {
        #expect(throws: ScriptedResponseError.self) {
            try ScriptedResponse.text(status: 999, "x").validate()
        }
        #expect(throws: ScriptedResponseError.self) {
            try ScriptedResponse.text(status: 99, "x").validate()
        }
    }

    @Test("ScriptedResponse.validate accepts valid status codes")
    func scriptedValidStatus() throws {
        try ScriptedResponse.text(status: 200, "ok").validate()
        try ScriptedResponse.text(status: 404, "missing").validate()
        try ScriptedResponse.text(status: 500, "boom").validate()
    }

    // MARK: - MockInferenceServer (HTTP round-trip)

    @Test("MockInferenceServer echo mode echoes last user message over HTTP")
    func echoModeRoundTrip() throws {
        let server = try MockInferenceServer()
        defer { server.stop() }
        let body = try postChat(server: server, content: "ping pong")
        let text = chatStreamText(body)
        #expect(text == "Echo: ping pong")
    }

    @Test("MockInferenceServer fixed mode reconstructs byte-exact over HTTP")
    func fixedModeRoundTrip() throws {
        let server = try MockInferenceServer()
        defer { server.stop() }
        server.setResponse(Self.mermaidText)
        let body = try postChat(server: server, content: "ignored")
        let text = chatStreamText(body)
        #expect(text == Self.mermaidText)
    }

    @Test("MockInferenceServer settings 404 until set then 200")
    func settingsRoundTrip() throws {
        let server = try MockInferenceServer()
        defer { server.stop() }
        let url = server.url + "/settings"
        // First: 404.
        let (status404, _) = try httpGet(url: url)
        #expect(status404 == 404)
        // After set_settings: 200 with the value.
        server.setSettings(.object([("tips", .array([.string("t1")]))]))
        let (status200, body) = try httpGet(url: url)
        #expect(status200 == 200)
        let value = try JSONValue.decode(body)
        #expect(value["tips"][0].stringValue == "t1")
        // preset_allow_access: 200 with {"allow_access": true}.
        server.presetAllowAccess()
        let (statusAllow, bodyAllow) = try httpGet(url: url)
        #expect(statusAllow == 200)
        let allowValue = try JSONValue.decode(bodyAllow)
        #expect(allowValue["allow_access"].boolValue == true)
    }

    @Test("MockInferenceServer request log captures arbitrary headers")
    func requestLogHeaders() throws {
        let server = try MockInferenceServer()
        defer { server.stop() }
        let url = server.url + "/chat/completions"
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("Bearer log-me", forHTTPHeaderField: "Authorization")
        request.setValue("zap", forHTTPHeaderField: "X-Test-Marker")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "test-model",
            "messages": [["role": "user", "content": "hi"]],
        ])
        _ = try synchronousData(for: request)
        let entries = server.requests()
        let entry = try #require(entries.last)
        #expect(entry.header("x-test-marker") == "zap")
        #expect(entry.header("X-Test-Marker") == "zap")
        #expect(entry.header("authorization") == "Bearer log-me")
        #expect(entry.authorization == "Bearer log-me")
        #expect(entry.header("x-absent") == nil)
    }

    @Test("MockInferenceServer required-auth rejects missing token then accepts valid token")
    func requiredAuthGate() throws {
        let server = try MockInferenceServer(models: [MockModelEntry(id: "test-model")], requiredToken: "secret-token")
        defer { server.stop() }
        // Missing auth: 401.
        let (status401, _) = try postChatStatus(server: server, content: "hi", auth: nil)
        #expect(status401 == 401)
        // Valid auth: 200.
        let (status200, _) = try postChatStatus(server: server, content: "hi there", auth: "Bearer secret-token")
        #expect(status200 == 200)
    }

    @Test("MockInferenceServer scripted responses serve FIFO per path then fall back")
    func scriptedFIFORoundTrip() throws {
        let server = try MockInferenceServer()
        defer { server.stop() }
        try server.enqueueResponse(path: "/v1/chat/completions", response: .text(status: 401, "Unauthorized"))
        try server.enqueueResponse(path: "/v1/chat/completions", response: .json(status: 500, .object([("error", .object([("message", .string("boom"))]))])))
        // FIFO: 401 first.
        let (s1, b1) = try postChatStatus(server: server, content: "hi", auth: nil)
        #expect(s1 == 401)
        #expect(String(data: b1, encoding: .utf8) == "Unauthorized")
        // Then 500.
        let (s2, b2) = try postChatStatus(server: server, content: "hi", auth: nil)
        #expect(s2 == 500)
        let v2 = try JSONValue.decode(b2)
        #expect(v2["error"]["message"].stringValue == "boom")
        // Queue drained: falls back to echo.
        let body = try postChat(server: server, content: "ping pong")
        #expect(chatStreamText(body) == "Echo: ping pong")
    }

    @Test("MockInferenceServer /v1/models returns the configured list")
    func modelsEndpoint() throws {
        let server = try MockInferenceServer(models: [
            MockModelEntry(id: "alpha"),
            MockModelEntry.withAgentType(id: "beta", agentType: "cursor").withProvider("xai"),
        ])
        defer { server.stop() }
        let (status, body) = try httpGet(url: server.url + "/models")
        #expect(status == 200)
        let value = try JSONValue.decode(body)
        let data = try #require(value["data"].arrayValue)
        #expect(data.count == 2)
        #expect(data[0]["id"].stringValue == "alpha")
        #expect(data[1]["id"].stringValue == "beta")
        #expect(data[1]["_meta"]["agentType"].stringValue == "cursor")
        #expect(data[1]["provider"].stringValue == "xai")
    }

    @Test("MockInferenceServer /v1/user omits subscriptionTier by default and includes it when set")
    func userEndpointTier() throws {
        let server = try MockInferenceServer()
        defer { server.stop() }
        // Default: no subscriptionTier field.
        let (status1, body1) = try httpGet(url: server.url + "/user")
        #expect(status1 == 200)
        let value1 = try JSONValue.decode(body1)
        #expect(value1["userId"].stringValue == "mock-user")
        #expect(value1["subscriptionTier"].isNull)
        // After set: tier present.
        server.setUserSubscriptionTier("pro")
        let (status2, body2) = try httpGet(url: server.url + "/user")
        #expect(status2 == 200)
        let value2 = try JSONValue.decode(body2)
        #expect(value2["subscriptionTier"].stringValue == "pro")
    }

    @Test("MockInferenceServer /v1/storage records uploads and honors the 401 gate")
    func storageUpload() throws {
        let server = try MockInferenceServer()
        defer { server.stop() }
        let url = URL(string: server.url + "/storage")!
        // Accepted upload.
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("path/to/blob", forHTTPHeaderField: "X-Storage-Path")
        request.setValue("Bearer test", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(repeating: 0x41, count: 16)
        _ = try synchronousData(for: request)
        #expect(server.storageRequestCount() == 1)
        let uploads = server.storageUploads()
        #expect(uploads.count == 1)
        #expect(uploads[0].path == "path/to/blob")
        #expect(uploads[0].size == 16)
        #expect(uploads[0].authorization == "Bearer test")
        // Flip the 401 gate.
        server.setStorageUnauthorized(true)
        _ = try synchronousData(for: request)
        #expect(server.storageRequestCount() == 2)
        #expect(server.storageUploads().count == 1) // the 401 didn't record
    }

    @Test("MockInferenceServer agent-turn script is consumed only by tool-bearing turns")
    func agentTurnScriptQueue() throws {
        let server = try MockInferenceServer()
        defer { server.stop() }
        try server.enqueueAgentTurnResponse(.text(status: 200, "agent-turn-reply"))
        // A request with no tools falls through to echo mode (the queued
        // script is not consumed).
        let bodyNoTools = try postChat(server: server, content: "hi")
        #expect(chatStreamText(bodyNoTools) == "Echo: hi")
        // The script is still queued for the next tool-bearing request.
        let url = URL(string: server.url + "/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "test-model",
            "messages": [["role": "user", "content": "go"]],
            "tools": [["type": "function", "function": ["name": "a"]], ["type": "function", "function": ["name": "b"]]],
        ])
        let (data, response) = try synchronousData(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        #expect(status == 200)
        #expect(String(data: data, encoding: .utf8) == "agent-turn-reply")
    }

    @Test("MockInferenceServer requestBodies skips body-less requests and preserves order")
    func requestBodiesOrder() throws {
        let server = try MockInferenceServer()
        defer { server.stop() }
        _ = try postChat(server: server, content: "first")
        // Body-less GET in between must be skipped, not break ordering.
        _ = try httpGet(url: server.url + "/models")
        _ = try postChat(server: server, content: "second")
        let bodies = server.requestBodies()
        #expect(bodies.count == 2)
        #expect(bodies[0]["messages"][0]["content"].stringValue == "first")
        #expect(bodies[1]["messages"][0]["content"].stringValue == "second")
    }

    @Test("MockInferenceServer hasChatCompletionRequest / hasResponsesRequest / messagesRequestCount")
    func requestCounters() throws {
        let server = try MockInferenceServer()
        defer { server.stop() }
        _ = try postChat(server: server, content: "hi")
        #expect(server.hasChatCompletionRequest())
        #expect(!server.hasResponsesRequest())
        #expect(server.messagesRequestCount() == 0)
        // POST /v1/messages.
        let url = URL(string: server.url + "/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "test-model",
            "messages": [["role": "user", "content": "hi"]],
        ])
        _ = try synchronousData(for: request)
        #expect(server.messagesRequestCount() == 1)
    }

    @Test("MockInferenceServer scripted raw body served byte-exact")
    func scriptedRawBody() throws {
        let server = try MockInferenceServer()
        defer { server.stop() }
        let raw = "data: {\"choices\":[]}\n\ndata: not-json-at-all\n\ndata: [DONE]\n\n"
        try server.enqueueResponse(path: "/v1/chat/completions", response: .text(status: 200, raw))
        let body = try postChat(server: server, content: "hi")
        #expect(body == raw)
    }

    @Test("MockInferenceServer scripted SSE preserves event names and order")
    func scriptedSSEOrder() throws {
        let server = try MockInferenceServer()
        defer { server.stop() }
        try server.enqueueResponse(path: "/v1/chat/completions", response: .sse([
            .withEvent("custom.kind", data: "{\"a\":1}"),
            .data("{\"b\":2}"),
        ]))
        let body = try postChat(server: server, content: "hi")
        let namedRange = body.range(of: "event: custom.kind")
        let plainRange = body.range(of: "data: {\"b\":2}")
        #expect(namedRange != nil)
        #expect(plainRange != nil)
        #expect(namedRange!.lowerBound < plainRange!.lowerBound)
        #expect(body.contains("event: custom.kind"))
        #expect(body.contains("data: {\"a\":1}"))
    }

    @Test("MockInferenceServer scripted response takes precedence over required auth")
    func scriptedPrecedenceOverAuth() throws {
        let server = try MockInferenceServer(models: [MockModelEntry(id: "test-model")], requiredToken: "secret-token")
        defer { server.stop() }
        try server.enqueueResponse(path: "/v1/chat/completions", response: .text(status: 200, "scripted"))
        // No token: the script still serves.
        let (s1, b1) = try postChatStatus(server: server, content: "hi", auth: nil)
        #expect(s1 == 200)
        #expect(String(data: b1, encoding: .utf8) == "scripted")
        // Queue drained: the auth gate applies again.
        let (s2, _) = try postChatStatus(server: server, content: "hi", auth: nil)
        #expect(s2 == 401)
    }

    @Test("MockInferenceServer scripted response headers reach the client")
    func scriptedHeaders() throws {
        let server = try MockInferenceServer()
        defer { server.stop() }
        var response = ScriptedResponse.text(status: 429, "slow down")
        response.headers.append(("retry-after", "7"))
        try server.enqueueResponse(path: "/v1/chat/completions", response: response)
        let url = URL(string: server.url + "/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "test-model",
            "messages": [["role": "user", "content": "hi"]],
        ])
        let (_, httpResponse) = try synchronousData(for: request)
        let http = try #require(httpResponse as? HTTPURLResponse)
        #expect(http.statusCode == 429)
        #expect(http.value(forHTTPHeaderField: "retry-after") == "7")
    }

    @Test("MockInferenceServer setAgentTurns serves byte-exact text only for tool-bearing turns")
    func setAgentTurnsText() throws {
        let server = try MockInferenceServer()
        defer { server.stop() }
        let mermaid = "```mermaid\nflowchart TD\n  A --> B\n```\n"
        server.setAgentTurns([mermaid])
        // Tool-bearing request consumes the queued turn.
        let url = URL(string: server.url + "/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "test-model",
            "messages": [["role": "user", "content": "go"]],
            "tools": [["type": "function", "function": ["name": "a"]], ["type": "function", "function": ["name": "b"]]],
        ])
        let (data, _) = try synchronousData(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(chatStreamText(body) == mermaid)
    }

    @Test("MockInferenceServer /v1/messages streams the last user text as a single delta")
    func messagesEndpoint() throws {
        let server = try MockInferenceServer()
        defer { server.stop() }
        let url = URL(string: server.url + "/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "test-model",
            "messages": [["role": "user", "content": "hello world"]],
        ])
        let (data, _) = try synchronousData(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        // Echo mode: messages endpoint emits "Echo: hello world" as a single
        // text_delta; reconstruct via `content_block_delta` deltas.
        let text = body.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("data:") else { return nil }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return nil }
            guard let value = try? JSONValue.decode(payload) else { return nil }
            guard value["type"].stringValue == "content_block_delta" else { return nil }
            return value["delta"]["text"].stringValue
        }.joined()
        #expect(text == "Echo: hello world")
        // The default stop_reason is "end_turn".
        #expect(body.contains("\"stop_reason\":\"end_turn\""))
    }

    @Test("MockInferenceServer setMessagesStopReason surfaces in the terminal message_delta")
    func messagesStopReason() throws {
        let server = try MockInferenceServer()
        defer { server.stop() }
        server.setMessagesStopReason("max_tokens")
        let url = URL(string: server.url + "/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "test-model",
            "messages": [["role": "user", "content": "hi"]],
        ])
        let (data, _) = try synchronousData(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(body.contains("\"stop_reason\":\"max_tokens\""))
    }

    @Test("MockInferenceServer /v1/responses streams output_text deltas in echo mode")
    func responsesEndpointEcho() throws {
        let server = try MockInferenceServer()
        defer { server.stop() }
        let url = URL(string: server.url + "/responses")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "test-model",
            "input": [["role": "user", "content": "hi there"]],
        ])
        let (data, _) = try synchronousData(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        let text = body.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("data:") else { return nil }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return nil }
            guard let value = try? JSONValue.decode(payload) else { return nil }
            guard value["type"].stringValue == "response.output_text.delta" else { return nil }
            return value["delta"].stringValue
        }.joined()
        // Echo mode for /v1/responses collapses whitespace: "hi there" → "hi there ".
        #expect(text == "Echo: hi there ")
    }

    @Test("MockInferenceServer lastSystemPrompt extracts the system prompt from chat completions")
    func lastSystemPrompt() throws {
        let server = try MockInferenceServer()
        defer { server.stop() }
        let url = URL(string: server.url + "/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "test-model",
            "messages": [
                ["role": "system", "content": "you are a test assistant"],
                ["role": "user", "content": "hi"],
            ],
        ])
        _ = try synchronousData(for: request)
        #expect(server.lastSystemPrompt() == "you are a test assistant")
    }

    @Test("MockInferenceServer presetAllowAccess sets {\"allow_access\": true}")
    func presetAllowAccess() throws {
        let server = try MockInferenceServer()
        defer { server.stop() }
        server.presetAllowAccess()
        let (status, body) = try httpGet(url: server.url + "/settings")
        #expect(status == 200)
        let value = try JSONValue.decode(body)
        #expect(value["allow_access"].boolValue == true)
    }

    @Test("MockInferenceServer setModels replaces the model list at runtime")
    func setModelsRuntime() throws {
        let server = try MockInferenceServer()
        defer { server.stop() }
        // Initial: one default "test-model".
        let (_, body1) = try httpGet(url: server.url + "/models")
        let value1 = try JSONValue.decode(body1)
        #expect(value1["data"].arrayValue?.count == 1)
        // Replace at runtime.
        server.setModels([MockModelEntry(id: "new-model")])
        let (_, body2) = try httpGet(url: server.url + "/models")
        let value2 = try JSONValue.decode(body2)
        #expect(value2["data"][0]["id"].stringValue == "new-model")
    }

    // MARK: - EnvGuard

    @Test("EnvGuard.set snapshots and restores the prior value")
    func envGuardRestore() throws {
        let key = "OG_TEST_ENVGUARD_\(UUID().uuidString)"
        let prior = ProcessInfo.processInfo.environment[key]
        #expect(prior == nil)
        let guard1 = EnvGuard.set(key, "first")
        #expect(ProcessInfo.processInfo.environment[key] == "first")
        // Disposing the first guard restores the prior (nil) value.
        // A second guard on the same key cannot overlap with the first
        // (the coordinator serializes per-key); this test disposes the
        // first guard explicitly before constructing the second, mirroring
        // the `#[serial]` invariant.
        guard1.dispose()
        #expect(ProcessInfo.processInfo.environment[key] == nil)
        let guard2 = EnvGuard.set(key, "second")
        #expect(ProcessInfo.processInfo.environment[key] == "second")
        guard2.dispose()
        #expect(ProcessInfo.processInfo.environment[key] == nil)
    }

    @Test("EnvGuard.unset removes and restores")
    func envGuardUnset() throws {
        let key = "OG_TEST_ENVGUARD_UNSET_\(UUID().uuidString)"
        let setGuard = EnvGuard.set(key, "initial")
        #expect(ProcessInfo.processInfo.environment[key] == "initial")
        setGuard.dispose()
        // Now the env is back to unset; the unset guard captures nil as
        // prior and restores nil on dispose.
        let unsetGuard = EnvGuard.unset(key)
        #expect(ProcessInfo.processInfo.environment[key] == nil)
        unsetGuard.dispose()
        #expect(ProcessInfo.processInfo.environment[key] == nil)
    }

    @Test("EnvGuard restores prior value when set after a non-guard set")
    func envGuardRestoresPriorValue() throws {
        // The Rust `EnvGuard` restores the prior value rather than always
        // unsetting — so a parent process's env var is preserved across a
        // guard lifetime. Verify the same here: set a value OUTSIDE a
        // guard, then set a guard that overwrites it, then dispose the
        // guard — the outside value must come back.
        let key = "OG_TEST_ENVGUARD_PRIOR_\(UUID().uuidString)"
        setenv(key, "outside", 1)
        defer { unsetenv(key) }
        let guard1 = EnvGuard.set(key, "inside")
        #expect(ProcessInfo.processInfo.environment[key] == "inside")
        guard1.dispose()
        #expect(ProcessInfo.processInfo.environment[key] == "outside")
    }

    @Test("EnvGuard snapshot is non-mutating and restores from an owned dictionary")
    func envGuardSnapshot() throws {
        // The snapshot variant does NOT touch the live env; it only
        // records the prior value from a caller-owned dictionary. Used by
        // helpers that pass explicit `environment: [String: String]` to a
        // child `Process` (the preferred non-mutating pattern).
        let env = ["MY_VAR": "from-dict"]
        let snap = EnvGuard.snapshot("MY_VAR", in: env)
        #expect(snap.key == "MY_VAR")
        // dispose is a no-op for snapshot guards.
        snap.dispose()
    }

    // MARK: - CountingServer (connection-counting, keep-alive)

    @Test("CountingServer counts accepted TCP connections, not requests")
    func countingServerCountsConnections() throws {
        // The Rust reference increments the accept counter EXACTLY ONCE
        // per accepted socket, then serves multiple requests over the same
        // socket via keep-alive. The previous Swift port routed through
        // `HttpServer` (which always sends `Connection: close` and cancels
        // after one response) AND bumped the counter from the request
        // handler — so it counted requests, not connections, and could
        // not validate pooling at all. This test pins the contract:
        // two requests over one retained client socket = 1 accept.
        let server = try spawnCountingServer()
        let url = URL(string: server.baseURL + "/chat/completions")!
        // Open a single raw TCP connection and send two HTTP/1.1 requests
        // over it without `Connection: close`, so the server keeps the
        // socket alive.
        let (acceptsBefore, _) = (server.accepts.value(), server.heads.value())
        #expect(acceptsBefore == 0)
        let (status1, body1, status2, body2) = try twoRequestsOverOneSocket(
            host: "127.0.0.1",
            port: boundPort(from: server.baseURL),
            path: "/v1/chat/completions"
        )
        #expect(status1 == 200)
        #expect(status2 == 200)
        #expect(String(data: body1, encoding: .utf8) == "{}")
        #expect(String(data: body2, encoding: .utf8) == "{}")
        // Two requests over ONE retained socket = exactly one accept.
        #expect(server.accepts.value() == 1)
        // Both request heads were recorded (per-request, not per-accept).
        #expect(server.heads.value().count == 2)
    }

    @Test("CountingServer records two accepts for two separate client sockets")
    func countingServerTwoClientsTwoAccepts() throws {
        // Separate client sockets yield separate accepts — this is the
        // negative case that proves the counter is per-connection, not a
        // single global bump.
        let server = try spawnCountingServer()
        let port = boundPort(from: server.baseURL)
        // First client: one request on its own socket.
        let (s1, _, _, _) = try twoRequestsOverOneSocket(
            host: "127.0.0.1", port: port, path: "/v1/chat/completions"
        )
        #expect(s1 == 200)
        // Second client: one request on a separate socket.
        let (s2, _, _, _) = try twoRequestsOverOneSocket(
            host: "127.0.0.1", port: port, path: "/v1/chat/completions"
        )
        #expect(s2 == 200)
        // Each client socket = one accept, so two separate clients = two
        // accepts total.
        #expect(server.accepts.value() == 2)
    }

    // MARK: - UdsProxy fault injection (Unix-only)

    #if os(macOS) || os(Linux)
    @Test("UdsProxy passes frames through untouched")
    func udsProxyPassthrough() throws {
        let tempRoot = "/tmp/og-uds-passthrough-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        let upstreamPath = "\(tempRoot)/real.sock"
        let upstream = try spawnEchoUpstream(path: upstreamPath)
        defer { upstream.stop() }
        // Give the echo upstream a moment to bind.
        Thread.sleep(forTimeInterval: 0.05)
        let proxy = try UdsProxy(
            proxyPath: "\(tempRoot)/proxy.sock",
            upstreamPath: upstreamPath,
            plan: FaultPlan()
        )
        defer { proxy.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let client = try connectUnix(path: proxy.proxyPath)
        defer { close(client) }
        for payload in ["one", "two", "three"] {
            try writeFrame(fd: client, body: payload)
            let echo = try readFrame(fd: client)
            #expect(echo == payload)
        }
        #expect(proxy.handle.forwarded(.clientToLeader) == 3)
        #expect(proxy.handle.forwarded(.leaderToClient) == 3)
    }

    @Test("UdsProxy.severNow drops active connections but allows reconnects")
    func udsProxySeverNowReconnect() throws {
        // The Rust `sever_now` cancels the CURRENT sever scope and swaps
        // in a FRESH one for later connections — so only connections
        // active at sever time die. The previous Swift port set a global
        // Boolean that was never reset, so EVERY subsequently accepted
        // connection died instantly. This test pins the contract: sever
        // an active connection, then reconnect through the same proxy and
        // prove the new connection works.
        let tempRoot = "/tmp/og-uds-sever-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        let upstreamPath = "\(tempRoot)/real.sock"
        let upstream = try spawnEchoUpstream(path: upstreamPath)
        defer { upstream.stop() }
        Thread.sleep(forTimeInterval: 0.05)
        let proxy = try UdsProxy(
            proxyPath: "\(tempRoot)/proxy.sock",
            upstreamPath: upstreamPath,
            plan: FaultPlan()
        )
        defer { proxy.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        // First connection: round-trip a frame, then sever.
        let client1 = try connectUnix(path: proxy.proxyPath)
        try writeFrame(fd: client1, body: "alive")
        let echo1 = try readFrame(fd: client1)
        #expect(echo1 == "alive")
        proxy.handle.severNow()
        // The active connection dies: the next read fails (EOF or error).
        let severedRead = try? readFrame(fd: client1)
        #expect(severedRead == nil)
        close(client1)

        // Reconnect through the same proxy. The fresh scope must allow
        // this connection to live — the previous implementation killed it
        // instantly because `severCancelled` was never reset.
        let client2 = try connectUnix(path: proxy.proxyPath)
        defer { close(client2) }
        try writeFrame(fd: client2, body: "after-sever")
        let echo2 = try readFrame(fd: client2)
        #expect(echo2 == "after-sever")
    }

    @Test("UdsProxy drops exactly the Nth frame")
    func udsProxyDropNth() throws {
        let tempRoot = "/tmp/og-uds-drop-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        let upstreamPath = "\(tempRoot)/real.sock"
        let upstream = try spawnEchoUpstream(path: upstreamPath)
        defer { upstream.stop() }
        Thread.sleep(forTimeInterval: 0.05)
        var plan = FaultPlan()
        plan.dropFrame = 2
        let proxy = try UdsProxy(
            proxyPath: "\(tempRoot)/proxy.sock",
            upstreamPath: upstreamPath,
            plan: plan
        )
        defer { proxy.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let client = try connectUnix(path: proxy.proxyPath)
        defer { close(client) }
        try writeFrame(fd: client, body: "first")
        try writeFrame(fd: client, body: "second")
        try writeFrame(fd: client, body: "third")
        // "second" is dropped; the client sees "first" then "third".
        #expect(try readFrame(fd: client) == "first")
        #expect(try readFrame(fd: client) == "third")
    }

    @Test("UdsProxy duplicates exactly the Nth frame")
    func udsProxyDuplicateNth() throws {
        let tempRoot = "/tmp/og-uds-dup-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        let upstreamPath = "\(tempRoot)/real.sock"
        let upstream = try spawnEchoUpstream(path: upstreamPath)
        defer { upstream.stop() }
        Thread.sleep(forTimeInterval: 0.05)
        var plan = FaultPlan()
        plan.duplicateFrame = 1
        let proxy = try UdsProxy(
            proxyPath: "\(tempRoot)/proxy.sock",
            upstreamPath: upstreamPath,
            plan: plan
        )
        defer { proxy.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let client = try connectUnix(path: proxy.proxyPath)
        defer { close(client) }
        try writeFrame(fd: client, body: "once")
        #expect(try readFrame(fd: client) == "once")
        #expect(try readFrame(fd: client) == "once")
    }
    #endif

    // MARK: - TestEnv hermeticity

    @Test("TestEnv.applyTestEnv sets isolated HOME/USERPROFILE/OPENGROK_HOME and mock URLs")
    func applyTestEnvHermetic() throws {
        let realHome = RealOpengrokHome(userHome: "/tmp/og-real-apply", opengrokHome: "/tmp/og-real-apply/.opengrok")
        let hermetic = try HermeticEnv(realHome: realHome, inherit: [:])
        defer { var mutable = hermetic; mutable.dispose() }
        let process = Process()
        TestEnv.applyTestEnv(to: process, hermetic: hermetic, mockURL: "http://127.0.0.1:9999/v1", environment: [:])
        #expect(process.environment?["HOME"] == hermetic.root.path)
        #expect(process.environment?["USERPROFILE"] == hermetic.root.path)
        #expect(process.environment?["OPENGROK_HOME"] == hermetic.opengrokHome.path)
        #expect(process.environment?["GROK_CLI_CHAT_PROXY_BASE_URL"] == "http://127.0.0.1:9999/v1")
        #expect(process.environment?["GROK_XAI_API_BASE_URL"] == "http://127.0.0.1:9999/v1")
        #expect(process.environment?["XAI_API_KEY"] == "test-key-for-ci")
        #expect(process.environment?["GROK_TELEMETRY_ENABLED"] == "false")
        // Inherited provider API keys are stripped.
        #expect(process.environment?["MOONSHOT_API_KEY"] == nil)
        #expect(process.environment?["OPENAI_API_KEY"] == nil)
    }

    @Test("TestEnv.gitWorkdir creates a temp git repo under a hermetic env")
    func gitWorkdirHermetic() throws {
        let realHome = RealOpengrokHome(
            userHome: "/tmp/og-real-git-\(UUID().uuidString)",
            opengrokHome: "/tmp/og-real-git-\(UUID().uuidString)/.opengrok"
        )
        let (env, repoPath) = try TestEnv.gitWorkdir(realHome: realHome, environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""])
        defer { var mutable = env; mutable.dispose() }
        #expect(env.environment["HOME"] == env.root.path)
        #expect(env.environment["OPENGROK_HOME"] == env.opengrokHome.path)
        // The repo is inside the hermetic env's root, never the real home.
        #expect(repoPath.path.hasPrefix(env.root.path))
        #expect(FileManager.default.fileExists(atPath: repoPath.appendingPathComponent("README.md").path))
        // The repo has at least one commit.
        let log = try HermeticGit.runGit(in: repoPath, arguments: ["log", "--oneline"], environment: HermeticGit.baseGitEnvironment(environment: env.environment))
        #expect(!log.isEmpty)
    }

    // MARK: - Headless crash detection

    @Test("Headless.assertNoCrashes passes on clean stderr")
    func assertNoCrashesClean() throws {
        try Headless.assertNoCrashes("all good")
    }

    @Test("Headless.assertNoCrashes throws on panic indicator")
    func assertNoCrashesPanic() {
        #expect(throws: HeadlessAssertionError.self) {
            try Headless.assertNoCrashes("thread panicked at 'foo'")
        }
    }

    @Test("Headless.assertNoCrashes throws on SIGSEGV")
    func assertNoCrashesSegv() {
        #expect(throws: HeadlessAssertionError.self) {
            try Headless.assertNoCrashes("fatal: SIGSEGV received")
        }
    }

    @Test("Headless.stderrTail truncates to the last N characters")
    func stderrTailTruncates() {
        let stderr = "abcdefghijklmnopqrstuvwxyz"
        let tail = Headless.stderrTail(stderr, maxChars: 5)
        #expect(tail == "vwxyz")
        #expect(Headless.stderrTail("short", maxChars: 100) == "short")
    }

    // MARK: - Helpers

    /// POST to `/v1/chat/completions` and return the response body as a string.
    private func postChat(server: MockInferenceServer, content: String) throws -> String {
        let ( _, data) = try postChatStatus(server: server, content: content, auth: nil)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// POST to `/v1/chat/completions` and return the HTTP status + body data.
    private func postChatStatus(server: MockInferenceServer, content: String, auth: String?) throws -> (UInt16, Data) {
        let url = URL(string: server.url + "/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "test-model",
            "messages": [["role": "user", "content": content]],
        ])
        let (data, response) = try synchronousData(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (UInt16(status), data)
    }

    /// GET `url` and return the HTTP status + body data.
    private func httpGet(url: String) throws -> (UInt16, Data) {
        let (data, response) = try synchronousData(for: URLRequest(url: URL(string: url)!))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (UInt16(status), data)
    }

    /// Result slot for `synchronousData`. A box rather than captured `var`s
    /// because corelibs types the completion handler `@Sendable`, so mutating
    /// captured locals from it does not compile on Linux.
    private final class DataTaskResult: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (data: Data?, response: URLResponse?, error: Error?) = (nil, nil, nil)

        func store(_ data: Data?, _ response: URLResponse?, _ error: Error?) {
            lock.lock()
            defer { lock.unlock() }
            value = (data, response, error)
        }

        func take() -> (data: Data?, response: URLResponse?, error: Error?) {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private struct MissingResponse: Error {}

    /// Synchronous wrapper around `URLSession.dataTask` using a semaphore.
    private func synchronousData(for request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        let result = DataTaskResult()
        URLSession.shared.dataTask(with: request) { data, response, error in
            result.store(data, response, error)
            semaphore.signal()
        }.resume()
        semaphore.wait()
        let outcome = result.take()
        if let error = outcome.error { throw error }
        guard let response = outcome.response else { throw MissingResponse() }
        return (outcome.data ?? Data(), response)
    }

    /// Concatenation of all chat-completion content deltas in an SSE body.
    private func chatStreamText(_ body: String) -> String {
        body.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("data:") else { return nil }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return nil }
            guard let value = try? JSONValue.decode(payload) else { return nil }
            return value["choices"][0]["delta"]["content"].stringValue
        }.joined()
    }

    /// Extract the TCP port from a base URL of the form
    /// `http://127.0.0.1:<port>/...`.
    private func boundPort(from baseURL: String) -> Int {
        // Find the port between `:` after the host and the next `/`.
        guard let colonRange = baseURL.range(of: "127.0.0.1:") else { return 0 }
        let afterColon = baseURL[colonRange.upperBound...]
        let portEnd = afterColon.firstIndex(of: "/") ?? afterColon.endIndex
        return Int(afterColon[..<portEnd]) ?? 0
    }

    /// Open a single TCP connection to `host:port`, send two sequential
    /// HTTP/1.1 requests over it WITHOUT `Connection: close` (so the
    /// counting server keeps the socket alive), and return the status codes
    /// and bodies for both. This proves the server counts accepts (one per
    /// socket) rather than requests (one per request).
    private func twoRequestsOverOneSocket(
        host: String, port: Int, path: String
    ) throws -> (UInt16, Data, UInt16, Data) {
        let fd = socket(AF_INET, sockStreamType, 0)
        if fd < 0 { throw NSError(domain: "CountingServerTest", code: 1) }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Foundation.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected < 0 {
            throw NSError(domain: "CountingServerTest", code: 2)
        }
        // Two identical POSTs without `Connection: close`: the counting
        // server must keep the socket alive between them.
        let body = "{\"model\":\"test\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"
        let bodyBytes = Data(body.utf8)
        let head = "POST \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nContent-Type: application/json\r\nContent-Length: \(bodyBytes.count)\r\nConnection: keep-alive\r\n\r\n"
        func sendRequest() throws {
            let headBytes = Data(head.utf8)
            try sendAll(fd: fd, data: headBytes)
            try sendAll(fd: fd, data: bodyBytes)
        }
        func readResponse() throws -> (UInt16, Data) {
            // Read until \r\n\r\n, parse status + content-length, then
            // read exactly content-length bytes.
            var buf = Data()
            while buf.range(of: Data("\r\n\r\n".utf8)) == nil {
                var chunk = [UInt8](repeating: 0, count: 4096)
                let n = chunk.withUnsafeMutableBufferPointer { ptr in
                    Foundation.read(fd, ptr.baseAddress, ptr.count)
                }
                if n <= 0 {
                    throw NSError(domain: "CountingServerTest", code: 3)
                }
                buf.append(contentsOf: chunk.prefix(n))
            }
            let headEnd = buf.range(of: Data("\r\n\r\n".utf8))!.upperBound
            let headString = String(data: buf.prefix(headEnd), encoding: .utf8) ?? ""
            let statusLine = headString.components(separatedBy: "\r\n").first ?? ""
            let statusParts = statusLine.split(separator: " ")
            let status = UInt16(statusParts.count >= 2 ? Int(statusParts[1]) ?? 0 : 0)
            let contentLength = headString.components(separatedBy: "\r\n")
                .compactMap { line -> Int? in
                    guard let colon = line.firstIndex(of: ":") else { return nil }
                    let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    guard name == "content-length" else { return nil }
                    return Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)) ?? 0
                }
                .first ?? 0
            var body = buf.suffix(from: headEnd)
            while body.count < contentLength {
                var chunk = [UInt8](repeating: 0, count: 4096)
                let n = chunk.withUnsafeMutableBufferPointer { ptr in
                    Foundation.read(fd, ptr.baseAddress, ptr.count)
                }
                if n <= 0 { break }
                body.append(contentsOf: chunk.prefix(n))
            }
            return (status, Data(body.prefix(contentLength)))
        }
        try sendRequest()
        let r1 = try readResponse()
        try sendRequest()
        let r2 = try readResponse()
        return (r1.0, r1.1, r2.0, r2.1)
    }

    /// Write `data` fully to `fd`, retrying partial writes.
    private func sendAll(fd: Int32, data: Data) throws {
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { ptr -> Int in
                Foundation.write(fd, ptr.baseAddress!.advanced(by: sent), data.count - sent)
            }
            if n <= 0 {
                throw NSError(domain: "CountingServerTest", code: 4)
            }
            sent += n
        }
    }

    #if os(macOS) || os(Linux)
    /// Spawn a simple unix-domain-socket echo server at `path`: every
    /// length-prefixed frame received is echoed back verbatim. Mirrors the
    /// Rust `spawn_echo_upstream` test helper.
    ///
    /// Call `stop()` on the returned handle when the test is done; the accept and
    /// per-connection threads block indefinitely otherwise.
    private func spawnEchoUpstream(path: String) throws -> EchoUpstream {
        try EchoUpstream(path: path)
    }

    /// Connect a unix-domain socket to `path`.
    private func connectUnix(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, sockStreamType, 0)
        if fd < 0 { throw NSError(domain: "UdsProxyTest", code: 4) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { cPath in
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                let count = min(strlen(cPath), buf.count - 1)
                let bytes = UnsafeBufferPointer(start: cPath, count: count)
                    .map { UInt8(bitPattern: $0) }
                buf.copyBytes(from: bytes)
            }
        }
        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Foundation.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected < 0 { close(fd); throw NSError(domain: "UdsProxyTest", code: 5) }
        return fd
    }

    /// Write a length-prefixed frame with `body` to `fd`.
    private func writeFrame(fd: Int32, body: String) throws {
        let bodyBytes = [UInt8](body.utf8)
        let len = UInt32(bodyBytes.count)
        let lenPrefix: [UInt8] = [
            UInt8(truncatingIfNeeded: len >> 24),
            UInt8(truncatingIfNeeded: len >> 16),
            UInt8(truncatingIfNeeded: len >> 8),
            UInt8(truncatingIfNeeded: len),
        ]
        guard writeAll(fd: fd, bytes: lenPrefix) else {
            throw NSError(domain: "UdsProxyTest", code: 6)
        }
        guard writeAll(fd: fd, bytes: bodyBytes) else {
            throw NSError(domain: "UdsProxyTest", code: 7)
        }
    }

    /// Read a length-prefixed frame from `fd` and return its body as a
    /// UTF-8 string. Returns nil on EOF/error (used to assert sever).
    private func readFrame(fd: Int32) throws -> String? {
        var len = [UInt8](repeating: 0, count: 4)
        guard readExact(fd: fd, buffer: &len, count: 4) else { return nil }
        let bodyLen = Int(UInt32(len[0]) << 24 | UInt32(len[1]) << 16 | UInt32(len[2]) << 8 | UInt32(len[3]))
        var body = [UInt8](repeating: 0, count: bodyLen)
        if bodyLen > 0 {
            guard readExact(fd: fd, buffer: &body, count: bodyLen) else { return nil }
        }
        return String(bytes: body, encoding: .utf8)
    }

    /// Read exactly `count` bytes from `fd` into `buffer`.
    private func readExact(fd: Int32, buffer: inout [UInt8], count: Int) -> Bool {
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBufferPointer { ptr in
                Foundation.read(fd, ptr.baseAddress!.advanced(by: got), count - got)
            }
            if n <= 0 { return false }
            got += n
        }
        return true
    }

    /// Write all of `bytes` to `fd`, retrying partial writes.
    private func writeAll(fd: Int32, bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer { ptr in
                Foundation.write(fd, ptr.baseAddress!.advanced(by: sent), bytes.count - sent)
            }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
    #endif
}

#if os(macOS) || os(Linux)

/// Unix-domain echo server backing the `UdsProxy` fixtures: every length-prefixed frame is
/// echoed back verbatim.
///
/// The accept loop and the per-connection reader loops block, so the fixture owns an explicit
/// shutdown. Without one the threads survive for the life of the test process — one sampled
/// hang showed the suite parked in this helper's `accept()`. `stop()` wakes the accept loop
/// through a self-pipe, shuts the live connections down so their blocking reads return, and
/// joins both before releasing the listening socket.
private final class EchoUpstream: @unchecked Sendable {
    private let path: String
    private var listenFD: Int32 = -1
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1
    private let lock = NSLock()
    private var stopping = false
    private var clients: Set<Int32> = []
    private let threads = DispatchGroup()

    init(path: String) throws {
        self.path = path
        unlink(path)
        let fd = socket(AF_UNIX, sockStreamType, 0)
        if fd < 0 { throw NSError(domain: "UdsProxyTest", code: 1) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { cPath in
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                let count = min(strlen(cPath), buf.count - 1)
                let bytes = UnsafeBufferPointer(start: cPath, count: count)
                    .map { UInt8(bitPattern: $0) }
                buf.copyBytes(from: bytes)
            }
        }
        let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bound < 0 { close(fd); throw NSError(domain: "UdsProxyTest", code: 2) }
        if listen(fd, 128) < 0 { close(fd); throw NSError(domain: "UdsProxyTest", code: 3) }
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        listenFD = fd

        var wake: [Int32] = [-1, -1]
        if pipe(&wake) == 0 {
            wakeRead = wake[0]
            wakeWrite = wake[1]
            for end in wake {
                let f = fcntl(end, F_GETFL)
                if f >= 0 { _ = fcntl(end, F_SETFL, f | O_NONBLOCK) }
            }
        }

        threads.enter()
        let thread = Thread { [self] in
            defer { threads.leave() }
            acceptLoop()
        }
        thread.name = "opengrok.test.echo-upstream"
        thread.start()
    }

    deinit { stop() }

    func stop() {
        var live: [Int32] = []
        lock.lock()
        if stopping {
            lock.unlock()
            return
        }
        stopping = true
        live = Array(clients)
        if wakeWrite >= 0 {
            var byte: UInt8 = 1
            _ = Foundation.write(wakeWrite, &byte, 1)
        }
        lock.unlock()

        // Blocking reads on a shut-down socket return 0, which ends the connection loops.
        // The loops own closing their own descriptor.
        for client in live { shutdown(client, Int32(SHUT_RDWR)) }
        _ = threads.wait(timeout: .now() + 2)

        lock.lock()
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        if wakeRead >= 0 { close(wakeRead); wakeRead = -1 }
        if wakeWrite >= 0 { close(wakeWrite); wakeWrite = -1 }
        lock.unlock()
        unlink(path)
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private func acceptLoop() {
        while true {
            if isStopping { return }
            var fds = [
                pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)
            ]
            let ready = poll(&fds, 2, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if isStopping { return }
            guard ready > 0, fds[0].revents != 0 else { continue }
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR
                    || errno == ECONNABORTED { continue }
                return
            }
            // BSD accept() inherits O_NONBLOCK from the listening socket; the connection
            // loops want blocking reads.
            let clientFlags = fcntl(client, F_GETFL)
            if clientFlags >= 0 {
                _ = fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK)
            }
            lock.lock()
            if stopping {
                lock.unlock()
                close(client)
                return
            }
            clients.insert(client)
            lock.unlock()
            // `stop()` shuts these sockets down under a serving thread; without this a
            // half-written frame would raise SIGPIPE and take the whole test process with it.
            #if canImport(Darwin)
            var on: Int32 = 1
            _ = setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &on,
                socklen_t(MemoryLayout<Int32>.size)
            )
            #endif

            threads.enter()
            let connThread = Thread { [self] in
                defer { threads.leave() }
                serve(client: client)
            }
            connThread.name = "opengrok.test.echo-upstream.conn"
            connThread.start()
        }
    }

    private func serve(client: Int32) {
        defer {
            lock.lock()
            clients.remove(client)
            lock.unlock()
            close(client)
        }
        while true {
            var len = [UInt8](repeating: 0, count: 4)
            guard Self.readExact(fd: client, buffer: &len, count: 4) else { return }
            let bodyLen = Int(
                UInt32(len[0]) << 24 | UInt32(len[1]) << 16 | UInt32(len[2]) << 8 | UInt32(len[3])
            )
            var body = [UInt8](repeating: 0, count: bodyLen)
            if bodyLen > 0 {
                guard Self.readExact(fd: client, buffer: &body, count: bodyLen) else { return }
            }
            guard Self.writeAll(fd: client, bytes: len) else { return }
            if bodyLen > 0 {
                guard Self.writeAll(fd: client, bytes: body) else { return }
            }
        }
    }

    private static func readExact(fd: Int32, buffer: inout [UInt8], count: Int) -> Bool {
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBufferPointer { ptr in
                Foundation.read(fd, ptr.baseAddress!.advanced(by: got), count - got)
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            got += n
        }
        return true
    }

    private static func writeAll(fd: Int32, bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer { ptr -> Int in
                #if canImport(Darwin)
                return Foundation.write(fd, ptr.baseAddress!.advanced(by: sent), bytes.count - sent)
                #else
                // Linux has no SO_NOSIGPIPE; MSG_NOSIGNAL is the per-call equivalent.
                return send(
                    fd,
                    ptr.baseAddress!.advanced(by: sent),
                    bytes.count - sent,
                    Int32(MSG_NOSIGNAL)
                )
                #endif
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
}

#endif
