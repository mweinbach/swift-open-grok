import Foundation
import OpenGrokShared
import Testing

@testable import OpenGrokAgentControlTools

private actor RecordingSessionCollaborationBackend: SessionCollaborationBackend {
    private(set) var listCalls = 0
    private(set) var readCalls: [(sessionID: String, maxUpdates: Int)] = []
    private(set) var messageCalls: [(sessionID: String, message: String)] = []
    private var status: MessageSessionStatus = .accepted

    func setStatus(_ status: MessageSessionStatus) {
        self.status = status
    }

    func listSessions() async throws -> ListSessionsOutput {
        listCalls += 1
        return ListSessionsOutput(busEnabled: true, sessions: [
            LiveSessionEntry(
                sessionID: "root",
                cwd: "/tmp/project",
                projectName: "project",
                modelID: "grok-4",
                status: "idle",
                isSelf: true
            )
        ])
    }

    func readSession(sessionID: String, maxUpdates: Int) async throws -> ReadSessionOutput {
        readCalls.append((sessionID: sessionID, maxUpdates: maxUpdates))
        return ReadSessionOutput(
            sessionID: sessionID,
            title: "Peer title",
            live: true,
            updates: [SessionCollaborationTranscriptEntry(role: "agent", text: "Working")]
        )
    }

    func messageSession(
        sessionID: String,
        message: String
    ) async throws -> MessageSessionStatus {
        messageCalls.append((sessionID: sessionID, message: message))
        return status
    }
}

@Suite("Cross-process session collaboration tool contracts")
struct SessionCollaborationToolsTests {
    private let surface = SessionCollaborationToolSurface()

    @Test("tool names, read-only scopes, and model descriptions match Rust")
    func toolMetadata() {
        #expect(SessionCollaborationTool.allCases.map(\.rawValue) == [
            "list_sessions", "read_session", "message_session",
        ])
        #expect(SessionCollaborationTool.listSessions.isReadOnly)
        #expect(SessionCollaborationTool.readSession.isReadOnly)
        #expect(!SessionCollaborationTool.messageSession.isReadOnly)
        #expect(SessionCollaborationTool.listSessions.descriptionTemplate.contains("including this one"))
        #expect(SessionCollaborationTool.messageSession.descriptionTemplate.contains(
            "never resend an accepted message"
        ))
    }

    @Test("input schemas preserve required names and deny-unknown-fields boundaries")
    func schemasMatchRust() {
        let list = SessionCollaborationToolSurface.inputSchema(for: .listSessions)
        #expect(list["properties"] == .object([:]))
        #expect(list["additionalProperties"] == nil)

        let read = SessionCollaborationToolSurface.inputSchema(for: .readSession)
        #expect(read["required"] == .array([.string("session_id")]))
        #expect(read["additionalProperties"] == .bool(false))
        #expect(read["properties"]?["max_updates"]?["minimum"] == .number(.int64(0)))

        let message = SessionCollaborationToolSurface.inputSchema(for: .messageSession)
        #expect(message["required"] == .array([.string("session_id"), .string("message")]))
        #expect(message["additionalProperties"] == .bool(false))
    }

    @Test("strict read and message decoding rejects unknown and negative fields")
    func strictInputDecoding() throws {
        let read = Data(#"{"session_id":"peer","extra":true}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ReadSessionInput.self, from: read)
        }

        let message = Data(#"{"session_id":"peer","message":"hello","extra":1}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MessageSessionInput.self, from: message)
        }

        let negative = Data(#"{"session_id":"peer","max_updates":-1}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ReadSessionInput.self, from: negative)
        }
    }

    @Test("list output uses exact snake_case keys and omits absent optional fields")
    func listOutputWireShape() throws {
        let output = ListSessionsOutput(busEnabled: true, sessions: [
            LiveSessionEntry(
                sessionID: "s-1",
                cwd: "/work/repo",
                projectName: "repo",
                status: "busy",
                isSelf: false
            )
        ])
        let value = try JSONValue.encode(output)
        #expect(value["bus_enabled"] == .bool(true))
        let entry = value["sessions"]?[0]
        #expect(entry?["session_id"] == .string("s-1"))
        #expect(entry?["project_name"] == .string("repo"))
        #expect(entry?["is_self"] == .bool(false))
        #expect(entry?["model_id"] == nil)
        #expect(entry?["title"] == nil)
    }

    @Test("read output keeps peer roles and omits absent title")
    func readOutputWireShape() throws {
        let output = ReadSessionOutput(
            sessionID: "peer",
            live: true,
            updates: [
                SessionCollaborationTranscriptEntry(role: "user", text: "Hi"),
                SessionCollaborationTranscriptEntry(role: "agent", text: "Hello"),
                SessionCollaborationTranscriptEntry(role: "peer", text: "Coordinate"),
            ]
        )
        let value = try JSONValue.encode(output)
        #expect(value["session_id"] == .string("peer"))
        #expect(value["title"] == nil)
        #expect(value["updates"]?[2]?["role"] == .string("peer"))
    }

    @Test("delivery verdicts use upstream snake_case spellings")
    func deliveryStatusWireShape() throws {
        for (status, spelling) in [
            (MessageSessionStatus.accepted, "accepted"),
            (.unknownSession, "unknown_session"),
            (.rejected, "rejected"),
        ] {
            let value = try JSONValue.encode(MessageSessionOutput(
                targetSessionID: "peer",
                status: status
            ))
            #expect(value["target_session_id"] == .string("peer"))
            #expect(value["status"] == .string(spelling))
        }
    }

    @Test("list forwards the real backend and retains self entry")
    func listDispatch() async throws {
        let backend = RecordingSessionCollaborationBackend()
        let output = try await surface.listSessions(backend: backend)
        #expect(output.busEnabled)
        #expect(output.sessions.first?.isSelf == true)
        #expect(await backend.listCalls == 1)
    }

    @Test("read defaults to 30 and clamps requested limits into 1 through 200")
    func readDefaultsAndBounds() async throws {
        let backend = RecordingSessionCollaborationBackend()
        for input in [
            ReadSessionInput(sessionID: "  peer  "),
            ReadSessionInput(sessionID: "peer", maxUpdates: 0),
            ReadSessionInput(sessionID: "peer", maxUpdates: 999),
            ReadSessionInput(sessionID: "peer", maxUpdates: 42),
        ] {
            let output = try await surface.readSession(input: input, backend: backend)
            #expect(output.sessionID == "peer")
        }
        let calls = await backend.readCalls
        #expect(calls.map(\.maxUpdates) == [30, 1, 200, 42])
        #expect(calls.allSatisfy { $0.sessionID == "peer" })
    }

    @Test("empty read targets and negative counts never reach the backend")
    func invalidReadNeverDispatches() async {
        let backend = RecordingSessionCollaborationBackend()
        await #expect(throws: SessionCollaborationError.emptySessionID) {
            try await surface.readSession(
                input: ReadSessionInput(sessionID: " \n "),
                backend: backend
            )
        }
        await #expect(throws: SessionCollaborationError.negativeMaxUpdates) {
            try await surface.readSession(
                input: ReadSessionInput(sessionID: "peer", maxUpdates: -1),
                backend: backend
            )
        }
        #expect(await backend.readCalls.isEmpty)
    }

    @Test("peer messages trim target and body before delivery")
    func messagesAreTrimmed() async throws {
        let backend = RecordingSessionCollaborationBackend()
        let output = try await surface.messageSession(
            input: MessageSessionInput(sessionID: " peer ", message: " \n hello \t "),
            backend: backend
        )
        #expect(output == MessageSessionOutput(targetSessionID: "peer", status: .accepted))
        let calls = await backend.messageCalls
        #expect(calls.count == 1)
        #expect(calls[0].sessionID == "peer")
        #expect(calls[0].message == "hello")
    }

    @Test("UTF-8 body limits count bytes, not graphemes, after whitespace trimming")
    func utf8BodyCap() async throws {
        let backend = RecordingSessionCollaborationBackend()
        let accepted = String(repeating: "é", count: 16_384)
        let output = try await surface.messageSession(
            input: MessageSessionInput(sessionID: "peer", message: " \(accepted) "),
            backend: backend
        )
        #expect(output.status == .accepted)

        let oversized = accepted + "é"
        await #expect(throws: SessionCollaborationError.messageTooLarge) {
            try await surface.messageSession(
                input: MessageSessionInput(sessionID: "peer", message: oversized),
                backend: backend
            )
        }
        #expect(await backend.messageCalls.count == 1)
    }

    @Test("empty peer targets and messages never reach the backend")
    func invalidMessageNeverDispatches() async {
        let backend = RecordingSessionCollaborationBackend()
        await #expect(throws: SessionCollaborationError.emptySessionID) {
            try await surface.messageSession(
                input: MessageSessionInput(sessionID: " ", message: "hello"),
                backend: backend
            )
        }
        await #expect(throws: SessionCollaborationError.emptyMessage) {
            try await surface.messageSession(
                input: MessageSessionInput(sessionID: "peer", message: "\n\t"),
                backend: backend
            )
        }
        #expect(await backend.messageCalls.isEmpty)
    }

    @Test("unknown and rejected deliveries are successful typed verdicts")
    func unsuccessfulDeliveryStatuses() async throws {
        let backend = RecordingSessionCollaborationBackend()
        for status in [MessageSessionStatus.unknownSession, .rejected] {
            await backend.setStatus(status)
            let output = try await surface.messageSession(
                input: MessageSessionInput(sessionID: "peer", message: "hello"),
                backend: backend
            )
            #expect(output.status == status)
        }
        #expect(await backend.messageCalls.count == 2)
    }
}
