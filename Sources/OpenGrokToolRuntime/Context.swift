// Context.swift
//
// Open Grok — Swift port of `xai-tool-runtime/src/context.rs`.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol

/// Open typed-extension store keyed by `ObjectIdentifier` (type).
///
/// Mirrors Rust `TypedExtensions`. Values are stored as type-erased
/// `Sendable` boxes for actor-safe sharing.
public final class TypedExtensions: @unchecked Sendable {
    private var map: [ObjectIdentifier: any Sendable] = [:]
    private let lock = NSLock()

    public init() {}

    public func insert<T: Sendable>(_ value: T) {
        lock.lock()
        defer { lock.unlock() }
        map[ObjectIdentifier(T.self)] = value
    }

    public func get<T: Sendable>(_ type: T.Type = T.self) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return map[ObjectIdentifier(type)] as? T
    }

    public func contains<T: Sendable>(_ type: T.Type = T.self) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return map[ObjectIdentifier(type)] != nil
    }

    @discardableResult
    public func remove<T: Sendable>(_ type: T.Type = T.self) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return map.removeValue(forKey: ObjectIdentifier(type)) as? T
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return map.count
    }

    public var isEmpty: Bool {
        count == 0
    }

    /// Copy entries from `defaults` that are not already present in `self`.
    public func mergeDefaults(from defaults: TypedExtensions) {
        defaults.lock.lock()
        let snapshot = defaults.map
        defaults.lock.unlock()
        lock.lock()
        defer { lock.unlock() }
        for (key, value) in snapshot {
            if map[key] == nil {
                map[key] = value
            }
        }
    }
}

/// Per-call context.
public struct ToolCallContext: Sendable {
    public var callId: ToolCallId
    public var extensions: TypedExtensions

    public init(callId: ToolCallId = ToolCallId.newV7(), extensions: TypedExtensions = TypedExtensions()) {
        self.callId = callId
        self.extensions = extensions
    }

    public mutating func insert<T: Sendable>(_ value: T) {
        extensions.insert(value)
    }

    public func get<T: Sendable>(_ type: T.Type = T.self) -> T? {
        extensions.get(type)
    }
}

/// Per-turn context consumed by `Tool.shouldList`.
public struct ListToolsContext: Sendable {
    public var extensions: TypedExtensions

    public init(extensions: TypedExtensions = TypedExtensions()) {
        self.extensions = extensions
    }
}

/// Working directory for relative path resolution.
public struct Cwd: Sendable, Hashable {
    public var path: String
    public init(_ path: String) { self.path = path }
}

/// Opaque behaviour version. Tools that branch on this MUST treat
/// unknown values as a hard error.
public struct BehaviorVersion: Sendable, Hashable {
    public var value: String
    public init(_ value: String) { self.value = value }
}

/// Distributed-trace correlation context (e.g. W3C `traceparent`).
public struct TraceContext: Sendable, Hashable {
    public var value: String
    public init(_ value: String) { self.value = value }
}

/// Session ID context — identifies which hub session this call belongs to.
public struct SessionContext: Sendable, Hashable {
    public var value: String
    public init(_ value: String) { self.value = value }
}

/// Cooperative-cancellation handle for the current tool call.
///
/// Tools MAY poll `isCancelled` for graceful shutdown; the dispatcher
/// also hard-cancels by abandoning the call task when it fires.
public final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    public func cancel() {
        lock.lock()
        _isCancelled = true
        let waiting = continuations
        continuations.removeAll()
        lock.unlock()
        for cont in waiting.values {
            cont.resume()
        }
    }

    /// Suspend until cancelled (or return immediately if already cancelled).
    ///
    /// Also returns when the awaiting task is cancelled so dispatch races
    /// that `cancelAll()` child watchers do not hang the task group.
    public func waitUntilCancelled() async {
        if isCancelled || Task.isCancelled { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock()
                // Re-check under the lock so a cancel that races registration
                // cannot leave this continuation stranded.
                if _isCancelled || Task.isCancelled {
                    lock.unlock()
                    cont.resume()
                    return
                }
                continuations[id] = cont
                lock.unlock()
            }
        } onCancel: { [self] in
            lock.lock()
            let cont = continuations.removeValue(forKey: id)
            lock.unlock()
            cont?.resume()
        }
    }
}

/// Per-user feature-flag bag attached as a `ToolCallContext` extension.
public struct WorkspaceViewerContext: Codable, Sendable, Hashable {
    public var streamToolProgress: Bool

    private enum CodingKeys: String, CodingKey {
        case streamToolProgress = "stream_tool_progress"
    }

    public init(streamToolProgress: Bool = false) {
        self.streamToolProgress = streamToolProgress
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.streamToolProgress = try c.decodeIfPresent(Bool.self, forKey: .streamToolProgress) ?? false
    }
}

/// Per-tool configuration entry (shared wire shape used by
/// `session.bind` metadata and tools-api finalize config).
///
/// Mirrors Rust `xai_grok_tools_api::ToolConfigEntry`. Defined here so
/// `OpenGrokToolRuntime` does not depend on `OpenGrokToolsAPI` (SwiftPM
/// layering places ToolsAPI above Runtime).
public struct ToolConfigEntry: Codable, Sendable, Hashable {
    public var id: String
    public var paramsJson: String?
    public var nameOverride: String?
    public var paramsNameOverrides: [String: String]
    public var behaviorVersion: String?
    public var descriptionOverride: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case paramsJson = "params_json"
        case nameOverride = "name_override"
        case paramsNameOverrides = "params_name_overrides"
        case behaviorVersion = "behavior_version"
        case descriptionOverride = "description_override"
    }

    public init(
        id: String,
        paramsJson: String? = nil,
        nameOverride: String? = nil,
        paramsNameOverrides: [String: String] = [:],
        behaviorVersion: String? = nil,
        descriptionOverride: String? = nil
    ) {
        self.id = id
        self.paramsJson = paramsJson
        self.nameOverride = nameOverride
        self.paramsNameOverrides = paramsNameOverrides
        self.behaviorVersion = behaviorVersion
        self.descriptionOverride = descriptionOverride
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `id` is required — missing id must fail (not default to "").
        self.id = try c.decode(String.self, forKey: .id)
        self.paramsJson = try c.decodeIfPresent(String.self, forKey: .paramsJson)
        self.nameOverride = try c.decodeIfPresent(String.self, forKey: .nameOverride)
        // Map field is not Optional: explicit `null` is rejected (omit the
        // key or send `{}`). `decodeIfPresent` would coerce null → nil.
        if c.contains(.paramsNameOverrides) {
            if try c.decodeNil(forKey: .paramsNameOverrides) {
                throw DecodingError.valueNotFound(
                    [String: String].self,
                    DecodingError.Context(
                        codingPath: c.codingPath + [CodingKeys.paramsNameOverrides],
                        debugDescription: "params_name_overrides must be an object; null is not allowed"
                    )
                )
            }
            self.paramsNameOverrides = try c.decode([String: String].self, forKey: .paramsNameOverrides)
        } else {
            self.paramsNameOverrides = [:]
        }
        self.behaviorVersion = try c.decodeIfPresent(String.self, forKey: .behaviorVersion)
        self.descriptionOverride = try c.decodeIfPresent(String.self, forKey: .descriptionOverride)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(paramsJson, forKey: .paramsJson)
        try c.encodeIfPresent(nameOverride, forKey: .nameOverride)
        if !paramsNameOverrides.isEmpty {
            try c.encode(paramsNameOverrides, forKey: .paramsNameOverrides)
        }
        try c.encodeIfPresent(behaviorVersion, forKey: .behaviorVersion)
        try c.encodeIfPresent(descriptionOverride, forKey: .descriptionOverride)
    }
}

/// Wire shape of the Computer Hub `session.bind` metadata.
public struct WorkspaceBindMetadata: Codable, Sendable, Hashable {
    public var preset: String?
    public var capabilityMode: String?
    public var tools: [ToolConfigEntry]
    public var viewerCtx: WorkspaceViewerContext?
    public var yoloMode: Bool?

    private enum CodingKeys: String, CodingKey {
        case preset
        case capabilityMode = "capability_mode"
        case tools
        case viewerCtx = "viewer_ctx"
        case yoloMode = "yolo_mode"
    }

    public init(
        preset: String? = nil,
        capabilityMode: String? = nil,
        tools: [ToolConfigEntry] = [],
        viewerCtx: WorkspaceViewerContext? = nil,
        yoloMode: Bool? = nil
    ) {
        self.preset = preset
        self.capabilityMode = capabilityMode
        self.tools = tools
        self.viewerCtx = viewerCtx
        self.yoloMode = yoloMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerate missing/malformed sibling fields (mixed-version wire).
        self.preset = try? c.decodeIfPresent(String.self, forKey: .preset) ?? nil
        self.capabilityMode = try? c.decodeIfPresent(String.self, forKey: .capabilityMode) ?? nil
        self.tools = (try? c.decodeIfPresent([ToolConfigEntry].self, forKey: .tools)) ?? []
        self.viewerCtx = try? c.decodeIfPresent(WorkspaceViewerContext.self, forKey: .viewerCtx) ?? nil
        self.yoloMode = try? c.decodeIfPresent(Bool.self, forKey: .yoloMode) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(preset, forKey: .preset)
        try c.encodeIfPresent(capabilityMode, forKey: .capabilityMode)
        if !tools.isEmpty { try c.encode(tools, forKey: .tools) }
        try c.encodeIfPresent(viewerCtx, forKey: .viewerCtx)
        try c.encodeIfPresent(yoloMode, forKey: .yoloMode)
    }
}
