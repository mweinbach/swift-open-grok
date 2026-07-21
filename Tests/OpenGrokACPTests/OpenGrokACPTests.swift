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
    /// Decode the checked-in fixture and verify the Swift port exposes
    /// the same method catalog and extension metadata.
    @Test("acp-methods.json fixture matches Swift port")
    func fixtureParity() throws {
        // Locate the fixture through the test bundle's resource
        // lookup. SwiftPM copies Package.swift-declared resources
        // into the test bundle; for checked-in JSON under
        // `ProtocolFixtures/`, we resolve relative to the package
        // root via the build's runfiles path.
        let packageRoot = ProcessInfo.processInfo.environment["SRCROOT"]
            ?? FileManager.default.currentDirectoryPath
        let fixtureURL = URL(fileURLWithPath: packageRoot)
            .appendingPathComponent("ProtocolFixtures/acp-methods.json")
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

    @Test("deinit cancels pending continuation so awaiter doesn't hang")
    func deinitCancelsPending() async {
        // Use a weak reference to detect when the channel has been
        // deinitialized. The awaiter must receive a RecvFailed error
        // (not hang forever).
        weak var weakChannel: ResponseChannel<AcpResponseEnvelope>?

        let result: AcpResult<AcpResponseEnvelope> = await withCheckedContinuation { outerCont in
            // Local scope so the strong reference drops at the end of
            // this closure, triggering deinit.
            do {
                let channel = ResponseChannel<AcpResponseEnvelope>()
                weakChannel = channel
                Task<AcpResult<AcpResponseEnvelope>, Never> {
                    let r = await channel.awaitResponse()
                    outerCont.resume(returning: r)
                    return r
                }
            }
        }

        // The channel should have been deinitialized, which cancels
        // the pending continuation with a RecvFailed error.
        #expect(weakChannel == nil, "channel should be deinitialized")
        switch result {
        case .failure(let err):
            #expect(acpChannelFailure(err) == .recvFailed)
        case .success:
            Issue.record("expected cancellation error from deinit")
        }
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

        // Build a fake agent message and send from the client side.
        let responseRef = AcpResponseReference { _ in false }
        let agentMessage = AcpAgentMessage.prompt(
            .object(["sessionId": .string("s1"), "text": .string("hi")]),
            response: responseRef
        )
        #expect(clientChannel.send(agentMessage))

        // The agent channel should receive it.
        let received = await agentChannel.messages.first {
            $0.methodName == AgentMethodNames.sessionPrompt
        }
        #expect(received != nil)
        #expect(received?.methodName == AgentMethodNames.sessionPrompt)

        // Now send a client message from the agent side back to the
        // client.
        let clientResponseRef = AcpResponseReference { _ in false }
        let clientMessage = AcpClientMessage.sessionNotification(
            .object(["sessionId": .string("s1")]),
            response: clientResponseRef
        )
        #expect(agentChannel.send(clientMessage))

        let receivedClient = await clientChannel.messages.first {
            $0.methodName == ClientMethodNames.sessionUpdate
        }
        #expect(receivedClient != nil)
        #expect(receivedClient?.methodName == ClientMethodNames.sessionUpdate)

        // Close both channels.
        clientChannel.close()
        agentChannel.close()
    }
}

// MARK: - Message envelope convenience constructors

@Suite("AcpAgentMessage / AcpClientMessage convenience constructors")
struct MessageConstructorTests {
    private func makeRef() -> AcpResponseReference {
        AcpResponseReference { _ in false }
    }

    @Test("AcpAgentMessage.prompt carries the session/prompt method name")
    func agentPrompt() {
        let msg = AcpAgentMessage.prompt(.null, response: makeRef())
        #expect(msg.methodName == AgentMethodNames.sessionPrompt)
        #expect(msg.envelope.method == AgentMethodNames.sessionPrompt)
    }

    @Test("AcpAgentMessage.setSessionModel uses the snake_case canonical name")
    func agentSetSessionModel() {
        let msg = AcpAgentMessage.setSessionModel(.null, response: makeRef())
        #expect(msg.methodName == AgentMethodNames.sessionSetModel)
    }

    @Test("AcpAgentMessage.extMethod carries the custom method name verbatim")
    func agentExtMethod() {
        let msg = AcpAgentMessage.extMethod("x.ai/foo", .null, response: makeRef())
        #expect(msg.methodName == "x.ai/foo")
    }

    @Test("AcpClientMessage.requestPermission carries the reverse-RPC method name")
    func clientRequestPermission() {
        let msg = AcpClientMessage.requestPermission(.null, response: makeRef())
        #expect(msg.methodName == ClientMethodNames.sessionRequestPermission)
    }

    @Test("AcpClientMessage.sessionNotification carries the session/update name")
    func clientSessionNotification() {
        let msg = AcpClientMessage.sessionNotification(.null, response: makeRef())
        #expect(msg.methodName == ClientMethodNames.sessionUpdate)
    }

    @Test("messages with equal envelopes are equal (channel identity ignored)")
    func messageEqualityIgnoresChannel() {
        let a = AcpAgentMessage.prompt(.null, response: makeRef())
        let b = AcpAgentMessage.prompt(.null, response: makeRef())
        #expect(a == b)
    }
}
