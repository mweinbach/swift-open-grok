// RelocationTypes.swift
//
// Types and error models for durable session relocation and transactional authority.
// Port of `crates/codegen/xai-grok-shell/src/session/storage/relocation/` (journal.rs, mod.rs).

import Foundation
import OpenGrokShared

// MARK: - Relocation Phase

/// 7-stage lifecycle phase of a session relocation transaction.
///
/// Authority boundary rule:
/// - Source path is authoritative through `.targetPublished` (and in `.rolledBack`).
/// - Target path becomes authoritative once `.ready` (and in `.sourcePruned`, `.committed`).
public enum RelocationPhase: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case initiated
    case sourceVerified = "source_verified"
    case targetPublished = "target_published"
    case ready
    case sourcePruned = "source_pruned"
    case committed
    case rolledBack = "rolled_back"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "initiated":
            self = .initiated
        case "source_verified", "sourceVerified":
            self = .sourceVerified
        case "target_published", "targetPublished":
            self = .targetPublished
        case "ready":
            self = .ready
        case "source_pruned", "sourcePruned":
            self = .sourcePruned
        case "committed":
            self = .committed
        case "rolled_back", "rolledBack":
            self = .rolledBack
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown relocation phase: \(raw)"
            )
        }
    }

    /// Whether the target directory is authoritative in this phase.
    /// Source is authoritative through `targetPublished`; Target is authoritative from `ready` onward.
    public var hasTargetAuthority: Bool {
        switch self {
        case .ready, .sourcePruned, .committed:
            return true
        case .initiated, .sourceVerified, .targetPublished, .rolledBack:
            return false
        }
    }

    /// Whether the source directory is authoritative in this phase.
    public var hasSourceAuthority: Bool {
        !hasTargetAuthority
    }

    /// Whether this phase represents a terminal (completed or rolled back) transaction.
    public var isTerminal: Bool {
        self == .committed || self == .rolledBack
    }
}

// MARK: - Pending CWD Switch Reminder

/// Reminder staged for exactly-once injection when a relocated session resumes.
public struct PendingCwdSwitchReminder: Codable, Sendable, Equatable, Hashable {
    public var cwdGeneration: UInt64
    public var previousCWD: String
    public var destinationCWD: String
    public var content: String
    public var destinationProjectInstructions: String?

    private enum CodingKeys: String, CodingKey {
        case cwdGeneration = "cwd_generation"
        case previousCWD = "previous_cwd"
        case destinationCWD = "destination_cwd"
        case content
        case destinationProjectInstructions = "destination_project_instructions"
    }

    public init(
        cwdGeneration: UInt64,
        previousCWD: String,
        destinationCWD: String,
        content: String,
        destinationProjectInstructions: String? = nil
    ) {
        self.cwdGeneration = cwdGeneration
        self.previousCWD = previousCWD
        self.destinationCWD = destinationCWD
        self.content = content
        self.destinationProjectInstructions = destinationProjectInstructions
    }
}

// MARK: - Relocation Journal State

/// Persisted transaction journal record for a session relocation.
public struct RelocationJournalState: Codable, Sendable, Equatable {
    public static let currentVersion: UInt8 = 1

    public var version: UInt8
    public var sessionID: String
    public var nonce: String
    public var sourceCWD: String
    public var targetCWD: String
    public var cwdGeneration: UInt64
    public var phase: RelocationPhase
    public var createdAtMS: UInt64
    public var updatedAtMS: UInt64
    public var pendingReminder: PendingCwdSwitchReminder?
    public var extra: [String: JSONValue]

    private enum CodingKeys: String, CodingKey {
        case version
        case sessionID = "session_id"
        case nonce
        case sourceCWD = "source_cwd"
        case targetCWD = "target_cwd"
        case cwdGeneration = "cwd_generation"
        case phase
        case createdAtMS = "created_at_ms"
        case updatedAtMS = "updated_at_ms"
        case pendingReminder = "pending_reminder"
    }

    public init(
        version: UInt8 = currentVersion,
        sessionID: String,
        nonce: String = UUID().uuidString,
        sourceCWD: String,
        targetCWD: String,
        cwdGeneration: UInt64 = 1,
        phase: RelocationPhase = .initiated,
        createdAtMS: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000),
        updatedAtMS: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000),
        pendingReminder: PendingCwdSwitchReminder? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.version = version
        self.sessionID = sessionID
        self.nonce = nonce
        self.sourceCWD = sourceCWD
        self.targetCWD = targetCWD
        self.cwdGeneration = cwdGeneration
        self.phase = phase
        self.createdAtMS = createdAtMS
        self.updatedAtMS = updatedAtMS
        self.pendingReminder = pendingReminder
        self.extra = extra
    }

    private static let knownKeys: Set<String> = Set(
        [
            CodingKeys.version, .sessionID, .nonce, .sourceCWD,
            .targetCWD, .cwdGeneration, .phase, .createdAtMS,
            .updatedAtMS, .pendingReminder,
        ].map(\.rawValue)
    )

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(UInt8.self, forKey: .version) ?? Self.currentVersion
        sessionID = try c.decode(String.self, forKey: .sessionID)
        nonce = try c.decodeIfPresent(String.self, forKey: .nonce) ?? "default-nonce"
        sourceCWD = try c.decode(String.self, forKey: .sourceCWD)
        targetCWD = try c.decode(String.self, forKey: .targetCWD)
        cwdGeneration = try c.decodeIfPresent(UInt64.self, forKey: .cwdGeneration) ?? 1
        phase = try c.decode(RelocationPhase.self, forKey: .phase)
        createdAtMS = try c.decodeIfPresent(UInt64.self, forKey: .createdAtMS) ?? 0
        updatedAtMS = try c.decodeIfPresent(UInt64.self, forKey: .updatedAtMS) ?? 0
        pendingReminder = try c.decodeIfPresent(PendingCwdSwitchReminder.self, forKey: .pendingReminder)
        extra = try UnknownFields.decode(from: decoder, knownKeyStrings: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(nonce, forKey: .nonce)
        try c.encode(sourceCWD, forKey: .sourceCWD)
        try c.encode(targetCWD, forKey: .targetCWD)
        try c.encode(cwdGeneration, forKey: .cwdGeneration)
        try c.encode(phase, forKey: .phase)
        try c.encode(createdAtMS, forKey: .createdAtMS)
        try c.encode(updatedAtMS, forKey: .updatedAtMS)
        try c.encodeIfPresent(pendingReminder, forKey: .pendingReminder)
        if !extra.isEmpty {
            var any = encoder.container(keyedBy: AnyCodingKey.self)
            try UnknownFields.encode(extra, into: &any)
        }
    }
}

// MARK: - Relocation Authority

/// Resolved working-directory authority for a session.
public struct RelocationAuthority: Sendable, Equatable {
    public let sessionID: String
    public let cwd: String
    public let phase: RelocationPhase
    public let sessionDir: URL

    public init(sessionID: String, cwd: String, phase: RelocationPhase, sessionDir: URL) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.phase = phase
        self.sessionDir = sessionDir
    }
}

// MARK: - Recovery Action

/// Recovery action determined by analyzing persisted relocation phase.
public enum RecoveryAction: String, Codable, Sendable, Equatable {
    case rollBackToSource = "roll_back_to_source"
    case commitTarget = "commit_target"
    case verifyCommitted = "verify_committed"
    case verifyRolledBack = "verify_rolled_back"
}

// MARK: - Relocation Errors

/// Errors encountered during session relocation, verification, and recovery.
public enum RelocationError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidComponent(field: String, value: String)
    case invalidCWD(field: String, value: String)
    case leaseBusy(sessionID: String)
    case journalExists(sessionID: String)
    case journalMissing(sessionID: String)
    case invalidPhase(operation: String, actual: RelocationPhase)
    case transactionMismatch(sessionID: String)
    case collision(path: String)
    case inconsistent(String)
    case unsupportedPublication
    case recoveryRequired(phase: RelocationPhase, message: String)
    case rolledBack(reason: String)
    case rollbackFailed(source: String, rollback: String)
    case tornWrite(path: String, message: String)
    case io(operation: String, path: String, message: String)
    case json(path: String, message: String)

    public var description: String {
        switch self {
        case .invalidComponent(let field, let value):
            return "invalid relocation \(field): \"\(value)\""
        case .invalidCWD(let field, let value):
            return "invalid relocation \(field) (must be non-empty absolute path): \"\(value)\""
        case .leaseBusy(let id):
            return "session \(id) already has an active relocation lease"
        case .journalExists(let id):
            return "relocation journal already exists for session \(id)"
        case .journalMissing(let id):
            return "relocation journal is missing for session \(id)"
        case .invalidPhase(let op, let actual):
            return "relocation phase \(actual.rawValue) does not permit \(op)"
        case .transactionMismatch(let id):
            return "relocation transaction identity does not match current journal for session \(id)"
        case .collision(let path):
            return "relocation collision at: \(path)"
        case .inconsistent(let msg):
            return "relocation state is inconsistent: \(msg)"
        case .unsupportedPublication:
            return "atomic no-replace publication is unsupported on this platform or filesystem"
        case .recoveryRequired(let phase, let msg):
            return "relocation requires recovery from phase \(phase.rawValue): \(msg)"
        case .rolledBack(let reason):
            return "relocation failed and was rolled back: \(reason)"
        case .rollbackFailed(let src, let rb):
            return "relocation failed (\(src)) and rollback also failed (\(rb))"
        case .tornWrite(let path, let msg):
            return "torn write detected at \(path): \(msg)"
        case .io(let op, let path, let msg):
            return "I/O error during \(op) at \(path): \(msg)"
        case .json(let path, let msg):
            return "JSON decode/encode error at \(path): \(msg)"
        }
    }
}
