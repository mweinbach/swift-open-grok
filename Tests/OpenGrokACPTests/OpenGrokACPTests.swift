// OpenGrokACPTests.swift
//
// Deterministic tests for OpenGrokACP, translated from the Rust
// `xai-acp-lib` test suites in `src/common.rs` (channel-failure
// classifier round-trip), `src/channel.rs` (acp_send failure modes),
// and the `ProtocolFixtures/acp-methods.json` fixture (method name
// catalog + Open Grok extension metadata).
//
// The key acceptance criterion — "Channel cancellation closes pending
// continuations exactly once and never resumes a Swift continuation
// twice" — is pinned by the `ResponseChannel` cancellation tests.

import Testing
import Foundation
@testable import OpenGrokACP
import OpenGrokShared

// MARK: - Open Grok extension metadata + method catalog (fixture parity)

@Suite("Open Grok ACP fixture parity")
struct OpenGrokACPFixtureTests {
    /// Walk up from this source file looking for `ProtocolFixtures/<name>`.
    static func resolveProtocolFixture(_ name: String) throws -> URL {
        let fm = FileManager.default
        // Resolve symlinks so focused test packages that symlink Tests/
        // still locate the destination package's ProtocolFixtures.
        let starts = [
            URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent(),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent(),
        ]
        for start in starts {
            var dir = start
            for _ in 0..<8 {
                let candidate = dir
                    .appendingPathComponent("ProtocolFixtures")
                    .appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
                dir = dir.deletingLastPathComponent()
            }
        }
        for root in [
            ProcessInfo.processInfo.environment["SRCROOT"],
            FileManager.default.currentDirectoryPath,
            "/Users/mweinbach/Projects/swift-open-grok",
        ].compactMap({ $0 }) {
            let fallback = URL(fileURLWithPath: root)
                .appendingPathComponent("ProtocolFixtures")
                .appendingPathComponent(name)
            if fm.fileExists(atPath: fallback.path) {
                return fallback
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// Decode the checked-in fixture and verify the Swift port exposes
    /// the same method catalog and extension metadata.
    @Test("acp-methods.json fixture matches Swift port")
    func fixtureParity() throws {
        // Resolve ProtocolFixtures relative to this source file (walk up
        // to the package root) so isolated focused-test packages that
        // symlink Tests/ still find the checked-in corpus.
        let fixtureURL = try Self.resolveProtocolFixture("acp-methods.json")
        let data = try Data(contentsOf: fixtureURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // The `methods` array in the fixture must be a subset of the
        // Swift port's recognized methods.
        let methods = json?["methods"] as? [String] ?? []
        #expect(!methods.isEmpty)
        for method in methods {
            #expect(OpenGrokACPMethodCatalog.contains(method), "Method \(method) is in the fixture but not in the Swift catalog")
        }

        // The Open Grok extension block must match exactly.
        let extensions = json?["extensions"] as? [String: [String: String]] ?? [:]
        let openGrok = extensions[OpenGrokACPExtension.namespace]
        #expect(openGrok != nil)
        #expect(openGrok?["product"] == OpenGrokACPExtension.product)
        #expect(openGrok?["executable"] == OpenGrokACPExtension.executable)
        #expect(openGrok?["stateDirectory"] == OpenGrokACPExtension.stateDirectory)
        #expect(openGrok?["homeEnvironmentVariable"] == OpenGrokACPExtension.homeEnvironmentVariable)

        // The Swift port's `wireDictionary` must round-trip the
        // fixture's extension block byte-significantly (modulo key
        // ordering).
        #expect(OpenGrokACPExtension.wireDictionary == openGrok)
    }

    @Test("method name constants match the fixture's documented surface")
    func methodConstantsMatchFixture() {
        // The fixture's `methods` array captures the camelCase
        // surface; the Swift port exposes both camelCase aliases AND
        // snake_case canonical forms.
        #expect(AgentMethodNames.initialize == "initialize")
        #expect(AgentMethodNames.authenticate == "authenticate")
        #expect(AgentMethodNames.sessionNew == "session/new")
        #expect(AgentMethodNames.sessionLoad == "session/load")
        #expect(AgentMethodNames.sessionResume == "session/resume")
        #expect(AgentMethodNames.sessionFork == "session/fork")
        #expect(AgentMethodNames.sessionList == "session/list")
        #expect(AgentMethodNames.sessionPrompt == "session/prompt")
        #expect(AgentMethodNames.sessionCancel == "session/cancel")
        // camelCase fixture spellings:
        #expect(AgentMethodNames.sessionSetModelCamel == "session/setModel")
        #expect(AgentMethodNames.sessionSetModeCamel == "session/setMode")
        // snake_case canonical spellings:
        #expect(AgentMethodNames.sessionSetModel == "session/set_model")
        #expect(AgentMethodNames.sessionSetMode == "session/set_mode")
    }

    @Test("client method name constants match the schema crate")
    func clientMethodConstants() {
        #expect(ClientMethodNames.sessionUpdate == "session/update")
        #expect(ClientMethodNames.sessionRequestPermission == "session/request_permission")
        #expect(ClientMethodNames.fsWriteTextFile == "fs/write_text_file")
        #expect(ClientMethodNames.fsReadTextFile == "fs/read_text_file")
        #expect(ClientMethodNames.terminalCreate == "terminal/create")
        #expect(ClientMethodNames.terminalOutput == "terminal/output")
        #expect(ClientMethodNames.terminalRelease == "terminal/release")
        #expect(ClientMethodNames.terminalWaitForExit == "terminal/wait_for_exit")
        #expect(ClientMethodNames.terminalKill == "terminal/kill")
    }
}

// MARK: - AcpErrorCode wire form

@Suite("AcpErrorCode wire form")
struct AcpErrorCodeTests {
    @Test("error codes serialize as raw integers")
    func errorCodesSerializeAsIntegers() throws {
        for code in [
            AcpErrorCode.parseError,
            .invalidRequest,
            .methodNotFound,
            .invalidParams,
            .internalError,
            .requestCancelled,
            .authRequired,
            .resourceNotFound,
            .urlElicitationRequired,
        ] {
            let data = try JSONEncoder().encode(code)
            let json = String(data: data, encoding: .utf8)
            #expect(json == "\(code.code)")
            let decoded = try JSONDecoder().decode(AcpErrorCode.self, from: data)
            #expect(decoded == code)
        }
    }

    @Test("unknown integer codes round-trip as .other")
    func unknownCodesRoundTrip() throws {
        let code = AcpErrorCode.other(42)
        let data = try JSONEncoder().encode(code)
        let decoded = try JSONDecoder().decode(AcpErrorCode.self, from: data)
        #expect(decoded == .other(42))
    }

    @Test("fromCode maps each integer to the correct case")
    func fromCodeMapping() {
        #expect(AcpErrorCode.fromCode(-32700) == .parseError)
        #expect(AcpErrorCode.fromCode(-32600) == .invalidRequest)
        #expect(AcpErrorCode.fromCode(-32601) == .methodNotFound)
        #expect(AcpErrorCode.fromCode(-32602) == .invalidParams)
        #expect(AcpErrorCode.fromCode(-32603) == .internalError)
        #expect(AcpErrorCode.fromCode(-32800) == .requestCancelled)
        #expect(AcpErrorCode.fromCode(-32000) == .authRequired)
        #expect(AcpErrorCode.fromCode(-32002) == .resourceNotFound)
        #expect(AcpErrorCode.fromCode(-32042) == .urlElicitationRequired)
        #expect(AcpErrorCode.fromCode(99) == .other(99))
    }

    @Test("display names match Rust strum::Display")
    func displayNames() {
        #expect(AcpErrorCode.parseError.displayName == "Parse error")
        #expect(AcpErrorCode.invalidRequest.displayName == "Invalid request")
        #expect(AcpErrorCode.methodNotFound.displayName == "Method not found")
        #expect(AcpErrorCode.invalidParams.displayName == "Invalid params")
        #expect(AcpErrorCode.internalError.displayName == "Internal error")
        #expect(AcpErrorCode.requestCancelled.displayName == "Request cancelled")
        #expect(AcpErrorCode.authRequired.displayName == "Authentication required")
        #expect(AcpErrorCode.resourceNotFound.displayName == "Resource not found")
        #expect(AcpErrorCode.urlElicitationRequired.displayName == "URL elicitation required")
        #expect(AcpErrorCode.other(1).displayName == "Unknown error")
    }
}

// MARK: - AcpError wire form

@Suite("AcpError wire form")
struct AcpErrorTests {
    @Test("AcpError serializes with code, message, and optional data")
    func errorWireForm() throws {
        let err = AcpError(code: .methodNotFound, message: "no such method")
        let data = try JSONEncoder().encode(err)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["code"] as? Int == -32601)
        #expect(object?["message"] as? String == "no such method")
        // `data` is omitted when nil.
        #expect(object?["data"] == nil)
    }

    @Test("AcpError with data serializes the data field")
    func errorWithData() throws {
        let err = AcpError(
            code: .resourceNotFound,
            message: "not found",
            data: .object(["uri": .string("file:///tmp/x")])
        )
        let data = try JSONEncoder().encode(err)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["data"] != nil)
        let dataDict = object?["data"] as? [String: Any]
        #expect(dataDict?["uri"] as? String == "file:///tmp/x")
    }

    @Test("AcpError round-trips through Codable")
    func errorRoundTrip() throws {
        let original = AcpError.internalError("boom").withData(.string("extra"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AcpError.self, from: data)
        #expect(decoded.code == .internalError)
        #expect(decoded.message == "boom")
        #expect(decoded.data == .string("extra"))
    }

    @Test("convenience constructors produce the right code")
    func convenienceConstructors() {
        #expect(AcpError.parseError().code == .parseError)
        #expect(AcpError.invalidRequest().code == .invalidRequest)
        #expect(AcpError.methodNotFound().code == .methodNotFound)
        #expect(AcpError.invalidParams().code == .invalidParams)
        #expect(AcpError.internalError().code == .internalError)
        #expect(AcpError.requestCancelled().code == .requestCancelled)
        #expect(AcpError.authRequired().code == .authRequired)
        #expect(AcpError.urlElicitationRequired().code == .urlElicitationRequired)
    }

    @Test("resourceNotFound attaches the uri in data")
    func resourceNotFoundWithURI() {
        let err = AcpError.resourceNotFound(uri: "file:///x")
        #expect(err.code == .resourceNotFound)
        guard case .object(let dict) = err.data,
              case .string(let uri) = dict["uri"] else {
            Issue.record("expected data.uri string")
            return
        }
        #expect(uri == "file:///x")
    }

    @Test("internalError(message) preserves the custom message")
    func internalErrorCustomMessage() {
        let err = AcpError.internalError("custom boom")
        #expect(err.code == .internalError)
        #expect(err.message == "custom boom")
    }
}

// MARK: - AcpChannelFailure classifier

@Suite("AcpChannelFailure classifier")
struct AcpChannelFailureTests {
    @Test("classifier round-trips both kinds")
    func classifierRoundTrip() {
        for kind in [AcpChannelFailure.sendFailed, .recvFailed] {
            let err = acpChannelFailureError("boom", kind)
            // Code stays INTERNAL_ERROR for backward compatibility.
            #expect(err.code == .internalError)
            #expect(acpChannelFailure(err) == kind)
        }
    }

    @Test("classifier returns nil for untagged errors")
    func classifierNoneForUntagged() {
        #expect(acpChannelFailure(AcpError.internalError("plain")) == nil)
        // A different `data` payload must not be misread as a channel kind.
        #expect(acpChannelFailure(AcpError.invalidParams().withData(.string("unknown session id"))) == nil)
    }

    @Test("from(tag:) round-trips the wire tags")
    func tagRoundTrip() {
        #expect(AcpChannelFailure.from(tag: "send_failed") == .sendFailed)
        #expect(AcpChannelFailure.from(tag: "recv_failed") == .recvFailed)
        #expect(AcpChannelFailure.from(tag: "unknown") == nil)
    }

    @Test("channel-failure error tags data under the namespaced key")
    func dataKeyNamespaced() {
        let err = acpChannelFailureError("disconnected", .sendFailed)
        guard case .object(let dict) = err.data,
              case .string(let tag) = dict[AcpChannelFailure.dataKey] else {
            Issue.record("expected data[\(AcpChannelFailure.dataKey)] string")
            return
        }
        #expect(tag == "send_failed")
    }
}

// MARK: - ResponseChannel: exactly-once cancellation (acceptance criterion)

@Suite("ResponseChannel exactly-once cancellation")
struct ResponseChannelCancellationTests {
    @Test("resume(with:) delivers exactly once")
    func resumeDeliversExactlyOnce() async {
        let channel = ResponseChannel<AcpResponseEnvelope>()
        let sent = AcpResult<AcpResponseEnvelope>.success(AcpResponseEnvelope(result: .string("ok")))

        // Start awaiting in a child task.
        let task = Task<AcpResult<AcpResponseEnvelope>, Never> {
            await channel.awaitResponse()
        }

        // Deliver the result.
        let first = channel.resume(with: sent)
        #expect(first, "first resume should win")

        // A second resume must be a no-op (returns false).
        let second = channel.resume(with: sent)
        #expect(!second, "second resume must be a no-op")

        // The awaiter must receive the first delivery.
        let received = await task.value
        switch received {
        case .success(let env):
            #expect(env.result == .string("ok"))
        case .failure:
            Issue.record("expected success")
        }
    }

    @Test("cancel() delivers a RecvFailed error exactly once")
    func cancelDeliversRecvFailed() async {
        let channel = ResponseChannel<AcpResponseEnvelope>()

        let task = Task<AcpResult<AcpResponseEnvelope>, Never> {
            await channel.awaitResponse()
        }

        let first = channel.cancel()
        #expect(first)

        // A second cancel must be a no-op.
        let second = channel.cancel()
        #expect(!second)

        // A resume after cancel must also be a no-op.
        let third = channel.resume(with: .success(AcpResponseEnvelope()))
        #expect(!third)

        let received = await task.value
        switch received {
        case .failure(let err):
            #expect(err.code == .internalError)
            #expect(acpChannelFailure(err) == .recvFailed)
        case .success:
            Issue.record("expected cancellation error")
        }
    }

    @Test("deinit / sender-drop surfaces RecvFailed without hanging")
    func deinitCancelsPending() async {
        // Rust oneshot drops the *sender* half while the receiver is
        // waiting. Swift's single-object channel cannot deinit while an
        // awaiter holds `self` for `awaitResponse()`, so sender-drop is
        // modeled by `cancel()` (also invoked from `deinit` when the
        // last non-waiter reference is released before a waiter attaches).
        //
        // Case A: cancel while a waiter is registered — must not hang.
        let channel = ResponseChannel<AcpResponseEnvelope>()
        let task = Task { await channel.awaitResponse() }
        // Yield so the awaiter can register its continuation.
        await Task.yield()
        _ = channel.cancel()
        let result = await task.value
        switch result {
        case .failure(let err):
            #expect(acpChannelFailure(err) == .recvFailed)
        case .success:
            Issue.record("expected cancellation error from sender-drop")
        }

        // Case B: deinit before any waiter — next await gets RecvFailed.
        var orphan: ResponseChannel<AcpResponseEnvelope>? = ResponseChannel()
        _ = orphan!.cancel() // mark closed
        orphan = nil
        // Construct a fresh closed-via-cancel path already covered above;
        // deinit after buffered cancel is a no-op and must not trap.
    }

    @Test("awaitResponse after channel is closed returns RecvFailed immediately")
    func awaitAfterCloseReturnsImmediately() async {
        let channel = ResponseChannel<AcpResponseEnvelope>()
        // Close before anyone awaits.
        _ = channel.cancel()

        // The awaiter must NOT hang; it gets a RecvFailed error
        // immediately.
        let result = await channel.awaitResponse()
        switch result {
        case .failure(let err):
            #expect(acpChannelFailure(err) == .recvFailed)
        case .success:
            Issue.record("expected cancellation error")
        }
    }
}

// MARK: - Channel pair (acpChannels)

@Suite("acpChannels linked pair")
struct AcpChannelsTests {
    @Test("client and agent channels are linked bidirectionally")
    func channelsLinkedBidirectionally() async {
        let (clientChannel, agentChannel) = acpChannels()

        let prompt = PromptRequest(
            sessionId: AcpSessionId("s1"),
            prompt: [.text("hi")]
        )
        let agentMessage = AcpAgentMessage.prompt(AcpArgs(request: prompt))
        #expect(clientChannel.send(agentMessage))

        let received = await agentChannel.messages.first {
            $0.methodName == AgentMethodNames.sessionPrompt
        }
        #expect(received != nil)
        #expect(received?.methodName == AgentMethodNames.sessionPrompt)

        let notification = SessionNotification(
            sessionId: AcpSessionId("s1"),
            update: .agentMessageChunk(ContentChunk(content: .text("ok")))
        )
        let clientMessage = AcpClientMessage.sessionNotification(AcpArgs(request: notification))
        #expect(agentChannel.send(clientMessage))

        let receivedClient = await clientChannel.messages.first {
            $0.methodName == ClientMethodNames.sessionUpdate
        }
        #expect(receivedClient != nil)
        #expect(receivedClient?.methodName == ClientMethodNames.sessionUpdate)

        clientChannel.close()
        agentChannel.close()
    }

    @Test("send returns false after peer close (sendFailed path)")
    func sendFailsAfterClose() {
        let (clientChannel, agentChannel) = acpChannels()
        agentChannel.close()
        let prompt = PromptRequest(sessionId: AcpSessionId("s1"), prompt: [.text("x")])
        let accepted = clientChannel.send(.prompt(AcpArgs(request: prompt)))
        #expect(!accepted)
        clientChannel.close()
    }

    @Test("typed prompt round-trip responds exactly once under race")
    func typedPromptRoundTripRace() async {
        let (clientChannel, agentChannel) = acpChannels()
        let request = PromptRequest(sessionId: AcpSessionId("s1"), prompt: [.text("hello")])
        let args = AcpArgs(request: request)

        let waiter = Task {
            await args.response.awaitResponse()
        }
        #expect(clientChannel.send(.prompt(args)))

        // Agent receives and responds; race a second response.
        let received = await agentChannel.messages.first { $0.methodName == AgentMethodNames.sessionPrompt }
        #expect(received != nil)
        if case .prompt(let inbound)? = received {
            let ok = inbound.respond(.success(PromptResponse(stopReason: .endTurn)))
            #expect(ok)
            let again = inbound.respond(.success(PromptResponse(stopReason: .cancelled)))
            #expect(!again)
        } else {
            Issue.record("expected prompt message")
        }

        let result = await waiter.value
        switch result {
        case .success(let response):
            #expect(response.stopReason == .endTurn)
        case .failure:
            Issue.record("expected success")
        }
        clientChannel.close()
        agentChannel.close()
    }
}

// MARK: - Typed message constructors + dispatch

@Suite("Typed AcpAgentMessage / AcpClientMessage")
struct MessageConstructorTests {
    @Test("AcpAgentMessage.prompt carries the session/prompt method name")
    func agentPrompt() {
        let request = PromptRequest(sessionId: AcpSessionId("s"), prompt: [.text("hi")])
        let msg = AcpAgentMessage.prompt(AcpArgs(request: request))
        #expect(msg.methodName == AgentMethodNames.sessionPrompt)
    }

    @Test("AcpAgentMessage.setSessionModel uses the snake_case canonical name")
    func agentSetSessionModel() {
        let request = SetSessionModelRequest(sessionId: AcpSessionId("s"), modelId: ModelId("m"))
        let msg = AcpAgentMessage.setSessionModel(AcpArgs(request: request))
        #expect(msg.methodName == AgentMethodNames.sessionSetModel)
    }

    @Test("AcpAgentMessage.extMethod carries the custom method name verbatim")
    func agentExtMethod() {
        let request = ExtRequest(method: "x.ai/foo", params: .object([:]))
        let msg = AcpAgentMessage.extMethod(AcpArgs(request: request))
        #expect(msg.methodName == "x.ai/foo")
    }

    @Test("AcpClientMessage.requestPermission carries the reverse-RPC method name")
    func clientRequestPermission() {
        let request = RequestPermissionRequest(
            sessionId: AcpSessionId("s"),
            toolCall: ToolCallUpdate(toolCallId: ToolCallId("t")),
            options: []
        )
        let msg = AcpClientMessage.requestPermission(AcpArgs(request: request))
        #expect(msg.methodName == ClientMethodNames.sessionRequestPermission)
    }

    @Test("AcpClientMessage.sessionNotification carries the session/update name")
    func clientSessionNotification() {
        let request = SessionNotification(
            sessionId: AcpSessionId("s"),
            update: .currentModeUpdate(CurrentModeUpdate(currentModeId: SessionModeId("code")))
        )
        let msg = AcpClientMessage.sessionNotification(AcpArgs(request: request))
        #expect(msg.methodName == ClientMethodNames.sessionUpdate)
    }

    @Test("messages with the same method name are equal (channel identity ignored)")
    func messageEqualityIgnoresChannel() {
        let a = AcpAgentMessage.prompt(AcpArgs(
            request: PromptRequest(sessionId: AcpSessionId("s"), prompt: [.text("a")])
        ))
        let b = AcpAgentMessage.prompt(AcpArgs(
            request: PromptRequest(sessionId: AcpSessionId("s"), prompt: [.text("b")])
        ))
        #expect(a == b)
    }

    @Test("dispatch accepts camelCase setMode alias")
    func dispatchCamelCaseAlias() throws {
        let params: JSONValue = .object([
            "sessionId": .string("s1"),
            "modeId": .string("code"),
        ])
        let decoded = decodeAcpAgentMessage(method: AgentMethodNames.sessionSetModeCamel, params: params)
        switch decoded {
        case .success(let message):
            #expect(message.methodName == AgentMethodNames.sessionSetMode)
        case .failure(let error):
            Issue.record("decode failed: \(error)")
        }
    }
}

// MARK: - Typed wire corpus

@Suite("Typed ACP wire schemas")
struct TypedACPWireTests {
    @Test("InitializeRequest / Response round-trip with Open Grok meta")
    func initializeRoundTrip() throws {
        let meta: AcpMeta = [
            OpenGrokACPExtension.namespace: .object(
                OpenGrokACPExtension.wireDictionary.mapValues { .string($0) }
            ),
        ]
        let request = InitializeRequest(
            protocolVersion: .v1,
            clientCapabilities: ClientCapabilities(
                fs: FileSystemCapabilities(readTextFile: true, writeTextFile: true),
                terminal: true
            ),
            clientInfo: Implementation(name: "open-grok-pager", version: "0.1.0"),
            meta: meta
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(InitializeRequest.self, from: data)
        #expect(decoded.protocolVersion == .v1)
        #expect(decoded.clientCapabilities.terminal)
        #expect(decoded.clientInfo?.name == "open-grok-pager")
        #expect(decoded.meta?[OpenGrokACPExtension.namespace] != nil)

        let response = InitializeResponse(
            protocolVersion: .v1,
            agentCapabilities: AgentCapabilities(loadSession: true),
            authMethods: [AuthMethod(id: AuthMethodId("xai"), name: "xAI")],
            agentInfo: Implementation(name: OpenGrokACPExtension.executable, version: "0.1.0"),
            meta: meta
        )
        let rData = try JSONEncoder().encode(response)
        let rDecoded = try JSONDecoder().decode(InitializeResponse.self, from: rData)
        #expect(rDecoded.agentCapabilities.loadSession)
        #expect(rDecoded.authMethods.first?.id.rawValue == "xai")
    }

    @Test("PromptRequest preserves text content blocks")
    func promptRequestWire() throws {
        let request = PromptRequest(
            sessionId: AcpSessionId("sess-1"),
            prompt: [.text("hello"), .image(ImageContent(data: "abc", mimeType: "image/png"))]
        )
        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["sessionId"] as? String == "sess-1")
        let prompt = object?["prompt"] as? [[String: Any]]
        #expect(prompt?.count == 2)
        #expect(prompt?[0]["type"] as? String == "text")
        #expect(prompt?[1]["type"] as? String == "image")

        let decoded = try JSONDecoder().decode(PromptRequest.self, from: data)
        #expect(decoded.prompt.count == 2)
    }

    @Test("JSON-RPC request preserves id across error and result")
    func jsonRpcIdPreservation() throws {
        let id = AcpRequestId.number(42)
        let request = AuthenticateRequest(methodId: AuthMethodId("xai"))
        let encoded = try encodeJsonRpcRequest(id: id, request: request)
        #expect(encoded.objectValue?["id"]?.int64Value == 42)
        #expect(encoded.objectValue?["method"]?.stringValue == AgentMethodNames.authenticate)

        let err = try encodeJsonRpcError(id: id, error: .authRequired())
        #expect(err.objectValue?["id"]?.int64Value == 42)
        #expect(err.objectValue?["error"]?.objectValue?["code"]?.int64Value == -32000)

        let result = try encodeJsonRpcResult(id: .string("abc"), result: AuthenticateResponse())
        #expect(result.objectValue?["id"]?.stringValue == "abc")
    }

    @Test("session list / fork / resume / set_config_option decode")
    func sessionLifecycleWire() throws {
        let list = ListSessionsRequest(cwd: "/tmp/proj")
        let listData = try JSONEncoder().encode(list)
        #expect(try JSONDecoder().decode(ListSessionsRequest.self, from: listData).cwd == "/tmp/proj")

        let fork = ForkSessionRequest(sessionId: AcpSessionId("s1"), cwd: "/tmp")
        let forkData = try JSONEncoder().encode(fork)
        #expect(try JSONDecoder().decode(ForkSessionRequest.self, from: forkData).sessionId.rawValue == "s1")

        let resume = ResumeSessionRequest(sessionId: AcpSessionId("s1"))
        let resumeData = try JSONEncoder().encode(resume)
        #expect(try JSONDecoder().decode(ResumeSessionRequest.self, from: resumeData).sessionId.rawValue == "s1")

        let config = SetSessionConfigOptionRequest(
            sessionId: AcpSessionId("s1"),
            configId: SessionConfigId("model"),
            value: "grok"
        )
        let configData = try JSONEncoder().encode(config)
        let configDecoded = try JSONDecoder().decode(SetSessionConfigOptionRequest.self, from: configData)
        #expect(configDecoded.value == "grok")
    }

    @Test("permission reverse request + cancelled outcome")
    func permissionWire() throws {
        let request = RequestPermissionRequest(
            sessionId: AcpSessionId("s1"),
            toolCall: ToolCallUpdate(toolCallId: ToolCallId("tc1"), title: "Write"),
            options: [
                PermissionOption(optionId: PermissionOptionId("once"), name: "Allow once", kind: .allowOnce),
            ]
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(RequestPermissionRequest.self, from: data)
        #expect(decoded.options.first?.kind == .allowOnce)

        let cancelled = RequestPermissionResponse(outcome: .cancelled)
        let cData = try JSONEncoder().encode(cancelled)
        let cDecoded = try JSONDecoder().decode(RequestPermissionResponse.self, from: cData)
        if case .cancelled = cDecoded.outcome {
            // ok
        } else {
            Issue.record("expected cancelled")
        }
    }

    @Test("terminal create/output/kill round-trip")
    func terminalWire() throws {
        let create = CreateTerminalRequest(sessionId: AcpSessionId("s"), command: "bash", args: ["-lc", "ls"])
        let createData = try JSONEncoder().encode(create)
        #expect(try JSONDecoder().decode(CreateTerminalRequest.self, from: createData).command == "bash")

        let output = TerminalOutputResponse(output: "hi\n", truncated: false)
        let outData = try JSONEncoder().encode(output)
        #expect(try JSONDecoder().decode(TerminalOutputResponse.self, from: outData).output == "hi\n")

        let kill = KillTerminalRequest(sessionId: AcpSessionId("s"), terminalId: TerminalId("t1"))
        let killData = try JSONEncoder().encode(kill)
        #expect(try JSONDecoder().decode(KillTerminalRequest.self, from: killData).terminalId.rawValue == "t1")
    }
}

// MARK: - Ask-user reverse request

@Suite("AskUserQuestion reverse request")
struct AskUserQuestionTests {
    @Test("single-select with recommended label and preview round-trips")
    func singleSelectRecommended() throws {
        let request = AskUserQuestionExtRequest(
            sessionId: "sess-1",
            toolCallId: "tc-1",
            questions: [
                AskUserQuestion(
                    question: "Which database?",
                    options: [
                        AskUserQuestionOption(
                            label: "Redis",
                            description: "In-memory",
                            preview: "<div>redis</div>"
                        ).withRecommendedLabel(),
                        AskUserQuestionOption(label: "Postgres", description: "Relational"),
                    ],
                    multiSelect: false
                ),
            ],
            mode: .default
        )
        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["sessionId"] as? String == "sess-1")
        #expect(object?["toolCallId"] as? String == "tc-1")
        #expect(object?["mode"] as? String == "default")
        let questions = object?["questions"] as? [[String: Any]]
        let options = questions?[0]["options"] as? [[String: Any]]
        #expect(options?[0]["label"] as? String == "Redis (Recommended)")
        #expect(options?[0]["preview"] as? String == "<div>redis</div>")

        let decoded = try JSONDecoder().decode(AskUserQuestionExtRequest.self, from: data)
        #expect(decoded.questions[0].options[0].label.contains("Recommended"))
        #expect(decoded.methodName == OpenGrokACPExtMethods.askUserQuestion)
    }

    @Test("multi-select answers round-trip as string arrays")
    func multiSelectAnswers() throws {
        let response = AskUserQuestionExtResponse.accepted(
            answers: [
                AskUserAnswer(question: "Which caches?", labels: ["Redis", "Memcached"]),
            ],
            annotations: nil
        )
        let data = try JSONEncoder().encode(response)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["outcome"] as? String == "accepted")
        let answers = object?["answers"] as? [String: Any]
        #expect(answers?["Which caches?"] as? [String] == ["Redis", "Memcached"])

        let decoded = try JSONDecoder().decode(AskUserQuestionExtResponse.self, from: data)
        #expect(decoded.answersMap["Which caches?"] == ["Redis", "Memcached"])
    }

    @Test("legacy string answer form expands to single-element array")
    func legacyStringAnswer() throws {
        let raw = """
        {"outcome":"accepted","answers":{"Which cache?":"Only hot-path caches"}}
        """
        let decoded = try JSONDecoder().decode(
            AskUserQuestionExtResponse.self,
            from: Data(raw.utf8)
        )
        #expect(decoded.answersMap["Which cache?"] == ["Only hot-path caches"])
    }

    @Test("Other freeform input carries notes annotation")
    func otherFreeform() throws {
        let response = AskUserQuestionExtResponse.acceptedOther(
            question: "Notes?",
            notes: "please use SQLite"
        )
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(AskUserQuestionExtResponse.self, from: data)
        switch decoded {
        case .accepted(let answers, let annotations):
            #expect(answers.first?.labels == [AskUserQuestionOther.label])
            #expect(annotations?["Notes?"]?.notes == "please use SQLite")
        default:
            Issue.record("expected accepted")
        }
    }

    @Test("cancelled / chat_about_this / skip_interview outcomes")
    func planModeOutcomes() throws {
        for (json, matcher) in [
            (#"{"outcome":"cancelled"}"#, "cancelled"),
            (#"{"outcome":"chat_about_this","partial_answers":{"Q?":"A"}}"#, "chat"),
            (#"{"outcome":"skip_interview"}"#, "skip"),
        ] as [(String, String)] {
            let decoded = try JSONDecoder().decode(
                AskUserQuestionExtResponse.self,
                from: Data(json.utf8)
            )
            switch (matcher, decoded) {
            case ("cancelled", .cancelled):
                break
            case ("chat", .chatAboutThis(let partial)):
                #expect(partial["Q?"] == "A")
            case ("skip", .skipInterview):
                break
            default:
                Issue.record("unexpected outcome for \(matcher): \(decoded)")
            }
        }
    }

    @Test("dispatch routes x.ai/ask_user_question as typed reverse request")
    func dispatchAskUser() throws {
        let params = try JSONValue.encode(
            AskUserQuestionExtRequest(
                sessionId: "s",
                toolCallId: "tc",
                questions: [],
                mode: .plan
            )
        )
        let agent = decodeAcpAgentMessage(method: OpenGrokACPExtMethods.askUserQuestion, params: params)
        switch agent {
        case .success(let message):
            #expect(message.methodName == OpenGrokACPExtMethods.askUserQuestion)
        case .failure(let error):
            Issue.record("\(error)")
        }
        let client = decodeAcpClientMessage(method: OpenGrokACPExtMethods.askUserQuestion, params: params)
        switch client {
        case .success(let message):
            #expect(message.methodName == OpenGrokACPExtMethods.askUserQuestion)
        case .failure(let error):
            Issue.record("\(error)")
        }
    }

    @Test("malformed ask-user params surface invalidParams")
    func malformedAskUser() {
        let result = decodeAcpClientMessage(
            method: OpenGrokACPExtMethods.askUserQuestion,
            params: .string("not-an-object")
        )
        switch result {
        case .failure(.invalidParams):
            break
        default:
            Issue.record("expected invalidParams, got \(result)")
        }
    }
}

// MARK: - Transport response bridge + extension dispatch

@Suite("ACP transport response bridge")
struct AcpTransportResponseBridgeTests {
    @Test("typed success bridges into supplied JSONValue channel exactly once")
    func successBridgesExactlyOnce() async throws {
        let outer = ResponseChannel<JSONValue>()
        let params = try JSONValue.encode(
            AuthenticateRequest(methodId: AuthMethodId("xai"))
        )
        let decoded = decodeAcpAgentMessage(
            method: AgentMethodNames.authenticate,
            params: params,
            responseChannel: outer
        )
        guard case .success(.authenticate(let args)) = decoded else {
            Issue.record("expected authenticate message, got \(decoded)")
            return
        }

        let waiter = Task { await outer.awaitResponse() }
        let first = args.respond(.success(AuthenticateResponse()))
        #expect(first)
        let second = args.respond(.success(AuthenticateResponse()))
        #expect(!second)

        let received = await waiter.value
        switch received {
        case .success:
            break
        case .failure(let error):
            Issue.record("expected success, got \(error)")
        }
        // Outer channel also rejects a late resume.
        #expect(!outer.resume(with: .success(.object([:]))))
    }

    @Test("typed AcpError bridges into supplied channel")
    func errorBridges() async throws {
        let outer = ResponseChannel<JSONValue>()
        let params = try JSONValue.encode(
            PromptRequest(sessionId: AcpSessionId("s"), prompt: [.text("x")])
        )
        let decoded = decodeAcpAgentMessage(
            method: AgentMethodNames.sessionPrompt,
            params: params,
            responseChannel: outer
        )
        guard case .success(.prompt(let args)) = decoded else {
            Issue.record("expected prompt")
            return
        }

        let waiter = Task { await outer.awaitResponse() }
        #expect(args.respond(.failure(.authRequired())))
        let received = await waiter.value
        switch received {
        case .failure(let error):
            #expect(error.code == .authRequired)
        case .success:
            Issue.record("expected failure")
        }
    }

    @Test("cancel races with response: first wins on both channels")
    func cancelRace() async throws {
        let outer = ResponseChannel<JSONValue>()
        let params = try JSONValue.encode(
            PromptRequest(sessionId: AcpSessionId("s"), prompt: [.text("x")])
        )
        let decoded = decodeAcpAgentMessage(
            method: AgentMethodNames.sessionPrompt,
            params: params,
            responseChannel: outer
        )
        guard case .success(.prompt(let args)) = decoded else {
            Issue.record("expected prompt")
            return
        }

        let waiter = Task { await outer.awaitResponse() }
        // Cancel the typed channel first; outer must observe RecvFailed.
        #expect(args.response.cancel())
        #expect(!args.respond(.success(PromptResponse(stopReason: .endTurn))))

        let received = await waiter.value
        switch received {
        case .failure(let error):
            #expect(acpChannelFailure(error) == .recvFailed)
        case .success:
            Issue.record("expected cancel failure")
        }
    }

    @Test("duplicate response race: only first bridges")
    func duplicateResponseRace() async throws {
        let outer = ResponseChannel<JSONValue>()
        let params = try JSONValue.encode(
            AuthenticateRequest(methodId: AuthMethodId("xai"))
        )
        let decoded = decodeAcpAgentMessage(
            method: AgentMethodNames.authenticate,
            params: params,
            responseChannel: outer
        )
        guard case .success(.authenticate(let args)) = decoded else {
            Issue.record("expected authenticate")
            return
        }

        let waiter = Task { await outer.awaitResponse() }
        #expect(args.respond(.failure(.internalError("first"))))
        #expect(!args.respond(.failure(.internalError("second"))))

        let received = await waiter.value
        switch received {
        case .failure(let error):
            #expect(error.message == "first")
        case .success:
            Issue.record("expected first failure")
        }
    }

    @Test("typed waiter and transport channel both observe the same success")
    func dualObservation() async throws {
        let outer = ResponseChannel<JSONValue>()
        let params = try JSONValue.encode(
            AuthenticateRequest(methodId: AuthMethodId("xai"))
        )
        let decoded = decodeAcpAgentMessage(
            method: AgentMethodNames.authenticate,
            params: params,
            responseChannel: outer
        )
        guard case .success(.authenticate(let args)) = decoded else {
            Issue.record("expected authenticate")
            return
        }

        let typedWaiter = Task { await args.response.awaitResponse() }
        let outerWaiter = Task { await outer.awaitResponse() }
        #expect(args.respond(.success(AuthenticateResponse())))

        switch await typedWaiter.value {
        case .success:
            break
        case .failure(let error):
            Issue.record("typed waiter failed: \(error)")
        }
        switch await outerWaiter.value {
        case .success:
            break
        case .failure(let error):
            Issue.record("outer waiter failed: \(error)")
        }
    }

    @Test("outer cancel wins race against late typed response")
    func outerCancelWinsRace() async throws {
        let outer = ResponseChannel<JSONValue>()
        let params = try JSONValue.encode(
            PromptRequest(sessionId: AcpSessionId("s"), prompt: [.text("x")])
        )
        let decoded = decodeAcpAgentMessage(
            method: AgentMethodNames.sessionPrompt,
            params: params,
            responseChannel: outer
        )
        guard case .success(.prompt(let args)) = decoded else {
            Issue.record("expected prompt")
            return
        }

        let waiter = Task { await outer.awaitResponse() }
        await Task.yield()
        #expect(outer.cancel())
        // Typed respond may still succeed on its own channel; outer stays cancelled.
        _ = args.respond(.success(PromptResponse(stopReason: .endTurn)))

        let received = await waiter.value
        switch received {
        case .failure(let error):
            #expect(acpChannelFailure(error) == .recvFailed)
        case .success:
            Issue.record("expected outer cancel to win")
        }
    }

    @Test("extension method response bridges JSON body")
    func extensionMethodBridge() async {
        let outer = ResponseChannel<JSONValue>()
        let decoded = decodeAcpAgentMessage(
            method: "x.ai/custom",
            params: .object(["a": .number(.int64(1))]),
            responseChannel: outer,
            isNotification: false
        )
        guard case .success(.extMethod(let args)) = decoded else {
            Issue.record("expected extMethod, got \(decoded)")
            return
        }
        #expect(args.methodName == "x.ai/custom")

        let waiter = Task { await outer.awaitResponse() }
        await Task.yield()
        #expect(args.respond(.success(ExtResponse(.object(["ok": .bool(true)])))))

        let result = await waiter.value
        switch result {
        case .success(let value):
            #expect(value.objectValue?["ok"]?.boolValue == true)
        case .failure(let error):
            Issue.record("expected success, got \(error)")
        }
    }
}

@Suite("ACP extension notification dispatch")
struct AcpExtensionNotificationDispatchTests {
    @Test("unknown agent request becomes extMethod with original name")
    func unknownAgentRequest() {
        let result = decodeAcpAgentMessage(
            method: "x.ai/custom_method",
            params: .object(["foo": .string("bar")]),
            isNotification: false
        )
        switch result {
        case .success(.extMethod(let args)):
            #expect(args.request.method == "x.ai/custom_method")
            #expect(args.methodName == "x.ai/custom_method")
        default:
            Issue.record("expected extMethod, got \(result)")
        }
    }

    @Test("unknown agent notification becomes extNotification with original name")
    func unknownAgentNotification() {
        let result = decodeAcpAgentMessage(
            method: "x.ai/queue/changed",
            params: .object(["queued": .number(.int64(2))]),
            isNotification: true
        )
        switch result {
        case .success(.extNotification(let args)):
            #expect(args.request.method == "x.ai/queue/changed")
            #expect(args.methodName == "x.ai/queue/changed")
        default:
            Issue.record("expected extNotification, got \(result)")
        }
    }

    @Test("literal ext_notification placeholder still classifies as notification")
    func literalExtNotification() {
        let result = decodeAcpAgentMessage(
            method: "ext_notification",
            params: .object([:]),
            isNotification: false
        )
        switch result {
        case .success(.extNotification(let args)):
            #expect(args.request.method == "ext_notification")
        default:
            Issue.record("expected extNotification placeholder, got \(result)")
        }
    }

    @Test("unknown client notification preserves method name")
    func unknownClientNotification() {
        let result = decodeAcpClientMessage(
            method: "x.ai/leader_reconnected",
            params: .object(["sessionId": .string("s1")]),
            isNotification: true
        )
        switch result {
        case .success(.extNotification(let args)):
            #expect(args.request.method == "x.ai/leader_reconnected")
        default:
            Issue.record("expected client extNotification, got \(result)")
        }
    }

    @Test("unknown client request becomes extMethod")
    func unknownClientRequest() {
        let result = decodeAcpClientMessage(
            method: "x.ai/custom_method",
            params: .object(["foo": .string("bar")]),
            isNotification: false
        )
        switch result {
        case .success(.extMethod(let args)):
            #expect(args.request.method == "x.ai/custom_method")
        default:
            Issue.record("expected client extMethod, got \(result)")
        }
    }
}

// MARK: - Captured wire corpus

@Suite("ACP wire corpus fixtures")
struct ACPWireCorpusTests {
    private struct Corpus: Decodable {
        var cases: [CorpusCase]
    }

    private struct CorpusCase: Decodable {
        var name: String
        var direction: String?
        var method: String?
        var isNotification: Bool?
        var params: JSONValue?
        var response: JSONValue?
        var kind: String?
        var id: JSONValue?
        var error: AcpError?
    }

    private static func loadCorpus() throws -> Corpus {
        // Embedded fixture (see ACPWireCorpusFixture.swift) so the corpus
        // ships without Package.swift resource registration.
        let data = Data(ACPWireCorpusFixture.json.utf8)
        return try JSONDecoder().decode(Corpus.self, from: data)
    }

    @Test("wire corpus cases decode through typed dispatch")
    func corpusDispatchRoundTrip() throws {
        let corpus = try Self.loadCorpus()
        #expect(corpus.cases.count >= 15)

        for item in corpus.cases {
            if item.kind == "jsonrpc-error" {
                guard let error = item.error, let idValue = item.id else {
                    Issue.record("\(item.name): missing error/id")
                    continue
                }
                let id: AcpRequestId
                if let n = idValue.int64Value {
                    id = .number(n)
                } else if case .number(.double(let d)) = idValue, d.rounded() == d {
                    id = .number(Int64(d))
                } else if let s = idValue.stringValue {
                    id = .string(s)
                } else {
                    Issue.record("\(item.name): unsupported id")
                    continue
                }
                let encoded = try encodeJsonRpcError(id: id, error: error)
                // Compare semantically: JSONNumber may decode corpus ints as
                // double while encodeJsonRpcError emits int64.
                switch id {
                case .number(let n):
                    #expect(encoded.objectValue?["id"]?.int64Value == n)
                case .string(let s):
                    #expect(encoded.objectValue?["id"]?.stringValue == s)
                case .null:
                    #expect(encoded.objectValue?["id"] == .null)
                }
                #expect(encoded.objectValue?["error"]?.objectValue?["code"]?.int64Value == Int64(error.code.code))
                continue
            }

            guard let method = item.method, let params = item.params else {
                Issue.record("\(item.name): missing method/params")
                continue
            }
            let isNotification = item.isNotification ?? false
            switch item.direction {
            case "agent", nil:
                let decoded = decodeAcpAgentMessage(
                    method: method,
                    params: params,
                    isNotification: isNotification
                )
                switch decoded {
                case .success(let message):
                    if isNotification || method == "ext_notification" {
                        if method == AgentMethodNames.sessionCancel {
                            #expect(message.methodName == AgentMethodNames.sessionCancel)
                        } else if OpenGrokACPMethodCatalog.contains(method) {
                            #expect(message.methodName == method
                                || message.methodName == AgentMethodNames.sessionSetMode
                                || message.methodName == AgentMethodNames.sessionSetModel)
                        } else {
                            #expect(message.methodName == method)
                            if case .extNotification = message {
                                // ok
                            } else {
                                Issue.record("\(item.name): expected extNotification for \(method)")
                            }
                        }
                    } else if !OpenGrokACPMethodCatalog.contains(method)
                        && method != "ext_method"
                        && method != OpenGrokACPExtMethods.askUserQuestion {
                        if case .extMethod(let args) = message {
                            #expect(args.methodName == method)
                        } else {
                            Issue.record("\(item.name): expected extMethod for \(method)")
                        }
                    } else {
                        // Known methods: methodName may normalize camelCase aliases.
                        #expect(!message.methodName.isEmpty)
                    }
                case .failure(let error):
                    Issue.record("\(item.name): decode failed: \(error)")
                }
            case "client":
                let decoded = decodeAcpClientMessage(
                    method: method,
                    params: params,
                    isNotification: isNotification
                )
                switch decoded {
                case .success(let message):
                    if isNotification && !OpenGrokACPMethodCatalog.contains(method) {
                        if case .extNotification(let args) = message {
                            #expect(args.methodName == method)
                        } else {
                            Issue.record("\(item.name): expected client extNotification")
                        }
                    } else {
                        #expect(!message.methodName.isEmpty)
                    }
                case .failure(let error):
                    Issue.record("\(item.name): client decode failed: \(error)")
                }
            default:
                Issue.record("\(item.name): unknown direction \(item.direction ?? "nil")")
            }

            if let response = item.response, method == OpenGrokACPExtMethods.askUserQuestion {
                let decoded = try response.decode(AskUserQuestionExtResponse.self)
                // Round-trip response body.
                let reencoded = try JSONValue.encode(decoded)
                let again = try reencoded.decode(AskUserQuestionExtResponse.self)
                #expect(String(describing: again) == String(describing: decoded))
            }
        }
    }

    @Test("ask-user corpus preserves recommended labels, multi-select, Other, cancel")
    func askUserCorpusShapes() throws {
        let corpus = try Self.loadCorpus()
        let byName = Dictionary(uniqueKeysWithValues: corpus.cases.map { ($0.name, $0) })

        let single = try #require(byName["ask-user-single-select-recommended"])
        let singleParams = try #require(single.params)
        let singleReq = try singleParams.decode(AskUserQuestionExtRequest.self)
        #expect(singleReq.questions[0].options[0].label.contains("Recommended"))
        #expect(singleReq.questions[0].options[0].preview == "<div>redis</div>")
        #expect(singleReq.questions[0].multiSelect == false)

        let multi = try #require(byName["ask-user-multi-select"]?.response)
        let multiResp = try multi.decode(AskUserQuestionExtResponse.self)
        #expect(multiResp.answersMap["Which caches?"] == ["Redis", "Memcached"])

        let other = try #require(byName["ask-user-other-freeform"]?.response)
        let otherResp = try other.decode(AskUserQuestionExtResponse.self)
        if case .accepted(let answers, let annotations) = otherResp {
            #expect(answers.first?.labels == [AskUserQuestionOther.label])
            #expect(annotations?["Notes?"]?.notes == "please use SQLite")
        } else {
            Issue.record("expected accepted Other response")
        }

        let cancelled = try #require(byName["ask-user-cancelled"]?.response)
        let cancelledResp = try cancelled.decode(AskUserQuestionExtResponse.self)
        if case .cancelled = cancelledResp {
            // ok
        } else {
            Issue.record("expected cancelled")
        }
    }
}
