// ChatFormatVersionTests.swift
//
// Golden fixtures for chat-history format versioning and relocation-record
// preservation at pin 80dff0a9.
//
// Provenance:
//   * `CHAT_FORMAT_VERSION` —
//     `crates/codegen/xai-grok-shell/src/session/persistence.rs:31`
//   * serde default 0 vs constructor default 1 — persistence.rs:905-909, :1027
//   * `ensure_chat_history` —
//     `crates/codegen/xai-grok-shell/src/session/storage/jsonl/mod.rs:103-113`
//   * version-dependent decode order — jsonl/mod.rs:842-853
//   * relocation fields on `Summary` — persistence.rs:858-870

import Foundation
import Testing
@testable import OpenGrokShellSessionSupport
import OpenGrokShared

@Suite("Chat format version")
struct ChatFormatVersionTests {
    @Test("current version matches CHAT_FORMAT_VERSION")
    func currentVersion() {
        #expect(chatFormatVersion == 1)
    }

    /// jsonl/mod.rs:842-853. The version does **not** reject a load: it picks
    /// which shape to attempt first, and either way the other shape is tried
    /// as a fallback, so no line is dropped for a version mismatch.
    @Test("decode order flips at the current version")
    func decodeOrder() {
        #expect(ChatHistoryDecodeOrder.forVersion(0) == .chatRequestMessageFirst)
        #expect(ChatHistoryDecodeOrder.forVersion(1) == .conversationItemFirst)
        // A future version still prefers the newer shape (`>=`, not `==`).
        #expect(ChatHistoryDecodeOrder.forVersion(2) == .conversationItemFirst)
    }

    /// `ensure_chat_history` uses `!=`, so a rebuild happens only at an exact
    /// version match — a future-version summary is skipped too, rather than
    /// rebuilt into the wrong shape.
    @Test("rebuild is gated on exact version equality, not a range")
    func rebuildGate() {
        #expect(!chatHistoryMayBeRebuilt(chatFormatVersion: 0))
        #expect(chatHistoryMayBeRebuilt(chatFormatVersion: 1))
        #expect(!chatHistoryMayBeRebuilt(chatFormatVersion: 2))
    }

    /// The asymmetry is deliberate and easy to get wrong: serde's `#[serde(default)]`
    /// on a `u8` yields 0, so a summary with no version field is legacy-format
    /// by definition — but `Summary::default()` stamps CHAT_FORMAT_VERSION on
    /// newly created sessions.
    @Test("an absent version field decodes as 0 while the constructor defaults to 1")
    func absentVersusConstructedDefault() throws {
        let json = """
        {"session_id":"s1","cwd":"/tmp","session_summary":"",
         "created_at":"2026-01-04T12:00:00Z","updated_at":"2026-01-04T12:00:00Z",
         "num_messages":0,"num_chat_messages":0,"current_model_id":"grok-4.5"}
        """
        let decoded = try WireJSONDecoder.make().decode(SessionSummary.self, from: Data(json.utf8))
        #expect(decoded.chatFormatVersion == 0)
        #expect(decoded.chatHistoryDecodeOrder == .chatRequestMessageFirst)

        let constructed = SessionSummary(sessionID: SessionID("s2"), cwd: "/tmp")
        #expect(constructed.chatFormatVersion == 1)
        #expect(constructed.chatHistoryDecodeOrder == .conversationItemFirst)
    }
}

@Suite("Session summary relocation-record preservation")
struct SessionSummaryRelocationPreservationTests {
    /// A summary written by Rust at pin 80dff0a9 while a working-directory
    /// relocation is in flight. The four `cwd_*` keys plus `previous_cwd` are
    /// the relocation subsystem's on-disk record (persistence.rs:858-870);
    /// this port does not interpret them, so it must at minimum not drop
    /// them. Porting the subsystem itself is out of scope — see
    /// `session/storage/relocation/` in the Rust tree.
    private static let relocationSummaryJSON = """
    {
      "session_id" : "sess-1",
      "cwd" : "/Users/dev/project-new",
      "session_summary" : "porting the data layer",
      "created_at" : "2026-01-04T12:00:00Z",
      "updated_at" : "2026-01-04T13:30:00Z",
      "num_messages" : 42,
      "num_chat_messages" : 40,
      "current_model_id" : "grok-4.5",
      "next_trace_turn" : 7,
      "chat_format_version" : 1,
      "ever_used_codex" : false,
      "session_kind" : "fork",
      "cwd_generation" : 3,
      "previous_cwd" : "/Users/dev/project-old",
      "cwd_switch_bookkeeping_generation" : 2,
      "pending_cwd_switch_reminder" : {
        "generation" : 3,
        "from" : "/Users/dev/project-old",
        "to" : "/Users/dev/project-new"
      },
      "source_workspace_dir" : "/Users/dev/project-old",
      "git_root_dir" : "/Users/dev/project-new"
    }
    """

    @Test("modelled fields decode with their Rust values")
    func modelledFields() throws {
        let s = try WireJSONDecoder.make().decode(
            SessionSummary.self, from: Data(Self.relocationSummaryJSON.utf8))
        #expect(s.sessionID.rawValue == "sess-1")
        #expect(s.cwd == "/Users/dev/project-new")
        #expect(s.messageCount == 42)
        #expect(s.chatMessageCount == 40)
        #expect(s.nextTraceTurn == 7)
        #expect(s.chatFormatVersion == 1)
        #expect(s.sessionKind == "fork")
    }

    /// The relocation record must land in `extra` rather than being discarded.
    @Test("relocation keys are captured as unknown fields")
    func relocationKeysCaptured() throws {
        let s = try WireJSONDecoder.make().decode(
            SessionSummary.self, from: Data(Self.relocationSummaryJSON.utf8))
        #expect(s.extra["cwd_generation"]?.doubleValue == 3)
        #expect(s.extra["previous_cwd"] == .string("/Users/dev/project-old"))
        #expect(s.extra["cwd_switch_bookkeeping_generation"]?.doubleValue == 2)
        #expect(s.extra["pending_cwd_switch_reminder"] != nil)
        #expect(s.extra["source_workspace_dir"] == .string("/Users/dev/project-old"))
        #expect(s.extra["git_root_dir"] == .string("/Users/dev/project-new"))
    }

    /// The property that makes a mixed Rust/Swift session directory safe:
    /// loading and re-saving a session mid-relocation must not corrupt or
    /// drop the record. Without the unknown-field bag this loses six keys and
    /// the relocation cannot complete.
    @Test("a relocation record survives a decode/encode round trip intact")
    func roundTripPreservesRelocation() throws {
        let original = try JSONSerialization.jsonObject(
            with: Data(Self.relocationSummaryJSON.utf8)) as! [String: Any]

        let s = try WireJSONDecoder.make().decode(
            SessionSummary.self, from: Data(Self.relocationSummaryJSON.utf8))
        let reencoded = try WireJSONEncoder.makeSorted().encode(s)
        let round = try JSONSerialization.jsonObject(with: reencoded) as! [String: Any]

        for key in original.keys {
            #expect(round[key] != nil, "round trip dropped \(key)")
        }
        #expect(round["cwd_generation"] as? Int == 3)
        #expect(round["previous_cwd"] as? String == "/Users/dev/project-old")
        let reminder = try #require(round["pending_cwd_switch_reminder"] as? [String: Any])
        #expect(reminder["generation"] as? Int == 3)
        #expect(reminder["to"] as? String == "/Users/dev/project-new")

        // And the decoded form is stable across a second pass.
        let again = try WireJSONDecoder.make().decode(SessionSummary.self, from: reencoded)
        #expect(again == s)
    }

    /// A summary with no unknown keys must not gain an empty `extra` object
    /// or otherwise change shape.
    @Test("a summary with no unknown keys encodes without an extra bag")
    func noExtraWhenNothingUnknown() throws {
        let s = SessionSummary(sessionID: SessionID("s3"), cwd: "/tmp", currentModelID: "grok-4.5")
        #expect(s.extra.isEmpty)
        let data = try WireJSONEncoder.makeSorted().encode(s)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["extra"] == nil)
        #expect(obj["chat_format_version"] as? Int == 1)
    }
}
