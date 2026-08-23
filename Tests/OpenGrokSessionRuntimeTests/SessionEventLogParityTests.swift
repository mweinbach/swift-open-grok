import Foundation
import OpenGrokShared
import Testing
@testable import OpenGrokSessionRuntime

#if os(Windows)
import COpenGrokSockets
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokSessionPersistence
import OpenGrokShellSessionSupport
#endif

private struct SessionEventLogFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-event-log-\(UUID().uuidString)",
            isDirectory: true
        )
        #if os(Windows)
        try OpenGrokConfig.createDirAllOwnerOnly(directory, stateRoot: directory)
        #else
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #endif
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    func read() throws -> [[String: JSONValue]] {
        let data = try Data(contentsOf: directory.appendingPathComponent("events.jsonl"))
        return try data.split(separator: 0x0A).map { line in
            try JSONDecoder().decode([String: JSONValue].self, from: Data(line))
        }
    }
}

private final class SessionEventFailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@Suite("Durable session event log Rust parity")
struct SessionEventLogParityTests {
    @Test("records are flat Rust-compatible events with millisecond UTC timestamps")
    func flatWireFormat() throws {
        let fixture = try SessionEventLogFixture()
        defer { fixture.cleanup() }
        let log = try SessionEventLog(
            sessionDirectory: fixture.directory,
            clock: { Date(timeIntervalSince1970: 0) }
        )

        #expect(log.emit(.turnStarted(
            sessionID: "session-1",
            turnNumber: 4,
            modelID: "grok-4.5",
            yoloMode: false,
            conversationMessageCount: 7,
            relationship: .primary,
            redirectKind: nil
        )))
        #expect(log.emit(.toolStarted(toolName: "read_file")))
        #expect(log.emit(.toolCompleted(
            toolName: "read_file",
            durationMilliseconds: 12,
            outcome: .success,
            toolCallID: "call-1",
            source: .shell
        )))

        let values = try fixture.read()
        #expect(values.count == 3)
        #expect(values[0]["ts"] == .string("1970-01-01T00:00:00.000Z"))
        #expect(values[0]["type"] == .string("turn_started"))
        #expect(values[0]["session_id"] == .string("session-1"))
        #expect(values[0]["schema_version"] == .string("1.0"))
        #expect(values[0]["turn_number"]?.uint64Value == 4)
        #expect(values[0]["session_relationship"] == .string("primary"))
        #expect(values[0]["redirect_kind"] == nil)
        #expect(values[1]["tool_call_id"] == nil)
        #expect(values[1]["session_id"] == nil)
        #expect(values[2]["tool_call_id"] == .string("call-1"))
        #expect(values[2]["duration_ms"]?.uint64Value == 12)
        #expect(values[2]["source"] == nil)
    }

    @Test("event logs are owner-private and never follow a symlink")
    func ownerPrivateAndSymlinkSafe() throws {
        let fixture = try SessionEventLogFixture()
        defer { fixture.cleanup() }
        let log = try SessionEventLog(sessionDirectory: fixture.directory)
        #expect(log.emit(.firstToken))
        #if os(Windows)
        #expect(log.fileURL.path.withCString { og_file_is_owner_only($0) } == 1)
        #expect(log.fileURL.path.withCString { og_path_is_private_to_current_user($0, 0) } == 1)
        #else
        let attributes = try FileManager.default.attributesOfItem(atPath: log.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #endif

        let other = try SessionEventLogFixture()
        defer { other.cleanup() }
        let target = other.directory.appendingPathComponent("private-target")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: other.directory.appendingPathComponent("events.jsonl"),
            withDestinationURL: target
        )
        #expect(throws: SessionEventLogError.self) {
            try SessionEventLog(sessionDirectory: other.directory)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
    }

    @Test("reopened owner-private event logs append without truncating existing records")
    func reopeningExistingLogPreservesRecords() throws {
        let fixture = try SessionEventLogFixture()
        defer { fixture.cleanup() }

        let first = try SessionEventLog(sessionDirectory: fixture.directory)
        #expect(first.emit(.firstToken))

        let reopened = try SessionEventLog(sessionDirectory: fixture.directory)
        #expect(reopened.emit(.toolStarted(toolName: "read_file")))
        #expect(first.emit(.phaseChanged(.streamingText)))

        let values = try fixture.read()
        #expect(values.compactMap { $0["type"]?.stringValue } == [
            "first_token",
            "tool_started",
            "phase_changed",
        ])

        #if os(Windows)
        #expect(reopened.fileURL.path.withCString { og_file_is_owner_only($0) } == 1)
        #expect(reopened.fileURL.path.withCString { og_path_is_private_to_current_user($0, 0) } == 1)
        #endif
    }

    @Test("concurrent callers append complete independent JSONL records")
    func concurrentRecordsStayIntact() async throws {
        let fixture = try SessionEventLogFixture()
        defer { fixture.cleanup() }
        let log = try SessionEventLog(sessionDirectory: fixture.directory)

        await withTaskGroup(of: Bool.self) { group in
            for index in UInt32(0)..<128 {
                group.addTask { log.emit(.loopStarted(index)) }
            }
            for await succeeded in group {
                #expect(succeeded)
            }
        }

        let values = try fixture.read()
        #expect(values.count == 128)
        #expect(Set(values.compactMap { $0["loop_index"]?.uint64Value }).count == 128)
    }

    @Test("tracker resets first token each round and closes active tools before one terminal")
    func trackerOrderingAndCancellation() async throws {
        let fixture = try SessionEventLogFixture()
        defer { fixture.cleanup() }
        let tracker = SessionEventTracker(
            log: try SessionEventLog(sessionDirectory: fixture.directory),
            initialTurnNumber: 9
        )

        #expect(await tracker.beginTurn(
            sessionID: "tracked",
            modelID: "grok-4.5",
            yoloMode: true,
            conversationMessageCount: 3
        ))
        #expect(await tracker.beginSamplerRound())
        #expect(await tracker.noteToken(phase: .streamingText))
        #expect(await tracker.noteToken(phase: .streamingText))
        #expect(await tracker.toolStarted(name: "bash", callID: "tool-1"))
        #expect(await tracker.toolCompleted(callID: "tool-1", outcome: .success))
        #expect(await tracker.beginSamplerRound())
        #expect(await tracker.noteToken(phase: .streamingReasoning))
        #expect(await tracker.toolStarted(name: "read_file", callID: "tool-2"))
        #expect(await tracker.endTurn(
            outcome: .cancelled,
            cancellationCategory: .midTurnAbort
        ))
        #expect(await tracker.endTurn(outcome: .cancelled) == false)

        let values = try fixture.read()
        let types = values.compactMap { $0["type"]?.stringValue }
        #expect(values.first?["turn_number"]?.uint64Value == 9)
        #expect(types.filter { $0 == "first_token" }.count == 2)
        #expect(types.filter { $0 == "turn_ended" }.count == 1)
        #expect(Array(types.suffix(2)) == ["tool_completed", "turn_ended"])
        #expect(values[values.count - 2]["outcome"] == .string("cancelled"))
        #expect(values.last?["cancellation_category"] == .string("mid_turn_abort"))
        #expect(values.compactMap { $0["loop_index"]?.uint64Value } == [0, 1])
    }

    @Test("oversized events fail open and report exactly one observable diagnostic")
    func boundedFailureReportsOnce() throws {
        let fixture = try SessionEventLogFixture()
        defer { fixture.cleanup() }
        let failures = SessionEventFailureCounter()
        let log = try SessionEventLog(
            sessionDirectory: fixture.directory,
            onFirstFailure: { _ in failures.increment() }
        )
        let event = SessionEventLogEvent.turnStarted(
            sessionID: "session",
            turnNumber: 0,
            modelID: String(repeating: "x", count: 70_000),
            yoloMode: false,
            conversationMessageCount: 0,
            relationship: .primary,
            redirectKind: nil
        )

        #expect(log.emit(event) == false)
        #expect(log.emit(event) == false)
        #expect(failures.value == 1)
        #expect(log.firstFailure != nil)
        #expect(try fixture.read().isEmpty)
    }

    @Test("MCP failures retain optional canonical target and timeout fields")
    func mcpFailureFields() throws {
        let fixture = try SessionEventLogFixture()
        defer { fixture.cleanup() }
        let log = try SessionEventLog(sessionDirectory: fixture.directory)
        #expect(log.emit(.mcpServerFailed(
            serverName: "local-tools",
            transport: "stdio",
            errorType: .timeout,
            errorMessage: "connection timed out",
            durationMilliseconds: 1200,
            target: "stdio",
            timeoutSeconds: 30
        )))

        let value = try #require(fixture.read().first)
        #expect(value["type"] == .string("mcp_server_failed"))
        #expect(value["target"] == .string("stdio"))
        #expect(value["timeout_sec"]?.uint64Value == 30)
    }

    @Test("unsigned event counters stay exact JSON integers through the entire UInt64 range")
    func unsignedWireCountersRemainLossless() throws {
        let fixture = try SessionEventLogFixture()
        defer { fixture.cleanup() }
        let log = try SessionEventLog(sessionDirectory: fixture.directory)

        #expect(log.emit(.turnStarted(
            sessionID: "unsigned-boundary",
            turnNumber: UInt64.max,
            modelID: "grok",
            yoloMode: false,
            conversationMessageCount: 0,
            relationship: .primary,
            redirectKind: nil
        )))
        #expect(log.emit(.toolCompleted(
            toolName: "read_file",
            durationMilliseconds: UInt64.max,
            outcome: .success,
            toolCallID: "boundary",
            source: .shell
        )))

        let values = try fixture.read()
        #expect(values[0]["turn_number"]?.uint64Value == UInt64.max)
        #expect(values[0]["conversation_message_count"]?.uint64Value == 0)
        #expect(values[1]["duration_ms"]?.uint64Value == UInt64.max)

        let wire = try String(
            contentsOf: fixture.directory.appendingPathComponent("events.jsonl"),
            encoding: .utf8
        )
        #expect(wire.contains(#""turn_number":18446744073709551615"#))
        #expect(wire.contains(#""duration_ms":18446744073709551615"#))
        #expect(wire.contains(#""conversation_message_count":0"#))
    }

    #if os(Windows)
    @Test("canonical sessions beyond MAX_PATH durably record the real turn and tool lifecycle")
    func extendedLengthCanonicalSessionRecordsTurnAndToolEvents() async throws {
        let fixture = try SessionEventLogFixture()
        defer { fixture.cleanup() }
        let stateRoot = fixture.directory.appendingPathComponent(
            String(repeating: "s", count: 120),
            isDirectory: true
        )
        let workspace = fixture.directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let sessionID = UUID().uuidString
        let documents = SessionDocumentStore(grokHome: stateRoot)
        let session = try documents.sessionDirectory(sessionID: sessionID, cwd: workspace.path)
        #expect(session.path.utf16.count > 260)
        try documents.save(PersistedSessionState(
            summary: SessionSummary(
                sessionID: SessionID(sessionID),
                cwd: workspace.path,
                currentModelID: "grok-code-fast-1"
            )
        ))
        let directoryMetadata = try #require(WindowsSecurePath.metadata(at: session))
        #expect(directoryMetadata.isDirectory)
        #expect(!directoryMetadata.isReparsePoint)

        let tracker = SessionEventTracker(
            log: try SessionEventLog(
                sessionDirectory: session,
                clock: { Date(timeIntervalSince1970: 0) }
            )
        )
        #expect(await tracker.beginTurn(
            sessionID: sessionID,
            modelID: "grok-code-fast-1",
            yoloMode: false,
            conversationMessageCount: 0
        ))
        #expect(await tracker.beginSamplerRound())
        #expect(await tracker.noteToken(phase: .streamingText))
        #expect(await tracker.toolStarted(name: "read_file", callID: "long-tool-1"))
        #expect(await tracker.toolCompleted(callID: "long-tool-1", outcome: .success))
        #expect(await tracker.endTurn(outcome: .completed))

        let eventFile = session.appendingPathComponent("events.jsonl")
        #expect(eventFile.path.utf16.count > 260)
        let nativeFile = try WindowsSecurePath.extendedLengthPath(eventFile.path)
        #expect(nativeFile.withCString { og_file_is_owner_only($0) } == 1)
        #expect(nativeFile.withCString { og_path_is_private_to_current_user($0, 0) } == 1)
        let bytes = try PathSecurity.readNoFollow(
            eventFile,
            maximumBytes: SessionEventLog.maximumRecordBytes,
            requireOwnerOnly: true
        )
        let values = try bytes.split(separator: 0x0A).map { line in
            try JSONDecoder().decode([String: JSONValue].self, from: Data(line))
        }
        #expect(values.compactMap { $0["type"]?.stringValue } == [
            "turn_started",
            "loop_started",
            "phase_changed",
            "first_token",
            "phase_changed",
            "phase_changed",
            "tool_started",
            "tool_completed",
            "turn_ended",
        ])
        #expect(values.first?["session_id"] == .string(sessionID))
        #expect(values.first?["ts"] == .string("1970-01-01T00:00:00.000Z"))
        #expect(values.first { $0["type"] == .string("tool_completed") }?["tool_call_id"]
            == .string("long-tool-1"))
        #expect(values.last?["outcome"] == .string("completed"))
    }

    @Test("event writers reject a session directory with an inherited broad Windows DACL")
    func broadSessionDirectoryFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-event-log-broad-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let nativeDirectory = try WindowsSecurePath.extendedLengthPath(directory.path)
        let ownerPrivate = nativeDirectory.withCString {
            og_path_is_private_to_current_user($0, 1)
        }
        guard ownerPrivate == 0 else {
            Issue.record("negative Windows session fixture unexpectedly has an owner-only DACL")
            return
        }

        #expect(throws: SessionEventLogError.self) {
            try SessionEventLog(sessionDirectory: directory)
        }
        #expect(try WindowsSecurePath.metadata(
            at: directory.appendingPathComponent("events.jsonl")
        ) == nil)
    }
    #endif
}
