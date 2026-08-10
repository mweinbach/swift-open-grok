import OpenGrokACP
import OpenGrokShared
import Testing

@testable import OpenGrokACPRuntime

private actor RosterActivityCapture {
    private var values: [ACPLeaderRosterActivity] = []

    func record(_ message: ACPMessage) {
        guard case .notification(let method, let params) = message,
              ACPMethodRoute.normalize(method: method, params: params).method
                == ACPLeaderRosterMethods.sessionsChanged,
              let changed = try? params.decode(ACPLeaderRosterChanged.self),
              let activity = changed.upserted.first?.activity
        else { return }
        values.append(activity)
    }

    func activities() -> [ACPLeaderRosterActivity] {
        values
    }
}

@Suite("Leader roster wire protocol")
struct ACPLeaderRosterProtocolTests {
    @Test("entry and delta use upstream field and enum spellings")
    func wireShape() throws {
        let changed = ACPLeaderRosterChanged(
            upserted: [
                ACPLeaderRosterEntry(
                    sessionId: "sess-1",
                    title: "Build",
                    cwd: "/repo",
                    isWorktree: true,
                    modelId: "grok-4",
                    reasoningEffort: "high",
                    yolo: true,
                    activity: .needsInput,
                    resident: true,
                    lastChangeUnixMs: 42,
                    origin: .remote(host: "devbox")
                )
            ],
            removed: ["sess-old"]
        )

        let value = try JSONValue.encode(changed)
        guard case .object(let object) = value,
              case .array(let upserted)? = object["upserted"],
              case .object(let entry) = upserted.first,
              case .object(let origin)? = entry["origin"]
        else {
            Issue.record("leader roster delta did not encode as an object")
            return
        }

        #expect(entry["sessionId"] == .string("sess-1"))
        #expect(entry["isWorktree"] == .bool(true))
        #expect(entry["reasoningEffort"] == .string("high"))
        #expect(entry["activity"] == .string("needs_input"))
        guard case .number(let lastChange)? = entry["lastChangeUnixMs"] else {
            Issue.record("lastChangeUnixMs was not numeric")
            return
        }
        #expect(lastChange.int64Value == 42)
        #expect(origin["kind"] == .string("remote"))
        #expect(origin["host"] == .string("devbox"))
        #expect(object["removed"] == .array([.string("sess-old")]))

        #expect(try value.decode(ACPLeaderRosterChanged.self) == changed)
        #expect(ACPLeaderRosterMethods.sessionsList == "x.ai/sessions/list")
        #expect(ACPLeaderRosterMethods.sessionsChanged == "x.ai/sessions/changed")

        let nilOptionals = try JSONValue.encode(ACPLeaderRosterEntry(
            sessionId: "sess-nil",
            cwd: "/repo",
            isWorktree: false,
            yolo: false,
            activity: .idle,
            resident: true,
            lastChangeUnixMs: 43,
            origin: .local
        ))
        guard case .object(let nilEntry) = nilOptionals else {
            Issue.record("leader roster entry did not encode as an object")
            return
        }
        #expect(nilEntry["title"] == .null)
        #expect(nilEntry["modelId"] == .null)
        #expect(nilEntry["reasoningEffort"] == nil)
    }

    @Test("reverse interaction publishes needs-input then restores idle")
    func reverseInteractionLifecycle() async throws {
        let runtime = ACPAgentRuntime(
            makeSessionId: { "sess-input" },
            rosterTimestampMilliseconds: { 7 }
        )
        _ = await runtime.handle(.request(
            id: .number(1),
            method: AgentMethodNames.initialize,
            params: .object([
                "protocolVersion": .number(.int64(1)),
                "clientCapabilities": .object([:]),
            ])
        ))
        _ = await runtime.handle(.request(
            id: .number(2),
            method: AgentMethodNames.sessionNew,
            params: .object([
                "cwd": .string("/repo"),
                "mcpServers": .array([]),
            ])
        ))
        let capture = RosterActivityCapture()
        await runtime.setRosterNotificationSink { message in
            await capture.record(message)
        }

        await runtime.setReverseSender { message in
            guard case .request(let id, _, _) = message else {
                throw ACPRuntimeError.transport("expected reverse request")
            }
            _ = await runtime.handle(.response(id: id, result: .object([:]), error: nil))
        }

        let response = try await runtime.requestClient(
            method: ClientMethodNames.sessionRequestPermission,
            params: .object(["sessionId": .string("sess-input")])
        )
        #expect(response == .object([:]))
        #expect(await capture.activities() == [.needsInput, .idle])
    }
}
