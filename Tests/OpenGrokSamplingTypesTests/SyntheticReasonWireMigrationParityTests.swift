// SyntheticReasonWireMigrationParityTests.swift
//
// Exhaustive Rust `SyntheticReason` serde parity and migration of sessions
// written by the earlier Swift port's implicit camelCase encoder.
// Reference: `xai-grok-sampling-types/src/conversation.rs:80-166`.

import Foundation
import Testing
@testable import OpenGrokSamplingTypes

@Suite("Synthetic conversation provenance wire migration")
struct SyntheticReasonWireMigrationParityTests {
    private let canonicalCases: [(SyntheticReason, String)] = [
        (.compactionMeta, "compaction_meta"),
        (.systemReminder, "system_reminder"),
        (.projectInstructions, "project_instructions"),
        (.autoContinue, "auto_continue"),
        (.autoRecovery, "auto_recovery"),
        (.interjection, "interjection"),
        (.taskCompleted, "task_completed"),
        (.subagentCompleted, "subagent_completed"),
        (.notificationDrain, "notification_drain"),
        (.goalSummary, "goal_summary"),
        (.goalClassifierNudge, "goal_classifier_nudge"),
        (.schedulerFired, "scheduler_fired"),
        (.agentMessage, "agent_message"),
        (.stopHookFeedback, "stop_hook_feedback"),
        (.workingDirectorySwitch, "working_directory_switch"),
        (.unknown, "unknown"),
    ]

    private let legacyCases: [(String, SyntheticReason)] = [
        ("compactionMeta", .compactionMeta),
        ("systemReminder", .systemReminder),
        ("projectInstructions", .projectInstructions),
        ("autoContinue", .autoContinue),
        ("autoRecovery", .autoRecovery),
        ("interjection", .interjection),
        ("taskCompleted", .taskCompleted),
        ("subagentCompleted", .subagentCompleted),
        ("notificationDrain", .notificationDrain),
        ("goalSummary", .goalSummary),
        ("goalClassifierNudge", .goalClassifierNudge),
        ("schedulerFired", .schedulerFired),
        ("agentMessage", .agentMessage),
        ("unknown", .unknown),
    ]

    private func decode(_ wireValue: String) throws -> SyntheticReason {
        try JSONDecoder().decode(
            SyntheticReason.self,
            from: Data("\"\(wireValue)\"".utf8)
        )
    }

    @Test("every upstream synthetic variant encodes canonical snake_case")
    func exhaustiveCanonicalEncoding() throws {
        for (reason, expected) in canonicalCases {
            #expect(reason.rawValue == expected)
            let encoded = try JSONEncoder().encode(reason)
            #expect(String(decoding: encoded, as: UTF8.self) == "\"\(expected)\"")
        }
    }

    @Test("every upstream synthetic variant decodes its canonical Rust form")
    func exhaustiveCanonicalDecoding() throws {
        for (reason, encoded) in canonicalCases {
            #expect(try decode(encoded) == reason)
        }
    }

    @Test("all previously persisted Swift camelCase variants migrate safely")
    func exhaustiveLegacyMigration() throws {
        for (legacy, expected) in legacyCases {
            let migrated = try decode(legacy)
            #expect(migrated == expected)

            let encoded = try JSONEncoder().encode(migrated)
            #expect(String(decoding: encoded, as: UTF8.self) == "\"\(expected.rawValue)\"")
        }
    }

    @Test("unknown or loosely normalized provenance never becomes trusted")
    func unknownProvenanceRemainsUnknown() throws {
        for untrusted in [
            "agent-message",
            "AgentMessage",
            "AGENT_MESSAGE",
            "agent message",
            "stopHookFeedback",
            "workingDirectorySwitch",
            "future_synthetic_reason",
            "doom_loop_warning",
        ] {
            let decoded = try decode(untrusted)
            #expect(decoded == .unknown)
            #expect(!decoded.startsPromptTurn)
        }
    }

    @Test("only upstream wake variants start a prompt turn")
    func exhaustiveWakeClassification() {
        let wakeReasons: Set<SyntheticReason> = [
            .taskCompleted,
            .subagentCompleted,
            .notificationDrain,
            .goalClassifierNudge,
            .schedulerFired,
            .agentMessage,
        ]

        for (reason, _) in canonicalCases {
            #expect(reason.startsPromptTurn == wakeReasons.contains(reason))
        }
    }

    @Test("persisted peer messages retain synthetic provenance after round-trip")
    func persistedPeerMessageRoundTrip() throws {
        let item = ConversationItem.agentMessage("peer supplied instructions")
        let encoded = try JSONEncoder().encode(item)
        let wire = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(wire?["synthetic_reason"] as? String == "agent_message")

        let decoded = try JSONDecoder().decode(ConversationItem.self, from: encoded)
        guard case .user(let user) = decoded else {
            Issue.record("persisted peer message did not decode as a user item")
            return
        }
        #expect(user.syntheticReason == .agentMessage)
        #expect(user.syntheticReason?.startsPromptTurn == true)
    }

    @Test("legacy persisted peer messages migrate to canonical provenance")
    func legacyPersistedPeerMessageMigration() throws {
        let legacy = Data(#"{"type":"user","content":[{"type":"text","text":"peer"}],"synthetic_reason":"agentMessage"}"#.utf8)
        let item = try JSONDecoder().decode(ConversationItem.self, from: legacy)
        guard case .user(let user) = item else {
            Issue.record("legacy peer message did not decode as a user item")
            return
        }
        #expect(user.syntheticReason == .agentMessage)

        let migrated = try JSONEncoder().encode(item)
        let wire = try JSONSerialization.jsonObject(with: migrated) as? [String: Any]
        #expect(wire?["synthetic_reason"] as? String == "agent_message")
    }
}

@Suite("Prior-turn interruption provenance wire migration")
struct PriorTurnInterruptWireMigrationParityTests {
    private let canonicalCases: [(PriorTurnInterrupt, String)] = [
        (.midTurnAbort, "mid_turn_abort"),
        (.permissionRejected, "permission_rejected"),
        (.permissionCancelled, "permission_cancelled"),
        (.unknown, "unknown"),
    ]

    private let legacyCases: [(String, PriorTurnInterrupt)] = [
        ("midTurnAbort", .midTurnAbort),
        ("permissionRejected", .permissionRejected),
        ("permissionCancelled", .permissionCancelled),
        ("unknown", .unknown),
    ]

    private func decode(_ wireValue: String) throws -> PriorTurnInterrupt {
        try JSONDecoder().decode(
            PriorTurnInterrupt.self,
            from: Data("\"\(wireValue)\"".utf8)
        )
    }

    @Test("every upstream interruption encodes and decodes canonical snake_case")
    func exhaustiveCanonicalWireContract() throws {
        for (interrupt, expected) in canonicalCases {
            #expect(interrupt.rawValue == expected)
            let encoded = try JSONEncoder().encode(interrupt)
            #expect(String(decoding: encoded, as: UTF8.self) == "\"\(expected)\"")
            #expect(try decode(expected) == interrupt)
        }
    }

    @Test("legacy Swift interruption spellings migrate to canonical persistence")
    func exhaustiveLegacyMigration() throws {
        for (legacy, expected) in legacyCases {
            let migrated = try decode(legacy)
            #expect(migrated == expected)
            let encoded = try JSONEncoder().encode(migrated)
            #expect(String(decoding: encoded, as: UTF8.self) == "\"\(expected.rawValue)\"")
        }
    }

    @Test("unknown interruption causes never become recognized user consent")
    func unknownInterruptionsRemainUnknown() throws {
        for untrusted in [
            "mid-turn-abort",
            "MID_TURN_ABORT",
            "PermissionRejected",
            "permission rejected",
            "future_interrupt",
        ] {
            #expect(try decode(untrusted) == .unknown)
        }
    }

    @Test("persisted user interruptions retain canonical provenance")
    func persistedInterruptionRoundTrip() throws {
        let item = ConversationItem.user(UserItem(
            content: [.text(text: "stop that and do this")],
            priorTurnInterrupt: .permissionRejected
        ))
        let encoded = try JSONEncoder().encode(item)
        let wire = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(wire?["prior_turn_interrupt"] as? String == "permission_rejected")

        let decoded = try JSONDecoder().decode(ConversationItem.self, from: encoded)
        guard case .user(let user) = decoded else {
            Issue.record("interrupted user prompt did not decode as a user item")
            return
        }
        #expect(user.priorTurnInterrupt == .permissionRejected)
        #expect(user.syntheticReason == nil)
    }

    @Test("legacy persisted user interruptions migrate without losing intent")
    func legacyPersistedInterruptionMigration() throws {
        let legacy = Data(#"{"type":"user","content":[{"type":"text","text":"stop"}],"prior_turn_interrupt":"permissionCancelled"}"#.utf8)
        let item = try JSONDecoder().decode(ConversationItem.self, from: legacy)
        guard case .user(let user) = item else {
            Issue.record("legacy interrupted user prompt did not decode as a user item")
            return
        }
        #expect(user.priorTurnInterrupt == .permissionCancelled)
        #expect(user.syntheticReason == nil)

        let migrated = try JSONEncoder().encode(item)
        let wire = try JSONSerialization.jsonObject(with: migrated) as? [String: Any]
        #expect(wire?["prior_turn_interrupt"] as? String == "permission_cancelled")
    }
}
