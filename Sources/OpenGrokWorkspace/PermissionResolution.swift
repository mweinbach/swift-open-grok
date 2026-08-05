// PermissionResolution.swift
//
// Sources the permission rule engine. Ported from
// `xai-grok-workspace/src/permission/resolution.rs` (1394 L) and
// `xai-grok-workspace/src/permission/claude_settings.rs` (564 L).
//
// Until this existed the DSL in `PermissionRules.swift` and the evaluator in
// `PermissionPolicy.swift` were correct but had no input: nothing parsed
// `[permission]` out of config.toml and nothing read `.claude/settings.json`.
//
// Merge order (resolution.rs:495-534) — provenance display only; evaluation is
// always deny > ask > allow:
//   requirements → managed settings → managed defaultMode synthetics →
//   managed_config → config.toml → .claude settings
//
// Trust: only `systemRequirements` and `managedSettings` are admin tier
// (`is_admin_source`, resolution.rs:368-373). Project-scoped inputs
// (`.opengrok/config.toml` under cwd, project `.claude/settings*.json`) are
// gated on folder trust by the caller passing `projectTrusted: false`, which
// mirrors `claude_settings_paths_for_trust` (claude_settings.rs:390-396).

import Foundation
import OpenGrokConfig
import OpenGrokPaths

// MARK: - Skipped entries

/// A rule that was parsed but not applied, with the reason (surfaced to the
/// user so a typo in a deny rule is never silently a no-op).
public struct SkippedPermission: Sendable, Equatable, Hashable {
    public var rule: String
    public var reason: String

    public init(rule: String, reason: String) {
        self.rule = rule
        self.reason = reason
    }
}

// MARK: - Resolved result

/// Everything the live session needs to build a `PermissionHandle`.
public struct ResolvedPermissions: Sendable, Equatable {
    public var config: PermissionConfig
    /// Effective `defaultMode` after managed-outranks-user precedence.
    public var defaultMode: DefaultPermissionMode
    /// Parsed from `.claude/settings.json`; extra roots for `allowedRoots`.
    public var additionalDirectories: [String]
    /// Non-nil when managed policy forbids bypassPermissions/YOLO.
    public var yoloPinReason: String?
    /// True when the user asked for always-approve **and** no pin vetoed it.
    /// Evaluated after deny/ask by the engine, matching Rust's ordering, so it
    /// never overrides an explicit deny rule.
    public var alwaysApprove: Bool
    public var skipped: [SkippedPermission]
    /// Files that contributed, for `/permissions`-style inspection.
    public var sources: [String]

    public init(
        config: PermissionConfig = PermissionConfig(),
        defaultMode: DefaultPermissionMode = .default,
        additionalDirectories: [String] = [],
        yoloPinReason: String? = nil,
        alwaysApprove: Bool = false,
        skipped: [SkippedPermission] = [],
        sources: [String] = []
    ) {
        self.config = config
        self.defaultMode = defaultMode
        self.additionalDirectories = additionalDirectories
        self.yoloPinReason = yoloPinReason
        self.alwaysApprove = alwaysApprove
        self.skipped = skipped
        self.sources = sources
    }
}

// MARK: - YOLO pin reasons (resolution.rs:949-952)

public let yoloPinReasonRequirementsMessage =
    "always-approve disabled by managed policy "
    + "([ui] disable_bypass_permissions_mode = true in requirements.toml)"
public let yoloPinReasonLegacyYoloMessage =
    "always-approve disabled by managed policy "
    + "([ui] yolo = false in requirements.toml)"

/// Pure core of `resolve_yolo_policy_block` (resolution.rs:994-1010).
///
/// Only root-owned `requirements.toml` layers are consulted — a vendor
/// `managed-settings.json` deliberately cannot arm the pin (resolution.rs:954).
/// A non-bool value fails open (`requirements_lock_bool`, resolution.rs:976).
public func resolveYoloPolicyBlock(requirementsLayers: [TOMLValue]) -> String? {
    for layer in requirementsLayers {
        if case .boolean(let disabled)? =
            layer[path: ["ui", "disable_bypass_permissions_mode"]], disabled {
            return yoloPinReasonRequirementsMessage
        }
        if case .boolean(let yolo)? = layer[path: ["ui", "yolo"]], yolo == false {
            return yoloPinReasonLegacyYoloMessage
        }
    }
    return nil
}

// MARK: - TOML `[permission]` (resolution.rs:99-145)

/// Parse a `[permission]` table.
///
/// Two accepted shapes, compact wins: if **any** of `deny`/`allow`/`ask` is
/// present the verbose `[[permission.rules]]` form is not attempted at all
/// (`found_compact` short-circuit, resolution.rs:137).
public func parseTOMLPermissionSection(
    _ permission: TOMLValue,
    source: PermissionRuleSource
) -> (rules: [PermissionRule], promptPolicy: PromptPolicy?, skipped: [SkippedPermission]) {
    var rules: [PermissionRule] = []
    var skipped: [SkippedPermission] = []
    var foundCompact = false

    // Deny first so provenance ordering matches Rust; evaluation is
    // order-independent regardless.
    for (action, key) in [
        (RuleAction.deny, "deny"),
        (RuleAction.allow, "allow"),
        (RuleAction.ask, "ask"),
    ] {
        guard let value = permission[key] else { continue }
        guard case .array(let items) = value else {
            skipped.append(SkippedPermission(
                rule: "permission.\(key)",
                reason: "expected an array of rule strings"
            ))
            continue
        }
        foundCompact = true
        for (index, item) in items.enumerated() {
            guard case .string(let text) = item else {
                skipped.append(SkippedPermission(
                    rule: "permission.\(key)[\(index)]",
                    reason: "expected string"
                ))
                continue
            }
            do {
                rules.append(try parsePermissionRule(text, action: action, source: source))
            } catch {
                skipped.append(SkippedPermission(
                    rule: text,
                    reason: String(describing: error)
                ))
            }
        }
    }

    if foundCompact { return (rules, nil, skipped) }

    // Verbose form: `[[permission.rules]]` + `permission.prompt_policy`.
    // Field names are snake_case as written — there is no `rename_all` on the
    // Rust `PermissionConfig` / `PermissionRule` structs (types.rs:313-351).
    var promptPolicy: PromptPolicy?
    if case .string(let raw)? = permission["prompt_policy"] {
        if let parsed = PromptPolicy(rawValue: raw) {
            promptPolicy = parsed
        } else {
            skipped.append(SkippedPermission(
                rule: "permission.prompt_policy=\(raw)",
                reason: "unrecognized value; treated as ask"
            ))
        }
    }
    if case .array(let entries)? = permission["rules"] {
        for (index, entry) in entries.enumerated() {
            guard case .table = entry else {
                skipped.append(SkippedPermission(
                    rule: "permission.rules[\(index)]",
                    reason: "expected a table"
                ))
                continue
            }
            guard case .string(let actionRaw)? = entry["action"],
                  let action = RuleAction(rawValue: actionRaw) else {
                skipped.append(SkippedPermission(
                    rule: "permission.rules[\(index)]",
                    reason: "missing or unrecognized `action` (allow/deny/ask)"
                ))
                continue
            }
            // Rust's ToolFilter is `rename_all = "lowercase"`, which collapses
            // WebFetch → "webfetch" and WebSearch → "websearch". Swift's raw
            // values are snake_case, so both spellings are accepted here.
            var tool = ToolFilter.any
            if case .string(let toolRaw)? = entry["tool"] {
                guard let parsed = parseToolFilterRawValue(toolRaw) else {
                    skipped.append(SkippedPermission(
                        rule: "permission.rules[\(index)].tool=\(toolRaw)",
                        reason: "unrecognized tool filter"
                    ))
                    continue
                }
                tool = parsed
            }
            var pattern: String?
            if case .string(let p)? = entry["pattern"], !p.isEmpty { pattern = p }
            var mode = PatternMode.glob
            if case .string(let m)? = entry["pattern_mode"], let parsed = PatternMode(rawValue: m) {
                mode = parsed
            }
            rules.append(PermissionRule(
                action: action,
                tool: tool,
                pattern: pattern,
                patternMode: mode,
                source: source
            ))
        }
    }
    return (rules, promptPolicy, skipped)
}

/// Accept both Swift's snake_case raw values and Rust's `rename_all =
/// "lowercase"` spellings (`webfetch` / `websearch`, types.rs:369-381).
func parseToolFilterRawValue(_ raw: String) -> ToolFilter? {
    switch raw {
    case "webfetch": return .webFetch
    case "websearch": return .webSearch
    default: return ToolFilter(rawValue: raw)
    }
}

// MARK: - Claude-compatible settings JSON (claude_settings.rs)

/// One parsed `.claude/settings.json` (or managed-settings.json).
public struct ClaudeSettingsPermissions: Sendable, Equatable {
    public var allow: [String] = []
    public var deny: [String] = []
    public var ask: [String] = []
    /// Canonical key is `permissions.defaultMode`; a root-level `defaultMode`
    /// is the grok-legacy fallback used **only** when the nested key is absent
    /// (`extract_default_mode`, claude_settings.rs:147-179).
    public var defaultMode: String?
    /// True when the file claimed the defaultMode slot, even with an
    /// unrecognized value — claiming is what makes "most specific file wins".
    public var claimsDefaultMode: Bool = false
    public var additionalDirectories: [String] = []
    public var skipped: [SkippedPermission] = []

    public init() {}

    public var isEmpty: Bool {
        allow.isEmpty && deny.isEmpty && ask.isEmpty
            && !claimsDefaultMode && additionalDirectories.isEmpty
    }
}

/// Tolerant JSON parse matching `load_claude_settings` (claude_settings.rs:91).
/// A malformed array element is skipped with a warning, never fatal.
public func parseClaudeSettingsJSON(_ data: Data) -> ClaudeSettingsPermissions? {
    guard let root = try? JSONSerialization.jsonObject(with: data),
          let object = root as? [String: Any] else { return nil }
    var out = ClaudeSettingsPermissions()

    let permissions = object["permissions"] as? [String: Any]

    func extractStringArray(_ container: [String: Any]?, _ key: String, label: String) -> [String] {
        guard let raw = container?[key] else { return [] }
        guard let array = raw as? [Any] else {
            out.skipped.append(SkippedPermission(
                rule: label, reason: "expected an array of rule strings"
            ))
            return []
        }
        var values: [String] = []
        for (index, element) in array.enumerated() {
            if let text = element as? String {
                values.append(text)
            } else {
                out.skipped.append(SkippedPermission(
                    rule: "\(label)[\(index)]", reason: "expected string"
                ))
            }
        }
        return values
    }

    out.allow = extractStringArray(permissions, "allow", label: "permissions.allow")
    out.deny = extractStringArray(permissions, "deny", label: "permissions.deny")
    out.ask = extractStringArray(permissions, "ask", label: "permissions.ask")

    // Nested-first, and a present-but-non-string nested value does *not*
    // revive the root-level legacy key (claude_settings.rs:147-179).
    if let nested = permissions?["defaultMode"] {
        out.claimsDefaultMode = true
        if let text = nested as? String {
            out.defaultMode = text
        } else {
            out.skipped.append(SkippedPermission(
                rule: "permissions.defaultMode", reason: "expected string"
            ))
        }
    } else if let legacy = object["defaultMode"] {
        out.claimsDefaultMode = true
        if let text = legacy as? String { out.defaultMode = text }
    }

    if let nested = permissions?["additionalDirectories"] as? [Any] {
        out.additionalDirectories = nested.compactMap { $0 as? String }
    } else if let legacy = object["additionalDirectories"] as? [Any] {
        out.additionalDirectories = legacy.compactMap { $0 as? String }
    }

    return out
}

extension ClaudeSettingsPermissions {
    /// `ParsedPermissions::into_permission_config` (claude_settings.rs:53-71).
    func rules(source: PermissionRuleSource) -> (rules: [PermissionRule], skipped: [SkippedPermission]) {
        var out: [PermissionRule] = []
        var bad: [SkippedPermission] = []
        for (action, list, label) in [
            (RuleAction.deny, deny, "deny"),
            (RuleAction.allow, allow, "allow"),
            (RuleAction.ask, ask, "ask"),
        ] {
            for text in list {
                do {
                    out.append(try parsePermissionRule(text, action: action, source: source))
                } catch {
                    bad.append(SkippedPermission(
                        rule: "permissions.\(label): \(text)",
                        reason: String(describing: error)
                    ))
                }
            }
        }
        return (out, bad)
    }
}

// MARK: - Settings path discovery (claude_settings.rs:354-458)

/// Repo root = nearest ancestor holding a `.git`, dropped when it is `$HOME`
/// (`find_repo_root`, claude_settings.rs:447-458).
func claudeRepoRoot(cwd: URL, home: URL?) -> URL? {
    var dir = cwd.standardizedFileURL
    for _ in 0..<64 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
            if let home, dir.standardizedFileURL.path == home.standardizedFileURL.path {
                return nil
            }
            return dir
        }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }
    return nil
}

/// Project `.claude` settings, cwd-first (most specific first), walking up to
/// the repo root (`collect_project_claude_paths`, claude_settings.rs:417-444).
public func projectClaudeSettingsPaths(cwd: URL, home: URL? = nil) -> [URL] {
    let root = claudeRepoRoot(cwd: cwd, home: home)
    var out: [URL] = []
    var dir = cwd.standardizedFileURL
    for _ in 0..<64 {
        out.append(dir.appendingPathComponent(".claude/settings.local.json"))
        out.append(dir.appendingPathComponent(".claude/settings.json"))
        if let root, dir.path == root.standardizedFileURL.path { break }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
        if root == nil { break }
    }
    return out
}

/// `~/.claude/settings.local.json` then `~/.claude/settings.json`
/// (`global_claude_settings_paths`, claude_settings.rs:374-382).
public func globalClaudeSettingsPaths(home: URL) -> [URL] {
    [
        home.appendingPathComponent(".claude/settings.local.json"),
        home.appendingPathComponent(".claude/settings.json"),
    ]
}

/// The single choke point: untrusted folders see global settings only
/// (`claude_settings_paths_for_trust`, claude_settings.rs:390-396).
public func claudeSettingsPathsForTrust(
    cwd: URL,
    home: URL,
    projectTrusted: Bool
) -> [URL] {
    let global = globalClaudeSettingsPaths(home: home)
    guard projectTrusted else { return global }
    return projectClaudeSettingsPaths(cwd: cwd, home: home) + global
}

// MARK: - Full resolution

/// Inputs the caller assembles; every field is optional so a test can drive
/// one layer in isolation without touching the developer's real home.
public struct PermissionResolutionInputs: Sendable {
    /// TOML layers carrying a `[permission]` table, **each kept separate and
    /// tagged with its trust tier**, in Rust's collection order.
    ///
    /// Deliberately not the merged `AuthorityComposition.effective()` document:
    /// `deepMergeTOML` replaces arrays rather than concatenating them, so a
    /// user `config.toml` with `[permission] deny = [...]` would silently wipe
    /// a `managed_config.toml`'s deny list. Rust collects each layer's rules
    /// and concatenates (resolution.rs:498-527); evaluation stays
    /// order-independent because deny > ask > allow.
    public var permissionLayers: [(document: TOMLValue, source: PermissionRuleSource)]
    /// Requirements layers, consulted **only** for the YOLO pin. Trust tiering
    /// for their rules comes from `permissionLayers`.
    public var requirementsLayers: [TOMLValue]
    /// Parsed `managed-settings.json`, admin tier.
    public var managedSettings: ClaudeSettingsPermissions?
    public var cwd: URL
    public var home: URL
    public var projectTrusted: Bool
    /// `--allow` / `--allowedTools`, as typed. Left unparsed by the CLI so a
    /// bad rule surfaces as a `SkippedPermission` here, alongside failures from
    /// config.toml and `.claude/settings.json`, rather than in its own channel.
    public var cliAllowRules: [String]
    /// `--deny` / `--disallowedTools`, as typed.
    public var cliDenyRules: [String]
    /// `--permission-mode`. Outranks user files, but never managed settings.
    public var cliMode: DefaultPermissionMode?
    /// `--always-approve` / `--yolo` / `--dangerously-skip-permissions`. A
    /// request, not a resolved state — the YOLO pin can still veto it.
    public var cliAlwaysApprove: Bool
    /// Injectable so tests never read the developer's `~/.claude`.
    public var readFile: @Sendable (URL) -> Data?

    public init(
        permissionLayers: [(document: TOMLValue, source: PermissionRuleSource)] = [],
        requirementsLayers: [TOMLValue] = [],
        managedSettings: ClaudeSettingsPermissions? = nil,
        cwd: URL,
        home: URL,
        projectTrusted: Bool = true,
        cliAllowRules: [String] = [],
        cliDenyRules: [String] = [],
        cliMode: DefaultPermissionMode? = nil,
        cliAlwaysApprove: Bool = false,
        readFile: @escaping @Sendable (URL) -> Data? = { try? Data(contentsOf: $0) }
    ) {
        self.permissionLayers = permissionLayers
        self.requirementsLayers = requirementsLayers
        self.managedSettings = managedSettings
        self.cwd = cwd
        self.home = home
        self.projectTrusted = projectTrusted
        self.cliAllowRules = cliAllowRules
        self.cliDenyRules = cliDenyRules
        self.cliMode = cliMode
        self.cliAlwaysApprove = cliAlwaysApprove
        self.readFile = readFile
    }
}

/// Resolve the live permission policy from every source Rust consults.
///
/// `defaultMode` precedence (resolution.rs:479-484, 615-623): managed settings
/// outrank every user file; among user files the most specific one that
/// *claims* the key wins, even when its value is unrecognized.
public func resolvePermissions(_ inputs: PermissionResolutionInputs) -> ResolvedPermissions {
    var rules: [PermissionRule] = []
    var skipped: [SkippedPermission] = []
    var sources: [String] = []
    var promptPolicy: PromptPolicy?
    var additionalDirectories: [String] = []

    let yoloPinReason = resolveYoloPolicyBlock(requirementsLayers: inputs.requirementsLayers)

    // 1. Managed settings JSON — admin tier, and it owns defaultMode outright.
    var managedDefaultMode: String?
    if let managed = inputs.managedSettings {
        let parsed = managed.rules(source: .managedSettings)
        rules.append(contentsOf: parsed.rules)
        skipped.append(contentsOf: parsed.skipped)
        skipped.append(contentsOf: managed.skipped)
        if managed.claimsDefaultMode { managedDefaultMode = managed.defaultMode }
        additionalDirectories.append(contentsOf: managed.additionalDirectories)
        sources.append("managed-settings.json")
    }

    // 2. Every TOML layer carrying `[permission]`, each with its own trust
    //    tier. Requirements come first, then managed_config, then user config,
    //    then project config — the caller assembles that order, and a project
    //    layer is simply absent when the folder is untrusted.
    for layer in inputs.permissionLayers {
        guard let permission = layer.document["permission"] else { continue }
        let parsed = parseTOMLPermissionSection(permission, source: layer.source)
        rules.append(contentsOf: parsed.rules)
        skipped.append(contentsOf: parsed.skipped)
        if let p = parsed.promptPolicy { promptPolicy = p }
        sources.append("\(layer.source.rawValue) [permission]")
    }

    // 3. `.claude` settings — untrusted `settings` tier, most specific first.
    var userDefaultMode: String?
    var userDefaultModeClaimed = false
    for path in claudeSettingsPathsForTrust(
        cwd: inputs.cwd, home: inputs.home, projectTrusted: inputs.projectTrusted
    ) {
        guard let data = inputs.readFile(path),
              let parsedSettings = parseClaudeSettingsJSON(data) else { continue }
        let parsed = parsedSettings.rules(source: .settings)
        rules.append(contentsOf: parsed.rules)
        skipped.append(contentsOf: parsed.skipped)
        skipped.append(contentsOf: parsedSettings.skipped)
        additionalDirectories.append(contentsOf: parsedSettings.additionalDirectories)
        if parsedSettings.claimsDefaultMode && !userDefaultModeClaimed {
            userDefaultModeClaimed = true
            userDefaultMode = parsedSettings.defaultMode
        }
        sources.append(path.path)
    }

    // 4. CLI `--allow` / `--deny`. Their own tier, above every user file
    //    (`RequirementSource::Cli`), but deliberately NOT admin tier: a user's
    //    own flag must not smuggle a catch-all allow past an admin YOLO pin.
    for (action, list) in [
        (RuleAction.deny, inputs.cliDenyRules),
        (RuleAction.allow, inputs.cliAllowRules),
    ] {
        for text in list {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            do {
                rules.append(try parsePermissionRule(trimmed, action: action, source: .cli))
            } catch {
                skipped.append(SkippedPermission(
                    rule: trimmed,
                    reason: String(describing: error)
                ))
            }
        }
    }
    if !inputs.cliAllowRules.isEmpty || !inputs.cliDenyRules.isEmpty {
        sources.append("command line")
    }

    // Managed wins; then the CLI flag; user files only fill in when both left
    // the slot open (resolution.rs:479-484).
    let rawDefaultMode = managedDefaultMode ?? inputs.cliMode?.rawValue ?? userDefaultMode
    var defaultMode = DefaultPermissionMode.default
    if let raw = rawDefaultMode {
        let parsed = DefaultPermissionMode(parsing: raw)
        if parsed == .default && raw != "default" {
            skipped.append(SkippedPermission(
                rule: "defaultMode=\(raw)",
                reason: "unrecognized value; treated as default"
            ))
        }
        defaultMode = parsed
    }

    var config = PermissionConfig(rules: rules, promptPolicy: promptPolicy ?? .ask)

    // `bypassPermissions` cannot arm itself past an admin pin
    // (`synthetic_rules_for_default_mode`, resolution.rs:30-71).
    if defaultMode == .bypassPermissions, let reason = yoloPinReason {
        skipped.append(SkippedPermission(rule: "defaultMode=bypassPermissions", reason: reason))
    } else {
        var withMode = config
        applyDefaultMode(defaultMode, to: &withMode)
        // `applyDefaultMode` overwrites promptPolicy; an explicit
        // `prompt_policy` in config outranks a mode that has no opinion.
        if let explicit = promptPolicy, defaultMode.effects.promptPolicy == .ask {
            withMode.promptPolicy = explicit
        }
        config = withMode
    }

    // Under the pin, drop untrusted catch-all Allow rules before they are ever
    // compiled (`drop_untrusted_catchall_allows`, resolution.rs:377-406).
    if yoloPinReason != nil {
        let before = config.rules
        config.rules = clampRulesForYoloPin(before)
        for rule in before where !config.rules.contains(rule) {
            skipped.append(SkippedPermission(
                rule: "allow \(rule.pattern ?? "*") (catch-all)",
                reason: yoloPinReason ?? "yolo pinned"
            ))
        }
    }

    // `--yolo` is a request; an admin pin vetoes it, and the veto is reported
    // rather than silently applied (`yolo_disabled_by_policy`, resolution.rs:963).
    var alwaysApprove = inputs.cliAlwaysApprove
    if alwaysApprove, let reason = yoloPinReason {
        alwaysApprove = false
        skipped.append(SkippedPermission(rule: "--always-approve", reason: reason))
    }

    return ResolvedPermissions(
        config: config,
        defaultMode: defaultMode,
        additionalDirectories: additionalDirectories,
        yoloPinReason: yoloPinReason,
        alwaysApprove: alwaysApprove,
        skipped: skipped,
        sources: sources
    )
}
