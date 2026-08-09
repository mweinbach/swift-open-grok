// PagerAgentsConfigStore.swift
//
// The agents modal's two config writers (Wave 18 B9-b2), ported from
// `xai-grok-pager/src/views/agents_modal.rs` at upstream 650c1db7:
// `set_default_agent` (`:730-752` — write or clear `[agent] name`) and
// `toggle_agent` (`:754-778` — write `[subagents.toggle].<name>`), both
// against the USER config.toml (`grok_home().join("config.toml")`,
// `:731`/`:755`) — never the project one.
//
// Write-seam choice, deliberate: this is the B9-c1 ack store's
// parse-mutate-serialize shape (read the file fresh, splice, write
// atomically), NOT a `PagerSettingsStore` registry row — registry rows
// render in the settings modal, and neither of these keys has an upstream
// row there. Upstream edits with `toml_edit` and preserves comments and
// formatting; this port's TOML writer (`ConfigWrite.swift`) preserves key
// ORDER (insertion-ordered tables, in-place updates of existing keys) but
// drops comments on rewrite — the recorded config-write divergence every
// port writer shares. Cost carried knowingly: a hand-commented
// config.toml loses its comments the first time `t` or `s` is pressed,
// where upstream keeps them.
//
// The guard rail both writers share with upstream's
// `read_config_document_for_edit` (`config_toml_edit.rs:7-27`): a MISSING
// or unreadable file edits an empty document, but a non-empty file that
// does not parse is refused — "Could not read or parse config.toml" — so
// a malformed config is never clobbered by a single keystroke.

import Foundation
import OpenGrokConfig

/// A writer failure, carrying upstream's exact user-facing message — the
/// modal surfaces `message` verbatim as its inline error line
/// (`agents_modal.rs:2177`, `:2192`).
public struct PagerAgentsConfigWriteError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Reads and writes the two agents-modal keys in the user `config.toml`.
///
/// Read-modify-write against the file on every call, never a cached tree —
/// the `PagerSettingsStore` reasoning: another process may have edited the
/// file since this one loaded it, and re-reading is what keeps a toggle
/// from reverting someone else's change. Unrelated keys and tables survive
/// because only the one table is spliced.
public struct PagerAgentsConfigStore: Sendable {
    public var configPath: URL

    public init(configPath: URL) {
        self.configPath = configPath
    }

    /// `set_default_agent` (`agents_modal.rs:730-752`): pass a name to set
    /// `[agent] name`, `nil` to clear (remove the key).
    ///
    /// Surgery per upstream (`:738-748`): setting creates `[agent]` when
    /// missing and refuses a non-table (`"[agent] is not a table"`);
    /// clearing removes only the `name` key and — like upstream's
    /// `toml_edit` — leaves the emptied `[agent]` header behind rather
    /// than pruning it, and silently succeeds when `[agent]` is missing
    /// or not a table. The document is written even when the clear
    /// changed nothing (upstream's unconditional `fs::write`, `:749`).
    public func setDefaultAgent(_ name: String?) throws {
        var root = try documentForEdit()
        if let name {
            var agent: TOMLTable
            switch root["agent"] {
            case .none:
                agent = TOMLTable()
            case .some(let existing):
                guard let inner = existing.table else {
                    throw PagerAgentsConfigWriteError(message: "[agent] is not a table")
                }
                agent = inner
            }
            agent.insert(.string(name), forKey: "name")
            root.insert(.table(agent), forKey: "agent")
        } else if var agent = root["agent"]?.table {
            _ = agent.removeValue(forKey: "name")
            root.insert(.table(agent), forKey: "agent")
        }
        try write(root)
    }

    /// `toggle_agent` (`agents_modal.rs:754-778`): set
    /// `[subagents.toggle].<name> = enabled`, creating `[subagents]` and
    /// `[subagents.toggle]` when missing and refusing non-tables with
    /// upstream's exact messages (`:767`, `:773`). Every entry kind is
    /// writable — upstream applies no builtin/user/project guard
    /// (`:2183-2196`), so a built-in toggles exactly like a file-based
    /// agent.
    public func toggleAgent(name: String, enabled: Bool) throws {
        var root = try documentForEdit()
        var subagents: TOMLTable
        switch root["subagents"] {
        case .none:
            subagents = TOMLTable()
        case .some(let existing):
            guard let inner = existing.table else {
                throw PagerAgentsConfigWriteError(message: "subagents is not a table")
            }
            subagents = inner
        }
        var toggle: TOMLTable
        switch subagents["toggle"] {
        case .none:
            toggle = TOMLTable()
        case .some(let existing):
            guard let inner = existing.table else {
                throw PagerAgentsConfigWriteError(message: "subagents.toggle is not a table")
            }
            toggle = inner
        }
        toggle.insert(.boolean(enabled), forKey: name)
        subagents.insert(.table(toggle), forKey: "toggle")
        root.insert(.table(subagents), forKey: "subagents")
        try write(root)
    }

    /// `read_config_document_for_edit` (`config_toml_edit.rs:7-27`):
    /// missing or unreadable → an empty editable document; non-empty but
    /// unparseable → refuse, so the write path can never replace a config
    /// the user could still repair by hand.
    private func documentForEdit() throws -> TOMLTable {
        let content = (try? String(contentsOf: configPath, encoding: .utf8)) ?? ""
        if content.isEmpty { return TOMLTable() }
        guard let parsed = try? parseTOML(Data(content.utf8)), let table = parsed.table else {
            throw PagerAgentsConfigWriteError(message: "Could not read or parse config.toml")
        }
        return table
    }

    /// The shared write tail (`:749-750`/`:775-776`): parent dir + atomic
    /// replace via `writeConfigFile`, failures wrapped in upstream's
    /// `"Failed to write config.toml: {e}"`.
    private func write(_ root: TOMLTable) throws {
        do {
            try writeConfigFile(.table(root), to: configPath)
        } catch {
            throw PagerAgentsConfigWriteError(message: "Failed to write config.toml: \(error)")
        }
    }
}
