// ConfigValidation.swift
//
// Open Grok — Swift port of `xai-grok-tools-api/src/config_validation.rs`.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime

/// Why a `ToolConfigEntry` is invalid.
public enum ToolConfigEntryErrorKind: Sendable, Hashable {
    /// Not valid JSON. Includes an explicitly-set empty string.
    case paramsJsonParse(error: String, raw: String)
    /// Valid JSON but not an object.
    case paramsJsonNotObject(value: JSONValue)
    /// `name_override` is not a valid `ToolId`.
    case nameOverrideInvalid(name: String, error: String)
}

/// Validation error for one entry in a tool-config list.
public struct ToolConfigEntryError: Error, Sendable, Hashable, CustomStringConvertible {
    public var index: Int
    public var toolId: String
    public var kind: ToolConfigEntryErrorKind

    public init(index: Int, toolId: String, kind: ToolConfigEntryErrorKind) {
        self.index = index
        self.toolId = toolId
        self.kind = kind
    }

    /// Request field path of the failing field, e.g. `tools[3].params_json`.
    public var fieldPath: String {
        switch kind {
        case .paramsJsonParse, .paramsJsonNotObject:
            return "tools[\(index)].params_json"
        case .nameOverrideInvalid:
            return "tools[\(index)].name_override"
        }
    }

    public var description: String {
        switch kind {
        case .paramsJsonParse(let error, _):
            return "\(toolId): \(fieldPath) failed to parse JSON: \(error)"
        case .paramsJsonNotObject:
            return "\(toolId): \(fieldPath) must be a JSON object"
        case .nameOverrideInvalid(let name, let error):
            return "\(toolId): \(fieldPath) is not a valid tool name (\(name.debugDescription)): \(error)"
        }
    }
}

/// Parse and validate a `params_json`, returning the decoded object (or
/// `nil` when unset).
public func parseParamsJson(
    index: Int,
    toolId: String,
    paramsJson: String?
) -> Result<[String: JSONValue]?, ToolConfigEntryError> {
    guard let raw = paramsJson else {
        return .success(nil)
    }
    let data = Data(raw.utf8)
    let value: JSONValue
    do {
        value = try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
        return .failure(ToolConfigEntryError(
            index: index,
            toolId: toolId,
            kind: .paramsJsonParse(error: String(describing: error), raw: raw)
        ))
    }
    switch value {
    case .object(let object):
        return .success(object)
    default:
        return .failure(ToolConfigEntryError(
            index: index,
            toolId: toolId,
            kind: .paramsJsonNotObject(value: value)
        ))
    }
}

/// Validates a `name_override` against the `ToolId` charset/length contract.
public func validateNameOverride(
    index: Int,
    toolId: String,
    nameOverride: String?
) -> Result<Void, ToolConfigEntryError> {
    guard let name = nameOverride else {
        return .success(())
    }
    do {
        _ = try ToolId(name)
        return .success(())
    } catch {
        return .failure(ToolConfigEntryError(
            index: index,
            toolId: toolId,
            kind: .nameOverrideInvalid(name: name, error: String(describing: error))
        ))
    }
}

/// Returns the first entry whose `id` is not in `allowedIds`, as
/// `(index, id)`, or `nil` when all ids are allowed.
public func firstUnknownToolId(
    entries: [ToolConfigEntry],
    allowedIds: Set<String>
) -> (index: Int, id: String)? {
    for (index, entry) in entries.enumerated() {
        if !allowedIds.contains(entry.id) {
            return (index, entry.id)
        }
    }
    return nil
}

/// Validate a full list of tool config entries (params + name override).
public func validateToolConfigEntries(
    _ entries: [ToolConfigEntry]
) -> [ToolConfigEntryError] {
    var errors: [ToolConfigEntryError] = []
    for (index, entry) in entries.enumerated() {
        if case .failure(let err) = parseParamsJson(
            index: index,
            toolId: entry.id,
            paramsJson: entry.paramsJson
        ) {
            errors.append(err)
        }
        if case .failure(let err) = validateNameOverride(
            index: index,
            toolId: entry.id,
            nameOverride: entry.nameOverride
        ) {
            errors.append(err)
        }
    }
    return errors
}
