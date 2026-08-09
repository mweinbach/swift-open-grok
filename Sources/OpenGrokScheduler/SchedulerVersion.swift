// SchedulerVersion.swift
//
// Open Grok — Swift port of the `SchedulerVersion` VALUE from
// `xai-grok-tools/src/implementations/grok_build/scheduler/types.rs:5-32`:
// a `{generation: UUIDv7, revision: u64}` pair identifying one scheduler
// state transition.
//
// Deliberately NOT ported (recorded): `SchedulerClock`, `SchedulerReservation`,
// and the generation-rollover machinery (`types.rs:34-156`). Upstream uses
// them to stamp every `ScheduledTaskCreated`/`Fired`/`Removed` notification
// with a monotone version so a cross-process pager can order replayed events;
// this port is one process with no notification bridge, so nothing consumes a
// live version stream. The VALUE is ported because the occurrence journal
// persists versions inside `resources_state.json` and validates their shape on
// load — a file written by upstream must decode here byte-for-byte.

import Foundation

/// One scheduler transition version: `{generation, revision}` with
/// `#[serde(rename_all = "camelCase")]` (`types.rs:5-10`) — the JSON keys are
/// already camelCase and the generation is a hyphenated UUID string.
public struct SchedulerVersion: Hashable, Sendable, Codable {
    public var generation: UUID
    public var revision: UInt64

    public init(generation: UUID, revision: UInt64) {
        self.generation = generation
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case generation, revision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .generation)
        guard let uuid = UUID(uuidString: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .generation, in: c,
                debugDescription: "not a UUID: \(raw)"
            )
        }
        generation = uuid
        revision = try c.decode(UInt64.self, forKey: .revision)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // The uuid crate serializes lowercase hyphenated; Foundation's
        // `uuidString` is uppercase, so lowercase explicitly for byte parity.
        try c.encode(generation.uuidString.lowercased(), forKey: .generation)
        try c.encode(revision, forKey: .revision)
    }
}

extension UUID {
    /// Whether this is an RFC 9562 UUIDv7 with the RFC 4122 variant — the
    /// identity check the journal runs on decode (`occurrence_journal.rs:
    /// 31-40, 55-58`): version nibble 7 AND variant bits `10`.
    var isRFC9562V7: Bool {
        uuid.6 >> 4 == 7 && uuid.8 & 0xC0 == 0x80
    }

    /// Generate a UUIDv7 whose 48-bit timestamp comes from the injected
    /// clock — the port of `Uuid::now_v7()` (`occurrence_journal.rs:22`)
    /// with the process-clock read replaced by the caller's `now`, keeping
    /// the library deterministic up to the random tail.
    static func v7(now: Date) -> UUID {
        let ms = UInt64(max(0, now.timeIntervalSince1970 * 1000)) & 0xFFFF_FFFF_FFFF
        var bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        bytes[0] = UInt8(truncatingIfNeeded: ms >> 40)
        bytes[1] = UInt8(truncatingIfNeeded: ms >> 32)
        bytes[2] = UInt8(truncatingIfNeeded: ms >> 24)
        bytes[3] = UInt8(truncatingIfNeeded: ms >> 16)
        bytes[4] = UInt8(truncatingIfNeeded: ms >> 8)
        bytes[5] = UInt8(truncatingIfNeeded: ms)
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
