// RhaiJournal.swift
//
// Port of crates/codegen/xai-workflow/src/journal.rs (upstream Rhai workflow
// engine). The on-disk format is the interop contract: a Rust-written
// journal.jsonl must replay here and vice versa, so the entry encoding, the
// request hash, and the load-time repair rules all follow the Rust source
// line-for-line rather than being redesigned in Swift idiom.
//
// Names carry a `Rhai` prefix so this port can live beside the pre-existing
// `WorkflowJournal` in this target without colliding; see
// INTEGRATION-workflow.md for the intended split into OpenGrokWorkflowEngine.

import Foundation
import OpenGrokShared

/// journal.rs:6 — `MAX_JOURNAL_BYTES`.
public let rhaiMaxJournalBytes: UInt64 = 64 * 1024 * 1024
/// journal.rs:7 — `MAX_JOURNAL_ENTRIES` (= `MAX_HOST_CALLS`, lib.rs:17).
public let rhaiMaxJournalEntries = 10_000
/// journal.rs:9 — the sentinel key a catchable host failure is recorded under.
public let rhaiHostErrorKey = "__xai_workflow_host_error"
/// journal.rs:12 — the journal kind recorded by the script-facing `escalate()` gate.
public let rhaiEscalateKind = "escalate"

// MARK: - Canonical JSON

/// Serializes a `JSONValue` the way `journal.rs:377 canonical_json` + serde_json's
/// `to_string` do: object keys sorted recursively, no whitespace, serde-compatible
/// string escaping. The request hash is computed over this text, so any divergence
/// here silently breaks replay against Rust-written journals.
public enum RhaiCanonicalJSON {
    public static func string(_ value: JSONValue) -> String {
        var out = ""
        write(value, into: &out)
        return out
    }

    private static func write(_ value: JSONValue, into out: inout String) {
        switch value {
        case .null:
            out += "null"
        case .bool(let flag):
            out += flag ? "true" : "false"
        case .number(let number):
            out += self.number(number)
        case .string(let text):
            writeString(text, into: &out)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let fields):
            out += "{"
            for (index, key) in fields.keys.sorted().enumerated() {
                if index > 0 { out += "," }
                writeString(key, into: &out)
                out += ":"
                write(fields[key] ?? .null, into: &out)
            }
            out += "}"
        }
    }

    /// serde_json prints integers as plain decimals and floats through ryu's
    /// shortest round-trip form. Swift's `description` is also shortest
    /// round-trip but spells exponents `1e+300` / `1e-07` where Rust spells
    /// them `1e300` / `1e-7`, so the exponent is normalized to Rust's form.
    private static func number(_ number: JSONNumber) -> String {
        switch number {
        case .int64(let value):
            return String(value)
        case .uint64(let value):
            return String(value)
        case .double(let value):
            if value.isNaN || value.isInfinite { return "null" }
            if let exact = Int64(exactly: value.rounded()), Double(exact) == value {
                // serde_json prints an f64 whole number with a trailing `.0`.
                return "\(exact).0"
            }
            var text = "\(value)"
            if let exponent = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
                let mantissa = String(text[text.startIndex..<exponent])
                var rest = String(text[text.index(after: exponent)...])
                var sign = ""
                if rest.hasPrefix("+") {
                    rest.removeFirst()
                } else if rest.hasPrefix("-") {
                    sign = "-"
                    rest.removeFirst()
                }
                while rest.count > 1, rest.hasPrefix("0") { rest.removeFirst() }
                text = "\(mantissa)e\(sign)\(rest)"
            }
            return text
        }
    }

    private static func writeString(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

/// journal.rs:396 — `sha256(kind || 0x00 || canonical_json(payload))`, truncated
/// to the first **16 bytes** (32 hex characters). The truncation is not
/// cosmetic: a full 64-character digest would never match a Rust-written
/// `req_hash` and every replay would report divergence.
public func rhaiRequestHash(kind: String, payload: JSONValue) -> String {
    var input = Array(kind.utf8)
    input.append(0)
    input.append(contentsOf: Array(RhaiCanonicalJSON.string(payload).utf8))
    let digest = RhaiSHA256.hash(input)
    return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Entries

/// journal.rs:14 — one appended line of `journal.jsonl`.
public struct RhaiJournalEntry: Codable, Sendable, Hashable {
    public var seq: UInt64
    public var kind: String
    public var reqHash: String
    public var result: JSONValue
    public var atMS: UInt64

    private enum CodingKeys: String, CodingKey {
        case seq
        case kind
        case reqHash = "req_hash"
        case result
        case atMS = "at_ms"
    }

    public init(seq: UInt64, kind: String, reqHash: String, result: JSONValue, atMS: UInt64) {
        self.seq = seq
        self.kind = kind
        self.reqHash = reqHash
        self.result = result
        self.atMS = atMS
    }

    /// The exact line this entry appends, newline included. Written by hand
    /// rather than via `JSONEncoder` so field order matches Rust's struct order
    /// (`seq, kind, req_hash, result, at_ms`) and floats keep serde's spelling.
    public var lineText: String {
        var out = "{\"seq\":\(seq),\"kind\":"
        out += RhaiCanonicalJSON.string(.string(kind))
        out += ",\"req_hash\":"
        out += RhaiCanonicalJSON.string(.string(reqHash))
        out += ",\"result\":"
        out += RhaiCanonicalJSON.string(result)
        out += ",\"at_ms\":\(atMS)}\n"
        return out
    }

    static func decode(_ bytes: [UInt8]) throws -> RhaiJournalEntry {
        try JSONDecoder().decode(RhaiJournalEntry.self, from: Data(bytes))
    }
}

/// journal.rs:23 — the error surface, message-for-message with the Rust
/// `thiserror` strings so operator-facing failures read identically.
public enum RhaiJournalError: Error, Sendable, Hashable, CustomStringConvertible {
    case io(String)
    case parse(line: Int, error: String)
    case unsafeRestore(limit: UInt64, reason: String)
    case full(seq: UInt64, limit: UInt64)
    case sequence(index: Int, expected: UInt64, actual: UInt64)
    case divergence(seq: UInt64, kind: String)

    public var description: String {
        switch self {
        case .io(let error):
            return "journal io: \(error)"
        case .parse(let line, let error):
            return "journal parse at line \(line): \(error)"
        case .unsafeRestore(let limit, let reason):
            return "journal restore rejected (limit \(limit)): \(reason)"
        case .full(let seq, let limit):
            return "journal full: appending seq \(seq) would exceed the \(limit)-byte cap "
                + "that restore enforces, which would strand the run unresumable"
        case .sequence(let index, let expected, let actual):
            return "journal is not dense at entry \(index): expected sequence \(expected), found \(actual)"
        case .divergence(let seq, let kind):
            return "replay divergence at seq \(seq) (\(kind)): the script issued a different call than the "
                + "recorded run — the workflow script is nondeterministic or was edited mid-run"
        }
    }
}

// MARK: - Journal

/// journal.rs:50 — the append-only run journal.
///
/// Mutation is serialized by a lock so the type can cross the `Sendable`
/// boundary of the run parameters; the interpreter itself drives it from a
/// single task, exactly as the Rust `Rc<RefCell<Journal>>` does.
public final class RhaiJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [RhaiJournalEntry]
    private let path: URL?
    private var bytes: UInt64
    /// Byte offset where the trailing line starts; `nil` once that line has
    /// been rewritten in-session (journal.rs:54 `last_line_start`).
    private var lastLineStart: UInt64?
    /// Injected by tests to make `at_ms` deterministic.
    private let clock: @Sendable () -> UInt64

    public init(
        path: URL? = nil,
        clock: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.entries = []
        self.path = path
        self.bytes = 0
        self.lastLineStart = nil
        self.clock = clock
    }

    private init(
        path: URL,
        entries: [RhaiJournalEntry],
        bytes: UInt64,
        lastLineStart: UInt64?,
        clock: @escaping @Sendable () -> UInt64
    ) {
        self.path = path
        self.entries = entries
        self.bytes = bytes
        self.lastLineStart = lastLineStart
        self.clock = clock
    }

    // MARK: Loading

    /// journal.rs:67 — read a journal back, repairing a torn tail in place.
    ///
    /// A missing file is an empty journal. A complete but unparseable line is a
    /// hard error (the run cannot be trusted); only an *unterminated* tail is
    /// treated as a torn write and truncated, because that is the one failure a
    /// crash mid-append can produce.
    public static func load(
        path: URL,
        clock: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1000) }
    ) throws -> RhaiJournal {
        let content: [UInt8]
        do {
            content = try readBounded(path: path)
        } catch let error as RhaiJournalError {
            throw error
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            content = []
        } catch {
            if (error as NSError).code == NSFileReadNoSuchFileError {
                content = []
            } else {
                throw RhaiJournalError.io(String(describing: error))
            }
        }

        var entries: [RhaiJournalEntry] = []
        var offset = 0
        var lineNumber = 0
        var bytes = UInt64(content.count)
        var lastLineStart: UInt64?

        while offset < content.count {
            lineNumber += 1
            guard let newlineOffset = content[offset...].firstIndex(of: UInt8(ascii: "\n")) else {
                let tail = Array(content[offset...])
                if tail.allSatisfy(isASCIIWhitespace) {
                    try truncate(path: path, length: UInt64(offset))
                    bytes = UInt64(offset)
                    break
                }
                do {
                    let entry = try RhaiJournalEntry.decode(tail)
                    guard entries.count < rhaiMaxJournalEntries else {
                        throw RhaiJournalError.unsafeRestore(
                            limit: UInt64(rhaiMaxJournalEntries),
                            reason: "too many journal entries"
                        )
                    }
                    try validateSequence(entries, entry)
                    entries.append(entry)
                    lastLineStart = UInt64(offset)
                    try terminateLine(path: path)
                    bytes += 1
                } catch let error as RhaiJournalError {
                    throw error
                } catch {
                    // A tail without a newline is a torn append: drop it.
                    try truncate(path: path, length: UInt64(offset))
                    bytes = UInt64(offset)
                }
                break
            }

            let lineStart = offset
            let line = Array(content[offset..<newlineOffset])
            offset = newlineOffset + 1
            if line.allSatisfy(isASCIIWhitespace) { continue }

            let entry: RhaiJournalEntry
            do {
                entry = try RhaiJournalEntry.decode(line)
            } catch {
                throw RhaiJournalError.parse(line: lineNumber, error: String(describing: error))
            }
            guard entries.count < rhaiMaxJournalEntries else {
                throw RhaiJournalError.unsafeRestore(
                    limit: UInt64(rhaiMaxJournalEntries),
                    reason: "too many journal entries"
                )
            }
            try validateSequence(entries, entry)
            entries.append(entry)
            lastLineStart = UInt64(lineStart)
        }

        return RhaiJournal(
            path: path,
            entries: entries,
            bytes: bytes,
            lastLineStart: lastLineStart,
            clock: clock
        )
    }

    /// journal.rs:300 — refuse symlinks, non-regular files, and anything over
    /// the restore cap *before* reading it into memory.
    private static func readBounded(path: URL) throws -> [UInt8] {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        } catch {
            throw error
        }
        let type = attributes[.type] as? FileAttributeType
        guard type != .typeSymbolicLink else {
            throw RhaiJournalError.unsafeRestore(
                limit: rhaiMaxJournalBytes,
                reason: "journal is not a regular file: \(path.path)"
            )
        }
        guard type == .typeRegular else {
            throw RhaiJournalError.unsafeRestore(
                limit: rhaiMaxJournalBytes,
                reason: "journal is not a regular file: \(path.path)"
            )
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard size <= rhaiMaxJournalBytes else {
            throw RhaiJournalError.unsafeRestore(
                limit: rhaiMaxJournalBytes,
                reason: "journal exceeds \(rhaiMaxJournalBytes) bytes"
            )
        }
        let data = try Data(contentsOf: path)
        guard UInt64(data.count) <= rhaiMaxJournalBytes else {
            throw RhaiJournalError.unsafeRestore(
                limit: rhaiMaxJournalBytes,
                reason: "journal exceeds \(rhaiMaxJournalBytes) bytes"
            )
        }
        return Array(data)
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0B || byte == 0x0C || byte == 0x0D
    }

    // MARK: Reading

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    public var isEmpty: Bool { count == 0 }

    public var snapshot: [RhaiJournalEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// journal.rs:159 — how many agent slots this journal already accounts for.
    public var agentReservationCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return UInt64(entries.filter { $0.kind == "spawn_agent" }.count)
    }

    /// journal.rs:169 — whether `seq` was already recorded (i.e. we are replaying).
    public func covers(_ seq: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seq < UInt64(entries.count)
    }

    /// journal.rs:173 — the recorded result for `seq`, or `nil` when the run has
    /// caught up with the journal and this call must go live.
    ///
    /// A recorded entry whose kind or request hash differs is divergence, not a
    /// cache miss: the script asked for something the recorded run never did.
    public func replay(seq: UInt64, kind: String, reqHash: String) throws -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        guard seq < UInt64(entries.count) else { return nil }
        let entry = entries[Int(seq)]
        guard entry.seq == seq, entry.kind == kind, entry.reqHash == reqHash else {
            throw RhaiJournalError.divergence(seq: seq, kind: kind)
        }
        return entry.result
    }

    // MARK: Appending

    /// journal.rs:194 — append one entry, refusing to grow past the cap that
    /// `load` enforces (an oversized journal would strand the run unresumable).
    /// Persistence failures leave memory untouched so the caller can retry.
    public func record(seq: UInt64, kind: String, reqHash: String, result: JSONValue) throws {
        lock.lock()
        defer { lock.unlock() }
        try recordLocked(seq: seq, kind: kind, reqHash: reqHash, result: result)
    }

    private func recordLocked(seq: UInt64, kind: String, reqHash: String, result: JSONValue) throws {
        let entry = RhaiJournalEntry(
            seq: seq,
            kind: kind,
            reqHash: reqHash,
            result: result,
            atMS: clock()
        )
        try Self.validateSequence(entries, entry)
        let line = entry.lineText
        let lineBytes = UInt64(line.utf8.count)
        guard bytes + lineBytes <= rhaiMaxJournalBytes else {
            throw RhaiJournalError.full(seq: seq, limit: rhaiMaxJournalBytes)
        }
        if let path {
            try Self.appendLine(path: path, line: line)
        }
        lastLineStart = bytes
        bytes += lineBytes
        entries.append(entry)
    }

    // MARK: Escalation gates

    /// journal.rs:235 — true when the run is parked at an `escalate()` gate.
    ///
    /// Trailing-null is a real invariant: `escalate()` records its placeholder
    /// and pauses immediately, so nothing can follow it, and a noteless resume
    /// rewrites the placeholder to `""` as it replays past the gate.
    public var hasPendingEscalation: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let last = entries.last else { return false }
        return last.kind == rhaiEscalateKind && last.result.isNull
    }

    /// journal.rs:247 — deliver the resumer's fix note to a run paused at
    /// `escalate()`, rewriting the placeholder so replay hands it to the script.
    @discardableResult
    public func fulfillPendingEscalation(note: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let last = entries.last, last.kind == rhaiEscalateKind, last.result.isNull else {
            return false
        }
        // A missing offset means the trailing entry was already rewritten
        // in-session, so the placeholder now exposed belongs to an earlier,
        // already-consumed gate — nothing is pending.
        guard let newLength = lastLineStart else { return false }
        if let path {
            try Self.truncate(path: path, length: newLength)
        }
        let entry = entries.removeLast()
        bytes = newLength
        lastLineStart = nil
        try recordLocked(
            seq: entry.seq,
            kind: rhaiEscalateKind,
            reqHash: entry.reqHash,
            result: .string(note)
        )
        return true
    }

    /// journal.rs:272 — drop a trailing catchable-host-failure sentinel when
    /// that same failure is what killed the run, so a resume can retry the call
    /// instead of replaying the failure forever.
    ///
    /// It is deliberately a no-op when the sentinel is not the last entry or
    /// when the run died elsewhere: a sentinel the script *caught* must keep
    /// replaying, or the resumed run would take a different branch.
    @discardableResult
    public func pruneTrailingHostError(failureDetail: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let last = entries.last else { return false }
        guard let message = last.result[rhaiHostErrorKey]?.stringValue else { return false }
        guard !message.isEmpty, failureDetail.contains(message) else { return false }
        guard let newLength = lastLineStart else {
            throw RhaiJournalError.io("journal cannot locate the trailing entry's byte offset")
        }
        if let path {
            try Self.truncate(path: path, length: newLength)
        }
        entries.removeLast()
        bytes = newLength
        lastLineStart = nil
        return true
    }

    // MARK: File primitives

    private static func validateSequence(
        _ entries: [RhaiJournalEntry],
        _ entry: RhaiJournalEntry
    ) throws {
        let expected = UInt64(entries.count)
        guard entry.seq == expected else {
            throw RhaiJournalError.sequence(index: entries.count, expected: expected, actual: entry.seq)
        }
    }

    private static func truncate(path: URL, length: UInt64) throws {
        do {
            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            try handle.truncate(atOffset: length)
            try handle.synchronize()
        } catch {
            throw RhaiJournalError.io(String(describing: error))
        }
    }

    private static func terminateLine(path: URL) throws {
        try appendBytes(path: path, data: Data([UInt8(ascii: "\n")]))
    }

    private static func appendLine(path: URL, line: String) throws {
        try appendBytes(path: path, data: Data(line.utf8))
    }

    private static func appendBytes(path: URL, data: Data) throws {
        do {
            let directory = path.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            if !FileManager.default.fileExists(atPath: path.path) {
                guard FileManager.default.createFile(atPath: path.path, contents: nil) else {
                    throw RhaiJournalError.io("cannot create journal at \(path.path)")
                }
            }
            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch let error as RhaiJournalError {
            throw error
        } catch {
            throw RhaiJournalError.io(String(describing: error))
        }
    }
}

// MARK: - Sentinels

/// engine.rs:310 — a catchable host failure is journaled as this object so a
/// replay re-raises the same script-visible error.
public func rhaiHostErrorSentinel(_ message: String) -> JSONValue {
    .object([rhaiHostErrorKey: .string(message)])
}

/// engine.rs:305 — a `parallel()` sibling that hit a terminal condition is
/// journaled with this marker rather than a result.
public let rhaiHostTerminalKey = "__xai_workflow_parallel_terminal"
public let rhaiTerminalBudget = "budget_exceeded"
public let rhaiTerminalCancelled = "cancelled"
public let rhaiTerminalDroppedReply = "dropped_reply"

public func rhaiHostTerminalSentinel(_ kind: String) -> JSONValue {
    .object([rhaiHostTerminalKey: .string(kind)])
}
