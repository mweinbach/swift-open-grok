// PagerSlashMru.swift
//
// Slash-command recency, backing the dropdown's MRU rank boost.
//
// Ports `xai-grok-pager/src/slash/mru.rs`: a flat `command → last_used` map
// persisted at `<opengrok home>/slash-mru.json`, a recency-with-decay tiebreak
// (7-day half-life, 0.1 floor, `mru.rs:98-109`), a 256-entry cap
// (`mru.rs:162-170`), and atomic temp-file + rename persistence
// (`mru.rs:244-268`).
//
// Ownership mirrors upstream (`mru.rs:7-16`): the interactive controller owns
// one store as actor state; a default store is **in-memory** (no disk I/O),
// and production injects the disk-backed one. Persistence is a snapshot handed
// to `PagerSlashMruWriter`, a single serializing writer, so concurrent accepts
// can never reorder or tear the on-disk file — the same shape as upstream's
// one long-lived writer thread.

import Foundation
import OpenGrokShared

/// An owned, `Sendable` snapshot ready to write to disk — `MruSnapshot`
/// (`mru.rs:236-268`). Produced on the owning actor; written off it.
public struct PagerSlashMruSnapshot: Sendable {
    public let url: URL
    public let data: Data

    /// Atomic write: temp file + rename. Returns `true` on success. Best
    /// effort by design — each snapshot is the full map, so the next accept
    /// re-persists everything a transient failure dropped (`mru.rs:282-284`).
    @discardableResult
    public func write() -> Bool {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let temporary = url.appendingPathExtension("tmp")
        do {
            try data.write(to: temporary)
            try atomicallyReplaceItem(at: url, with: temporary)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }
}

/// Serializes MRU writes the way upstream's `slash-mru-writer` thread does
/// (`mru.rs:289-317`): one writer, in order, off the accepting actor.
public actor PagerSlashMruWriter {
    public static let shared = PagerSlashMruWriter()

    public init() {}

    @discardableResult
    public func write(_ snapshot: PagerSlashMruSnapshot) -> Bool {
        snapshot.write()
    }
}

public struct PagerSlashMru: Sendable, Equatable {
    /// `RECENCY_HALF_LIFE_SECS` (`mru.rs:30`).
    public static let halfLifeSeconds: Double = 7.0 * 86_400.0
    /// `RECENCY_FLOOR` (`mru.rs:31`) — any prior use stays above never-used.
    public static let recencyFloor: Double = 0.1
    /// `MAX_ENTRIES` (`mru.rs:32`).
    public static let maximumEntries = 256

    private var byCommand: [String: UInt64] = [:]
    private var loaded = false
    private var dirty = false
    private var persistEnabled: Bool
    private let storeURL: URL?

    /// Disk-backed store at `directory/slash-mru.json` — the file upstream
    /// keeps in `grok_home()` (`mru.rs:78-80`). The caller supplies the
    /// directory (the resolved opengrok home); this type deliberately does
    /// not resolve it, for the same reason upstream injects the store: an
    /// ambient default here would silently bind tests to the real home.
    public init(directory: URL) {
        storeURL = directory.appendingPathComponent("slash-mru.json")
        persistEnabled = true
    }

    /// Isolated in-memory store — `new_in_memory` (`mru.rs:70-76`). The
    /// controller's default, so recording and boosting work without any disk
    /// wiring; persistence needs the disk-backed initializer.
    public init() {
        storeURL = nil
        persistEnabled = false
        loaded = true
    }

    /// `normalize_command` (`mru.rs:82-89`).
    static func normalize(_ commandName: String) -> String? {
        var name = commandName.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.first == "/" { name.removeFirst() }
        return name.isEmpty ? nil : name
    }

    /// `recency_score` (`mru.rs:102-109`): pure recency scaled by exponential
    /// decay so a stale entry cannot win ties forever.
    public static func recencyScore(lastUsed: UInt64, now: UInt64) -> UInt64 {
        guard lastUsed > 0 else { return 0 }
        let age = Double(now > lastUsed ? now - lastUsed : 0)
        let factor = max(pow(0.5, age / halfLifeSeconds), recencyFloor)
        return UInt64(Double(lastUsed) * factor)
    }

    /// Record use of a canonical command name — `touch` (`mru.rs:173-184`).
    public mutating func touch(_ commandName: String, now: UInt64) {
        guard let command = Self.normalize(commandName) else { return }
        ensureLoaded()
        byCommand[command] = now
        trimToCap()
        if persistEnabled { dirty = true }
    }

    public mutating func lastUsed(_ commandName: String) -> UInt64 {
        guard let command = Self.normalize(commandName) else { return 0 }
        ensureLoaded()
        return byCommand[command] ?? 0
    }

    public mutating func rankScore(_ commandName: String, now: UInt64) -> UInt64 {
        Self.recencyScore(lastUsed: lastUsed(commandName), now: now)
    }

    /// Take a snapshot to persist when dirty; clears the dirty flag —
    /// `take_persist_snapshot` (`mru.rs:202-216`). `nil` when persistence is
    /// off or nothing changed.
    public mutating func takePersistSnapshot() -> PagerSlashMruSnapshot? {
        guard persistEnabled, dirty, let storeURL else { return nil }
        let file = StoredFile(byCommand: byCommand, byPrefix: [:])
        guard let data = try? JSONEncoder().encode(file) else { return nil }
        dirty = false
        return PagerSlashMruSnapshot(url: storeURL, data: data)
    }

    /// Re-flag unpersisted changes after a failed write — `mark_dirty`
    /// (`mru.rs:220-224`).
    public mutating func markDirty() {
        if persistEnabled { dirty = true }
    }

    // MARK: - Loading

    /// On-disk schema — `MruFile` (`mru.rs:35-42`). `by_prefix` is the legacy
    /// per-prefix layout, read once and collapsed.
    private struct StoredFile: Codable {
        var byCommand: [String: UInt64]
        var byPrefix: [String: [String: UInt64]]

        enum CodingKeys: String, CodingKey {
            case byCommand = "by_command"
            case byPrefix = "by_prefix"
        }

        init(byCommand: [String: UInt64], byPrefix: [String: [String: UInt64]]) {
            self.byCommand = byCommand
            self.byPrefix = byPrefix
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            byCommand = try container.decodeIfPresent(
                [String: UInt64].self, forKey: .byCommand
            ) ?? [:]
            byPrefix = try container.decodeIfPresent(
                [String: [String: UInt64]].self, forKey: .byPrefix
            ) ?? [:]
        }
    }

    /// `ensure_loaded` (`mru.rs:111-160`). Read failure other than not-found
    /// keeps an empty store and disables persistence for the session — never
    /// clobber a file we could not read. A corrupt file is ignored (and will
    /// be overwritten by the next successful record, as upstream's is).
    private mutating func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard persistEnabled, let storeURL else { return }
        let data: Data
        do {
            data = try Data(contentsOf: storeURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        } catch {
            let underlying = (error as NSError)
            if underlying.domain == NSCocoaErrorDomain,
               underlying.code == NSFileReadNoSuchFileError {
                return
            }
            persistEnabled = false
            return
        }
        guard let file = try? JSONDecoder().decode(StoredFile.self, from: data) else {
            return
        }
        byCommand = file.byCommand
        if byCommand.isEmpty && !file.byPrefix.isEmpty {
            // Collapse legacy per-prefix buckets: max timestamp per command
            // (`mru.rs:138-147`).
            for bucket in file.byPrefix.values {
                for (command, timestamp) in bucket {
                    byCommand[command] = max(byCommand[command] ?? 0, timestamp)
                }
            }
            dirty = true
        }
        trimToCap()
    }

    /// `trim_to_cap` (`mru.rs:162-170`): keep the newest `maximumEntries`.
    private mutating func trimToCap() {
        guard byCommand.count > Self.maximumEntries else { return }
        let kept = byCommand
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
            }
            .prefix(Self.maximumEntries)
        byCommand = Dictionary(uniqueKeysWithValues: Array(kept))
    }
}
