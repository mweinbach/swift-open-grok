// ACPSessionInfoStateCloseTests.swift
//
// The `x.ai/session/info`, `x.ai/session/state`, and `x.ai/session/close`
// ACP extension methods (Wave 20 S4), asserted at the live seams:
//
//   * `info` returns the resident session's display data inside the
//     `ExtMethodResult` envelope; an unknown/absent session returns `{}`.
//   * `state` returns metadata columns from the persisted record; a missing
//     session errors with invalid_params.
//   * `close` reports the close outcome (`closed`/`notResident`) and is
//     idempotent: a second close of the same session reports `notResident`.
//   * Out-of-scope methods (`updates`, `import`, `load_history`, `search`,
//     `repair`, `usage`) are refused with upstream's terminal error.

import Foundation
import OpenGrokACP
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokTestSupport
import Testing

@testable import OpenGrokACPRuntime
@testable import OpenGrokCLI

private typealias JSONValue = OpenGrokShared.JSONValue

// MARK: - Harness

private func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-acp-sessinfoclose-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

@discardableResult
private func seedSession(
    home: URL,
    id: String,
    cwd: URL,
    items: [ConversationItem] = [],
    title: String? = nil,
    modelID: String? = nil,
    provider: ModelProvider? = nil
) async throws -> LiveConversationRecord {
    let store = LiveConversationStore(openGrokHome: home)
    var record = LiveConversationRecord.new(sessionID: id, workingDirectory: cwd)
    record.items = items
    record.title = title
    record.currentModelID = modelID
    record.currentProvider = provider
    try await store.save(record)
    return record
}

private struct InfoStateCloseHarness {
    let home: URL
    let runtime: ACPAgentRuntime
    let gateway: ACPNotificationGateway

    static func start(
        home explicitHome: URL? = nil,
        liveSessionID: String? = nil,
        sessionInfoSnapshot: (@Sendable () async -> LiveSessionInfoSnapshot)? = nil,
        closeLive: (@Sendable () async -> LiveSessionCloseOutcome)? = nil
    ) async throws -> InfoStateCloseHarness {
        let home = try explicitHome ?? makeHome()
        let environment = ["OPENGROK_HOME": home.path, "HOME": home.path]
        let gateway = ACPNotificationGateway()
        let handler = LiveSessionAdminACPHandler(
            openGrokHome: home,
            gateway: gateway,
            liveSessionID: liveSessionID,
            sessionInfoSnapshot: sessionInfoSnapshot,
            closeLive: closeLive
        )
        let router = LiveACPExtensionRouter.build(
            feedback: nil,
            models: LiveModelsACPHandler(
                catalogStore: LiveModelCatalogStore(
                    input: .default,
                    environment: environment,
                    openGrokHome: home,
                    transport: MockHTTPTransport(responses: [])
                ),
                modelSwitch: nil
            ),
            sessionAdmin: handler
        )
        let runtime = ACPAgentRuntime(extensionRouter: router)
        await gateway.attach(runtime)
        let output = await runtime.handle(.request(
            id: .string("init"),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        guard case .response(_, _, nil) = output[0] else {
            throw ACPTransportError.invalidMessage("initialize failed: \(output)")
        }
        return InfoStateCloseHarness(home: home, runtime: runtime, gateway: gateway)
    }

    func call(
        _ method: String,
        id: String,
        params: JSONValue = .object([:])
    ) async -> (result: JSONValue?, error: AcpError?) {
        let output = await runtime.handle(.request(
            id: .string(id),
            method: method,
            params: params
        ))
        guard case .response(_, let result, let error) = output[0] else {
            return (nil, AcpError.internalError("no response for \(method)"))
        }
        return (result, error)
    }

    func shutdown() {
        try? FileManager.default.removeItem(at: home)
    }
}

// MARK: - x.ai/session/info

@Suite("ACP session info/state/close", .serialized)
struct ACPSessionInfoStateCloseTests {

    @Test("info returns the resident session's display data in the ExtMethodResult envelope")
    func infoReturnsResidentData() async throws {
        let harness = try await InfoStateCloseHarness.start(
            liveSessionID: "live-info-1",
            sessionInfoSnapshot: {
                LiveSessionInfoSnapshot(
                    modelID: "gpt-5.4-xhigh",
                    modelDisplayName: "GPT-5.4 xHigh",
                    resolvedModelID: "gpt-5.4-xhigh-fast",
                    cwd: "/Users/test/project",
                    conversationID: "conv-abc",
                    turns: 7,
                    turnIndex: 6,
                    context: LiveSessionContextInfo(
                        maxContextTokens: 128_000,
                        currentTokens: 42_000
                    )
                )
            }
        )
        defer { harness.shutdown() }

        let (result, error) = await harness.call(
            "x.ai/session/info",
            id: "i1",
            params: .object(["sessionId": .string("live-info-1")])
        )
        #expect(error == nil)

        let envelope = result?["result"]
        #expect(envelope?["sessionId"]?.stringValue == "live-info-1")
        #expect(envelope?["cwd"]?.stringValue == "/Users/test/project")

        let data = envelope?["data"]
        #expect(data?["model"]?.stringValue == "gpt-5.4-xhigh")
        #expect(data?["modelDisplayName"]?.stringValue == "GPT-5.4 xHigh")
        #expect(data?["resolvedModelId"]?.stringValue == "gpt-5.4-xhigh-fast")
        #expect(data?["turns"]?.int64Value == 7)
        #expect(data?["turnIndex"]?.int64Value == 6)
        #expect(data?["conversationId"]?.stringValue == "conv-abc")
        #expect(data?["context"]?["maxContextTokens"]?.int64Value == 128_000)
        #expect(data?["context"]?["currentTokens"]?.int64Value == 42_000)
    }

    @Test("info returns empty object when sessionId does not match the resident")
    func infoNonResidentReturnsEmpty() async throws {
        let harness = try await InfoStateCloseHarness.start(
            liveSessionID: "live-info-2",
            sessionInfoSnapshot: {
                LiveSessionInfoSnapshot(modelID: "m", turns: 1)
            }
        )
        defer { harness.shutdown() }

        let (result, error) = await harness.call(
            "x.ai/session/info",
            id: "i2",
            params: .object(["sessionId": .string("other-session")])
        )
        #expect(error == nil)
        #expect(result?["result"] == .object([:]))
    }

    @Test("info with no sessionId defaults to the resident session")
    func infoDefaultsToResident() async throws {
        let harness = try await InfoStateCloseHarness.start(
            liveSessionID: "live-info-3",
            sessionInfoSnapshot: {
                LiveSessionInfoSnapshot(modelID: "claude-5", turns: 3, turnIndex: 2)
            }
        )
        defer { harness.shutdown() }

        let (result, error) = await harness.call(
            "x.ai/session/info",
            id: "i3",
            params: .object([:])
        )
        #expect(error == nil)
        #expect(result?["result"]?["sessionId"]?.stringValue == "live-info-3")
        #expect(result?["result"]?["data"]?["model"]?.stringValue == "claude-5")
    }

    @Test("info returns empty when no live session exists")
    func infoNoLiveSession() async throws {
        let harness = try await InfoStateCloseHarness.start(
            liveSessionID: nil,
            sessionInfoSnapshot: nil
        )
        defer { harness.shutdown() }

        let (result, error) = await harness.call(
            "x.ai/session/info",
            id: "i4",
            params: .object(["sessionId": .string("anything")])
        )
        #expect(error == nil)
        #expect(result?["result"] == .object([:]))
    }

    // MARK: - x.ai/session/state

    @Test("state returns metadata columns from the persisted record")
    func stateReturnsMetadata() async throws {
        let harness = try await InfoStateCloseHarness.start()
        defer { harness.shutdown() }
        try await seedSession(
            home: harness.home, id: "state-1", cwd: harness.home,
            items: [.user("hello"), .user("world")],
            title: "My Session",
            modelID: "gpt-5.4",
            provider: .xai
        )

        let (result, error) = await harness.call(
            "x.ai/session/state",
            id: "s1",
            params: .object([
                "sessionId": .string("state-1"),
                "cwd": .string(harness.home.path),
            ])
        )
        #expect(error == nil)

        let state = result?["result"]
        let summary = state?["summary"]
        #expect(summary?["sessionId"]?.stringValue == "state-1")
        #expect(summary?["title"]?.stringValue == "My Session")
        #expect(summary?["modelId"]?.stringValue == "gpt-5.4")
        #expect(summary?["provider"]?.stringValue == "xai")
        #expect(summary?["messageCount"]?.int64Value == 2)
        #expect(summary?["workingDirectory"]?.stringValue != nil)
        #expect(summary?["createdAt"]?.stringValue != nil)
        #expect(summary?["updatedAt"]?.stringValue != nil)
    }

    @Test("state errors when session is not found")
    func stateSessionNotFound() async throws {
        let harness = try await InfoStateCloseHarness.start()
        defer { harness.shutdown() }

        let (_, error) = await harness.call(
            "x.ai/session/state",
            id: "s2",
            params: .object([
                "sessionId": .string("nonexistent"),
                "cwd": .string(harness.home.path),
            ])
        )
        #expect(error?.code == .invalidParams)
        #expect(error?.data == .string("session not found"))
    }

    @Test("state errors when cwd does not match")
    func stateCwdMismatch() async throws {
        let harness = try await InfoStateCloseHarness.start()
        defer { harness.shutdown() }
        try await seedSession(home: harness.home, id: "state-2", cwd: harness.home)

        let (_, error) = await harness.call(
            "x.ai/session/state",
            id: "s3",
            params: .object([
                "sessionId": .string("state-2"),
                "cwd": .string("/nonexistent/elsewhere"),
            ])
        )
        #expect(error?.code == .invalidParams)
        #expect(error?.data == .string("session not found"))
    }

    @Test("state errors on missing sessionId or cwd params")
    func stateMissingParams() async throws {
        let harness = try await InfoStateCloseHarness.start()
        defer { harness.shutdown() }

        let (_, noId) = await harness.call(
            "x.ai/session/state",
            id: "s4a",
            params: .object(["cwd": .string("/tmp")])
        )
        #expect(noId?.code == .invalidParams)
        #expect(noId?.data?.stringValue?.contains("sessionId") == true)

        let (_, noCwd) = await harness.call(
            "x.ai/session/state",
            id: "s4b",
            params: .object(["sessionId": .string("x")])
        )
        #expect(noCwd?.code == .invalidParams)
        #expect(noCwd?.data?.stringValue?.contains("cwd") == true)
    }

    @Test("state omits optional fields absent from the record")
    func stateOmitsAbsentFields() async throws {
        let harness = try await InfoStateCloseHarness.start()
        defer { harness.shutdown() }
        try await seedSession(home: harness.home, id: "state-3", cwd: harness.home)

        let (result, error) = await harness.call(
            "x.ai/session/state",
            id: "s5",
            params: .object([
                "sessionId": .string("state-3"),
                "cwd": .string(harness.home.path),
            ])
        )
        #expect(error == nil)
        let summary = result?["result"]?["summary"]
        #expect(summary?["title"] == nil)
        #expect(summary?["parentSessionId"] == nil)
        #expect(summary?["modelId"] == nil)
        #expect(summary?["provider"] == nil)
    }

    // MARK: - x.ai/session/close

    @Test("close reports 'closed' for the resident session and calls the closure")
    func closeResidentSession() async throws {
        let closedBox = ClosedBox()
        let harness = try await InfoStateCloseHarness.start(
            liveSessionID: "live-close-1",
            closeLive: {
                await closedBox.mark()
                return .closed
            }
        )
        defer { harness.shutdown() }

        let (result, error) = await harness.call(
            "x.ai/session/close",
            id: "c1",
            params: .object(["sessionId": .string("live-close-1")])
        )
        #expect(error == nil)
        #expect(result?["result"]?["success"]?.boolValue == true)
        #expect(result?["result"]?["outcome"]?.stringValue == "closed")
        #expect(await closedBox.wasCalled)
    }

    @Test("close is idempotent: a second call reports 'notResident'")
    func closeIdempotent() async throws {
        let counter = CallCounter()
        let harness = try await InfoStateCloseHarness.start(
            liveSessionID: "live-close-2",
            closeLive: {
                let count = await counter.increment()
                return count == 1 ? .closed : .notResident
            }
        )
        defer { harness.shutdown() }

        let (first, _) = await harness.call(
            "x.ai/session/close",
            id: "c2a",
            params: .object(["sessionId": .string("live-close-2")])
        )
        #expect(first?["result"]?["outcome"]?.stringValue == "closed")

        let (second, _) = await harness.call(
            "x.ai/session/close",
            id: "c2b",
            params: .object(["sessionId": .string("live-close-2")])
        )
        #expect(second?["result"]?["outcome"]?.stringValue == "notResident")
    }

    @Test("close reports 'notResident' for a non-resident session")
    func closeNonResident() async throws {
        let harness = try await InfoStateCloseHarness.start(
            liveSessionID: "live-close-3",
            closeLive: { .closed }
        )
        defer { harness.shutdown() }

        let (result, error) = await harness.call(
            "x.ai/session/close",
            id: "c3",
            params: .object(["sessionId": .string("other-session")])
        )
        #expect(error == nil)
        #expect(result?["result"]?["outcome"]?.stringValue == "notResident")
    }

    @Test("close reports 'notResident' when no live session exists")
    func closeNoLiveSession() async throws {
        let harness = try await InfoStateCloseHarness.start(
            liveSessionID: nil,
            closeLive: nil
        )
        defer { harness.shutdown() }

        let (result, error) = await harness.call(
            "x.ai/session/close",
            id: "c4",
            params: .object(["sessionId": .string("anything")])
        )
        #expect(error == nil)
        #expect(result?["result"]?["outcome"]?.stringValue == "notResident")
    }

    @Test("close errors on missing sessionId")
    func closeMissingParam() async throws {
        let harness = try await InfoStateCloseHarness.start(
            liveSessionID: "x",
            closeLive: { .closed }
        )
        defer { harness.shutdown() }

        let (_, error) = await harness.call(
            "x.ai/session/close",
            id: "c5",
            params: .object([:])
        )
        #expect(error?.code == .invalidParams)
        #expect(error?.data?.stringValue?.contains("sessionId") == true)
    }

    // MARK: - Out-of-scope refusals

    @Test("out-of-scope session methods are refused with upstream's terminal error")
    func outOfScopeMethodsRefused() async throws {
        let harness = try await InfoStateCloseHarness.start(
            liveSessionID: "live-refuse",
            closeLive: { .closed }
        )
        defer { harness.shutdown() }

        let refused = [
            "x.ai/session/updates",
            "x.ai/session/import",
            "x.ai/session/load_history",
            "x.ai/session/search",
            "x.ai/session/repair",
            "x.ai/session/usage",
        ]

        for method in refused {
            let (_, error) = await harness.call(method, id: "refuse-\(method)")
            #expect(
                error?.code == .methodNotFound,
                "expected method_not_found for \(method), got \(String(describing: error?.code))"
            )
            #expect(
                error?.data?.stringValue?.contains(method) == true,
                "expected error data to mention \(method)"
            )
        }
    }
}

// MARK: - Helpers

private actor ClosedBox {
    var wasCalled = false
    func mark() { wasCalled = true }
}

private actor CallCounter {
    var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}
