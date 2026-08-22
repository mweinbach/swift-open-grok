import Foundation
import OpenGrokACP
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokTestSupport
import Testing

@testable import OpenGrokACPRuntime
@testable import OpenGrokCLI

private typealias JSONValue = OpenGrokShared.JSONValue

private struct PersistentSessionACPFixture {
    let home: URL
    let firstWorkspace: URL
    let secondWorkspace: URL
    let runtime: ACPAgentRuntime

    static func make() async throws -> Self {
        let manager = FileManager.default
        let home = manager.temporaryDirectory.appendingPathComponent(
            "opengrok-acp-persisted-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(
            at: home,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let first = home.appendingPathComponent("first", isDirectory: true)
        let second = home.appendingPathComponent("second", isDirectory: true)
        try manager.createDirectory(at: first, withIntermediateDirectories: true)
        try manager.createDirectory(at: second, withIntermediateDirectories: true)
        let environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
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
            persistentSessions: LivePersistentSessionACPHandler(openGrokHome: home)
        )
        let runtime = ACPAgentRuntime(extensionRouter: router)
        let initialized = await runtime.handle(.request(
            id: .string("initialize"),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        guard case .response(_, _, nil) = try #require(initialized.first) else {
            throw ACPTransportError.invalidMessage("persisted ACP runtime failed to initialize")
        }
        return Self(
            home: home,
            firstWorkspace: first,
            secondWorkspace: second,
            runtime: runtime
        )
    }

    func seed(
        _ id: String,
        workspace: URL? = nil,
        title: String? = nil,
        age: TimeInterval = 0,
        hiddenSubagent: Bool = false
    ) async throws {
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000 + age)
        var record = LiveConversationRecord.new(
            sessionID: id,
            workingDirectory: workspace ?? firstWorkspace
        )
        record.createdAt = timestamp.addingTimeInterval(-60)
        record.updatedAt = timestamp
        record.items = [.user(title ?? id)]
        record.title = title
        record.currentModelID = "grok-test"
        record.sessionKind = hiddenSubagent ? "subagent" : nil
        try await LiveConversationStore(openGrokHome: home).save(record)
    }

    func call(
        _ method: String,
        params: JSONValue = .object([:])
    ) async throws -> (JSONValue?, AcpError?) {
        let messages = await runtime.handle(.request(
            id: .string(UUID().uuidString),
            method: method,
            params: params
        ))
        guard case .response(_, let result, let error) = try #require(messages.first) else {
            throw ACPTransportError.invalidMessage("persisted ACP method returned no response")
        }
        return (result, error)
    }

    func clean() {
        try? FileManager.default.removeItem(at: home)
    }
}

@Suite("ACP durable session discovery", .serialized)
struct LivePersistentSessionACPParityTests {
    @Test("dormant canonical sessions cross the actual ACP gateway with upstream's merged envelope")
    func dormantSessionsReachACP() async throws {
        let fixture = try await PersistentSessionACPFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("dormant-session", title: "A dormant conversation")

        let (response, error) = try await fixture.call("x.ai/session/list")
        #expect(error == nil)
        let payload = try #require(response?["result"])
        let sessions = try #require(payload["sessions"]?.arrayValue)
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session["sessionId"]?.stringValue == "dormant-session")
        #expect(session["summary"]?.stringValue == "A dormant conversation")
        #expect(session["title"]?.stringValue == "A dormant conversation")
        #expect(session["cwd"]?.stringValue == fixture.firstWorkspace.path)
        #expect(session["source"]?.stringValue == "local")
        #expect(session["modelId"]?.stringValue == "grok-test")
        #expect(session["_meta"]?["x.ai/session"]?["kind"]?.stringValue == "build")
        #expect(session["_meta"]?["x.ai/session"]?["facets"]?["cwd"]?.stringValue
            == fixture.firstWorkspace.path)
        #expect(payload["_meta"]?["x.ai/facets"]?["scope"]?.stringValue == "window")
        #expect(payload["_meta"]?["x.ai/partial"]?["conversations"]?.boolValue == false)
        #expect(payload["nextCursor"] == nil)
    }

    @Test("cwd scopes never leak sibling workspace sessions without explicit relaxation")
    func exactWorkspaceScope() async throws {
        let fixture = try await PersistentSessionACPFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("first-session", workspace: fixture.firstWorkspace)
        try await fixture.seed("other-session", workspace: fixture.secondWorkspace)

        let (response, error) = try await fixture.call(
            "x.ai/session/list",
            params: .object(["cwd": .string(fixture.firstWorkspace.path)])
        )
        #expect(error == nil)
        let sessions = try #require(response?["result"]?["sessions"]?.arrayValue)
        #expect(sessions.compactMap { $0["sessionId"]?.stringValue } == ["first-session"])
        #expect(response?["result"]?["_meta"]?["x.ai/listScope"] == nil)
    }

    @Test("workspace relaxation is opt-in and labels its broader response")
    func workspaceRelaxationIsExplicit() async throws {
        let fixture = try await PersistentSessionACPFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("other-session", workspace: fixture.secondWorkspace)

        let (strict, strictError) = try await fixture.call(
            "x.ai/session/list",
            params: .object(["cwd": .string(fixture.firstWorkspace.path)])
        )
        #expect(strictError == nil)
        #expect(strict?["result"]?["sessions"]?.arrayValue?.isEmpty == true)

        let (relaxed, relaxedError) = try await fixture.call(
            "x.ai/session/list",
            params: .object([
                "cwd": .string(fixture.firstWorkspace.path),
                "allowRelax": .bool(true),
            ])
        )
        #expect(relaxedError == nil)
        #expect(relaxed?["result"]?["sessions"]?[0]?["sessionId"]?.stringValue
            == "other-session")
        #expect(relaxed?["result"]?["_meta"]?["x.ai/listScope"]?.stringValue == "all")
    }

    @Test("query, metadata fallback, and build facets filter durable history")
    func queryAndFacets() async throws {
        let fixture = try await PersistentSessionACPFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("match", title: "Investigate Kubernetes")
        try await fixture.seed("other", title: "Refactor rendering")

        let (matching, matchingError) = try await fixture.call(
            "x.ai/session/list",
            params: .object([
                "_meta": .object([
                    "x.ai/query": .string("KUBERNETES"),
                    "x.ai/limit": .number(.uint64(1)),
                    "x.ai/facetFilters": .object([
                        "kind": .array([.string("build")]),
                    ]),
                ]),
            ])
        )
        #expect(matchingError == nil)
        #expect(matching?["result"]?["sessions"]?[0]?["sessionId"]?.stringValue == "match")

        let (chat, chatError) = try await fixture.call(
            "x.ai/session/list",
            params: .object([
                "_meta": .object([
                    "x.ai/facetFilters": .object(["kind": .string("chat")]),
                ]),
            ])
        )
        #expect(chatError == nil)
        #expect(chat?["result"]?["sessions"]?.arrayValue?.isEmpty == true)
    }

    @Test("opaque Rust-compatible cursors traverse newest-first pages without duplication")
    func newestFirstPagination() async throws {
        let fixture = try await PersistentSessionACPFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("oldest", age: 1)
        try await fixture.seed("middle", age: 2)
        try await fixture.seed("newest", age: 3)

        let (first, firstError) = try await fixture.call(
            "x.ai/session/list",
            params: .object(["limit": .number(.uint64(2))])
        )
        #expect(firstError == nil)
        let firstIDs = try #require(first?["result"]?["sessions"]?.arrayValue)
            .compactMap { $0["sessionId"]?.stringValue }
        #expect(firstIDs == ["newest", "middle"])
        let cursor = try #require(first?["result"]?["nextCursor"]?.stringValue)
        #expect(!cursor.contains("="))

        let (second, secondError) = try await fixture.call(
            "x.ai/session/list",
            params: .object([
                "limit": .number(.uint64(2)),
                "cursor": .string(cursor),
            ])
        )
        #expect(secondError == nil)
        #expect(second?["result"]?["sessions"]?[0]?["sessionId"]?.stringValue == "oldest")
        #expect(second?["result"]?["nextCursor"] == nil)
    }

    @Test("malformed cursors restart at the first page without accessing caller-controlled paths")
    func malformedCursorRestartsSafely() async throws {
        let fixture = try await PersistentSessionACPFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("real-session")

        for cursor in ["not base64 !!!", "../../../private/session", ""] {
            let (result, error) = try await fixture.call(
                "x.ai/session/list",
                params: .object(["cursor": .string(cursor)])
            )
            #expect(error == nil)
            #expect(result?["result"]?["sessions"]?[0]?["sessionId"]?.stringValue
                == "real-session")
        }
    }

    @Test("workspace session summaries use the raw Rust nested-info schema")
    func workspaceSummaryWireShape() async throws {
        let fixture = try await PersistentSessionACPFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("visible", title: "Manually renamed")
        try await fixture.seed("other", workspace: fixture.secondWorkspace)

        let (result, error) = try await fixture.call(
            "x.ai/session_summaries/session_list",
            params: .object(["workspace_directory": .string(fixture.firstWorkspace.path)])
        )
        #expect(error == nil)
        #expect(result?["result"] == nil)
        let rows = try #require(result?["session_summaries"]?.arrayValue)
        #expect(rows.count == 1)
        #expect(rows[0]["info"]?["id"]?.stringValue == "visible")
        #expect(rows[0]["info"]?["cwd"]?.stringValue == fixture.firstWorkspace.path)
        #expect(rows[0]["session_summary"]?.stringValue == "Manually renamed")
        #expect(rows[0]["current_model_id"]?.stringValue == "grok-test")
        #expect(rows[0]["session_id"] == nil)
    }

    @Test("workspace overview groups real persisted summaries by their authoritative cwd")
    func workspaceOverview() async throws {
        let fixture = try await PersistentSessionACPFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("first", workspace: fixture.firstWorkspace)
        try await fixture.seed("second", workspace: fixture.secondWorkspace)

        let (result, error) = try await fixture.call("x.ai/session_summaries/workspace_list")
        #expect(error == nil)
        let all = try #require(result?["all_sessions"]?.objectValue)
        #expect(Set(all.keys) == Set([fixture.firstWorkspace.path, fixture.secondWorkspace.path]))
        #expect(all[fixture.firstWorkspace.path]?[0]?["info"]?["id"]?.stringValue == "first")
        #expect(all[fixture.secondWorkspace.path]?[0]?["info"]?["id"]?.stringValue == "second")
        #expect(result?["result"] == nil)
    }

    @Test("recent workspace summaries are raw, globally sorted, and honor their limit")
    func recentSummaryLimit() async throws {
        let fixture = try await PersistentSessionACPFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("old", age: 1)
        try await fixture.seed("new", workspace: fixture.secondWorkspace, age: 2)

        let (result, error) = try await fixture.call(
            "x.ai/session_summaries/workspace_list_recent",
            params: .object(["limit": .number(.uint64(1))])
        )
        #expect(error == nil)
        let rows = try #require(result?.arrayValue)
        #expect(rows.count == 1)
        #expect(rows[0]["info"]?["id"]?.stringValue == "new")
    }

    @Test("missing fields, relative workspaces, negative limits, and invalid request types fail closed")
    func malformedRequestsFailClosed() async throws {
        let fixture = try await PersistentSessionACPFixture.make()
        defer { fixture.clean() }

        let failures: [(String, JSONValue)] = [
            ("x.ai/session_summaries/session_list", .object([:])),
            (
                "x.ai/session_summaries/session_list",
                .object(["workspace_directory": .string("../../outside")])
            ),
            ("x.ai/session_summaries/workspace_list_recent", .object([:])),
            (
                "x.ai/session_summaries/workspace_list_recent",
                .object(["limit": .number(.int64(-1))])
            ),
            ("x.ai/session/list", .object(["cwd": .string("relative") ])),
            ("x.ai/session/list", .object(["limit": .number(.int64(-1))])),
            ("x.ai/session/list", .array([])),
        ]
        for (method, params) in failures {
            let (_, error) = try await fixture.call(method, params: params)
            #expect(error?.code == .invalidParams, "\(method) accepted \(params)")
        }
    }

    @Test("hidden subagents, corrupt records, and symlinked summaries never leak into ACP")
    func maliciousAndHiddenEntriesStayPrivate() async throws {
        let fixture = try await PersistentSessionACPFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("visible")
        try await fixture.seed("hidden-child", hiddenSubagent: true)
        let sessions = fixture.home.appendingPathComponent("sessions", isDirectory: true)
        let corrupt = sessions.appendingPathComponent("corrupt.json")
        try Data("not a session".utf8).write(to: corrupt)

        let target = sessions.appendingPathComponent("visible.json")
        let symlink = sessions.appendingPathComponent("stolen.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        let (result, error) = try await fixture.call("x.ai/session/list")
        #expect(error == nil)
        let ids = try #require(result?["result"]?["sessions"]?.arrayValue)
            .compactMap { $0["sessionId"]?.stringValue }
        #expect(ids == ["visible"])
    }

    @Test("a symlinked sessions root is rejected instead of exposing another user's history")
    func symlinkedSessionRootRejected() async throws {
        let victim = try await PersistentSessionACPFixture.make()
        defer { victim.clean() }
        try await victim.seed("secret-session")
        let attacker = try await PersistentSessionACPFixture.make()
        defer { attacker.clean() }
        try FileManager.default.createSymbolicLink(
            at: attacker.home.appendingPathComponent("sessions"),
            withDestinationURL: victim.home.appendingPathComponent("sessions")
        )

        let (result, error) = try await attacker.call("x.ai/session/list")
        #expect(result == nil)
        #expect(error?.code == .internalError)
    }

    @Test("separate ACP runtimes enumerate only their own isolated OPENGROK_HOME")
    func independentConnectionsDoNotShareHistory() async throws {
        let first = try await PersistentSessionACPFixture.make()
        defer { first.clean() }
        let second = try await PersistentSessionACPFixture.make()
        defer { second.clean() }
        try await first.seed("first-private")
        try await second.seed("second-private")

        let (firstResult, firstError) = try await first.call("x.ai/session/list")
        let (secondResult, secondError) = try await second.call("x.ai/session/list")
        #expect(firstError == nil)
        #expect(secondError == nil)
        #expect(firstResult?["result"]?["sessions"]?[0]?["sessionId"]?.stringValue
            == "first-private")
        #expect(secondResult?["result"]?["sessions"]?[0]?["sessionId"]?.stringValue
            == "second-private")
    }
}
