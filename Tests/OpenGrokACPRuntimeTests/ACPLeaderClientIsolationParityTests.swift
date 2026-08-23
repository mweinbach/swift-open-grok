import Foundation
import OpenGrokACP
import OpenGrokHTTP
import OpenGrokShared
import Testing

@testable import OpenGrokACPRuntime

private struct ACPLeaderIsolationDriver: ACPPromptDriver {
    func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        await emit(
            SessionNotification(
                sessionId: context.session.sessionId,
                update: .agentMessageChunk(ContentChunk(
                    content: .text(TextContent(text: "leader-private-assistant-marker"))
                ))
            ),
            .durable
        )
        return PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: AcpSessionId) async {}
}

private enum ACPLeaderIsolationError: Error {
    case registrationFailed
    case timedOut
    case unsuccessfulResponse
}

private actor ACPLeaderIsolationInbox {
    private var messages: [ACPMessage] = []

    func append(_ message: ACPMessage) {
        messages.append(message)
    }

    func removeFirst(
        matching predicate: @Sendable (ACPMessage) -> Bool
    ) -> ACPMessage? {
        guard let index = messages.firstIndex(where: predicate) else { return nil }
        return messages.remove(at: index)
    }

    func drain() -> [ACPMessage] {
        defer { messages.removeAll() }
        return messages
    }

    func snapshot() -> [ACPMessage] {
        messages
    }
}

private actor ACPLeaderIsolationClient {
    private let channel: any WebSocketByteChannel
    private let reader: ACPLeaderChannelReader
    private let inbox = ACPLeaderIsolationInbox()
    private var readerTask: Task<Void, Never>?

    init(channel: any WebSocketByteChannel) {
        self.channel = channel
        self.reader = ACPLeaderChannelReader(
            channel: channel,
            maximumMessageSize: ACPLeaderProtocolLimits.maximumMessageSize
        )
    }

    func register(as name: String) async throws -> UInt64 {
        let registration = ACPLeaderClientMessage.register(
            clientType: name,
            mode: .stdio,
            capabilities: ACPLeaderClientCapabilities(
                terminal: true,
                fsRead: true,
                fsWrite: true
            )
        )
        try await channel.write(try ACPLeaderCodec.encode(registration))
        guard case .registered(let clientID, _, _, _, _)? = try await reader.next(
            ACPLeaderServerMessage.self
        ) else {
            throw ACPLeaderIsolationError.registrationFailed
        }

        readerTask = Task { [reader, inbox] in
            do {
                while let message = try await reader.next(ACPLeaderServerMessage.self) {
                    guard case .acp(let payload) = message else { continue }
                    let decoded = try ACPMessage(data: Data(payload.utf8))
                    await inbox.append(decoded)
                }
            } catch {}
        }
        return clientID
    }

    func send(_ message: ACPMessage) async throws {
        let payload = String(decoding: try message.encodedData(), as: UTF8.self)
        try await channel.write(try ACPLeaderCodec.encode(
            ACPLeaderClientMessage.acp(payload: payload)
        ))
    }

    func request(
        id: Int64,
        method: String,
        params: JSONValue
    ) async throws -> JSONValue {
        try await send(.request(id: .number(id), method: method, params: params))
        let response = try await next { message in
            if case .response(.number(id), _, _) = message { return true }
            return false
        }
        guard case .response(_, let result?, nil) = response else {
            throw ACPLeaderIsolationError.unsuccessfulResponse
        }
        return result
    }

    func next(
        timeoutSeconds: Double = 5,
        matching predicate: @escaping @Sendable (ACPMessage) -> Bool
    ) async throws -> ACPMessage {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let message = await inbox.removeFirst(matching: predicate) {
                return message
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw ACPLeaderIsolationError.timedOut
    }

    func drain() async -> [ACPMessage] {
        await inbox.drain()
    }

    func messages() async -> [ACPMessage] {
        await inbox.snapshot()
    }

    func close() async {
        await channel.close()
        readerTask?.cancel()
        await readerTask?.value
        readerTask = nil
    }
}

private actor ACPLeaderIsolationReverseResult {
    private(set) var value: JSONValue?

    func record(_ value: JSONValue) {
        self.value = value
    }
}

private actor ACPLeaderIsolationExtensionCounter {
    private(set) var methods = 0
    private(set) var notifications = 0

    func recordMethod() {
        methods += 1
    }

    func recordNotification() {
        notifications += 1
    }
}

private struct ACPLeaderIsolationExtensionHandler: ACPAgentExtensionHandler {
    let counter: ACPLeaderIsolationExtensionCounter

    func handle(method: String, params: JSONValue) async throws -> JSONValue {
        await counter.recordMethod()
        return .object(["authorized": .bool(true)])
    }
}

private struct ACPLeaderIsolationNotificationHandler: ACPAgentExtensionNotificationHandler {
    let counter: ACPLeaderIsolationExtensionCounter

    func handle(method: String, params: JSONValue) async {
        await counter.recordNotification()
    }
}

@Suite("ACP extension and leader router authority boundaries")
struct ACPLeaderAuthorityBoundaryTests {
    @Test("extension requests and mutating notifications require initialize and authentication")
    func extensionSurfacesFailClosedBeforeAuthentication() async throws {
        let counter = ACPLeaderIsolationExtensionCounter()
        let extensions = ACPExtensionMethodRouter().register(
            exact: "x.ai/interject",
            handler: ACPLeaderIsolationExtensionHandler(counter: counter)
        )
        let notifications = ACPExtensionNotificationRouter().register(
            exact: "x.ai/yolo_mode_changed",
            handler: ACPLeaderIsolationNotificationHandler(counter: counter)
        )
        let runtime = ACPAgentRuntime(
            configuration: ACPAgentConfiguration(requireAuthentication: true),
            extensionRouter: extensions,
            extensionNotifications: notifications
        )

        let beforeInitialization = await runtime.handle(.request(
            id: .number(1),
            method: "x.ai/interject",
            params: .object([:])
        ))
        guard case .response(_, nil, _?)? = beforeInitialization.last else {
            Issue.record("pre-initialization extension unexpectedly executed")
            return
        }
        _ = await runtime.handle(.notification(
            method: "x.ai/yolo_mode_changed",
            params: .object(["enabled": .bool(true)])
        ))

        _ = await runtime.handle(.request(
            id: .number(2),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        let unauthenticated = await runtime.handle(.request(
            id: .number(3),
            method: "x.ai/interject",
            params: .object([:])
        ))
        guard case .response(_, nil, let error?)? = unauthenticated.last else {
            Issue.record("unauthenticated extension unexpectedly executed")
            return
        }
        #expect(error.code == .authRequired)
        _ = await runtime.handle(.notification(
            method: "x.ai/yolo_mode_changed",
            params: .object(["enabled": .bool(true)])
        ))
        #expect(await counter.methods == 0)
        #expect(await counter.notifications == 0)
    }

    @Test("claiming an existing session never replaces its first connected driver")
    func repeatedDriverClaimsRemainObservers() async throws {
        let router = ACPLeaderRouter()
        let session = AcpSessionId("immutable-driver")
        try await router.register(clientID: "owner") { _ in }
        try await router.register(clientID: "observer") { _ in }
        try await router.claim(sessionID: session, clientID: "owner", role: .driver)
        try await router.claim(sessionID: session, clientID: "observer", role: .driver)

        #expect(await router.isDriver(clientID: "owner", for: session))
        #expect(await !router.isDriver(clientID: "observer", for: session))
        #expect(await router.sessionRecipients(session) == ["observer", "owner"])

        let reverse = ACPMessage.request(
            id: .number(99),
            method: ClientMethodNames.sessionRequestPermission,
            params: .object(["sessionId": .string(session.rawValue)])
        )
        #expect(await router.recipients(for: reverse, from: "") == ["owner"])
    }

    @Test("router recognizes every supported nested session identity spelling")
    func sessionIdentitySpellingsRouteToDriver() async throws {
        let router = ACPLeaderRouter()
        let session = AcpSessionId("normalized-session")
        try await router.register(clientID: "owner") { _ in }
        try await router.register(clientID: "observer") { _ in }
        try await router.claim(sessionID: session, clientID: "owner", role: .driver)
        try await router.claim(sessionID: session, clientID: "observer", role: .subscriber)

        for params: JSONValue in [
            .object(["session_id": .string(session.rawValue)]),
            .object(["sourceSessionId": .string(session.rawValue)]),
            .object(["source_session_id": .string(session.rawValue)]),
            .object(["params": .object(["session_id": .string(session.rawValue)])]),
        ] {
            let reverse = ACPMessage.request(
                id: .string(UUID().uuidString),
                method: OpenGrokACPExtMethods.askUserQuestion,
                params: params
            )
            #expect(await router.recipients(for: reverse, from: "") == ["owner"])
        }
    }
}

#if os(macOS) || os(Linux)

private struct ACPLeaderIsolationFixture {
    let directory: URL
    let runtime: ACPAgentRuntime
    let host: ACPLeaderIPCHost
    let listener: ACPLeaderSocketListener
    let acceptTask: Task<Void, Never>
    let owner: ACPLeaderIsolationClient
    let observer: ACPLeaderIsolationClient
    let ownerID: UInt64
    let observerID: UInt64
    let extensionCounter: ACPLeaderIsolationExtensionCounter

    init() async throws {
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        #if os(macOS)
        let directory = URL(fileURLWithPath: "/private/tmp/ogli-\(suffix)", isDirectory: true)
        #else
        let directory = URL(fileURLWithPath: "/tmp/ogli-\(suffix)", isDirectory: true)
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let extensionCounter = ACPLeaderIsolationExtensionCounter()
        let extensionHandler = ACPLeaderIsolationExtensionHandler(counter: extensionCounter)
        let extensions = ACPExtensionMethodRouter()
            .register(exact: "x.ai/mcp/upsert", handler: extensionHandler)
            .register(exact: "x.ai/share_session", handler: extensionHandler)
            .register(exact: "x.ai/session/fork", handler: extensionHandler)
            .register(exact: "x.ai/interject", handler: extensionHandler)
            .register(exact: "x.ai/sessionless/control", handler: extensionHandler)
        let notificationHandler = ACPLeaderIsolationNotificationHandler(counter: extensionCounter)
        let notifications = ACPExtensionNotificationRouter()
            .register(exact: "x.ai/yolo_mode_changed", handler: notificationHandler)
            .register(exact: "x.ai/permissions/reset", handler: notificationHandler)
        let runtime = ACPAgentRuntime(
            promptDriver: ACPLeaderIsolationDriver(),
            extensionRouter: extensions,
            extensionNotifications: notifications,
            makeSessionId: { "leader-isolated-root" }
        )
        let host = ACPLeaderIPCHost(runtime: runtime)
        let listener = ACPLeaderSocketListener(path: directory.appendingPathComponent("leader.sock"))
        let channels = try await listener.start()
        let acceptTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for await channel in channels {
                    group.addTask {
                        await host.serve(channel: channel)
                    }
                }
            }
        }

        let owner = ACPLeaderIsolationClient(channel: try await ACPLeaderSocketDialer.connect(
            path: directory.appendingPathComponent("leader.sock")
        ))
        let ownerID = try await owner.register(as: "authenticated-owner")
        let observer = ACPLeaderIsolationClient(channel: try await ACPLeaderSocketDialer.connect(
            path: directory.appendingPathComponent("leader.sock")
        ))
        let observerID = try await observer.register(as: "untrusted-observer")

        _ = try await owner.request(
            id: 1,
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        )

        self.directory = directory
        self.runtime = runtime
        self.host = host
        self.listener = listener
        self.acceptTask = acceptTask
        self.owner = owner
        self.observer = observer
        self.ownerID = ownerID
        self.observerID = observerID
        self.extensionCounter = extensionCounter
    }

    func createSession() async throws -> AcpSessionId {
        let result = try await owner.request(
            id: 2,
            method: AgentMethodNames.sessionNew,
            params: try JSONValue.encode(NewSessionRequest(cwd: directory.path))
        )
        return try result.decode(NewSessionResponse.self).sessionId
    }

    func shutdown() async {
        await owner.close()
        await observer.close()
        await host.stop()
        await listener.stop()
        acceptTask.cancel()
        await acceptTask.value
        await runtime.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private func withLeaderIsolationFixture<T>(
    _ body: (ACPLeaderIsolationFixture) async throws -> T
) async throws -> T {
    let fixture = try await ACPLeaderIsolationFixture()
    do {
        let result = try await body(fixture)
        await fixture.shutdown()
        return result
    } catch {
        await fixture.shutdown()
        throw error
    }
}

private func leaderIsolationReplayMetadata(_ message: ACPMessage) -> [String: JSONValue]? {
    guard case .notification(let method, let params) = message,
          method == ClientMethodNames.sessionUpdate,
          let metadata = params.objectValue?["_meta"]?.objectValue,
          metadata["isReplay"]?.boolValue == true
    else { return nil }
    return metadata
}

@Suite("Leader ACP authenticated client ownership and private replay", .serialized)
struct ACPLeaderClientIsolationParityTests {
    @Test("failed mutations and loads cannot reserve a future session identifier")
    func failedRequestsDoNotPreclaimFutureSession() async throws {
        try await withLeaderIsolationFixture { fixture in
            let future = AcpSessionId("leader-isolated-root")
            _ = try await fixture.observer.request(
                id: 99,
                method: AgentMethodNames.initialize,
                params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
            )
            try await fixture.observer.send(.request(
                id: .number(100),
                method: AgentMethodNames.sessionPrompt,
                params: .object(["sessionId": .string(future.rawValue)])
            ))
            _ = try await fixture.observer.next {
                if case .response(.number(100), nil, _?) = $0 { return true }
                return false
            }

            try await fixture.observer.send(.request(
                id: .number(101),
                method: AgentMethodNames.sessionLoad,
                params: try JSONValue.encode(LoadSessionRequest(
                    sessionId: future,
                    cwd: fixture.directory.path
                ))
            ))
            _ = try await fixture.observer.next {
                if case .response(.number(101), nil, _?) = $0 { return true }
                return false
            }

            let created = try await fixture.createSession()
            #expect(created == future)
            try await fixture.observer.send(.request(
                id: .number(102),
                method: AgentMethodNames.sessionPrompt,
                params: try JSONValue.encode(PromptRequest(
                    sessionId: created,
                    prompt: [.text("observer must not own the future identifier")]
                ))
            ))
            _ = try await fixture.observer.next {
                if case .response(.number(102), nil, _?) = $0 { return true }
                return false
            }
            _ = try await fixture.owner.request(
                id: 103,
                method: AgentMethodNames.sessionPrompt,
                params: try JSONValue.encode(PromptRequest(
                    sessionId: created,
                    prompt: [.text("the genuine creator retains authority")]
                ))
            )
        }
    }

    @Test("real concurrent Unix clients cannot steal session ownership or another client's replay")
    func creatorRemainsOwnerAndReplayIsPrivate() async throws {
        try await withLeaderIsolationFixture { fixture in
            #expect(fixture.ownerID != fixture.observerID)
            let sessionID = try await fixture.createSession()

            _ = try await fixture.owner.request(
                id: 3,
                method: AgentMethodNames.sessionPrompt,
                params: try JSONValue.encode(PromptRequest(
                    sessionId: sessionID,
                    prompt: [.text("owner-private-user-marker")],
                    messageId: "owner-original-turn"
                ))
            )
            _ = await fixture.owner.drain()
            _ = await fixture.observer.drain()

            _ = try await fixture.observer.request(
                id: 4,
                method: AgentMethodNames.sessionLoad,
                params: try JSONValue.encode(LoadSessionRequest(
                    sessionId: sessionID,
                    cwd: fixture.directory.path,
                    meta: [
                        ACPLeaderCapabilityInjection.clientIDKey:
                            .number(.uint64(fixture.ownerID)),
                    ]
                ))
            )

            let observerNotifications = await fixture.observer.drain()
            let privateReplays = observerNotifications.compactMap(leaderIsolationReplayMetadata)
            #expect(!privateReplays.isEmpty)
            #expect(privateReplays.allSatisfy {
                $0[ACPLeaderCapabilityInjection.clientIDKey] == .number(.uint64(fixture.observerID))
            })
            #expect(await fixture.owner.messages().compactMap(leaderIsolationReplayMetadata).isEmpty)

            _ = try await fixture.owner.request(
                id: 5,
                method: AgentMethodNames.sessionPrompt,
                params: try JSONValue.encode(PromptRequest(
                    sessionId: sessionID,
                    prompt: [.text("shared-live-turn-marker")],
                    messageId: "owner-shared-turn"
                ))
            )
            for client in [fixture.owner, fixture.observer] {
                let live = try await client.next { message in
                    guard case .notification(let method, let params) = message,
                          method == ClientMethodNames.sessionUpdate
                    else { return false }
                    return params.objectValue?["update"]?.objectValue?["content"]?
                        .objectValue?["text"]?.stringValue == "shared-live-turn-marker"
                }
                #expect(leaderIsolationReplayMetadata(live) == nil)
            }
        }
    }

    @Test("observer cannot answer or receive the immutable driver's reverse authority requests")
    func reverseAuthorityRemainsWithFirstAuthenticatedDriver() async throws {
        try await withLeaderIsolationFixture { fixture in
            let sessionID = try await fixture.createSession()

            _ = try await fixture.observer.request(
                id: 10,
                method: AgentMethodNames.sessionLoad,
                params: try JSONValue.encode(LoadSessionRequest(
                    sessionId: sessionID,
                    cwd: fixture.directory.path
                ))
            )
            _ = await fixture.owner.drain()
            _ = await fixture.observer.drain()

            for (offset, method) in [
                "fs/read_text_file",
                "terminal/create",
                ClientMethodNames.sessionRequestPermission,
            ].enumerated() {
                let captured = ACPLeaderIsolationReverseResult()
                let reverse = Task {
                    let response = try await fixture.runtime.requestClient(
                        method: method,
                        params: .object(["sessionId": .string(sessionID.rawValue)])
                    )
                    await captured.record(response)
                    return response
                }
                let request = try await fixture.owner.next { $0.method == method }
                guard case .request(let requestID, _, _) = request else {
                    Issue.record("owner did not receive a real reverse request")
                    reverse.cancel()
                    return
                }
                #expect(await fixture.observer.messages().allSatisfy { $0.method != method })

                try await fixture.observer.send(.response(
                    id: requestID,
                    result: .object(["value": .string("stolen")]),
                    error: nil
                ))
                _ = try await fixture.observer.request(
                    id: Int64(100 + offset),
                    method: ACPLeaderRosterMethods.sessionsList,
                    params: .object([:])
                )
                #expect(await captured.value == nil)

                let authorized = JSONValue.object(["value": .string("authorized-\(offset)")])
                try await fixture.owner.send(.response(
                    id: requestID,
                    result: authorized,
                    error: nil
                ))
                #expect(try await reverse.value == authorized)
            }
        }
    }

    @Test("only the authenticated first driver can submit visible genuine-user idle interjections")
    func idleInterjectionRequiresDriverAndRetainsUserProvenance() async throws {
        try await withLeaderIsolationFixture { fixture in
            let sessionID = try await fixture.createSession()
            _ = try await fixture.observer.request(
                id: 20,
                method: AgentMethodNames.sessionLoad,
                params: try JSONValue.encode(LoadSessionRequest(
                    sessionId: sessionID,
                    cwd: fixture.directory.path
                ))
            )
            _ = await fixture.owner.drain()
            _ = await fixture.observer.drain()

            let gateway = ACPNotificationGateway()
            await gateway.attach(fixture.runtime)

            let observerOwns = await ACPLeaderRequestAuthority.$clientID.withValue(
                String(fixture.observerID)
            ) {
                await gateway.ownsSession(sessionID)
            }
            #expect(!observerOwns)
            let refused = try await ACPLeaderRequestAuthority.$clientID.withValue(
                String(fixture.observerID)
            ) {
                try await gateway.submitUserInterjection(
                    sessionId: sessionID,
                    promptID: "observer-forged-user-turn",
                    text: "observer cannot impersonate the connected owner"
                )
            }
            #expect(refused == .unknownSession)

            let admitted = try await ACPLeaderRequestAuthority.$clientID.withValue(
                String(fixture.ownerID)
            ) {
                try await gateway.submitUserInterjection(
                    sessionId: sessionID,
                    promptID: "owner-authentic-user-interjection",
                    text: "an actual user supplied this idle interjection"
                )
            }
            #expect(admitted == .accepted)

            for client in [fixture.owner, fixture.observer] {
                let message = try await client.next { message in
                    guard case .notification(let method, let params) = message,
                          method == ClientMethodNames.sessionUpdate,
                          let update = params.objectValue?["update"]?.objectValue
                    else { return false }
                    return update["sessionUpdate"]?.stringValue == "user_message_chunk"
                        && update["content"]?.objectValue?["text"]?.stringValue
                            == "an actual user supplied this idle interjection"
                }
                guard case .notification(_, let params) = message else { continue }
                #expect(params.objectValue?["update"]?.objectValue?["_meta"]?
                    .objectValue?["hideFromScrollback"]?.boolValue != true)
            }
        }
    }

    @Test("observers cannot prompt, cancel, close, fork, reconfigure, reset, or mutate owner sessions")
    func observerMutationAttemptsNeverAcquireAuthority() async throws {
        try await withLeaderIsolationFixture { fixture in
            let sessionID = try await fixture.createSession()
            let session = JSONValue.string(sessionID.rawValue)

            try await fixture.observer.send(.request(
                id: .number(29),
                method: AgentMethodNames.sessionPrompt,
                params: .object(["sessionId": session])
            ))
            let deniedBeforeAttach = try await fixture.observer.next {
                if case .response(.number(29), nil, _?) = $0 { return true }
                return false
            }
            #expect(deniedBeforeAttach.id == .number(29))
            _ = try await fixture.owner.request(
                id: 31,
                method: AgentMethodNames.sessionPrompt,
                params: try JSONValue.encode(PromptRequest(
                    sessionId: sessionID,
                    prompt: [.text("not visible to an unregistered attacker")],
                    messageId: "owner-before-observer-attachment"
                ))
            )
            #expect(await fixture.observer.messages().allSatisfy {
                $0.method != ClientMethodNames.sessionUpdate
            })

            _ = try await fixture.observer.request(
                id: 30,
                method: AgentMethodNames.sessionLoad,
                params: try JSONValue.encode(LoadSessionRequest(
                    sessionId: sessionID,
                    cwd: fixture.directory.path
                ))
            )

            let attacks: [(String, JSONValue)] = [
                (AgentMethodNames.sessionPrompt, .object(["sessionId": session])),
                (AgentMethodNames.sessionCancel, .object(["sessionId": session])),
                (AgentMethodNames.sessionClose, .object(["sessionId": session])),
                (AgentMethodNames.sessionFork, .object(["sessionId": session])),
                (AgentMethodNames.sessionSetMode, .object(["sessionId": session])),
                (AgentMethodNames.sessionSetModel, .object(["sessionId": session])),
                (AgentMethodNames.sessionSetConfigOption, .object(["sessionId": session])),
                ("x.ai/mcp/upsert", .object(["session_id": session])),
                ("x.ai/share_session", .object(["params": .object(["session_id": session])])),
                ("x.ai/session/fork", .object(["sourceSessionId": session])),
                ("x.ai/interject", .object(["sessionId": session])),
                ("x.ai/sessionless/control", .object([:])),
            ]
            for (offset, attack) in attacks.enumerated() {
                let requestID = Int64(40 + offset)
                try await fixture.observer.send(.request(
                    id: .number(requestID),
                    method: attack.0,
                    params: attack.1
                ))
                let response = try await fixture.observer.next {
                    if case .response(.number(requestID), _, _) = $0 { return true }
                    return false
                }
                guard case .response(_, nil, _?) = response else {
                    Issue.record("observer mutation unexpectedly succeeded: \(attack.0)")
                    continue
                }
            }
            #expect(await fixture.extensionCounter.methods == 0)

            try await fixture.observer.send(.notification(
                method: "x.ai/yolo_mode_changed",
                params: .object(["yolo_mode": .bool(true)])
            ))
            try await fixture.observer.send(.notification(
                method: "x.ai/permissions/reset",
                params: .object(["session_id": session])
            ))
            _ = try await fixture.observer.request(
                id: 90,
                method: ACPLeaderRosterMethods.sessionsList,
                params: .object([:])
            )
            #expect(await fixture.extensionCounter.notifications == 0)

            let authorized = try await fixture.owner.request(
                id: 91,
                method: "x.ai/interject",
                params: .object(["sessionId": session])
            )
            #expect(authorized["authorized"]?.boolValue == true)
            #expect(await fixture.extensionCounter.methods == 1)
        }
    }

    @Test("observer loads replay without replacing the owner's working directory")
    func observerLoadCannotReconfigureOwningSession() async throws {
        try await withLeaderIsolationFixture { fixture in
            let sessionID = try await fixture.createSession()
            let hostileDirectory = fixture.directory.appendingPathComponent("observer-workspace")
            try FileManager.default.createDirectory(
                at: hostileDirectory,
                withIntermediateDirectories: true
            )

            _ = try await fixture.observer.request(
                id: 60,
                method: AgentMethodNames.sessionLoad,
                params: try JSONValue.encode(LoadSessionRequest(
                    sessionId: sessionID,
                    cwd: hostileDirectory.path,
                    additionalDirectories: [hostileDirectory.path]
                ))
            )
            let listed = try await fixture.owner.request(
                id: 61,
                method: AgentMethodNames.sessionList,
                params: .object([:])
            )
            let sessions = try listed.decode(ListSessionsResponse.self)
            #expect(sessions.sessions.first?.cwd == fixture.directory.path)
        }
    }

    @Test("targeted replay for a departed observer never falls back to another subscriber")
    func departedReplayTargetIsDropped() async throws {
        try await withLeaderIsolationFixture { fixture in
            let sessionID = try await fixture.createSession()
            _ = try await fixture.observer.request(
                id: 70,
                method: AgentMethodNames.sessionLoad,
                params: try JSONValue.encode(LoadSessionRequest(
                    sessionId: sessionID,
                    cwd: fixture.directory.path
                ))
            )
            _ = await fixture.owner.drain()
            await fixture.observer.close()

            await fixture.host.route(.notification(
                method: ClientMethodNames.sessionUpdate,
                params: .object([
                    "sessionId": .string(sessionID.rawValue),
                    "update": .object([
                        "sessionUpdate": .string("agent_message_chunk"),
                        "content": .object([
                            "type": .string("text"),
                            "text": .string("departed-client-private-replay-marker"),
                        ]),
                    ]),
                    "_meta": .object([
                        "isReplay": .bool(true),
                        ACPLeaderCapabilityInjection.clientIDKey:
                            .number(.uint64(fixture.observerID)),
                    ]),
                ])
            ))

            #expect(await fixture.owner.messages().compactMap(leaderIsolationReplayMetadata).isEmpty)
        }
    }
}

#endif
