// Builder.swift
//
// ToolRegistryBuilder + packs + finalize from
// `xai-grok-tools/src/registry/types.rs`.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes

// MARK: - Tool packs

/// A function that contributes registrations into a builder.
public typealias ToolPack = @Sendable (inout ToolRegistryBuilder) -> Void

private final class ToolPackStore: @unchecked Sendable {
    static let shared = ToolPackStore()
    private let lock = NSLock()
    private var packs: [ToolPack] = []

    func register(_ pack: @escaping ToolPack) {
        lock.lock()
        defer { lock.unlock() }
        packs.append(pack)
    }

    func snapshot() -> [ToolPack] {
        lock.lock()
        defer { lock.unlock() }
        return packs
    }

    /// Test-only: clear process-global packs.
    func resetForTests() {
        lock.lock()
        defer { lock.unlock() }
        packs.removeAll()
    }
}

/// Register an out-of-tree tool pack. Must run before the first
/// `ToolRegistryBuilder()` that should see it.
public func registerToolPack(_ pack: @escaping ToolPack) {
    ToolPackStore.shared.register(pack)
}

/// Test helper: clear process-global packs.
public func resetToolPacksForTests() {
    ToolPackStore.shared.resetForTests()
}

// MARK: - Entry

struct ToolEntry: Sendable {
    var spec: RegisteredToolSpec
    var handler: (any ToolHandler)?
}

// MARK: - Builder

public struct ToolRegistryBuilder: Sendable {
    private var tools: [String: ToolEntry] = [:]

    public init(registerBuiltins: Bool = true) {
        if registerBuiltins {
            for spec in BuiltinToolCatalog.fileTools {
                tools[spec.qualifiedId] = ToolEntry(spec: spec, handler: nil)
            }
            for pack in ToolPackStore.shared.snapshot() {
                var selfMut = self
                pack(&selfMut)
                self = selfMut
            }
        }
    }

    public mutating func register(spec: RegisteredToolSpec, handler: (any ToolHandler)? = nil) {
        tools[spec.qualifiedId] = ToolEntry(spec: spec, handler: handler)
    }

    public mutating func setHandler(qualifiedId: String, handler: any ToolHandler) {
        tools[qualifiedId]?.handler = handler
    }

    public func hasToolId(_ id: String) -> Bool {
        tools[id] != nil
    }

    public func knownToolIds() -> Set<String> {
        Set(tools.keys)
    }

    public func knownToolKinds() -> [String: ProductToolKind] {
        Dictionary(uniqueKeysWithValues: tools.map { ($0.key, $0.value.spec.kind) })
    }

    public func getToolsConfigRaw() -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (name, entry) in tools {
            out[name] = .object([
                "namespace": .string(entry.spec.namespace.rawValue),
                "id": .string(entry.spec.id),
                "kind": .string(entry.spec.kind.rawValue),
                "default_params": entry.spec.defaultParams,
                "input_schema": entry.spec.inputSchema,
            ])
        }
        return out
    }

    // MARK: Validate

    public func validateConfig(_ config: ToolServerConfig) -> [RequirementError] {
        var errors: [RequirementError] = []
        let presetName = config.behaviorPreset ?? "current"
        if lookupPreset(presetName) == nil {
            return [
                RequirementError(
                    tool: "(global)",
                    message: "unknown behavior_preset: \"\(presetName)\"",
                    fieldPath: "behavior_preset",
                    expected: "one of the registered behavior presets",
                    badValue: .string(presetName),
                    category: "behavior_preset"
                ),
            ]
        }

        var resolved: [(ToolEntry, String)] = []
        for toolConfig in config.tools {
            guard let entry = tools[toolConfig.id] else {
                errors.append(
                    RequirementError(
                        tool: toolConfig.id,
                        message: "not found in registry",
                        fieldPath: "id",
                        badValue: .string(toolConfig.id),
                        category: "tool_not_found"
                    )
                )
                continue
            }
            switch resolveVersion(
                presetName: presetName,
                fqToolId: toolConfig.id,
                override: toolConfig.behaviorVersion
            ) {
            case .failure(let message):
                errors.append(
                    RequirementError(
                        tool: toolConfig.id,
                        message: message.message,
                        fieldPath: "behavior_version",
                        badValue: .string(toolConfig.behaviorVersion ?? ""),
                        category: "behavior_version"
                    )
                )
                continue
            case .success:
                break
            }
            resolved.append((entry, toolConfig.resolveClientName(defaultId: entry.spec.id)))
        }
        if !errors.isEmpty { return errors }

        // Duplicate client names.
        var seen: [String: String] = [:]
        for (toolConfig, (_, clientName)) in zip(config.tools, resolved) {
            if let prev = seen[clientName] {
                errors.append(
                    RequirementError(
                        tool: toolConfig.id,
                        message:
                            "duplicate client_name \"\(clientName)\": already used by \(prev). Use name_override to give each tool a unique client-facing name.",
                        fieldPath: "name_override",
                        expected: "a unique client-facing tool name",
                        badValue: .string(clientName),
                        category: "duplicate_client_name"
                    )
                )
            } else {
                seen[clientName] = toolConfig.id
            }
        }
        if !errors.isEmpty { return errors }

        // Standard vs hashline file toolset mutual exclusion.
        let standard: Set<String> = [
            "GrokBuild:read_file", "GrokBuild:search_replace", "GrokBuild:grep",
        ]
        let hashline: Set<String> = [
            "GrokBuildHashline:hashline_read",
            "GrokBuildHashline:hashline_edit",
            "GrokBuildHashline:hashline_grep",
        ]
        let enabled = Set(config.tools.map(\.id))
        let hasStandard = !enabled.isDisjoint(with: standard)
        let hasHashline = !enabled.isDisjoint(with: hashline)
        if hasStandard && hasHashline {
            errors.append(
                RequirementError(
                    tool: "(file-toolset)",
                    message:
                        "mixed standard and hashline file tools are not allowed. Use either the standard bundle (read_file, search_replace, grep) or the hashline bundle (hashline_read, hashline_edit, hashline_grep), not both.",
                    fieldPath: "tools",
                    category: "file_toolset_conflict"
                )
            )
        }
        return errors
    }

    // MARK: Finalize

    public func finalize(
        config: ToolServerConfig,
        resources: ToolResources,
        options: FinalizeOptions = .unrestricted
    ) -> Result<FinalizedToolset, RequirementErrors> {
        // 1. Capability filter (deterministic drop by kind).
        var filtered = options.capabilityMode.filter(backfillKinds(config))

        // 2. Validate remaining config against catalog.
        let errors = validateConfig(filtered)
        if !errors.isEmpty { return .failure(RequirementErrors(errors)) }

        let presetName = filtered.behaviorPreset ?? "current"
        var finalized: [FinalizedTool] = []
        var clientNames: [String] = []

        for toolConfig in filtered.tools {
            guard let entry = tools[toolConfig.id] else { continue }
            let clientName = toolConfig.resolveClientName(defaultId: entry.spec.id)
            let visibility = listVisibility(
                clientName: clientName,
                kind: toolConfig.kind ?? entry.spec.kind,
                options: options
            )
            if visibility == .hidden { continue }

            let contract: String?
            switch resolveVersion(
                presetName: presetName,
                fqToolId: toolConfig.id,
                override: toolConfig.behaviorVersion
            ) {
            case .success(let v): contract = v
            case .failure: contract = nil
            }

            let description = toolConfig.descriptionOverride ?? entry.spec.description
            let def = ToolDescription(name: clientName, description: description)
                .withKind(entry.spec.kind.rawValue)
                .withNamespace(entry.spec.namespace.rawValue)
                .withArgumentsSchema(entry.spec.inputSchema)

            let reverseParams = reverseParamMap(toolConfig.paramsNameOverrides)

            finalized.append(
                FinalizedTool(
                    qualifiedId: toolConfig.id,
                    namespace: entry.spec.namespace,
                    id: entry.spec.id,
                    clientName: clientName,
                    kind: entry.spec.kind,
                    description: description,
                    definition: def,
                    inputSchema: entry.spec.inputSchema,
                    reverseParams: reverseParams,
                    contractVersion: contract,
                    visibility: visibility,
                    exposure: entry.spec.exposure,
                    handler: entry.handler
                )
            )
            clientNames.append(clientName)
        }

        // Deterministic order: sorted by client name.
        finalized.sort { $0.clientName < $1.clientName }

        let codeModeNs: [String: CodeModeToolNamespace]
        if options.emitCodeModeNamespaces {
            codeModeNs = codeModeNamespaceDescriptions(
                tools: finalized.map {
                    ($0.clientName, $0.kind, $0.description, $0.visibility)
                }
            )
        } else {
            codeModeNs = [:]
        }

        return .success(
            FinalizedToolset(
                tools: finalized,
                resources: resources,
                codeModeNamespaces: codeModeNs,
                options: options
            )
        )
    }

    /// Backfill `kind` from the catalog for capability filtering.
    private func backfillKinds(_ config: ToolServerConfig) -> ToolServerConfig {
        let kinds = knownToolKinds()
        let tools = config.tools.map { t -> ToolConfig in
            var copy = t
            if copy.kind == nil {
                copy.kind = kinds[t.id]
            }
            return copy
        }
        return ToolServerConfig(tools: tools, behaviorPreset: config.behaviorPreset)
    }
}

private func reverseParamMap(_ overrides: [String: String]?) -> [String: String] {
    guard let overrides else { return [:] }
    // canonical → client  becomes  client → canonical
    var rev: [String: String] = [:]
    for (canonical, client) in overrides {
        rev[client] = canonical
    }
    return rev
}
