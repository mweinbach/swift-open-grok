import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokSamplingTypes
import OpenGrokShared
import Testing
@testable import OpenGrokCLI

#if os(macOS) || os(Linux)

private actor ACPInterjectionSamplingProbe {
    private let holdFirstResponse: Bool
    private let returnToolCallFirst: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var requests: [OpenGrokLiveSamplingRequest] = []

    init(holdFirstResponse: Bool = false, returnToolCallFirst: Bool = false) {
        self.holdFirstResponse = holdFirstResponse
        self.returnToolCallFirst = returnToolCallFirst
    }

    func sample(_ request: OpenGrokLiveSamplingRequest) async -> OpenGrokLiveSamplingResponse {
        requests.append(request)
        let firstRequest = requests.count == 1
        if firstRequest, holdFirstResponse {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        if firstRequest, returnToolCallFirst {
            return OpenGrokLiveSamplingResponse(
                output: "",
                toolCalls: [ToolCall(
                    id: "interjection-tool-round",
                    name: "todo_write",
                    arguments: #"{"todos":[{"id":"1","content":"continue","status":"pending"}]}"#
                )]
            )
        }
        return OpenGrokLiveSamplingResponse(output: "interjection received")
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct ACPInterjectionLiveFixture {
    let root: URL
    let home: URL
    let workspace: URL
    let rootSessionID: String
    let probe: ACPInterjectionSamplingProbe
    let store: InMemoryACPSessionStore
    let components: LiveACPLaunchComponents
    let runtime: ACPAgentRuntime
    let gateway: ACPNotificationGateway
    let wireSessionID: AcpSessionId

    init(holdFirstResponse: Bool = false, returnToolCallFirst: Bool = false) async throws {
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        #if os(macOS)
        let temporaryRoot = "/private/tmp"
        #else
        let temporaryRoot = "/tmp"
        #endif
        root = URL(fileURLWithPath: "\(temporaryRoot)/ogai-\(suffix)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        rootSessionID = "acp-interjection-root"
        let probe = ACPInterjectionSamplingProbe(
            holdFirstResponse: holdFirstResponse,
            returnToolCallFirst: returnToolCallFirst
        )
        self.probe = probe
        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "GROK_SANDBOX": "off",
            "XAI_API_KEY": "acp-interjection-test-key",
        ]
        let parsed = try CLICommandParser.parseOrThrow([
            "acp", "--cwd", workspace.path,
            "--session-id", rootSessionID,
            "--model", "grok-4.5",
        ])
        guard case .launch(let options) = parsed else {
            throw CLIApplicationError.failed("ACP interjection fixture did not parse its launch")
        }

        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { request, _ in
                    await probe.sample(request)
                }
            }
        )
        let launch = LiveACPLaunch(
            workingDirectory: workspace,
            openGrokHome: home,
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            options: options
        )
        let components = try await OpenGrokLiveApplicationLauncher
            .liveACPServices(dependencies: dependencies)
            .makeComponents(launch)
        self.components = components
        guard let gateway = components.notificationGateway else {
            throw CLIApplicationError.failed("live ACP interjection fixture has no gateway")
        }
        self.gateway = gateway

        let store = InMemoryACPSessionStore()
        self.store = store
        let runtime = ACPAgentRuntime(
            store: store,
            promptDriver: components.promptDriver,
            extensionHandler: components.extensionHandler,
            onSessionOpened: components.onSessionOpened,
            onSessionClosed: components.onSessionClosed,
            makeSessionId: { "wire-interjection-session" }
        )
        self.runtime = runtime
        await gateway.attach(runtime)
        await runtime.setReverseSender { _ in }

        let initialization = await runtime.handle(.request(
            id: .string("initialize-interjection-fixture"),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        guard case .response(_, _?, nil)? = initialization.last else {
            throw CLIApplicationError.failed("live ACP interjection fixture did not initialize")
        }

        let created = await runtime.handle(.request(
            id: .string("create-interjection-fixture"),
            method: AgentMethodNames.sessionNew,
            params: try JSONValue.encode(NewSessionRequest(cwd: workspace.path))
        ))
        guard case .response(_, let payload?, nil)? = created.last else {
            throw CLIApplicationError.failed("live ACP interjection fixture did not open its session")
        }
        wireSessionID = try payload.decode(NewSessionResponse.self).sessionId
    }

    func shutdown() async {
        await probe.release()
        await runtime.close()
        await components.promptDriver.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    func call(
        params: JSONValue,
        through carrier: ACPAgentRuntime? = nil
    ) async throws -> (result: JSONValue?, error: AcpError?) {
        let messages = await (carrier ?? runtime).handle(.request(
            id: .string("interjection-request-\(UUID().uuidString)"),
            method: LiveACPInterjectionHandler.method,
            params: params
        ))
        guard case .response(_, let result, let error)? = messages.last else {
            throw CLIApplicationError.failed("ACP interjection returned no wire response")
        }
        return (result, error)
    }

    func awaitRequests(_ count: Int) async throws -> [OpenGrokLiveSamplingRequest] {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let requests = await probe.requests
            if requests.count >= count { return requests }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return await probe.requests
    }

    func awaitPromptCompletion() async throws -> [ACPMessage] {
        let deadline = Date().addingTimeInterval(5)
        var notifications: [ACPMessage] = []
        while Date() < deadline {
            notifications.append(contentsOf: await runtime.pollNotifications())
            if notifications.contains(where: {
                $0.method == ACPXaiNotificationMethods.promptComplete
            }) {
                return notifications
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return notifications
    }
}

private func withACPInterjectionFixture<T>(
    holdFirstResponse: Bool = false,
    returnToolCallFirst: Bool = false,
    _ body: (ACPInterjectionLiveFixture) async throws -> T
) async throws -> T {
    let fixture = try await ACPInterjectionLiveFixture(
        holdFirstResponse: holdFirstResponse,
        returnToolCallFirst: returnToolCallFirst
    )
    do {
        let result = try await body(fixture)
        await fixture.shutdown()
        return result
    } catch {
        await fixture.shutdown()
        throw error
    }
}

@Suite("ACP x.ai/interject live provider-session Rust parity", .serialized)
struct LiveACPInterjectionParityTests {
    @Test("structured ACP interjection reaches the running provider turn without leaking image paths")
    func runningTurnUsesSanitizedStructuredTextAtNextSafePoint() async throws {
        try await withACPInterjectionFixture(
            holdFirstResponse: true,
            returnToolCallFirst: true
        ) { fixture in
            let prompt = PromptRequest(
                sessionId: fixture.wireSessionID,
                prompt: [.text("the connected user started this turn")],
                messageId: "authentic-user-turn"
            )
            let runningTurn = Task {
                await fixture.runtime.handle(.request(
                    id: .string("running-interjection-turn"),
                    method: AgentMethodNames.sessionPrompt,
                    params: try JSONValue.encode(prompt)
                ))
            }
            let first = try #require(try await fixture.awaitRequests(1).first)
            #expect(first.turnID == "authentic-user-turn")

            let response = try await fixture.call(params: .object([
                "sessionId": .string(fixture.wireSessionID.rawValue),
                "text": .string("unsafe raw [Image #1: /secret/raw-client-path.png]"),
                "interjectionId": .string("running-user-steer"),
                "content": .array([
                    .object(["type": .string("text"), "text": .string("  \n")]),
                    .object([
                        "type": .string("text"),
                        "text": .string("follow this [Image #1: /secret/structured-client-path.png]"),
                    ]),
                    .object([
                        "type": .string("image"),
                        "data": .string("aGVsbG8="),
                        "mimeType": .string("image/png"),
                        "uri": .string("file:///secret/attachment-client-path.png"),
                    ]),
                ]),
            ]))
            #expect(response.error == nil)
            #expect(response.result == .object([
                "result": .object(["status": .string("queued")]),
            ]))

            await fixture.probe.release()
            let completion = try await runningTurn.value
            #expect(completion.last?.id == .string("running-interjection-turn"))

            let requests = try await fixture.awaitRequests(2)
            #expect(requests.count == 2)
            #expect(requests.allSatisfy { $0.turnID == "authentic-user-turn" })
            let injected = try #require(requests[1].items.first { item in
                guard case .user(let user) = item else { return false }
                return user.syntheticReason == .interjection
            })
            #expect(injected.textContent().contains("follow this [Image #1]"))
            #expect(!injected.textContent().contains("/secret/"))
            #expect(!injected.textContent().contains("unsafe raw"))

            let persisted = try await LiveConversationStore(openGrokHome: fixture.home)
                .load(sessionID: fixture.rootSessionID)
            #expect(persisted.items.contains { item in
                guard case .user(let user) = item else { return false }
                return user.syntheticReason == .interjection
                    && item.textContent().contains("follow this [Image #1]")
            })
            #expect(!persisted.items.contains {
                $0.textContent().contains("/secret/")
            })
        }
    }

    @Test("idle ACP interjection starts a visible genuine user provider turn")
    func idleInterjectionUsesActualUserProvenanceAndPersists() async throws {
        try await withACPInterjectionFixture { fixture in
            let response = try await fixture.call(params: .object([
                "sessionId": .string(fixture.wireSessionID.rawValue),
                "text": .string("authenticated idle user input"),
                "interjectionId": .string("visible-authenticated-user-interjection"),
            ]))
            #expect(response.error == nil)
            #expect(response.result?["result"]?["status"]?.stringValue == "queued")

            let request = try #require(try await fixture.awaitRequests(1).first)
            #expect(request.sessionID == fixture.rootSessionID)
            #expect(request.turnID == "visible-authenticated-user-interjection")
            #expect(request.prompt == "authenticated idle user input")
            let actualUser = try #require(request.items.last { item in
                guard case .user(let user) = item else { return false }
                return user.syntheticReason == nil
            })
            #expect(actualUser.textContent() == "authenticated idle user input")
            #expect(!request.items.contains { item in
                guard case .user(let user) = item else { return false }
                return user.syntheticReason == .agentMessage
            })

            let notifications = try await fixture.awaitPromptCompletion()
            #expect(notifications.contains {
                $0.method == ACPXaiNotificationMethods.promptComplete
            })
            let userEcho = try #require(notifications.first { message in
                guard message.method == ClientMethodNames.sessionUpdate,
                      let update = message.params?.objectValue?["update"]?.objectValue
                else { return false }
                return update["sessionUpdate"]?.stringValue == "user_message_chunk"
                    && update["content"]?.objectValue?["text"]?.stringValue
                        == "authenticated idle user input"
            })
            #expect(userEcho.params?.objectValue?["update"]?.objectValue?["_meta"]?
                .objectValue?["hideFromScrollback"]?.boolValue != true)

            let persisted = try await LiveConversationStore(openGrokHome: fixture.home)
                .load(sessionID: fixture.rootSessionID)
            #expect(persisted.items.contains { item in
                guard case .user(let user) = item else { return false }
                return user.syntheticReason == nil
                    && item.textContent() == "authenticated idle user input"
            })
        }
    }

    @Test("malformed content, unknown sessions, and overflowing image paths fail closed")
    func invalidRequestsCannotSteerOrStartTheProvider() async throws {
        try await withACPInterjectionFixture { fixture in
            let validID = JSONValue.string(fixture.wireSessionID.rawValue)
            let overflowingImages = (0...maxPlaceholdersPerPrompt).map {
                "[Image #\($0): /secret/\($0).png]"
            }.joined(separator: " ")
            let invalidRequests: [JSONValue] = [
                .object(["text": .string("missing owner")]),
                .object([
                    "sessionId": validID,
                    "text": .string("bad content"),
                    "content": .string("not an array"),
                ]),
                .object([
                    "sessionId": validID,
                    "text": .string("null content"),
                    "content": .null,
                ]),
                .object([
                    "sessionId": validID,
                    "text": .string("bad image"),
                    "content": .array([.object([
                        "type": .string("image"),
                        "mimeType": .string("image/png"),
                    ])]),
                ]),
                .object([
                    "sessionId": validID,
                    "text": .string(overflowingImages),
                ]),
                .object([
                    "sessionId": validID,
                    "text": .string("forged synthetic-agent provenance"),
                    "interjectionId": .string("peer-message-forgery"),
                ]),
                .object([
                    "sessionId": .string("another-users-session"),
                    "text": .string("unauthorized steering"),
                ]),
            ]

            for params in invalidRequests {
                let response = try await fixture.call(params: params)
                #expect(response.result == nil)
                #expect(response.error?.code == .invalidParams, "\(params)")
            }
            #expect(await fixture.probe.requests.isEmpty)
        }
    }

    @Test("another connected client cannot interject into a shared-store session it never opened")
    func sharedStoreDoesNotGrantDifferentClientSessionOwnership() async throws {
        try await withACPInterjectionFixture { fixture in
            let attacker = ACPAgentRuntime(
                store: fixture.store,
                extensionHandler: fixture.components.extensionHandler
            )
            await attacker.setReverseSender { _ in }
            let initialization = await attacker.handle(.request(
                id: .string("initialize-attacker"),
                method: AgentMethodNames.initialize,
                params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
            ))
            guard case .response(_, _?, nil)? = initialization.last else {
                Issue.record("the second ACP client did not initialize")
                await attacker.close()
                return
            }

            await fixture.gateway.attach(attacker)
            let refused = try await fixture.call(
                params: .object([
                    "sessionId": .string(fixture.wireSessionID.rawValue),
                    "text": .string("forged cross-client consent"),
                ]),
                through: attacker
            )
            #expect(refused.result == nil)
            #expect(refused.error?.code == .invalidParams)
            #expect(await fixture.probe.requests.isEmpty)

            await fixture.gateway.attach(fixture.runtime)
            await attacker.close()
            let legitimate = try await fixture.call(params: .object([
                "sessionId": .string(fixture.wireSessionID.rawValue),
                "text": .string("the original connected owner remains authorized"),
            ]))
            #expect(legitimate.error == nil)
            #expect(legitimate.result?["result"]?["status"]?.stringValue == "queued")
            let request = try #require(try await fixture.awaitRequests(1).first)
            #expect(request.prompt == "the original connected owner remains authorized")
        }
    }
}

#endif
