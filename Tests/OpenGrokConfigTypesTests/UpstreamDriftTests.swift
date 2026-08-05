// UpstreamDriftTests.swift
//
// Golden fixtures for the config-types schema added between pins
// 9739c4a2 and 80dff0a9. Every fixture below is hand-derived from the Rust
// source or its own unit tests at 80dff0a9; each test names its provenance.

import Foundation
import Testing
@testable import OpenGrokConfigTypes
import OpenGrokShared

private func parseRemote(_ json: String) throws -> RemoteSettings {
    try JSONDecoder().decode(RemoteSettings.self, from: Data(json.utf8))
}

private func roundTripRemote(_ s: RemoteSettings) throws -> RemoteSettings {
    try JSONDecoder().decode(RemoteSettings.self, from: JSONEncoder().encode(s))
}

@Suite("ImageGenerationProvider")
struct ImageGenerationProviderTests {
    /// Provenance: `xai-grok-config-types/src/lib.rs:26-48` at 80dff0a9.
    /// The wire form is snake_case with an explicit `openai` rename, so the
    /// enum case name and the wire token deliberately differ.
    @Test("canonical wire tokens and default")
    func canonicalTokens() {
        #expect(ImageGenerationProvider.default == .grok)
        #expect(ImageGenerationProvider.grok.canonical == "grok")
        #expect(ImageGenerationProvider.openAI.canonical == "openai")
    }

    /// `from_canonical` (lib.rs:46) trims and lowercases before matching.
    @Test("fromCanonical trims, lowercases, and rejects unknowns")
    func fromCanonical() {
        #expect(ImageGenerationProvider.fromCanonical("  OpenAI ") == .openAI)
        #expect(ImageGenerationProvider.fromCanonical("GROK") == .grok)
        #expect(ImageGenerationProvider.fromCanonical("dall-e") == nil)
        #expect(ImageGenerationProvider.fromCanonical("") == nil)
    }

    @Test("JSON round trip uses the canonical token")
    func jsonRoundTrip() throws {
        let data = try JSONEncoder().encode(ImageGenerationProvider.openAI)
        #expect(String(data: data, encoding: .utf8) == "\"openai\"")
        let back = try JSONDecoder().decode(ImageGenerationProvider.self, from: data)
        #expect(back == .openAI)
    }
}

@Suite("WorktreeKindMaxAge")
struct WorktreeKindMaxAgeTests {
    /// Provenance: the hand-written Serialize/Deserialize pair at
    /// `lib.rs:64-107`. Deserialize accepts four shapes; Serialize emits only
    /// two, so the wire form is deliberately asymmetric.
    @Test("decodes integer, \"never\", numeric string, and null")
    func decodeShapes() throws {
        func decode(_ json: String) throws -> WorktreeKindMaxAge {
            try JSONDecoder().decode(WorktreeKindMaxAge.self, from: Data(json.utf8))
        }
        #expect(try decode("604800") == .secs(604_800))
        #expect(try decode("\"never\"") == .never)
        #expect(try decode("\"NEVER\"") == .never)  // eq_ignore_ascii_case
        #expect(try decode("\"86400\"") == .secs(86_400))
        #expect(try decode("null") == .never)  // visit_unit
    }

    /// lib.rs:1327-1330: `Never` must serialize as the string `"never"`,
    /// never as null, so a re-read cannot mistake it for an absent key.
    @Test("encodes as bare integer or the string \"never\"")
    func encodeShapes() throws {
        let secs = try JSONEncoder().encode(WorktreeKindMaxAge.secs(120))
        #expect(String(data: secs, encoding: .utf8) == "120")
        let never = try JSONEncoder().encode(WorktreeKindMaxAge.never)
        #expect(String(data: never, encoding: .utf8) == "\"never\"")
    }

    @Test("rejects a non-numeric, non-\"never\" string")
    func rejectsGarbage() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WorktreeKindMaxAge.self, from: Data("\"soon\"".utf8))
        }
    }
}

@Suite("WorktreeAutoGcSettings")
struct WorktreeAutoGcSettingsTests {
    /// Provenance: `worktree_auto_gc_partial_object_and_round_trip`,
    /// lib.rs:1237-1325. The full-object fixture and every expected value are
    /// taken verbatim from that test.
    @Test("full object decodes every knob")
    func fullObject() throws {
        let json = """
        {
            "worktree_auto_gc": {
                "enabled": true,
                "max_age_secs": 604800,
                "min_interval_secs": 21600,
                "dry_run": true,
                "include_orphan_snapshots": false,
                "max_age_by_kind": {
                    "session": 604800,
                    "subagent": 86400,
                    "manual": "never"
                }
            }
        }
        """
        let agc = try #require(parseRemote(json).worktreeAutoGc)
        #expect(agc.enabled == true)
        #expect(agc.maxAgeSecs == 604_800)
        #expect(agc.minIntervalSecs == 21_600)
        #expect(agc.dryRun == true)
        #expect(agc.includeOrphanSnapshots == false)
        #expect(agc.includeRebuild == nil)
        #expect(agc.rebuildMinIntervalSecs == nil)
        #expect(agc.maxAgeByKind == [
            "session": .secs(604_800),
            "subagent": .secs(86_400),
            "manual": .never,
        ])
        #expect(try roundTripRemote(parseRemote(json)).worktreeAutoGc == agc)
    }

    @Test("partial object leaves untouched knobs nil; absent key yields nil")
    func partialAndAbsent() throws {
        let agc = try #require(parseRemote(#"{"worktree_auto_gc":{"enabled":false}}"#).worktreeAutoGc)
        #expect(agc.enabled == false)
        #expect(agc.maxAgeSecs == nil)
        #expect(agc.maxAgeByKind == nil)
        #expect(try parseRemote("{}").worktreeAutoGc == nil)
    }

    /// A wrong-typed field must not take its siblings down with it — the
    /// object stays present and only the bad field drops (lib.rs:1298-1303).
    @Test("wrong-typed field drops to nil without losing the sibling kill-switch")
    func fieldWiseTolerance() throws {
        let json = #"{"worktree_auto_gc":{"enabled":false,"max_age_secs":"nope"}}"#
        let agc = try #require(parseRemote(json).worktreeAutoGc)
        #expect(agc.enabled == false)
        #expect(agc.maxAgeSecs == nil)
    }

    /// Unknown future knobs are ignored rather than failing (lib.rs:1294-1297).
    @Test("unknown nested keys are ignored")
    func unknownKeysIgnored() throws {
        let json = #"{"worktree_auto_gc":{"enabled":true,"future_knob":1}}"#
        #expect(try parseRemote(json).worktreeAutoGc?.enabled == true)
    }

    /// Per-entry tolerance inside the map: a nested-object value is skipped
    /// while its siblings survive; `null` means never (lib.rs:1304-1322).
    @Test("max_age_by_kind skips bad entries and reads null as never")
    func perEntryTolerance() throws {
        let json = """
        {"worktree_auto_gc":{"max_age_by_kind":{
            "subagent": 86400, "session": {"nested": true}, "manual": "never"
        }}}
        """
        let map = try #require(parseRemote(json).worktreeAutoGc?.maxAgeByKind)
        #expect(map["subagent"] == .secs(86_400))
        #expect(map["manual"] == .never)
        #expect(map["session"] == nil)

        let nullNever = #"{"worktree_auto_gc":{"max_age_by_kind":{"manual":null,"pool":172800}}}"#
        let map2 = try #require(parseRemote(nullNever).worktreeAutoGc?.maxAgeByKind)
        #expect(map2["manual"] == .never)
        #expect(map2["pool"] == .secs(172_800))
    }

    /// The whole-value tolerance that motivates the custom deserializer: a
    /// malformed `worktree_auto_gc` must not fail the entire RemoteSettings
    /// parse and take unrelated fields with it (lib.rs:1323-1325).
    @Test("a non-object worktree_auto_gc does not fail the whole parse")
    func nestedBadDoesNotFailParse() throws {
        let s = try parseRemote(#"{"leader_mode":true,"worktree_auto_gc":"not-an-object"}"#)
        #expect(s.leaderMode == true)
        #expect(s.worktreeAutoGc == nil)
    }
}

@Suite("RemoteSettings new keys at pin 80dff0a9")
struct RemoteSettingsNewKeysTests {
    /// Provenance: `remote_settings_workflows_flag_round_trips`, lib.rs:1805.
    @Test("workflows_enabled round trips")
    func workflowsEnabled() throws {
        let s = try parseRemote(#"{"workflows_enabled": true}"#)
        #expect(s.workflowsEnabled == true)
        #expect(try roundTripRemote(s).workflowsEnabled == true)
    }

    /// Provenance: `remote_settings_privacy_notice_rollout_absent_null_true_false`,
    /// lib.rs:1944-1956. `null` and absent are both nil, and `false` must
    /// survive the round trip distinctly from absent.
    @Test("privacy_notice_rollout distinguishes absent, null, true and false")
    func privacyNoticeRollout() throws {
        #expect(try parseRemote("{}").privacyNoticeRollout == nil)
        #expect(try parseRemote(#"{"privacy_notice_rollout": null}"#).privacyNoticeRollout == nil)
        let on = try parseRemote(#"{"privacy_notice_rollout": true}"#)
        #expect(on.privacyNoticeRollout == true)
        #expect(try roundTripRemote(on).privacyNoticeRollout == true)
        let off = try parseRemote(#"{"privacy_notice_rollout": false}"#)
        #expect(off.privacyNoticeRollout == false)
        #expect(try roundTripRemote(off).privacyNoticeRollout == false)
    }

    /// Provenance: `remote_settings_privacy_banner_reshow_days`, lib.rs:1958-1966.
    @Test("privacy_banner_reshow_days round trips")
    func privacyBannerReshowDays() throws {
        #expect(try parseRemote("{}").privacyBannerReshowDays == nil)
        #expect(try parseRemote(#"{"privacy_banner_reshow_days": 30}"#).privacyBannerReshowDays == 30)
        let s = try parseRemote(#"{"privacy_banner_reshow_days": 7}"#)
        #expect(try roundTripRemote(s).privacyBannerReshowDays == 7)
    }

    /// Provenance: field declarations at lib.rs:461-464, 747-749, 1038-1040.
    @Test("scheduler, signature-verification and subagent-depth keys round trip")
    func scalarKeys() throws {
        let json = """
        {"scheduler_background_loops": false,
         "managed_config_signature_verification": false,
         "subagents_max_depth": 3,
         "image_edit_model_override": "grok-imagine-edit"}
        """
        let s = try parseRemote(json)
        #expect(s.schedulerBackgroundLoops == false)
        #expect(s.managedConfigSignatureVerification == false)
        #expect(s.subagentsMaxDepth == 3)
        #expect(s.imageEditModelOverride == "grok-imagine-edit")

        let round = try roundTripRemote(s)
        #expect(round.schedulerBackgroundLoops == false)
        #expect(round.managedConfigSignatureVerification == false)
        #expect(round.subagentsMaxDepth == 3)
        #expect(round.imageEditModelOverride == "grok-imagine-edit")
    }

    /// Provenance: `deserialize_tolerant_slash_command_tags`, lib.rs:419-441.
    @Test("slash_command_tags round trips and tolerates a malformed value")
    func slashCommandTags() throws {
        let s = try parseRemote(#"{"slash_command_tags":{"workflows":"beta","ultracode":"new"}}"#)
        #expect(s.slashCommandTags == ["workflows": "beta", "ultracode": "new"])
        #expect(try roundTripRemote(s).slashCommandTags == s.slashCommandTags)

        let bad = try parseRemote(#"{"leader_mode":true,"slash_command_tags":["a","b"]}"#)
        #expect(bad.leaderMode == true)
        #expect(bad.slashCommandTags == nil)
    }

    /// The new keys must not disturb the existing surface: an old server's
    /// payload still parses and the new fields simply stay nil.
    @Test("a payload with none of the new keys leaves them all nil")
    func oldServerPayload() throws {
        let s = try parseRemote(#"{"leader_mode":true,"telemetry_enabled":false}"#)
        #expect(s.leaderMode == true)
        #expect(s.telemetryEnabled == false)
        #expect(s.workflowsEnabled == nil)
        #expect(s.worktreeAutoGc == nil)
        #expect(s.slashCommandTags == nil)
        #expect(s.schedulerBackgroundLoops == nil)
        #expect(s.managedConfigSignatureVerification == nil)
        #expect(s.privacyNoticeRollout == nil)
        #expect(s.privacyBannerReshowDays == nil)
        #expect(s.subagentsMaxDepth == nil)
        #expect(s.imageEditModelOverride == nil)
    }
}
