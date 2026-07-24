// Versions.swift
//
// Behavior presets and version-managed tools from
// `xai-grok-tools/src/versions.rs`.

import Foundation

public enum BehaviorLifecycle: String, Codable, Sendable, Hashable {
    case active
    case deprecated
    case removed
}

public struct VersionLifecycle: Sendable, Hashable, Equatable {
    public var version: String
    public var lifecycle: BehaviorLifecycle
    public var replacement: String?
    public var summary: String

    public init(
        version: String,
        lifecycle: BehaviorLifecycle = .active,
        replacement: String? = nil,
        summary: String = ""
    ) {
        self.version = version
        self.lifecycle = lifecycle
        self.replacement = replacement
        self.summary = summary
    }
}

public struct ToolVersionEntry: Sendable, Hashable, Equatable {
    public var fqToolId: String
    public var versions: [VersionLifecycle]

    public init(fqToolId: String, versions: [VersionLifecycle]) {
        self.fqToolId = fqToolId
        self.versions = versions
    }
}

public struct PresetEntry: Sendable, Hashable, Equatable {
    public var name: String
    public var lifecycle: BehaviorLifecycle
    /// Per-tool default contract version for this preset.
    public var toolDefaults: [String: String]

    public init(
        name: String,
        lifecycle: BehaviorLifecycle = .active,
        toolDefaults: [String: String] = [:]
    ) {
        self.name = name
        self.lifecycle = lifecycle
        self.toolDefaults = toolDefaults
    }
}

/// Fully-qualified IDs that accept `behavior_version` overrides.
public let managedToolIds: Set<String> = [
    "GrokBuild:run_terminal_cmd",
    "GrokBuild:read_file",
    "GrokBuild:search_replace",
    "GrokBuild:list_dir",
    "GrokBuild:grep",
    "GrokBuild:kill_task",
    "GrokBuild:get_task_output",
]

private let currentVersion = VersionLifecycle(version: "current")
private let legacyBash = VersionLifecycle(
    version: "legacy-0.4.10", replacement: "current",
    summary: "Trailing-only & detection, legacy error text for background operator"
)
private let legacyRead = VersionLifecycle(
    version: "legacy-0.4.10", replacement: "current",
    summary: "No gitignore enforcement, generic error text"
)
private let legacySearchReplace = VersionLifecycle(
    version: "legacy-0.4.10", replacement: "current",
    summary: "No gitignore enforcement, structured errors downgraded"
)
private let legacyListDir = VersionLifecycle(
    version: "legacy-0.4.10", replacement: "current",
    summary: "Depth-threshold rendering, generic error text"
)
private let legacyKillTask = VersionLifecycle(
    version: "legacy-0.4.10", replacement: "current",
    summary: "Simple not-found text"
)
private let legacyTaskOutput = VersionLifecycle(
    version: "legacy-0.4.10", replacement: "current",
    summary: "Simple not-found text"
)

public let toolVersionRegistry: [ToolVersionEntry] = [
    ToolVersionEntry(fqToolId: "GrokBuild:run_terminal_cmd", versions: [currentVersion, legacyBash]),
    ToolVersionEntry(fqToolId: "GrokBuild:read_file", versions: [currentVersion, legacyRead]),
    ToolVersionEntry(fqToolId: "GrokBuild:search_replace", versions: [currentVersion, legacySearchReplace]),
    ToolVersionEntry(fqToolId: "GrokBuild:list_dir", versions: [currentVersion, legacyListDir]),
    ToolVersionEntry(fqToolId: "GrokBuild:grep", versions: [currentVersion]),
    ToolVersionEntry(fqToolId: "GrokBuild:kill_task", versions: [currentVersion, legacyKillTask]),
    ToolVersionEntry(fqToolId: "GrokBuild:get_task_output", versions: [currentVersion, legacyTaskOutput]),
]

public let behaviorPresets: [PresetEntry] = [
    PresetEntry(name: "current"),
    PresetEntry(
        name: "legacy-0.4.10",
        toolDefaults: [
            "GrokBuild:run_terminal_cmd": "legacy-0.4.10",
            "GrokBuild:read_file": "legacy-0.4.10",
            "GrokBuild:search_replace": "legacy-0.4.10",
            "GrokBuild:get_task_output": "legacy-0.4.10",
            "GrokBuild:kill_task": "legacy-0.4.10",
            "GrokBuild:list_dir": "legacy-0.4.10",
        ]
    ),
]

public func lookupPreset(_ name: String) -> PresetEntry? {
    behaviorPresets.first { $0.name == name }
}

public func isVersionManaged(_ fqToolId: String) -> Bool {
    managedToolIds.contains(fqToolId)
}

public func isLegacyContract(_ contractVersion: String?) -> Bool {
    contractVersion == "legacy-0.4.10"
}

/// Resolve contract version for a managed tool. Unmanaged tools return `nil`.
public func resolveVersion(
    presetName: String,
    fqToolId: String,
    override: String?
) -> Result<String?, String> {
    guard isVersionManaged(fqToolId) else {
        if let override, !override.isEmpty {
            return .failure(
                "behavior_version is only valid for version-managed tools; \(fqToolId) is unmanaged"
            )
        }
        return .success(nil)
    }
    guard let preset = lookupPreset(presetName) else {
        return .failure("unknown behavior_preset: \"\(presetName)\"")
    }
    let entry = toolVersionRegistry.first { $0.fqToolId == fqToolId }
    let supported = Set(entry?.versions.map(\.version) ?? ["current"])
    if let override {
        guard supported.contains(override) else {
            return .failure(
                "unsupported behavior_version \"\(override)\" for \(fqToolId); supported: \(supported.sorted())"
            )
        }
        return .success(override)
    }
    if let presetDefault = preset.toolDefaults[fqToolId] {
        return .success(presetDefault)
    }
    return .success("current")
}
