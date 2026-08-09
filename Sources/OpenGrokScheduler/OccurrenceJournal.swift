// OccurrenceJournal.swift
//
// Open Grok — Swift port of `xai-grok-tools/src/implementations/grok_build/
// scheduler/occurrence_journal.rs` (whole file): persisted one-shot removal
// receipts and restart reconciliation.
//
// A receipt records task absence and exact fire/removal versions in one JSON
// resources snapshot. Recovery is a pure plan: `reconcileOneShotOccurrences`
// reports removals requiring persistence and timer suppression while all
// state mutation/publication remains the runtime layer's job.
//
// Upstream honesty note, load-bearing for parity: at the pinned commit every
// journal CONSUMER carries `#[expect(dead_code, reason = "wired by durable
// one-shot actor layer")]` (`occurrence_journal.rs:155-158, 305-359,
// 363-366, 428-431, 445-448`) — the actor layer that would call prepare/
// finish/reconcile does not exist upstream either. This port matches that
// exactly: the journal is written, preserved, and validated through
// `SchedulerState`'s persistence round trip, and NOTHING reads it at
// runtime. Inventing a reader here would be divergence, not completeness
// (AGENTS.md §4).

import Foundation

/// `MAX_PENDING_ONE_SHOTS` (`occurrence_journal.rs:12`) — public because the
/// journal-full arm is part of the persisted-format contract its tests pin.
public let maxPendingOneShots = 50

/// `MAX_QUARANTINED_TASK_IDS` / `MAX_TASK_ID_BYTES`
/// (`occurrence_journal.rs:13-14`).
private let maxQuarantinedTaskIds = 50
private let maxTaskIdBytes = 256

// MARK: - Errors

/// Port of `OccurrenceJournalError` (`occurrence_journal.rs:259-284`),
/// display strings byte-for-byte — they surface through decode-quarantine
/// diagnostics and would be model/user-visible via any future recovery
/// surface.
public enum OccurrenceJournalError: Error, Equatable, Sendable {
    case taskNotFound(String)
    case notDurableOneShot(String)
    case taskAlreadyJournaled(String)
    case journalFull
    case invalidVersions
    case duplicateTransitionVersion
    case recoveryRequired
    case occurrenceNotFound
}

extension OccurrenceJournalError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .taskNotFound(let id):
            return "scheduled task \(id) was not found"
        case .notDurableOneShot(let id):
            return "scheduled task \(id) is not a durable one-shot"
        case .taskAlreadyJournaled(let id):
            return "scheduled task \(id) already has a pending occurrence"
        case .journalFull:
            return "maximum of \(maxPendingOneShots) pending one-shot occurrences reached"
        case .invalidVersions:
            return "one-shot fire/removal versions must be nonzero consecutive RFC UUIDv7 transitions"
        case .duplicateTransitionVersion:
            return "scheduler transition version is already journaled"
        case .recoveryRequired:
            return "one-shot journal requires manual recovery before new occurrences can be prepared"
        case .occurrenceNotFound:
            return "scheduled occurrence was not found"
        }
    }
}

// MARK: - Identity

/// `ScheduledOccurrenceId` (`occurrence_journal.rs:16-41`): serialized
/// transparently as a UUID string; DECODE validates RFC UUIDv7 identity.
/// Construction is unvalidated, like upstream's crate-private tuple
/// construction — the validation seam is the persistence boundary, where a
/// foreign file's claims get checked.
public struct ScheduledOccurrenceId: Hashable, Sendable, Codable {
    public let uuid: UUID

    public init(_ uuid: UUID) {
        self.uuid = uuid
    }

    /// `ScheduledOccurrenceId::new()` (`occurrence_journal.rs:21-23`) with
    /// the clock injected.
    public init(now: Date) {
        self.uuid = UUID.v7(now: now)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        guard let id = UUID(uuidString: raw), id.isRFC9562V7 else {
            throw DecodingError.dataCorruptedError(
                in: c,
                debugDescription: "scheduled occurrence identity must be an RFC UUIDv7"
            )
        }
        self.uuid = id
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(uuid.uuidString.lowercased())
    }
}

// MARK: - Versions

/// `ScheduledOccurrenceVersions` (`occurrence_journal.rs:43-98`): the fire
/// and removal transition versions of one journaled occurrence. The throwing
/// initializer is `try_new` — a nonzero fire revision, matching UUIDv7
/// generations, and `removal == fire + 1` without overflow.
public struct ScheduledOccurrenceVersions: Hashable, Sendable, Codable {
    public let fire: SchedulerVersion
    public let removal: SchedulerVersion

    /// `try_new` (`occurrence_journal.rs:51-68`).
    public init(fire: SchedulerVersion, removal: SchedulerVersion) throws {
        let generation = fire.generation
        if !generation.isRFC9562V7
            || fire.revision == 0
            || removal.generation != generation
            || fire.revision == UInt64.max
            || removal.revision != fire.revision + 1 {
            throw OccurrenceJournalError.invalidVersions
        }
        self.fire = fire
        self.removal = removal
    }

    func contains(_ version: SchedulerVersion) -> Bool {
        fire == version || removal == version
    }

    private enum CodingKeys: String, CodingKey {
        case fire, removal
    }

    /// Decode re-runs `try_new` (`occurrence_journal.rs:83-98`), so a file
    /// cannot smuggle in versions the constructor would refuse.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fire = try c.decode(SchedulerVersion.self, forKey: .fire)
        let removal = try c.decode(SchedulerVersion.self, forKey: .removal)
        do {
            try self.init(fire: fire, removal: removal)
        } catch let error as OccurrenceJournalError {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: c.codingPath,
                debugDescription: error.description
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fire, forKey: .fire)
        try c.encode(removal, forKey: .removal)
    }
}

// MARK: - Occurrence

/// `OneShotOccurrence` (`occurrence_journal.rs:100-133`). Decode rejects any
/// occurrence whose task is not a durable one-shot — a recurring or
/// ephemeral task in the journal is a corrupt receipt, not data.
public struct OneShotOccurrence: Equatable, Sendable, Codable {
    public let occurrenceId: ScheduledOccurrenceId
    public let task: ScheduledTask
    public let versions: ScheduledOccurrenceVersions

    init(occurrenceId: ScheduledOccurrenceId, task: ScheduledTask, versions: ScheduledOccurrenceVersions) {
        self.occurrenceId = occurrenceId
        self.task = task
        self.versions = versions
    }

    private enum CodingKeys: String, CodingKey {
        case occurrenceId, task, versions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let occurrenceId = try c.decode(ScheduledOccurrenceId.self, forKey: .occurrenceId)
        let task = try c.decode(ScheduledTask.self, forKey: .task)
        let versions = try c.decode(ScheduledOccurrenceVersions.self, forKey: .versions)
        if task.recurring || !task.durable {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: c.codingPath,
                debugDescription: OccurrenceJournalError.notDurableOneShot(task.id).description
            ))
        }
        self.occurrenceId = occurrenceId
        self.task = task
        self.versions = versions
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(occurrenceId, forKey: .occurrenceId)
        try c.encode(task, forKey: .task)
        try c.encode(versions, forKey: .versions)
    }
}

// MARK: - Journal

/// `OccurrenceJournal` (`occurrence_journal.rs:135-239`). Decoding is TOTAL:
/// any JSON shape produces a journal, with malformation expressed as
/// quarantine metadata (`blockAllOneShots` / `quarantinedTaskIds` /
/// `overflowed`) instead of a decode error — a corrupt receipt must suppress
/// one-shots, never crash the load (`decode_json`,
/// `occurrence_journal.rs:179-226`).
public struct OccurrenceJournal: Equatable, Sendable, Codable {
    public internal(set) var entries: [OneShotOccurrence] = []
    public internal(set) var quarantinedTaskIds: [String] = []
    public internal(set) var blockAllOneShots = false
    public internal(set) var overflowed = false

    public init() {}

    /// `is_empty` (`occurrence_journal.rs:148-153`) — the
    /// `skip_serializing_if` gate on `SchedulerState.occurrenceJournal`.
    public var isEmpty: Bool {
        entries.isEmpty && quarantinedTaskIds.isEmpty && !blockAllOneShots && !overflowed
    }

    /// `quarantine_diagnostics` (`occurrence_journal.rs:159-165`).
    public func quarantineDiagnostics() -> (taskIds: [String], blockAll: Bool, overflowed: Bool) {
        (quarantinedTaskIds, blockAllOneShots, overflowed)
    }

    // MARK: Lenient decode

    /// `decode_json` (`occurrence_journal.rs:180-226`): a bare array is the
    /// legacy entries-only form; an object reads the four current keys with
    /// per-key malformation flags; anything else is a global block. Entries
    /// past the 50 cap flip `overflowed`; an undecodable entry quarantines
    /// its task id when one can be salvaged and blocks everything otherwise.
    static func decodeLenient(_ value: JournalJSON) -> OccurrenceJournal {
        let entryValues: [JournalJSON]
        let taskIds: [String]
        let blockAll: Bool
        let overflowedFlag: Bool
        let isMalformed: Bool
        switch value {
        case .array(let values):
            entryValues = values
            taskIds = []
            blockAll = false
            overflowedFlag = false
            isMalformed = false
        case .object(let object):
            let (entries, badEntries) = parseArray(object["entries"])
            let (taskValues, badTaskIds) = parseArray(object["quarantinedTaskIds"])
            let badTaskElement = taskValues.contains { value in
                if case .string = value { return false }
                return true
            }
            let ids: [String] = taskValues.compactMap { value in
                if case .string(let s) = value { return s }
                return nil
            }
            let (block, badBlock) = parseBool(object["blockAllOneShots"])
            let (over, badOverflow) = parseBool(object["overflowed"])
            entryValues = entries
            taskIds = ids
            blockAll = block
            overflowedFlag = over
            isMalformed = badEntries || badTaskIds || badTaskElement || badBlock || badOverflow
        default:
            entryValues = []
            taskIds = []
            blockAll = true
            overflowedFlag = false
            isMalformed = true
        }

        var journal = OccurrenceJournal()
        journal.blockAllOneShots = blockAll || overflowedFlag || isMalformed
        journal.overflowed = overflowedFlag
        for taskId in taskIds {
            journal.quarantineTaskId(taskId)
        }
        if entryValues.count > maxPendingOneShots {
            journal.blockAllOneShots = true
            journal.overflowed = true
        }
        for value in entryValues.prefix(maxPendingOneShots) {
            if let data = try? value.encodedFragment(),
               let occurrence = try? JSONDecoder().decode(OneShotOccurrence.self, from: data) {
                journal.entries.append(occurrence)
            } else if let taskId = Self.quarantinedTaskId(value) {
                journal.quarantineTaskId(taskId)
            } else {
                journal.blockAllOneShots = true
            }
        }
        return journal
    }

    /// `quarantine_task_id` (`occurrence_journal.rs:228-238`): empty or
    /// oversized ids and quarantine overflow all degrade to the global block.
    mutating func quarantineTaskId(_ taskId: String) {
        if taskId.isEmpty || taskId.utf8.count > maxTaskIdBytes {
            blockAllOneShots = true
        } else if !quarantinedTaskIds.contains(taskId) {
            if quarantinedTaskIds.count == maxQuarantinedTaskIds {
                blockAllOneShots = true
            } else {
                quarantinedTaskIds.append(taskId)
            }
        }
    }

    /// `quarantined_task_id` (`occurrence_journal.rs:255-257`):
    /// `value["task"]["id"]` as a string, if the shape allows.
    private static func quarantinedTaskId(_ value: JournalJSON) -> String? {
        guard case .object(let object) = value,
              case .object(let task)? = object["task"],
              case .string(let id)? = task["id"]
        else { return nil }
        return id
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case entries, quarantinedTaskIds, blockAllOneShots, overflowed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = (try? c.decode(JournalJSON.self)) ?? .null
        self = Self.decodeLenient(raw)
    }

    /// Serde skips: `quarantinedTaskIds` when empty, the two flags when
    /// false (`occurrence_journal.rs:135-145`); `entries` always emits.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entries, forKey: .entries)
        if !quarantinedTaskIds.isEmpty {
            try c.encode(quarantinedTaskIds, forKey: .quarantinedTaskIds)
        }
        if blockAllOneShots {
            try c.encode(true, forKey: .blockAllOneShots)
        }
        if overflowed {
            try c.encode(true, forKey: .overflowed)
        }
    }
}

/// `parse_json_array` (`occurrence_journal.rs:241-246`): absent is fine,
/// non-array is malformed.
private func parseArray(_ value: JournalJSON?) -> ([JournalJSON], Bool) {
    guard let value else { return ([], false) }
    if case .array(let values) = value { return (values, false) }
    return ([], true)
}

/// `parse_json_bool` (`occurrence_journal.rs:248-253`): absent is false,
/// non-bool is malformed AND reads as true — malformation must fail toward
/// suppression, not permission.
private func parseBool(_ value: JournalJSON?) -> (Bool, Bool) {
    guard let value else { return (false, false) }
    if case .bool(let flag) = value { return (flag, false) }
    return (true, true)
}

// MARK: - Reconciliation

/// `OneShotJournalConflict` (`occurrence_journal.rs:286-291`).
public enum OneShotJournalConflict: Equatable, Sendable {
    case occurrenceId
    case taskId
    case transitionVersion
}

/// `SchedulerLoadReconciliation` (`occurrence_journal.rs:293-360`): the pure
/// recovery plan a durable one-shot actor layer would execute. Upstream marks
/// it `#[must_use = "loaded one-shot receipts must suppress timers and
/// reconcile resources"]`; Swift's unused-result warning carries the same
/// intent for the producing call.
public struct SchedulerLoadReconciliation: Sendable {
    public let requiresResourcesPersistence: Bool
    public let taskIdsToRemove: [String]
    public let blockedTaskIds: Set<String>
    public let blockAllOneShots: Bool
    public let recoveryRequired: Bool
    public let conflicts: [OneShotJournalConflict]
    public let overflowError: OccurrenceJournalError?
}

extension SchedulerState {
    /// `prepare_one_shot_occurrence` (`occurrence_journal.rs:367-373`) with
    /// the clock injected for the generated UUIDv7 identity.
    public mutating func prepareOneShotOccurrence(
        taskID: String,
        versions: ScheduledOccurrenceVersions,
        now: Date
    ) throws -> OneShotOccurrence {
        try prepareOneShotOccurrence(
            occurrenceID: ScheduledOccurrenceId(now: now),
            taskID: taskID,
            versions: versions
        )
    }

    /// `prepare_one_shot_occurrence_with_id` (`occurrence_journal.rs:
    /// 375-425`). Check order is the contract: recovery gate → capacity →
    /// duplicate task → duplicate version → task lookup → durability — and
    /// every failure leaves `tasks` and the journal untouched.
    public mutating func prepareOneShotOccurrence(
        occurrenceID: ScheduledOccurrenceId,
        taskID: String,
        versions: ScheduledOccurrenceVersions
    ) throws -> OneShotOccurrence {
        if !occurrenceJournal.quarantinedTaskIds.isEmpty
            || occurrenceJournal.blockAllOneShots
            || occurrenceJournal.overflowed
            || Self.hasConflict(occurrenceJournal.entries) {
            throw OccurrenceJournalError.recoveryRequired
        }
        if occurrenceJournal.entries.count >= maxPendingOneShots {
            throw OccurrenceJournalError.journalFull
        }
        if occurrenceJournal.entries.contains(where: { $0.task.id == taskID }) {
            throw OccurrenceJournalError.taskAlreadyJournaled(taskID)
        }
        if occurrenceJournal.entries.contains(where: {
            $0.versions.contains(versions.fire) || $0.versions.contains(versions.removal)
        }) {
            throw OccurrenceJournalError.duplicateTransitionVersion
        }
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            throw OccurrenceJournalError.taskNotFound(taskID)
        }
        if tasks[index].recurring || !tasks[index].durable {
            throw OccurrenceJournalError.notDurableOneShot(taskID)
        }

        let occurrence = OneShotOccurrence(
            occurrenceId: occurrenceID,
            task: tasks.remove(at: index),
            versions: versions
        )
        occurrenceJournal.entries.append(occurrence)
        return occurrence
    }

    /// `finish_one_shot_removal` (`occurrence_journal.rs:432-443`). Upstream
    /// tags the return `#[must_use = "the exact removal receipt must be
    /// durably cleared"]`.
    public mutating func finishOneShotRemoval(
        occurrenceID: ScheduledOccurrenceId
    ) throws -> OneShotOccurrence {
        guard let index = occurrenceJournal.entries.firstIndex(where: {
            $0.occurrenceId == occurrenceID
        }) else {
            throw OccurrenceJournalError.occurrenceNotFound
        }
        return occurrenceJournal.entries.remove(at: index)
    }

    /// `reconcile_one_shot_occurrences` (`occurrence_journal.rs:449-534`):
    /// pure — reads state, mutates nothing, reports the plan.
    public func reconcileOneShotOccurrences() -> SchedulerLoadReconciliation {
        var occurrenceCounts: [ScheduledOccurrenceId: Int] = [:]
        var taskCounts: [String: Int] = [:]
        var versionCounts: [SchedulerVersion: Int] = [:]
        for occurrence in occurrenceJournal.entries {
            occurrenceCounts[occurrence.occurrenceId, default: 0] += 1
            taskCounts[occurrence.task.id, default: 0] += 1
            for version in [occurrence.versions.fire, occurrence.versions.removal] {
                versionCounts[version, default: 0] += 1
            }
        }
        func conflictFor(_ occurrence: OneShotOccurrence) -> OneShotJournalConflict? {
            if occurrenceCounts[occurrence.occurrenceId, default: 0] > 1 {
                return .occurrenceId
            } else if taskCounts[occurrence.task.id, default: 0] > 1 {
                return .taskId
            } else if versionCounts[occurrence.versions.fire, default: 0] > 1
                || versionCounts[occurrence.versions.removal, default: 0] > 1 {
                return .transitionVersion
            }
            return nil
        }

        var blockedTaskIds = Set(occurrenceJournal.quarantinedTaskIds)
        let blockAllOneShots = occurrenceJournal.blockAllOneShots
        let overflowed = occurrenceJournal.overflowed
        let conflicts = occurrenceJournal.entries.compactMap(conflictFor)
        let recoveryRequired = blockAllOneShots
            || overflowed
            || !occurrenceJournal.quarantinedTaskIds.isEmpty
            || !conflicts.isEmpty
        blockedTaskIds.formUnion(occurrenceJournal.entries.map { $0.task.id })
        if blockAllOneShots {
            blockedTaskIds.formUnion(tasks.filter { !$0.recurring }.map { $0.id })
        }

        let taskIdsToRemove: [String]
        if recoveryRequired {
            taskIdsToRemove = []
        } else {
            let journaled = Set(occurrenceJournal.entries.map { $0.task.id })
            taskIdsToRemove = tasks.filter { journaled.contains($0.id) }.map { $0.id }
        }

        return SchedulerLoadReconciliation(
            requiresResourcesPersistence: !taskIdsToRemove.isEmpty,
            taskIdsToRemove: taskIdsToRemove,
            blockedTaskIds: blockedTaskIds,
            blockAllOneShots: blockAllOneShots,
            recoveryRequired: recoveryRequired,
            conflicts: conflicts,
            overflowError: overflowed ? OccurrenceJournalError.journalFull : nil
        )
    }

    /// `has_conflict` (`occurrence_journal.rs:537-547`).
    static func hasConflict(_ entries: [OneShotOccurrence]) -> Bool {
        let occurrenceIds = Set(entries.map { $0.occurrenceId })
        let taskIds = Set(entries.map { $0.task.id })
        let versions = Set(entries.flatMap { [$0.versions.fire, $0.versions.removal] })
        return occurrenceIds.count != entries.count
            || taskIds.count != entries.count
            || versions.count != entries.count * 2
    }
}

// MARK: - Minimal JSON value

/// The `serde_json::Value` stand-in the lenient journal decode needs.
/// Integers keep 64-bit precision through dedicated cases — a `u64` revision
/// above 2^53 must not round-trip through `Double` and come back corrupt.
enum JournalJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case uint(UInt64)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JournalJSON])
    case object([String: JournalJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let value = try? c.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? c.decode(UInt64.self) {
            self = .uint(value)
        } else if let value = try? c.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? c.decode(Double.self) {
            self = .double(value)
        } else if let value = try? c.decode(String.self) {
            self = .string(value)
        } else if let value = try? c.decode([JournalJSON].self) {
            self = .array(value)
        } else {
            self = .object(try c.decode([String: JournalJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .uint(let value): try c.encode(value)
        case .int(let value): try c.encode(value)
        case .double(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }

    /// Re-encode one journal entry so `OneShotOccurrence`'s strict decoder
    /// can rule on it — the port of `serde_json::from_value(value.clone())`
    /// (`occurrence_journal.rs:217`).
    func encodedFragment() throws -> Data {
        try JSONEncoder().encode(self)
    }
}
