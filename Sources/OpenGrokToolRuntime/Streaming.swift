// Streaming.swift
//
// Open Grok — Swift port of `xai-tool-runtime/src/streaming.rs`.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol

/// Per-frame `delta` byte cap used when `StreamingSpec.maxDeltaBytes` is unset.
public let defaultMaxDeltaBytes: Int = 16 * 1024

/// Canonical payload carried by a streaming tool's `ToolProgress.custom`.
public struct PartialResultPayload: Codable, Sendable, Hashable {
    public var delta: String
    public var totalBytes: UInt64
    public var truncated: Bool
    public var gap: Bool

    private enum CodingKeys: String, CodingKey {
        case delta
        case totalBytes = "total_bytes"
        case truncated
        case gap
    }

    public init(delta: String, totalBytes: UInt64, truncated: Bool = false, gap: Bool = false) {
        self.delta = delta
        self.totalBytes = totalBytes
        self.truncated = truncated
        self.gap = gap
    }

    public init(from decoder: Decoder) throws {
        // deny_unknown_fields: first decode as a map so unknown keys are visible.
        // KeyedDecodingContainer.allKeys only lists keys that match CodingKeys.
        let single = try decoder.singleValueContainer()
        let raw = try single.decode([String: JSONValue].self)
        let known: Set<String> = ["delta", "total_bytes", "truncated", "gap"]
        for key in raw.keys where !known.contains(key) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown field \(key) in PartialResultPayload"
                )
            )
        }
        guard case .string(let delta) = raw["delta"] else {
            throw DecodingError.keyNotFound(
                CodingKeys.delta,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "missing delta")
            )
        }
        self.delta = delta
        guard let totalValue = raw["total_bytes"] else {
            throw DecodingError.keyNotFound(
                CodingKeys.totalBytes,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "missing total_bytes")
            )
        }
        guard let total = totalValue.uint64Value else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath + [CodingKeys.totalBytes],
                    debugDescription: "total_bytes must be an unsigned 64-bit integer"
                )
            )
        }
        self.totalBytes = total
        if let truncated = raw["truncated"] {
            guard case .bool(let value) = truncated else {
                throw DecodingError.typeMismatch(
                    Bool.self,
                    DecodingError.Context(
                        codingPath: decoder.codingPath + [CodingKeys.truncated],
                        debugDescription: "truncated must be a boolean"
                    )
                )
            }
            self.truncated = value
        } else {
            self.truncated = false
        }
        if let gap = raw["gap"] {
            guard case .bool(let value) = gap else {
                throw DecodingError.typeMismatch(
                    Bool.self,
                    DecodingError.Context(
                        codingPath: decoder.codingPath + [CodingKeys.gap],
                        debugDescription: "gap must be a boolean"
                    )
                )
            }
            self.gap = value
        } else {
            self.gap = false
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(delta, forKey: .delta)
        try c.encode(totalBytes, forKey: .totalBytes)
        if truncated { try c.encode(truncated, forKey: .truncated) }
        if gap { try c.encode(gap, forKey: .gap) }
    }
}

/// Byte count of an incomplete UTF-8 sequence at the end of `bytes`.
private func incompleteUTF8SuffixLen(_ bytes: [UInt8]) -> Int {
    // Walk backwards to find start of last multi-byte sequence if incomplete.
    guard !bytes.isEmpty else { return 0 }
    // Valid UTF-8 decode of whole buffer?
    if String(bytes: bytes, encoding: .utf8) != nil {
        return 0
    }
    // Find the last lead byte and check if sequence is incomplete.
    var i = bytes.count - 1
    while i >= 0 && (bytes[i] & 0xC0) == 0x80 {
        i -= 1
        if i < 0 { return 0 }
    }
    let lead = bytes[i]
    let expected: Int
    if lead & 0x80 == 0 {
        expected = 1
    } else if lead & 0xE0 == 0xC0 {
        expected = 2
    } else if lead & 0xF0 == 0xE0 {
        expected = 3
    } else if lead & 0xF8 == 0xF0 {
        expected = 4
    } else {
        return 0
    }
    let have = bytes.count - i
    if have < expected {
        return have
    }
    return 0
}

/// Build at most one `ToolProgress.custom` delta from a monotonic byte source.
///
/// - Parameters:
///   - spec: streaming declaration from tool capabilities
///   - tail: newest bytes (possibly truncated tail buffer)
///   - total: monotonic count of bytes produced so far
///   - lastTotal: how much has already been surfaced (advanced in place)
///   - truncated: cumulative upstream-truncation flag
/// - Returns: progress item, or `nil` when `total` has not advanced
public func streamChunk(
    spec: StreamingSpec,
    tail: [UInt8],
    total: UInt64,
    lastTotal: inout UInt64,
    truncated: Bool
) -> ToolProgress? {
    if total <= lastTotal {
        return nil
    }
    let newCount = total - lastTotal
    let tailLen = UInt64(tail.count)
    let maxDelta = Int(spec.maxDeltaBytes ?? UInt32(defaultMaxDeltaBytes))

    // When all new bytes still fit in the tail, take the suffix; otherwise
    // the middle was dropped upstream and we mark `gap`.
    let gap = newCount > tailLen
    let available = gap ? tail : Array(tail.suffix(Int(newCount)))

    var cut = min(available.count, maxDelta)
    while cut > 0, incompleteUTF8SuffixLen(Array(available.prefix(cut))) > 0 {
        cut -= 1
    }
    if cut == 0, !available.isEmpty {
        cut = min(available.count, 4)
        while cut < available.count,
              incompleteUTF8SuffixLen(Array(available.prefix(cut))) > 0 {
            cut += 1
        }
    }
    guard cut > 0 else {
        return nil
    }

    let emitBytes = Array(available.prefix(cut))
    let delta = String(bytes: emitBytes, encoding: .utf8)
        ?? String(decoding: emitBytes, as: UTF8.self)
    let consumed = UInt64(emitBytes.count)
    if gap {
        lastTotal = total - (UInt64(available.count) - min(consumed, UInt64(available.count)))
    } else {
        lastTotal += consumed
    }

    let payload = PartialResultPayload(
        delta: delta,
        totalBytes: total,
        truncated: truncated,
        gap: gap
    )
    let value = (try? JSONValue.encode(payload)) ?? .object([
        "delta": .string(delta),
        "total_bytes": .number(.uint64(total)),
    ])
    return .custom(subkind: spec.subkind, payload: value)
}
