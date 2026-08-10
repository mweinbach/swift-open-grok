// PagerDashboardStore.swift
//
// Wave 18 B1-s: the dashboard's `[dashboard]` persistence — the port of
// the Persistence I/O half of `views/dashboard/state.rs`
// (`load_persisted_enabled` `:4894-4904`, `load_persisted_from_path`
// `:4917-4951`, `write_persisted_to_path` `:4961-5016`, the entry caps
// and lenient array parsers `:5065-5106`) at upstream pin 650c1db7.
//
// The table lives INSIDE the shared user `config.toml`, not in a file of
// its own, so every write is a splice against a document that also holds
// `[ui]`, `[hints]`, `[mcp_servers]`, … That is what makes the
// unparseable-file guard load-bearing rather than defensive: without it
// a single Ctrl+T pin would rewrite a config the user could still have
// repaired by hand, erasing every other table in it.
//
// Write seam follows the landed `PagerAgentsConfigStore` shape exactly —
// `documentForEdit` (missing/empty → a fresh table, non-empty and
// unparseable → refuse) plus `ConfigWrite.writeConfigFile`'s atomic
// tmp+rename. Divergences from upstream, recorded:
//
//   - Upstream's writer WARNS and returns `Ok(())` on an unparseable
//     file; this one throws `.unparseableConfig`. The composition
//     swallows the error (persist failures are never user-facing), so
//     the observable behaviour is identical — but a throw is testable
//     and an `Ok(())` that did nothing is not.
//   - Upstream `sync_all()`s the bytes and fsyncs the parent directory
//     before/after the rename; `writeConfigFile` does the tmp+rename
//     without the explicit fsyncs. That is the port-wide recorded
//     config-write divergence, not a new one here.
//   - Upstream's writer also does `t.remove("onboarding")` (`:5013`) to
//     purge a dead `[dashboard.onboarding]` key left by older builds.
//     Omitted: this port has never written that key, so the cleanup
//     could only ever delete something a user hand-wrote.
//   - Upstream orders the `pinned` array by `PersistedRowId`'s derived
//     `Ord` (variant order: every `top:` before every `sub:`); this port
//     sorts the KEY STRINGS, which puts `sub:` first. Array order in a
//     set-valued field is not semantic — loads rebuild a `Set` — and
//     sorting is what makes the file byte-deterministic at all, since
//     `Set` iteration order in Swift is seed-dependent per process (the
//     `PagerSettingsStore.writeMultiSelect` precedent, `:129-131`).
//     `reorder` is NOT sorted: there the order IS the value.

import Foundation
import OpenGrokConfig

/// A persistence failure. Loads never throw (they are lenient by
/// design); only the writer does.
public enum PagerDashboardStoreError: Error, Equatable, CustomStringConvertible {
    /// The config file is non-empty and does not parse, so writing would
    /// destroy data the user may still be able to recover.
    case unparseableConfig
    case writeFailed(String)

    public var description: String {
        switch self {
        case .unparseableConfig:
            return "refusing to persist dashboard: config.toml is non-empty and unparseable"
        case .writeFailed(let detail):
            return "Failed to write config.toml: \(detail)"
        }
    }
}

/// Persistent identity for a pinned / reordered row (`PersistedRowId`,
/// `state.rs:135-181`).
///
/// Keyed by ACP session id, never by a per-process handle: a handle is
/// meaningless across restarts and — worse — can be REISSUED, which
/// would silently reattach a pin to a different session.
public enum PagerPersistedRowID: Sendable, Equatable, Hashable {
    case topLevel(sessionID: String)
    case subagent(parentSessionID: String, childSessionID: String)

    /// On-disk spelling: `top:<session_id>` or
    /// `sub:<parent_session_id>:<child_session_id>` (`to_key`,
    /// `state.rs:148-158`). Session ids are opaque here — they are never
    /// escaped or split when writing.
    public var key: String {
        switch self {
        case .topLevel(let sessionID):
            return "top:\(sessionID)"
        case .subagent(let parent, let child):
            return "sub:\(parent):\(child)"
        }
    }

    /// Parse a key back, returning nil for anything malformed
    /// (`from_key`, `state.rs:160-181`).
    ///
    /// Only the FIRST colon after `sub:` splits, so a child session id
    /// containing colons round-trips intact. The rejection table, all of
    /// it deliberate: `top:` with an empty id, `sub::child`,
    /// `sub:parent:`, `sub:foo` (no second colon), and any unknown
    /// prefix.
    public init?(key: String) {
        if key.hasPrefix("top:") {
            let sessionID = String(key.dropFirst(4))
            if sessionID.isEmpty { return nil }
            self = .topLevel(sessionID: sessionID)
            return
        }
        if key.hasPrefix("sub:") {
            let rest = key.dropFirst(4)
            guard let split = rest.firstIndex(of: ":") else { return nil }
            let parent = String(rest[rest.startIndex..<split])
            let child = String(rest[rest.index(after: split)...])
            if parent.isEmpty || child.isEmpty { return nil }
            self = .subagent(parentSessionID: parent, childSessionID: child)
            return
        }
        return nil
    }
}

/// The `[dashboard]` table's whole persisted shape
/// (`PersistedDashboard`, `state.rs:377-399`).
public struct PagerPersistedDashboard: Sendable, Equatable {
    public var enabled: Bool
    public var grouping: PagerDashboardGrouping
    public var pinned: Set<PagerPersistedRowID>
    public var reorder: [PagerPersistedRowID]

    public init(
        enabled: Bool = true,
        grouping: PagerDashboardGrouping = .state,
        pinned: Set<PagerPersistedRowID> = [],
        reorder: [PagerPersistedRowID] = []
    ) {
        self.enabled = enabled
        self.grouping = grouping
        self.pinned = pinned
        self.reorder = reorder
    }

    /// Feature-flag defaults (`PersistedDashboard::defaults`,
    /// `state.rs:384-392`): the dashboard is ON unless a config or the
    /// environment says otherwise.
    public static let defaults = PagerPersistedDashboard()
}

/// Reads and writes `[dashboard]` in a config.toml.
///
/// Takes the config-file URL explicitly rather than resolving a home:
/// the render target performs no environment lookups, so the
/// composition (which already resolves `OPENGROK_HOME`) supplies the
/// path — the same seam `PagerAgentsConfigStore` uses.
public struct PagerDashboardStore: Sendable {
    /// Cap the parsed entry count so a corrupted or hostile config
    /// cannot balloon allocations (`MAX_PERSISTED_ENTRIES`,
    /// `state.rs:5068`).
    public static let maxPersistedEntries = 256
    /// Cap persist-key length so one malformed entry cannot carry
    /// megabytes (`MAX_PERSIST_KEY_LEN`, `state.rs:5071`). Measured in
    /// UTF-8 BYTES, matching Rust's `str::len` — Swift's `count` is
    /// grapheme clusters and would admit a much longer key.
    public static let maxPersistKeyLength = 1024

    public var configPath: URL

    public init(configPath: URL) {
        self.configPath = configPath
    }

    // MARK: Loading

    /// Read just `[dashboard].enabled` (`load_persisted_enabled`,
    /// `state.rs:4894-4904`).
    ///
    /// Lenient in the strongest sense: a missing file, a parse failure,
    /// a missing key, or a non-boolean value all return nil, and the
    /// caller reads nil as "use the default". Never throws — a broken
    /// config must not stop the pager from starting.
    public func loadEnabled() -> Bool? {
        guard let root = readRoot() else { return nil }
        return root["dashboard"]?["enabled"]?.boolValue
    }

    /// Read the whole `[dashboard]` table
    /// (`load_persisted_from_path`, `state.rs:4917-4951`).
    ///
    /// Returns nil only when the file is missing, unreadable,
    /// unparseable, or has no `[dashboard]` key at all. Once the table
    /// exists, every individual field falls back to its default rather
    /// than failing the whole load: a garbage `enabled` still lets the
    /// pins load, and vice versa.
    ///
    /// A `dashboard` key that is not a table yields the defaults, not
    /// nil — upstream's `toml_edit` `Item::get` returns `None` for every
    /// field of a non-table, so each falls back independently.
    public func load() -> PagerPersistedDashboard? {
        guard let root = readRoot(), let entry = root["dashboard"] else { return nil }
        let table = entry.table
        let enabled = table?["enabled"]?.boolValue ?? true
        var grouping = PagerDashboardGrouping.state
        switch table?["grouping"]?.stringValue {
        case "directory", "dir": grouping = .directory
        // "state", an unknown string, a non-string, or absent → State.
        default: grouping = .state
        }
        let pinned = Set(Self.parsePersistKeys(table?["pinned"]))
        let reorder = Self.parsePersistKeys(table?["reorder"])
        return PagerPersistedDashboard(
            enabled: enabled,
            grouping: grouping,
            pinned: pinned,
            reorder: reorder
        )
    }

    /// Parse a persisted key array (`parse_persist_keys` /
    /// `parse_persist_key_list`, `state.rs:5073-5106`). A non-array
    /// yields nothing; inside the array, over-long, non-string and
    /// malformed entries are skipped individually rather than failing
    /// the field.
    private static func parsePersistKeys(_ value: TOMLValue?) -> [PagerPersistedRowID] {
        guard let array = value?.arrayValue else { return [] }
        return array.prefix(maxPersistedEntries).compactMap { element in
            guard let key = element.stringValue,
                  key.utf8.count <= maxPersistKeyLength else { return nil }
            return PagerPersistedRowID(key: key)
        }
    }

    private func readRoot() -> TOMLValue? {
        guard let content = try? String(contentsOf: configPath, encoding: .utf8),
              let parsed = try? parseTOML(content) else { return nil }
        return parsed
    }

    // MARK: Writing

    /// Splice `[dashboard]` into the config file
    /// (`write_persisted_to_path`, `state.rs:4961-5016`).
    ///
    /// Only the four keys are touched; every other key in `[dashboard]`
    /// — and every other table in the file — survives, because the
    /// document is re-read and mutated rather than regenerated.
    public func write(_ persisted: PagerPersistedDashboard) throws {
        var root = try documentForEdit()
        // A `dashboard` key that exists but is not a table: upstream's
        // `as_table_mut()` returns None and the writer returns without
        // writing (`:4998-5000`). Mirrored — clobbering an unrecognised
        // shape is the very thing this whole path guards against.
        if let existing = root["dashboard"], existing.table == nil { return }
        var table = root["dashboard"]?.table ?? TOMLTable()
        table.insert(.boolean(persisted.enabled), forKey: "enabled")
        table.insert(.string(persisted.grouping.rawValue), forKey: "grouping")
        // Sorted: `pinned` is a Set, and Set iteration order in Swift is
        // per-process seeded, so an unsorted write would produce a
        // spurious diff on every pin. Same reasoning as
        // `PagerSettingsStore.writeMultiSelect` (`:129-131`).
        let pinnedKeys = persisted.pinned.map(\.key).sorted()
        table.insert(.array(pinnedKeys.map(TOMLValue.string)), forKey: "pinned")
        // NOT sorted: reorder is an ordering list, so its order is the
        // value being persisted.
        table.insert(
            .array(persisted.reorder.map { TOMLValue.string($0.key) }),
            forKey: "reorder"
        )
        root = .table({
            var rootTable = root.table ?? TOMLTable()
            rootTable.insert(.table(table), forKey: "dashboard")
            return rootTable
        }())
        do {
            try writeConfigFile(root, to: configPath)
        } catch {
            throw PagerDashboardStoreError.writeFailed("\(error)")
        }
    }

    /// `read_config_document_for_edit` (`config_toml_edit.rs:7-27`), the
    /// same guard `PagerAgentsConfigStore` uses: a missing or unreadable
    /// file edits a fresh document, but a non-empty file that does not
    /// parse is refused, so a pin can never clobber `[ui]`, `[hints]`,
    /// or anything else the user has in there.
    private func documentForEdit() throws -> TOMLValue {
        let content = (try? String(contentsOf: configPath, encoding: .utf8)) ?? ""
        if content.isEmpty { return .table(TOMLTable()) }
        guard let parsed = try? parseTOML(content), parsed.isTable else {
            throw PagerDashboardStoreError.unparseableConfig
        }
        return parsed
    }
}

// MARK: - Bridging live row ids to persisted ones

extension PagerDashboardRowID {
    /// The on-disk identity for this row, or nil when it has none.
    ///
    /// PORT DIVERGENCE (lead ruling): a dormant catalog row persists as
    /// a `top:<session_id>` key, exactly like a live one. Upstream
    /// refuses to persist roster rows at all (`state.rs:1313-1316`),
    /// because there the roster is another PROCESS's live view and a pin
    /// on it would be meaningless once that process exits. Here the
    /// dormant feed is the on-disk session catalog: the session outlives
    /// every process, so a pin on it is exactly as durable as a pin on
    /// an attached tab, and dropping it would make pinning a session and
    /// then detaching silently lose the pin. Both kinds resolve back
    /// through `resolve(in:)`, which picks whichever kind the session is
    /// TODAY.
    public var persisted: PagerPersistedRowID? {
        switch self {
        case .session(let sessionID), .dormant(let sessionID):
            return .topLevel(sessionID: sessionID)
        case .subagent(let parent, let child):
            return .subagent(parentSessionID: parent, childSessionID: child)
        }
    }
}

extension PagerPersistedRowID {
    /// Resolve back to whichever live row id carries this identity now
    /// (`PersistedDashboard::resolve`, `state.rs:1275-1294`).
    ///
    /// A `top:` key matches a `.session` row OR a `.dormant` one — the
    /// same session, seen through whichever feed currently owns it — so
    /// a pin survives attaching and detaching. Unresolved keys are
    /// dropped by the caller's `gcStaleRefs`.
    public func resolve(in candidates: [PagerDashboardRowID]) -> PagerDashboardRowID? {
        candidates.first { $0.persisted == self }
    }
}

extension PagerDashboardState {
    /// Apply a loaded `[dashboard]` to this state, resolving each key
    /// against the rows that exist right now. Keys that resolve to
    /// nothing are dropped here rather than lingering as phantoms.
    public mutating func apply(
        _ persisted: PagerPersistedDashboard,
        resolvingAgainst candidates: [PagerDashboardRowID]
    ) {
        grouping = persisted.grouping
        pinned = Set(persisted.pinned.compactMap { $0.resolve(in: candidates) })
        // compactMap keeps the surviving entries in their persisted
        // order — the reorder list's order IS its meaning.
        reorder = persisted.reorder.compactMap { $0.resolve(in: candidates) }
    }

    /// Project this state back onto the persisted shape.
    ///
    /// `enabled` is a PARAMETER, never a hardcoded `true`: it is threaded
    /// from the on-disk value so a user who deliberately set
    /// `enabled = false` does not have it silently overwritten by the
    /// next pin or grouping toggle (`dispatch_dashboard_persist`,
    /// `dispatch/dashboard.rs:2369-2384`).
    ///
    /// `filter`, `searchActive`, `collapsedSections`, `idleShowAll` and
    /// the cursor are absent by construction — they are per-open state,
    /// and writing them would make the next launch open in a filtered
    /// view the user never asked for.
    public func toPersisted(enabled: Bool) -> PagerPersistedDashboard {
        PagerPersistedDashboard(
            enabled: enabled,
            grouping: grouping,
            pinned: Set(pinned.compactMap(\.persisted)),
            reorder: reorder.compactMap(\.persisted)
        )
    }
}
