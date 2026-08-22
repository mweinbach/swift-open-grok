import OpenGrokShared
import Testing
@testable import OpenGrokShellSessionSupport

@Suite("Code Mode notification-scoped replay suppression")
struct CodeModeTransportReplaySecurityTests {
    private func update(
        method: String = "session/update",
        tag: String = "tool_call",
        callID: String,
        title: String = "exec",
        marker: Bool? = nil,
        misplacedMarker: Bool = false
    ) -> SessionUpdate {
        var object: [String: JSONValue] = [
            "sessionUpdate": .string(tag),
            "toolCallId": .string(callID),
            "title": .string(title),
            "rawInput": .object(["source": .string("SECRET_JAVASCRIPT")]),
        ]
        var params: [String: JSONValue] = [:]
        if let marker {
            let metadata: JSONValue = .object(["open-grok/codeModeTransport": .bool(marker)])
            if misplacedMarker {
                object["_meta"] = metadata
            } else {
                params["_meta"] = metadata
            }
        }
        params["update"] = .object(object)
        if method == "_x.ai/session/update" {
            return .xai(.object(params))
        }
        return .acp(.object(params))
    }

    @Test("marked transport bases and outputs disappear while same-name plugin and nested calls remain")
    func exactCallIdentityPreservesPlugins() {
        let projection = SessionTranscriptProjector.project([
            update(callID: "outer-exec", marker: true),
            update(callID: "nested", title: "read_file"),
            update(tag: "tool_call_update", callID: "outer-exec"),
            update(callID: "plugin-exec", title: "exec"),
            update(callID: "outer-wait", title: "wait", marker: true),
            update(callID: "plugin-wait", title: "wait"),
        ])

        #expect(projection.toolMetadata == ["read_file", "exec", "wait"])
        #expect(projection.events == [
            .toolCall(title: "read_file", paths: []),
            .toolCall(title: "exec", paths: []),
            .toolCall(title: "wait", paths: []),
        ])
        #expect(projection.malformedUpdateCount == 0)
    }

    @Test("a marker present only on the terminal update hides the already-persisted base")
    func terminalOnlyMarkerSuppressesEarlierSecret() {
        let projection = SessionTranscriptProjector.project([
            update(callID: "outer-terminal-only"),
            update(callID: "nested", title: "read_file"),
            update(tag: "tool_call_update", callID: "outer-terminal-only", marker: true),
        ])

        #expect(projection.toolMetadata == ["read_file"])
        #expect(projection.events == [.toolCall(title: "read_file", paths: [])])
        #expect(projection.malformedUpdateCount == 0)
    }

    @Test("false markers and markers misplaced on update metadata never hide a plugin")
    func markerMustBeTrueOnNotification() {
        let projection = SessionTranscriptProjector.project([
            update(callID: "false-marker", marker: false),
            update(callID: "misplaced-marker", marker: true, misplacedMarker: true),
        ])

        #expect(projection.toolMetadata == ["exec", "exec"])
        #expect(projection.events.count == 2)
        #expect(projection.malformedUpdateCount == 0)
    }

    @Test("xAI extension notifications cannot authorize hiding an ACP plugin call")
    func providerRailsRemainIsolated() {
        let projection = SessionTranscriptProjector.project([
            update(
                method: "_x.ai/session/update",
                tag: "tool_call_update",
                callID: "same-id",
                marker: true
            ),
            update(callID: "same-id", title: "exec"),
        ])

        #expect(projection.toolMetadata == ["exec"])
        #expect(projection.events == [.toolCall(title: "exec", paths: [])])
        #expect(projection.malformedUpdateCount == 0)
    }

    @Test("a marked non-transport tool cannot suppress a genuine same-ID plugin")
    func baseMarkerRequiresReservedTransportName() {
        let projection = SessionTranscriptProjector.project([
            update(callID: "plugin", title: "read_file", marker: true),
            update(callID: "plugin", title: "exec"),
        ])

        #expect(projection.toolMetadata == ["read_file", "exec"])
        #expect(projection.events.count == 2)
        #expect(projection.malformedUpdateCount == 0)
    }
}
