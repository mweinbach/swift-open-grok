// SubagentPersonaLoader.swift
//
// The runtime-side personas map: the port of `SubagentsConfig`'s persona
// discovery and layering (`xai-grok-shell/src/config/mod.rs`).
//
// Upstream splits persona loading in two, and this file mirrors that split
// exactly because the halves have different lifetimes:
//
//   * The trust-independent BASE — inline `[subagents.personas]` config
//     entries, then `{grok_home}/personas/*.toml` (user scope), then
//     `{grok_home}/bundled/personas/*.toml` (bundled scope) — is resolved
//     once at startup (`resolve_base_with_sources`, config/mod.rs:512-535,
//     copied onto the agent config by `resolve_subagents`,
//     agent/config.rs:2255-2263).
//   * The PROJECT overlay — `{cwd}/.opengrok/personas/*.toml`, gated on the
//     parent cwd's folder-trust verdict — is recomputed on every spawn
//     (`effective_definition_maps` called from
//     mvp_agent/subagent_coordinator.rs:459-474). A per-spawn overlay is one
//     directory scan; upstream pays it each time rather than caching, and so
//     does this port.
//
// Precedence (highest first): inline config > project file (trusted only) >
// user file > bundled file. Within the base the ordering falls out of
// first-insertion-wins (`discover_personas_in_dir` skips names already
// present, config/mod.rs:301-303); across the overlay it falls out of the
// merge rule at config/mod.rs:554-559 — a base entry re-inserts over the
// project map when it is inline (`source_path.is_none()`) or when the
// project did not shadow the name.
//
// Malformed input NEVER fails a session: an unreadable directory returns
// (config/mod.rs:286-292), and an unreadable or unparseable persona file is
// skipped (config/mod.rs:304-319, a `tracing::warn!` upstream — this port
// has no tracing sink, so the skip is silent; the modal slices B9-b1..b3 own
// any user-facing surfacing).

import Foundation
import OpenGrokConfig

public enum SubagentPersonaLoader {
    // MARK: - Base map (once per session)

    /// The trust-independent base map, from the effective config document
    /// plus the user and bundled persona directories under `openGrokHome`.
    ///
    /// `configDocument` must be the session's trust-gated effective config
    /// (the same authority chain the `[subagents.toggle]` reader uses), and
    /// `openGrokHome` the session's resolved home — both are threaded from
    /// the composition, never read from process globals (the recorded
    /// process-cwd footgun applies to homes exactly as it does to cwds).
    public static func basePersonas(
        configDocument: TOMLValue,
        openGrokHome: URL
    ) -> [String: SubagentPersona] {
        var personas = inlinePersonas(in: configDocument)
        // User scope, then bundled scope: first-insertion-wins gives inline >
        // user > bundled (config/mod.rs:528-534).
        discoverPersonas(
            inDirectory: openGrokHome.appendingPathComponent("personas", isDirectory: true),
            into: &personas
        )
        // `bundled_root()` is `{grok_home}/bundled` (shell bundle.rs:86-88).
        discoverPersonas(
            inDirectory: openGrokHome
                .appendingPathComponent("bundled", isDirectory: true)
                .appendingPathComponent("personas", isDirectory: true),
            into: &personas
        )
        return personas
    }

    // MARK: - Per-spawn overlay

    /// The map a single spawn resolves against: the trusted project overlay
    /// from `{cwd}/.opengrok/personas/*.toml`, merged with the base under
    /// upstream's rule (config/mod.rs:546-560). `cwd` is the PARENT session's
    /// cwd — upstream overlays against `parent_cwd` even when the task names
    /// a different child cwd (subagent_coordinator.rs:472).
    public static func effectivePersonas(
        base: [String: SubagentPersona],
        cwd: URL,
        projectTrusted: Bool
    ) -> [String: SubagentPersona] {
        var project: [String: SubagentPersona] = [:]
        if projectTrusted {
            discoverPersonas(
                inDirectory: cwd
                    .appendingPathComponent(".opengrok", isDirectory: true)
                    .appendingPathComponent("personas", isDirectory: true),
                into: &project
            )
        }
        for (name, persona) in base {
            // Inline entries (no source path) always win; file-based base
            // entries (user/bundled) lose to a project shadow
            // (config/mod.rs:554-559 — the personas arm keys on
            // `source_path`, unlike the roles arm's `source_dir`).
            if persona.sourcePath == nil || project[name] == nil {
                project[name] = persona
            }
        }
        return project
    }

    // MARK: - Directory discovery

    /// Load every `*.toml` in `directory` whose stem is not already present.
    /// The file stem becomes the persona name; `sourceDirectory` and
    /// `sourcePath` are stamped so relative `instructions_file` references
    /// resolve against the file's own directory (config/mod.rs:294-311).
    static func discoverPersonas(
        inDirectory directory: URL,
        into personas: inout [String: SubagentPersona]
    ) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles]
              )
        else { return }
        // read_dir order is OS-arbitrary upstream; stems are unique within a
        // directory so ordering cannot change the outcome. Sorted here only
        // for deterministic traversal.
        for file in entries.filter({ $0.pathExtension == "toml" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.deletingPathExtension().lastPathComponent
            guard !name.isEmpty, personas[name] == nil else { continue }
            // A file that cannot be read or parsed is SKIPPED, never fatal
            // (config/mod.rs:304-319): a malformed persona file must not
            // take a session down.
            guard let content = try? String(contentsOf: file, encoding: .utf8),
                  let document = try? parseTOML(content),
                  let table = document.table,
                  var persona = persona(fromTable: table)
            else { continue }
            persona.sourceDirectory = file.deletingLastPathComponent()
            persona.sourcePath = file.path
            personas[name] = persona
        }
    }

    // MARK: - Inline `[subagents.personas]`

    /// Parse `[subagents.personas.<name>]` tables from the effective config.
    /// Inline entries carry no source path — that absence IS their priority
    /// bit in the overlay merge.
    ///
    /// Recorded divergence: upstream deserializes the whole `[subagents]`
    /// section in one `try_into().ok().unwrap_or_default()`
    /// (config/mod.rs:517-520), so one malformed persona entry silently
    /// blanks EVERY subagents setting, toggles included. This port skips
    /// only the malformed entry, matching the per-key lenient shape the
    /// composition's `[subagents.toggle]` reader already established. Cost:
    /// a config that upstream would treat as "no subagents config at all"
    /// keeps its well-formed entries here.
    static func inlinePersonas(in configDocument: TOMLValue) -> [String: SubagentPersona] {
        guard let table = configDocument[path: ["subagents", "personas"]]?.table else { return [:] }
        var personas: [String: SubagentPersona] = [:]
        for (name, value) in table.pairs {
            guard let entryTable = value.table, let persona = persona(fromTable: entryTable) else { continue }
            personas[name] = persona
        }
        return personas
    }

    // MARK: - Strict field mapping

    /// Map one persona table to `SubagentPersona` with upstream's serde
    /// strictness: unknown keys at the persona level are ignored
    /// (`#[serde(default)]`, no `deny_unknown_fields` —
    /// subagent-resolution config.rs:61-101), but a known key with the
    /// wrong type fails the WHOLE persona, exactly as serde fails the whole
    /// `toml::from_str::<SubagentPersona>`. Returns `nil` for malformed.
    ///
    /// The `inherits`/`extends`/`parent` aliases and the tool allow/deny
    /// lists are this port's existing persona extensions (already decoded by
    /// `SubagentPersona.init(from:)` and consumed by `resolvePersona`);
    /// upstream ignores those keys, so accepting them diverges only where
    /// the port already diverged.
    static func persona(fromTable table: TOMLTable) -> SubagentPersona? {
        do {
            return SubagentPersona(
                instructions: try optionalString(table, "instructions"),
                description: try optionalString(table, "description"),
                instructionsFile: try optionalString(table, "instructions_file"),
                inputs: try ioFields(table, "inputs"),
                outputs: try ioFields(table, "outputs"),
                defaultIsolation: try optionalString(table, "default_isolation"),
                model: try optionalString(table, "model"),
                reasoningEffort: try optionalString(table, "reasoning_effort"),
                inherits: try optionalString(table, "inherits")
                    ?? optionalString(table, "extends")
                    ?? optionalString(table, "parent"),
                toolAllowlist: try optionalStringArray(table, "tool_allowlist"),
                toolDenylist: try optionalStringArray(table, "tool_denylist")
            )
        } catch {
            return nil
        }
    }

    private struct MalformedPersona: Error {}

    private static func optionalString(_ table: TOMLTable, _ key: String) throws -> String? {
        guard let value = table[key] else { return nil }
        guard let string = value.stringValue else { throw MalformedPersona() }
        return string
    }

    private static func optionalBool(_ table: TOMLTable, _ key: String) throws -> Bool? {
        guard let value = table[key] else { return nil }
        guard let bool = value.boolValue else { throw MalformedPersona() }
        return bool
    }

    private static func optionalStringArray(_ table: TOMLTable, _ key: String) throws -> [String]? {
        guard let value = table[key] else { return nil }
        guard let array = value.arrayValue else { throw MalformedPersona() }
        return try array.map {
            guard let string = $0.stringValue else { throw MalformedPersona() }
            return string
        }
    }

    /// `PersonaIOField` upstream is `deny_unknown_fields` with `name` and
    /// `description` required (subagent-resolution config.rs:104-125): an
    /// unknown or missing field inside one entry fails the whole persona.
    private static func ioFields(_ table: TOMLTable, _ key: String) throws -> [PersonaIOField] {
        guard let value = table[key] else { return [] }
        guard let array = value.arrayValue else { throw MalformedPersona() }
        let knownKeys: Set<String> = ["name", "io_type", "required", "description"]
        return try array.map { entry in
            guard let entryTable = entry.table,
                  entryTable.allKeys.allSatisfy({ knownKeys.contains($0) }),
                  let name = try optionalString(entryTable, "name"),
                  let description = try optionalString(entryTable, "description")
            else { throw MalformedPersona() }
            return PersonaIOField(
                name: name,
                ioType: try optionalString(entryTable, "io_type") ?? "file",
                required: try optionalBool(entryTable, "required") ?? false,
                description: description
            )
        }
    }
}
