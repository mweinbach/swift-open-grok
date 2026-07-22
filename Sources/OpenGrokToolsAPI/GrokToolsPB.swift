// GrokToolsPB.swift
//
// Open Grok — hand-translated protobuf contract for `xai.grok.tools.v1`
// (`crates/codegen/xai-grok-tools-api/proto/grok-tools.proto`).
//
// Types live under `GrokToolsV1` (Rust `xai_grok_tools_api::pb`). Binary
// encode/decode uses `ProtoWriter` / `ProtoReader` from ProtobufWire.swift.

import Foundation

// MARK: - Package xai.grok.tools.v1

/// Namespace for generated tools-API protobuf types (Rust `pb` module).
public enum GrokToolsV1 {

    /// Proto enum `OutputFormat`.
    public enum OutputFormat: Sendable, Hashable, Codable {
        case unspecified
        case `default`
        case concise
        case UNRECOGNIZED(Int32)

        public static var allCases: [Self] {
            [.unspecified, .`default`, .concise]
        }
        public init(rawValue: Int32) {
            switch rawValue {
            case 0: self = .unspecified
            case 1: self = .`default`
            case 2: self = .concise
            default: self = .UNRECOGNIZED(rawValue)
            }
        }
        public var rawValue: Int32 {
            switch self {
            case .unspecified: return 0
            case .`default`: return 1
            case .concise: return 2
            case .UNRECOGNIZED(let v): return v
            }
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int32.self) { self.init(rawValue: i) }
            else if let s = try? c.decode(String.self) { self.init(rawValue: Self.rawValue(fromName: s)) }
            else { self = .UNRECOGNIZED(0) }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
        private static func rawValue(fromName name: String) -> Int32 {
            switch name {
            case "OUTPUT_FORMAT_UNSPECIFIED", "unspecified": return 0
            case "OUTPUT_FORMAT_DEFAULT", "default": return 1
            case "OUTPUT_FORMAT_CONCISE", "concise": return 2
            default: return 0
            }
        }
    }

    /// Proto enum `ErrorCode`.
    public enum ErrorCode: Sendable, Hashable, Codable {
        case unspecified
        case invalidInput
        case missingRequiredField
        case invalidToolName
        case toolDisabled
        case toolNotFound
        case fileNotFound
        case fileNotRead
        case fileExternallyModified
        case fileAlreadyExists
        case permissionDenied
        case multipleMatches
        case noMatches
        case executionFailed
        case timeout
        case cancelled
        case rateLimited
        case `internal`
        case notImplemented
        case UNRECOGNIZED(Int32)

        public static var allCases: [Self] {
            [.unspecified, .invalidInput, .missingRequiredField, .invalidToolName, .toolDisabled, .toolNotFound, .fileNotFound, .fileNotRead, .fileExternallyModified, .fileAlreadyExists, .permissionDenied, .multipleMatches, .noMatches, .executionFailed, .timeout, .cancelled, .rateLimited, .`internal`, .notImplemented]
        }
        public init(rawValue: Int32) {
            switch rawValue {
            case 0: self = .unspecified
            case 100: self = .invalidInput
            case 101: self = .missingRequiredField
            case 102: self = .invalidToolName
            case 103: self = .toolDisabled
            case 104: self = .toolNotFound
            case 200: self = .fileNotFound
            case 201: self = .fileNotRead
            case 202: self = .fileExternallyModified
            case 203: self = .fileAlreadyExists
            case 204: self = .permissionDenied
            case 205: self = .multipleMatches
            case 206: self = .noMatches
            case 300: self = .executionFailed
            case 301: self = .timeout
            case 302: self = .cancelled
            case 303: self = .rateLimited
            case 500: self = .`internal`
            case 501: self = .notImplemented
            default: self = .UNRECOGNIZED(rawValue)
            }
        }
        public var rawValue: Int32 {
            switch self {
            case .unspecified: return 0
            case .invalidInput: return 100
            case .missingRequiredField: return 101
            case .invalidToolName: return 102
            case .toolDisabled: return 103
            case .toolNotFound: return 104
            case .fileNotFound: return 200
            case .fileNotRead: return 201
            case .fileExternallyModified: return 202
            case .fileAlreadyExists: return 203
            case .permissionDenied: return 204
            case .multipleMatches: return 205
            case .noMatches: return 206
            case .executionFailed: return 300
            case .timeout: return 301
            case .cancelled: return 302
            case .rateLimited: return 303
            case .`internal`: return 500
            case .notImplemented: return 501
            case .UNRECOGNIZED(let v): return v
            }
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int32.self) { self.init(rawValue: i) }
            else if let s = try? c.decode(String.self) { self.init(rawValue: Self.rawValue(fromName: s)) }
            else { self = .UNRECOGNIZED(0) }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
        private static func rawValue(fromName name: String) -> Int32 {
            switch name {
            case "ERROR_CODE_UNSPECIFIED", "unspecified": return 0
            case "ERROR_CODE_INVALID_INPUT", "invalidInput": return 100
            case "ERROR_CODE_MISSING_REQUIRED_FIELD", "missingRequiredField": return 101
            case "ERROR_CODE_INVALID_TOOL_NAME", "invalidToolName": return 102
            case "ERROR_CODE_TOOL_DISABLED", "toolDisabled": return 103
            case "ERROR_CODE_TOOL_NOT_FOUND", "toolNotFound": return 104
            case "ERROR_CODE_FILE_NOT_FOUND", "fileNotFound": return 200
            case "ERROR_CODE_FILE_NOT_READ", "fileNotRead": return 201
            case "ERROR_CODE_FILE_EXTERNALLY_MODIFIED", "fileExternallyModified": return 202
            case "ERROR_CODE_FILE_ALREADY_EXISTS", "fileAlreadyExists": return 203
            case "ERROR_CODE_PERMISSION_DENIED", "permissionDenied": return 204
            case "ERROR_CODE_MULTIPLE_MATCHES", "multipleMatches": return 205
            case "ERROR_CODE_NO_MATCHES", "noMatches": return 206
            case "ERROR_CODE_EXECUTION_FAILED", "executionFailed": return 300
            case "ERROR_CODE_TIMEOUT", "timeout": return 301
            case "ERROR_CODE_CANCELLED", "cancelled": return 302
            case "ERROR_CODE_RATE_LIMITED", "rateLimited": return 303
            case "ERROR_CODE_INTERNAL", "internal": return 500
            case "ERROR_CODE_NOT_IMPLEMENTED", "notImplemented": return 501
            default: return 0
            }
        }
    }

    /// Proto enum `StreamDataKind`.
    public enum StreamDataKind: Sendable, Hashable, Codable {
        case unspecified
        case promptText
        case outputJson
        case UNRECOGNIZED(Int32)

        public static var allCases: [Self] {
            [.unspecified, .promptText, .outputJson]
        }
        public init(rawValue: Int32) {
            switch rawValue {
            case 0: self = .unspecified
            case 1: self = .promptText
            case 2: self = .outputJson
            default: self = .UNRECOGNIZED(rawValue)
            }
        }
        public var rawValue: Int32 {
            switch self {
            case .unspecified: return 0
            case .promptText: return 1
            case .outputJson: return 2
            case .UNRECOGNIZED(let v): return v
            }
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int32.self) { self.init(rawValue: i) }
            else if let s = try? c.decode(String.self) { self.init(rawValue: Self.rawValue(fromName: s)) }
            else { self = .UNRECOGNIZED(0) }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
        private static func rawValue(fromName name: String) -> Int32 {
            switch name {
            case "STREAM_DATA_KIND_UNSPECIFIED", "unspecified": return 0
            case "STREAM_DATA_KIND_PROMPT_TEXT", "promptText": return 1
            case "STREAM_DATA_KIND_OUTPUT_JSON", "outputJson": return 2
            default: return 0
            }
        }
    }

    /// Proto enum `ToolCategory`.
    public enum ToolCategory: Sendable, Hashable, Codable {
        case unspecified
        case file
        case search
        case shell
        case workflow
        case external
        case custom
        case UNRECOGNIZED(Int32)

        public static var allCases: [Self] {
            [.unspecified, .file, .search, .shell, .workflow, .external, .custom]
        }
        public init(rawValue: Int32) {
            switch rawValue {
            case 0: self = .unspecified
            case 1: self = .file
            case 2: self = .search
            case 3: self = .shell
            case 4: self = .workflow
            case 5: self = .external
            case 6: self = .custom
            default: self = .UNRECOGNIZED(rawValue)
            }
        }
        public var rawValue: Int32 {
            switch self {
            case .unspecified: return 0
            case .file: return 1
            case .search: return 2
            case .shell: return 3
            case .workflow: return 4
            case .external: return 5
            case .custom: return 6
            case .UNRECOGNIZED(let v): return v
            }
        }
        public var asStr: String {
            switch self {
            case .unspecified: return "unspecified"
            case .file: return "file"
            case .search: return "search"
            case .shell: return "shell"
            case .workflow: return "workflow"
            case .external: return "external"
            case .custom: return "custom"
            case .UNRECOGNIZED: return "unspecified"
            }
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int32.self) { self.init(rawValue: i) }
            else if let s = try? c.decode(String.self) { self.init(rawValue: Self.rawValue(fromName: s)) }
            else { self = .UNRECOGNIZED(0) }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
        private static func rawValue(fromName name: String) -> Int32 {
            switch name {
            case "TOOL_CATEGORY_UNSPECIFIED", "unspecified": return 0
            case "TOOL_CATEGORY_FILE", "file": return 1
            case "TOOL_CATEGORY_SEARCH", "search": return 2
            case "TOOL_CATEGORY_SHELL", "shell": return 3
            case "TOOL_CATEGORY_WORKFLOW", "workflow": return 4
            case "TOOL_CATEGORY_EXTERNAL", "external": return 5
            case "TOOL_CATEGORY_CUSTOM", "custom": return 6
            default: return 0
            }
        }
    }

    /// Proto enum `ToolSource`.
    public enum ToolSource: Sendable, Hashable, Codable {
        case unspecified
        case builtin
        case mcp
        case custom
        case skill
        case UNRECOGNIZED(Int32)

        public static var allCases: [Self] {
            [.unspecified, .builtin, .mcp, .custom, .skill]
        }
        public init(rawValue: Int32) {
            switch rawValue {
            case 0: self = .unspecified
            case 1: self = .builtin
            case 2: self = .mcp
            case 3: self = .custom
            case 4: self = .skill
            default: self = .UNRECOGNIZED(rawValue)
            }
        }
        public var rawValue: Int32 {
            switch self {
            case .unspecified: return 0
            case .builtin: return 1
            case .mcp: return 2
            case .custom: return 3
            case .skill: return 4
            case .UNRECOGNIZED(let v): return v
            }
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int32.self) { self.init(rawValue: i) }
            else if let s = try? c.decode(String.self) { self.init(rawValue: Self.rawValue(fromName: s)) }
            else { self = .UNRECOGNIZED(0) }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
        private static func rawValue(fromName name: String) -> Int32 {
            switch name {
            case "TOOL_SOURCE_UNSPECIFIED", "unspecified": return 0
            case "TOOL_SOURCE_BUILTIN", "builtin": return 1
            case "TOOL_SOURCE_MCP", "mcp": return 2
            case "TOOL_SOURCE_CUSTOM", "custom": return 3
            case "TOOL_SOURCE_SKILL", "skill": return 4
            default: return 0
            }
        }
    }

    /// Proto message `FinalizeToolServerConfigRequest`.
    public struct FinalizeToolServerConfigRequest: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var tools: [ToolConfigEntry]
        /// Field 2.
        public var truncation: TruncationConfig?
        /// Field 3.
        public var systemRemindersEnabled: Bool
        /// Field 4.
        public var initialToolStateJson: String?
        /// Field 5.
        public var behaviorPreset: String?
        public init(
            tools: [ToolConfigEntry] = [],
            truncation: TruncationConfig? = nil,
            systemRemindersEnabled: Bool = false,
            initialToolStateJson: String? = nil,
            behaviorPreset: String? = nil
        ) {
            self.tools = tools
            self.truncation = truncation
            self.systemRemindersEnabled = systemRemindersEnabled
            self.initialToolStateJson = initialToolStateJson
            self.behaviorPreset = behaviorPreset
        }
        public init() {
            self.tools = []
            self.truncation = nil
            self.systemRemindersEnabled = false
            self.initialToolStateJson = nil
            self.behaviorPreset = nil
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            for item in tools { w.writeMessagePresence(1, item.protobufData(), has: true) }
            if let v = truncation { w.writeMessagePresence(2, v.protobufData(), has: true) }
            w.writeBool(3, systemRemindersEnabled)
            if let v = initialToolStateJson { w.writeStringPresence(4, v, has: true) }
            if let v = behaviorPreset { w.writeStringPresence(5, v, has: true) }
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    tools.append(try ToolConfigEntry(protobufBytes: try r.readLengthDelimited()))
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    truncation = try TruncationConfig(protobufBytes: try r.readLengthDelimited())
                case 3:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    systemRemindersEnabled = try r.readBool()
                case 4:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    initialToolStateJson = try r.readString()
                case 5:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    behaviorPreset = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let tools: UInt32 = 1
            public static let truncation: UInt32 = 2
            public static let systemRemindersEnabled: UInt32 = 3
            public static let initialToolStateJson: UInt32 = 4
            public static let behaviorPreset: UInt32 = 5
        }
    }

    /// Proto message `ToolConfigEntry`.
    public struct ToolConfigEntry: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var id: String
        /// Field 2.
        public var paramsJson: String?
        /// Field 3.
        public var nameOverride: String?
        /// Field 4 (map).
        public var paramsNameOverrides: [String: String]
        /// Field 5.
        public var behaviorVersion: String?
        /// Field 6.
        public var descriptionOverride: String?
        public init(
            id: String = "",
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

        public init() {
            self.id = ""
            self.paramsJson = nil
            self.nameOverride = nil
            self.paramsNameOverrides = [:]
            self.behaviorVersion = nil
            self.descriptionOverride = nil
        }

        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeString(1, id)
            if let v = paramsJson { w.writeStringPresence(2, v, has: true) }
            if let v = nameOverride { w.writeStringPresence(3, v, has: true) }
            for (k, v) in paramsNameOverrides {
                var entry = ProtoWriter()
                entry.writeString(1, k)
                entry.writeString(2, v)
                w.writeMessagePresence(4, entry.data, has: true)
            }
            if let v = behaviorVersion { w.writeStringPresence(5, v, has: true) }
            if let v = descriptionOverride { w.writeStringPresence(6, v, has: true) }
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    id = try r.readString()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    paramsJson = try r.readString()
                case 3:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    nameOverride = try r.readString()
                case 4:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    var er = ProtoReader(try r.readLengthDelimited())
                    var k: String = ""
                    var v: String = ""
                    while let (ef, et) = try er.readTag() {
                        switch ef {
                        case 1:
                            guard et == 2 else { try er.skip(wireType: et); continue }
                            k = try er.readString()
                        case 2:
                            guard et == 2 else { try er.skip(wireType: et); continue }
                            v = try er.readString()
                        default: try er.skip(wireType: et)
                        }
                    }
                    paramsNameOverrides[k] = v
                case 5:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    behaviorVersion = try r.readString()
                case 6:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    descriptionOverride = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let id: UInt32 = 1
            public static let paramsJson: UInt32 = 2
            public static let nameOverride: UInt32 = 3
            public static let paramsNameOverrides: UInt32 = 4
            public static let behaviorVersion: UInt32 = 5
            public static let descriptionOverride: UInt32 = 6
        }
    }

    /// Proto message `FinalizeConfigValidationDetails`.
    public struct FinalizeConfigValidationDetails: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var violations: [FinalizeConfigViolation]
        public init(
            violations: [FinalizeConfigViolation] = []
        ) {
            self.violations = violations
        }
        public init() {
            self.violations = []
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            for item in violations { w.writeMessagePresence(1, item.protobufData(), has: true) }
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    violations.append(try FinalizeConfigViolation(protobufBytes: try r.readLengthDelimited()))
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let violations: UInt32 = 1
        }
    }

    /// Proto message `FinalizeConfigViolation`.
    public struct FinalizeConfigViolation: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var entryIndex: UInt32?
        /// Field 2.
        public var toolId: String
        /// Field 3.
        public var fieldPath: String?
        /// Field 4.
        public var message: String
        /// Field 5.
        public var expected: String?
        /// Field 6.
        public var badValueJson: String?
        /// Field 7.
        public var category: String
        public init(
            entryIndex: UInt32? = nil,
            toolId: String = "",
            fieldPath: String? = nil,
            message: String = "",
            expected: String? = nil,
            badValueJson: String? = nil,
            category: String = ""
        ) {
            self.entryIndex = entryIndex
            self.toolId = toolId
            self.fieldPath = fieldPath
            self.message = message
            self.expected = expected
            self.badValueJson = badValueJson
            self.category = category
        }
        public init() {
            self.entryIndex = nil
            self.toolId = ""
            self.fieldPath = nil
            self.message = ""
            self.expected = nil
            self.badValueJson = nil
            self.category = ""
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            if let v = entryIndex { w.writeUInt32Presence(1, v, has: true) }
            w.writeString(2, toolId)
            if let v = fieldPath { w.writeStringPresence(3, v, has: true) }
            w.writeString(4, message)
            if let v = expected { w.writeStringPresence(5, v, has: true) }
            if let v = badValueJson { w.writeStringPresence(6, v, has: true) }
            w.writeString(7, category)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    entryIndex = try r.readUInt32()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    toolId = try r.readString()
                case 3:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    fieldPath = try r.readString()
                case 4:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    message = try r.readString()
                case 5:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    expected = try r.readString()
                case 6:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    badValueJson = try r.readString()
                case 7:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    category = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let entryIndex: UInt32 = 1
            public static let toolId: UInt32 = 2
            public static let fieldPath: UInt32 = 3
            public static let message: UInt32 = 4
            public static let expected: UInt32 = 5
            public static let badValueJson: UInt32 = 6
            public static let category: UInt32 = 7
        }
    }

    /// Proto message `VersionWarning`.
    public struct VersionWarning: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var fqToolId: String
        /// Field 2.
        public var deprecatedVersion: String
        /// Field 3.
        public var replacement: String
        /// Field 4.
        public var message: String
        public init(
            fqToolId: String = "",
            deprecatedVersion: String = "",
            replacement: String = "",
            message: String = ""
        ) {
            self.fqToolId = fqToolId
            self.deprecatedVersion = deprecatedVersion
            self.replacement = replacement
            self.message = message
        }
        public init() {
            self.fqToolId = ""
            self.deprecatedVersion = ""
            self.replacement = ""
            self.message = ""
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeString(1, fqToolId)
            w.writeString(2, deprecatedVersion)
            w.writeString(3, replacement)
            w.writeString(4, message)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    fqToolId = try r.readString()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    deprecatedVersion = try r.readString()
                case 3:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    replacement = try r.readString()
                case 4:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    message = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let fqToolId: UInt32 = 1
            public static let deprecatedVersion: UInt32 = 2
            public static let replacement: UInt32 = 3
            public static let message: UInt32 = 4
        }
    }

    /// Proto message `FinalizeToolServerConfigResponse`.
    public struct FinalizeToolServerConfigResponse: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var success: Bool
        /// Field 2.
        public var message: String
        /// Field 3.
        public var tools: [ToolInfo]
        /// Field 4.
        public var versionWarnings: [VersionWarning]
        public init(
            success: Bool = false,
            message: String = "",
            tools: [ToolInfo] = [],
            versionWarnings: [VersionWarning] = []
        ) {
            self.success = success
            self.message = message
            self.tools = tools
            self.versionWarnings = versionWarnings
        }
        public init() {
            self.success = false
            self.message = ""
            self.tools = []
            self.versionWarnings = []
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeBool(1, success)
            w.writeString(2, message)
            for item in tools { w.writeMessagePresence(3, item.protobufData(), has: true) }
            for item in versionWarnings { w.writeMessagePresence(4, item.protobufData(), has: true) }
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    success = try r.readBool()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    message = try r.readString()
                case 3:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    tools.append(try ToolInfo(protobufBytes: try r.readLengthDelimited()))
                case 4:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    versionWarnings.append(try VersionWarning(protobufBytes: try r.readLengthDelimited()))
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let success: UInt32 = 1
            public static let message: UInt32 = 2
            public static let tools: UInt32 = 3
            public static let versionWarnings: UInt32 = 4
        }
    }

    /// Proto message `ExecuteToolRequest`.
    public struct ExecuteToolRequest: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var toolName: String
        /// Field 2.
        public var inputJson: String
        /// Field 4.
        public var options: ExecutionOptions?
        /// Field 5.
        public var callId: String?
        public init(
            toolName: String = "",
            inputJson: String = "",
            options: ExecutionOptions? = nil,
            callId: String? = nil
        ) {
            self.toolName = toolName
            self.inputJson = inputJson
            self.options = options
            self.callId = callId
        }
        public init() {
            self.toolName = ""
            self.inputJson = ""
            self.options = nil
            self.callId = nil
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeString(1, toolName)
            w.writeString(2, inputJson)
            if let v = options { w.writeMessagePresence(4, v.protobufData(), has: true) }
            if let v = callId { w.writeStringPresence(5, v, has: true) }
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    toolName = try r.readString()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    inputJson = try r.readString()
                case 4:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    options = try ExecutionOptions(protobufBytes: try r.readLengthDelimited())
                case 5:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    callId = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let toolName: UInt32 = 1
            public static let inputJson: UInt32 = 2
            public static let options: UInt32 = 4
            public static let callId: UInt32 = 5
        }
    }

    /// Proto message `ExecutionOptions`.
    public struct ExecutionOptions: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var timeoutMs: UInt64?
        /// Field 2.
        public var background: Bool
        /// Field 3.
        public var outputFormat: OutputFormat
        /// Field 4.
        public var workingDirectory: String?
        /// Field 5.
        public var includeFields: [String]
        /// Field 6.
        public var excludeFields: [String]
        /// Field 7.
        public var streamChunkSize: UInt32?
        public init(
            timeoutMs: UInt64? = nil,
            background: Bool = false,
            outputFormat: OutputFormat = .unspecified,
            workingDirectory: String? = nil,
            includeFields: [String] = [],
            excludeFields: [String] = [],
            streamChunkSize: UInt32? = nil
        ) {
            self.timeoutMs = timeoutMs
            self.background = background
            self.outputFormat = outputFormat
            self.workingDirectory = workingDirectory
            self.includeFields = includeFields
            self.excludeFields = excludeFields
            self.streamChunkSize = streamChunkSize
        }
        public init() {
            self.timeoutMs = nil
            self.background = false
            self.outputFormat = .unspecified
            self.workingDirectory = nil
            self.includeFields = []
            self.excludeFields = []
            self.streamChunkSize = nil
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            if let v = timeoutMs { w.writeUInt64Presence(1, v, has: true) }
            w.writeBool(2, background)
            w.writeEnum(3, outputFormat.rawValue)
            if let v = workingDirectory { w.writeStringPresence(4, v, has: true) }
            for item in includeFields { w.writeString(5, item) }
            for item in excludeFields { w.writeString(6, item) }
            if let v = streamChunkSize { w.writeUInt32Presence(7, v, has: true) }
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    timeoutMs = try r.readUInt64()
                case 2:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    background = try r.readBool()
                case 3:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    outputFormat = OutputFormat(rawValue: try r.readInt32())
                case 4:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    workingDirectory = try r.readString()
                case 5:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    includeFields.append(try r.readString())
                case 6:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    excludeFields.append(try r.readString())
                case 7:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    streamChunkSize = try r.readUInt32()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let timeoutMs: UInt32 = 1
            public static let background: UInt32 = 2
            public static let outputFormat: UInt32 = 3
            public static let workingDirectory: UInt32 = 4
            public static let includeFields: UInt32 = 5
            public static let excludeFields: UInt32 = 6
            public static let streamChunkSize: UInt32 = 7
        }
    }

    /// Proto message `TruncationConfig`.
    public struct TruncationConfig: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var defaultMaxOutputBytes: UInt32?
        /// Field 2 (map).
        public var perToolMaxOutputBytes: [String: UInt32]
        /// Field 3.
        public var maxCharsPerLine: UInt32?
        /// Field 4.
        public var maxLinesRead: UInt32?
        public init(
            defaultMaxOutputBytes: UInt32? = nil,
            perToolMaxOutputBytes: [String: UInt32] = [:],
            maxCharsPerLine: UInt32? = nil,
            maxLinesRead: UInt32? = nil
        ) {
            self.defaultMaxOutputBytes = defaultMaxOutputBytes
            self.perToolMaxOutputBytes = perToolMaxOutputBytes
            self.maxCharsPerLine = maxCharsPerLine
            self.maxLinesRead = maxLinesRead
        }
        public init() {
            self.defaultMaxOutputBytes = nil
            self.perToolMaxOutputBytes = [:]
            self.maxCharsPerLine = nil
            self.maxLinesRead = nil
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            if let v = defaultMaxOutputBytes { w.writeUInt32Presence(1, v, has: true) }
            for (k, v) in perToolMaxOutputBytes {
                var entry = ProtoWriter()
                entry.writeString(1, k)
                entry.writeUInt32(2, v)
                w.writeMessagePresence(2, entry.data, has: true)
            }
            if let v = maxCharsPerLine { w.writeUInt32Presence(3, v, has: true) }
            if let v = maxLinesRead { w.writeUInt32Presence(4, v, has: true) }
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    defaultMaxOutputBytes = try r.readUInt32()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    var er = ProtoReader(try r.readLengthDelimited())
                    var k: String = ""
                    var v: UInt32 = 0
                    while let (ef, et) = try er.readTag() {
                        switch ef {
                        case 1:
                            guard et == 2 else { try er.skip(wireType: et); continue }
                            k = try er.readString()
                        case 2:
                            guard et == 0 else { try er.skip(wireType: et); continue }
                            v = UInt32(try er.readVarint())
                        default: try er.skip(wireType: et)
                        }
                    }
                    perToolMaxOutputBytes[k] = v
                case 3:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    maxCharsPerLine = try r.readUInt32()
                case 4:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    maxLinesRead = try r.readUInt32()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let defaultMaxOutputBytes: UInt32 = 1
            public static let perToolMaxOutputBytes: UInt32 = 2
            public static let maxCharsPerLine: UInt32 = 3
            public static let maxLinesRead: UInt32 = 4
        }
    }

    /// Proto message `ExecuteToolResponse`.
    public struct ExecuteToolResponse: ProtobufMessage, Sendable, Hashable {
        public enum ResultOneOf: Sendable, Hashable {
            case success(ToolSuccess) // = 2
            case error(ToolError) // = 3
        }
        public var result: ResultOneOf?
        /// Field 1.
        public var callId: String
        /// Field 4.
        public var metadata: ExecutionMetadata?
        public init(
            result: ResultOneOf? = nil,
            callId: String = "",
            metadata: ExecutionMetadata? = nil
        ) {
            self.result = result
            self.callId = callId
            self.metadata = metadata
        }
        public init() {
            self.result = nil
            self.callId = ""
            self.metadata = nil
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            if let one = result {
                switch one {
                case .success(let v):
                    w.writeMessagePresence(2, v.protobufData(), has: true)
                case .error(let v):
                    w.writeMessagePresence(3, v.protobufData(), has: true)
                }
            }
            w.writeString(1, callId)
            if let v = metadata { w.writeMessagePresence(4, v.protobufData(), has: true) }
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    result = .success(try ToolSuccess(protobufBytes: try r.readLengthDelimited()))
                case 3:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    result = .error(try ToolError(protobufBytes: try r.readLengthDelimited()))
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    callId = try r.readString()
                case 4:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    metadata = try ExecutionMetadata(protobufBytes: try r.readLengthDelimited())
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let success: UInt32 = 2
            public static let error: UInt32 = 3
            public static let callId: UInt32 = 1
            public static let metadata: UInt32 = 4
        }
    }

    /// Proto message `ToolSuccess`.
    public struct ToolSuccess: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 2.
        public var outputJson: String
        /// Field 3.
        public var promptText: String
        public init(
            outputJson: String = "",
            promptText: String = ""
        ) {
            self.outputJson = outputJson
            self.promptText = promptText
        }
        public init() {
            self.outputJson = ""
            self.promptText = ""
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeString(2, outputJson)
            w.writeString(3, promptText)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    outputJson = try r.readString()
                case 3:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    promptText = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let outputJson: UInt32 = 2
            public static let promptText: UInt32 = 3
        }
    }

    /// Proto message `ToolError`.
    public struct ToolError: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var code: ErrorCode
        /// Field 2.
        public var message: String
        /// Field 3.
        public var detailsJson: String?
        /// Field 4.
        public var retryable: Bool
        /// Field 5.
        public var suggestion: String?
        /// Field 6.
        public var filePath: String?
        /// Field 7.
        public var lineNumber: Int32?
        public init(
            code: ErrorCode = .unspecified,
            message: String = "",
            detailsJson: String? = nil,
            retryable: Bool = false,
            suggestion: String? = nil,
            filePath: String? = nil,
            lineNumber: Int32? = nil
        ) {
            self.code = code
            self.message = message
            self.detailsJson = detailsJson
            self.retryable = retryable
            self.suggestion = suggestion
            self.filePath = filePath
            self.lineNumber = lineNumber
        }
        public init() {
            self.code = .unspecified
            self.message = ""
            self.detailsJson = nil
            self.retryable = false
            self.suggestion = nil
            self.filePath = nil
            self.lineNumber = nil
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeEnum(1, code.rawValue)
            w.writeString(2, message)
            if let v = detailsJson { w.writeStringPresence(3, v, has: true) }
            w.writeBool(4, retryable)
            if let v = suggestion { w.writeStringPresence(5, v, has: true) }
            if let v = filePath { w.writeStringPresence(6, v, has: true) }
            if let v = lineNumber { w.writeInt32Presence(7, v, has: true) }
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    code = ErrorCode(rawValue: try r.readInt32())
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    message = try r.readString()
                case 3:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    detailsJson = try r.readString()
                case 4:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    retryable = try r.readBool()
                case 5:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    suggestion = try r.readString()
                case 6:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    filePath = try r.readString()
                case 7:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    lineNumber = try r.readInt32()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let code: UInt32 = 1
            public static let message: UInt32 = 2
            public static let detailsJson: UInt32 = 3
            public static let retryable: UInt32 = 4
            public static let suggestion: UInt32 = 5
            public static let filePath: UInt32 = 6
            public static let lineNumber: UInt32 = 7
        }
    }

    /// Proto message `ExecutionMetadata`.
    public struct ExecutionMetadata: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var durationMs: UInt64
        /// Field 2.
        public var estimatedTokens: Int32
        /// Field 3.
        public var truncated: Bool
        /// Field 4.
        public var toolVersion: String
        /// Field 5.
        public var contractVersion: String
        public init(
            durationMs: UInt64 = 0,
            estimatedTokens: Int32 = 0,
            truncated: Bool = false,
            toolVersion: String = "",
            contractVersion: String = ""
        ) {
            self.durationMs = durationMs
            self.estimatedTokens = estimatedTokens
            self.truncated = truncated
            self.toolVersion = toolVersion
            self.contractVersion = contractVersion
        }
        public init() {
            self.durationMs = 0
            self.estimatedTokens = 0
            self.truncated = false
            self.toolVersion = ""
            self.contractVersion = ""
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeUInt64(1, durationMs)
            w.writeInt32(2, estimatedTokens)
            w.writeBool(3, truncated)
            w.writeString(4, toolVersion)
            w.writeString(5, contractVersion)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    durationMs = try r.readUInt64()
                case 2:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    estimatedTokens = try r.readInt32()
                case 3:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    truncated = try r.readBool()
                case 4:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    toolVersion = try r.readString()
                case 5:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    contractVersion = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let durationMs: UInt32 = 1
            public static let estimatedTokens: UInt32 = 2
            public static let truncated: UInt32 = 3
            public static let toolVersion: UInt32 = 4
            public static let contractVersion: UInt32 = 5
        }
    }

    /// Proto message `ToolStreamChunk`.
    public struct ToolStreamChunk: ProtobufMessage, Sendable, Hashable {
        public enum ChunkOneOf: Sendable, Hashable {
            case data(StreamDataChunk) // = 2
            case finalResult(StreamFinalResult) // = 3
        }
        public var chunk: ChunkOneOf?
        /// Field 1.
        public var callId: String
        public init(
            chunk: ChunkOneOf? = nil,
            callId: String = ""
        ) {
            self.chunk = chunk
            self.callId = callId
        }
        public init() {
            self.chunk = nil
            self.callId = ""
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            if let one = chunk {
                switch one {
                case .data(let v):
                    w.writeMessagePresence(2, v.protobufData(), has: true)
                case .finalResult(let v):
                    w.writeMessagePresence(3, v.protobufData(), has: true)
                }
            }
            w.writeString(1, callId)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    chunk = .data(try StreamDataChunk(protobufBytes: try r.readLengthDelimited()))
                case 3:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    chunk = .finalResult(try StreamFinalResult(protobufBytes: try r.readLengthDelimited()))
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    callId = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let data: UInt32 = 2
            public static let finalResult: UInt32 = 3
            public static let callId: UInt32 = 1
        }
    }

    /// Proto message `StreamDataChunk`.
    public struct StreamDataChunk: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var kind: StreamDataKind
        /// Field 2.
        public var data: Data
        /// Field 3.
        public var offset: UInt64
        public init(
            kind: StreamDataKind = .unspecified,
            data: Data = Data(),
            offset: UInt64 = 0
        ) {
            self.kind = kind
            self.data = data
            self.offset = offset
        }
        public init() {
            self.kind = .unspecified
            self.data = Data()
            self.offset = 0
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeEnum(1, kind.rawValue)
            w.writeBytes(2, data)
            w.writeUInt64(3, offset)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    kind = StreamDataKind(rawValue: try r.readInt32())
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    self.data = try r.readLengthDelimited()
                case 3:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    offset = try r.readUInt64()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let kind: UInt32 = 1
            public static let data: UInt32 = 2
            public static let offset: UInt32 = 3
        }
    }

    /// Proto message `StreamFinalResult`.
    public struct StreamFinalResult: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var metadata: ExecutionMetadata?
        /// Field 2.
        public var error: ToolError?
        /// Field 3.
        public var promptTextSize: UInt64
        /// Field 4.
        public var outputJsonSize: UInt64
        public init(
            metadata: ExecutionMetadata? = nil,
            error: ToolError? = nil,
            promptTextSize: UInt64 = 0,
            outputJsonSize: UInt64 = 0
        ) {
            self.metadata = metadata
            self.error = error
            self.promptTextSize = promptTextSize
            self.outputJsonSize = outputJsonSize
        }
        public init() {
            self.metadata = nil
            self.error = nil
            self.promptTextSize = 0
            self.outputJsonSize = 0
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            if let v = metadata { w.writeMessagePresence(1, v.protobufData(), has: true) }
            if let v = error { w.writeMessagePresence(2, v.protobufData(), has: true) }
            w.writeUInt64(3, promptTextSize)
            w.writeUInt64(4, outputJsonSize)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    metadata = try ExecutionMetadata(protobufBytes: try r.readLengthDelimited())
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    error = try ToolError(protobufBytes: try r.readLengthDelimited())
                case 3:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    promptTextSize = try r.readUInt64()
                case 4:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    outputJsonSize = try r.readUInt64()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let metadata: UInt32 = 1
            public static let error: UInt32 = 2
            public static let promptTextSize: UInt32 = 3
            public static let outputJsonSize: UInt32 = 4
        }
    }

    /// Proto message `ListToolsRequest`.
    public struct ListToolsRequest: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var category: ToolCategory?
        /// Field 2.
        public var includeDisabled: Bool
        /// Field 3.
        public var includeSchemas: Bool
        public init(
            category: ToolCategory? = nil,
            includeDisabled: Bool = false,
            includeSchemas: Bool = false
        ) {
            self.category = category
            self.includeDisabled = includeDisabled
            self.includeSchemas = includeSchemas
        }
        public init() {
            self.category = nil
            self.includeDisabled = false
            self.includeSchemas = false
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            if let v = category { w.writeEnumPresence(1, v.rawValue, has: true) }
            w.writeBool(2, includeDisabled)
            w.writeBool(3, includeSchemas)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    category = ToolCategory(rawValue: try r.readInt32())
                case 2:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    includeDisabled = try r.readBool()
                case 3:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    includeSchemas = try r.readBool()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let category: UInt32 = 1
            public static let includeDisabled: UInt32 = 2
            public static let includeSchemas: UInt32 = 3
        }
    }

    /// Proto message `ListToolsResponse`.
    public struct ListToolsResponse: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var tools: [ToolInfo]
        /// Field 2.
        public var totalCount: Int32
        /// Field 3.
        public var enabledCount: Int32
        public init(
            tools: [ToolInfo] = [],
            totalCount: Int32 = 0,
            enabledCount: Int32 = 0
        ) {
            self.tools = tools
            self.totalCount = totalCount
            self.enabledCount = enabledCount
        }
        public init() {
            self.tools = []
            self.totalCount = 0
            self.enabledCount = 0
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            for item in tools { w.writeMessagePresence(1, item.protobufData(), has: true) }
            w.writeInt32(2, totalCount)
            w.writeInt32(3, enabledCount)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    tools.append(try ToolInfo(protobufBytes: try r.readLengthDelimited()))
                case 2:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    totalCount = try r.readInt32()
                case 3:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    enabledCount = try r.readInt32()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let tools: UInt32 = 1
            public static let totalCount: UInt32 = 2
            public static let enabledCount: UInt32 = 3
        }
    }

    /// Proto message `GetToolInfoRequest`.
    public struct GetToolInfoRequest: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var toolName: String
        public init(
            toolName: String = ""
        ) {
            self.toolName = toolName
        }
        public init() {
            self.toolName = ""
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeString(1, toolName)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    toolName = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let toolName: UInt32 = 1
        }
    }

    /// Proto message `ToolInfo`.
    public struct ToolInfo: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var name: String
        /// Field 2.
        public var displayName: String
        /// Field 3.
        public var description: String
        /// Field 4.
        public var shortDescription: String?
        /// Field 5.
        public var category: ToolCategory
        /// Field 6.
        public var inputSchemaJson: String
        /// Field 7.
        public var enabled: Bool
        /// Field 8.
        public var capabilities: ToolCapabilities?
        /// Field 9.
        public var version: String
        /// Field 10.
        public var source: ToolSource
        /// Field 12.
        public var optionsSchemaJson: String?
        /// Field 13.
        public var defaultOptionsJson: String?
        /// Field 14.
        public var currentOptionsJson: String?
        /// Field 15.
        public var outputFormats: [OutputFormatSpec]
        /// Field 16.
        public var outputFields: [OutputFieldSpec]
        /// Field 17.
        public var outputSchemaJson: String
        /// Field 18.
        public var contractVersion: String
        /// Field 19.
        public var namespace: String
        public init(
            name: String = "",
            displayName: String = "",
            description: String = "",
            shortDescription: String? = nil,
            category: ToolCategory = .unspecified,
            inputSchemaJson: String = "",
            enabled: Bool = false,
            capabilities: ToolCapabilities? = nil,
            version: String = "",
            source: ToolSource = .unspecified,
            optionsSchemaJson: String? = nil,
            defaultOptionsJson: String? = nil,
            currentOptionsJson: String? = nil,
            outputFormats: [OutputFormatSpec] = [],
            outputFields: [OutputFieldSpec] = [],
            outputSchemaJson: String = "",
            contractVersion: String = "",
            namespace: String = ""
        ) {
            self.name = name
            self.displayName = displayName
            self.description = description
            self.shortDescription = shortDescription
            self.category = category
            self.inputSchemaJson = inputSchemaJson
            self.enabled = enabled
            self.capabilities = capabilities
            self.version = version
            self.source = source
            self.optionsSchemaJson = optionsSchemaJson
            self.defaultOptionsJson = defaultOptionsJson
            self.currentOptionsJson = currentOptionsJson
            self.outputFormats = outputFormats
            self.outputFields = outputFields
            self.outputSchemaJson = outputSchemaJson
            self.contractVersion = contractVersion
            self.namespace = namespace
        }
        public init() {
            self.name = ""
            self.displayName = ""
            self.description = ""
            self.shortDescription = nil
            self.category = .unspecified
            self.inputSchemaJson = ""
            self.enabled = false
            self.capabilities = nil
            self.version = ""
            self.source = .unspecified
            self.optionsSchemaJson = nil
            self.defaultOptionsJson = nil
            self.currentOptionsJson = nil
            self.outputFormats = []
            self.outputFields = []
            self.outputSchemaJson = ""
            self.contractVersion = ""
            self.namespace = ""
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeString(1, name)
            w.writeString(2, displayName)
            w.writeString(3, description)
            if let v = shortDescription { w.writeStringPresence(4, v, has: true) }
            w.writeEnum(5, category.rawValue)
            w.writeString(6, inputSchemaJson)
            w.writeBool(7, enabled)
            if let v = capabilities { w.writeMessagePresence(8, v.protobufData(), has: true) }
            w.writeString(9, version)
            w.writeEnum(10, source.rawValue)
            if let v = optionsSchemaJson { w.writeStringPresence(12, v, has: true) }
            if let v = defaultOptionsJson { w.writeStringPresence(13, v, has: true) }
            if let v = currentOptionsJson { w.writeStringPresence(14, v, has: true) }
            for item in outputFormats { w.writeMessagePresence(15, item.protobufData(), has: true) }
            for item in outputFields { w.writeMessagePresence(16, item.protobufData(), has: true) }
            w.writeString(17, outputSchemaJson)
            w.writeString(18, contractVersion)
            w.writeString(19, namespace)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    name = try r.readString()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    displayName = try r.readString()
                case 3:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    description = try r.readString()
                case 4:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    shortDescription = try r.readString()
                case 5:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    category = ToolCategory(rawValue: try r.readInt32())
                case 6:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    inputSchemaJson = try r.readString()
                case 7:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    enabled = try r.readBool()
                case 8:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    capabilities = try ToolCapabilities(protobufBytes: try r.readLengthDelimited())
                case 9:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    version = try r.readString()
                case 10:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    source = ToolSource(rawValue: try r.readInt32())
                case 12:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    optionsSchemaJson = try r.readString()
                case 13:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    defaultOptionsJson = try r.readString()
                case 14:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    currentOptionsJson = try r.readString()
                case 15:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    outputFormats.append(try OutputFormatSpec(protobufBytes: try r.readLengthDelimited()))
                case 16:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    outputFields.append(try OutputFieldSpec(protobufBytes: try r.readLengthDelimited()))
                case 17:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    outputSchemaJson = try r.readString()
                case 18:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    contractVersion = try r.readString()
                case 19:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    namespace = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let name: UInt32 = 1
            public static let displayName: UInt32 = 2
            public static let description: UInt32 = 3
            public static let shortDescription: UInt32 = 4
            public static let category: UInt32 = 5
            public static let inputSchemaJson: UInt32 = 6
            public static let enabled: UInt32 = 7
            public static let capabilities: UInt32 = 8
            public static let version: UInt32 = 9
            public static let source: UInt32 = 10
            public static let optionsSchemaJson: UInt32 = 12
            public static let defaultOptionsJson: UInt32 = 13
            public static let currentOptionsJson: UInt32 = 14
            public static let outputFormats: UInt32 = 15
            public static let outputFields: UInt32 = 16
            public static let outputSchemaJson: UInt32 = 17
            public static let contractVersion: UInt32 = 18
            public static let namespace: UInt32 = 19
        }
    }

    /// Proto message `OutputFormatSpec`.
    public struct OutputFormatSpec: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var format: OutputFormat
        /// Field 2.
        public var description: String
        /// Field 3.
        public var defaultFields: [String]
        public init(
            format: OutputFormat = .unspecified,
            description: String = "",
            defaultFields: [String] = []
        ) {
            self.format = format
            self.description = description
            self.defaultFields = defaultFields
        }
        public init() {
            self.format = .unspecified
            self.description = ""
            self.defaultFields = []
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeEnum(1, format.rawValue)
            w.writeString(2, description)
            for item in defaultFields { w.writeString(3, item) }
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    format = OutputFormat(rawValue: try r.readInt32())
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    description = try r.readString()
                case 3:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    defaultFields.append(try r.readString())
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let format: UInt32 = 1
            public static let description: UInt32 = 2
            public static let defaultFields: UInt32 = 3
        }
    }

    /// Proto message `OutputFieldSpec`.
    public struct OutputFieldSpec: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var name: String
        /// Field 2.
        public var description: String
        /// Field 3.
        public var jsonType: String
        /// Field 4.
        public var exampleJson: String?
        /// Field 5.
        public var includedIn: [OutputFormat]
        /// Field 6.
        public var potentiallyLarge: Bool
        public init(
            name: String = "",
            description: String = "",
            jsonType: String = "",
            exampleJson: String? = nil,
            includedIn: [OutputFormat] = [],
            potentiallyLarge: Bool = false
        ) {
            self.name = name
            self.description = description
            self.jsonType = jsonType
            self.exampleJson = exampleJson
            self.includedIn = includedIn
            self.potentiallyLarge = potentiallyLarge
        }
        public init() {
            self.name = ""
            self.description = ""
            self.jsonType = ""
            self.exampleJson = nil
            self.includedIn = []
            self.potentiallyLarge = false
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeString(1, name)
            w.writeString(2, description)
            w.writeString(3, jsonType)
            if let v = exampleJson { w.writeStringPresence(4, v, has: true) }
            for item in includedIn { w.writeEnum(5, item.rawValue) }
            w.writeBool(6, potentiallyLarge)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    name = try r.readString()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    description = try r.readString()
                case 3:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    jsonType = try r.readString()
                case 4:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    exampleJson = try r.readString()
                case 5:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    includedIn.append(OutputFormat(rawValue: try r.readInt32()))
                case 6:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    potentiallyLarge = try r.readBool()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let name: UInt32 = 1
            public static let description: UInt32 = 2
            public static let jsonType: UInt32 = 3
            public static let exampleJson: UInt32 = 4
            public static let includedIn: UInt32 = 5
            public static let potentiallyLarge: UInt32 = 6
        }
    }

    /// Proto message `ToolCapabilities`.
    public struct ToolCapabilities: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var supportsBackground: Bool
        /// Field 2.
        public var supportsStreaming: Bool
        /// Field 4.
        public var hasSideEffects: Bool
        /// Field 5.
        public var supportsCancellation: Bool
        /// Field 6.
        public var supportsTimeout: Bool
        /// Field 10.
        public var customCapabilities: [String]
        public init(
            supportsBackground: Bool = false,
            supportsStreaming: Bool = false,
            hasSideEffects: Bool = false,
            supportsCancellation: Bool = false,
            supportsTimeout: Bool = false,
            customCapabilities: [String] = []
        ) {
            self.supportsBackground = supportsBackground
            self.supportsStreaming = supportsStreaming
            self.hasSideEffects = hasSideEffects
            self.supportsCancellation = supportsCancellation
            self.supportsTimeout = supportsTimeout
            self.customCapabilities = customCapabilities
        }
        public init() {
            self.supportsBackground = false
            self.supportsStreaming = false
            self.hasSideEffects = false
            self.supportsCancellation = false
            self.supportsTimeout = false
            self.customCapabilities = []
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeBool(1, supportsBackground)
            w.writeBool(2, supportsStreaming)
            w.writeBool(4, hasSideEffects)
            w.writeBool(5, supportsCancellation)
            w.writeBool(6, supportsTimeout)
            for item in customCapabilities { w.writeString(10, item) }
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    supportsBackground = try r.readBool()
                case 2:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    supportsStreaming = try r.readBool()
                case 4:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    hasSideEffects = try r.readBool()
                case 5:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    supportsCancellation = try r.readBool()
                case 6:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    supportsTimeout = try r.readBool()
                case 10:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    customCapabilities.append(try r.readString())
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let supportsBackground: UInt32 = 1
            public static let supportsStreaming: UInt32 = 2
            public static let hasSideEffects: UInt32 = 4
            public static let supportsCancellation: UInt32 = 5
            public static let supportsTimeout: UInt32 = 6
            public static let customCapabilities: UInt32 = 10
        }
    }

    /// Proto message `EnableToolRequest`.
    public struct EnableToolRequest: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var toolName: String
        public init(
            toolName: String = ""
        ) {
            self.toolName = toolName
        }
        public init() {
            self.toolName = ""
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeString(1, toolName)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    toolName = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let toolName: UInt32 = 1
        }
    }

    /// Proto message `EnableToolResponse`.
    public struct EnableToolResponse: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var success: Bool
        /// Field 2.
        public var message: String
        public init(
            success: Bool = false,
            message: String = ""
        ) {
            self.success = success
            self.message = message
        }
        public init() {
            self.success = false
            self.message = ""
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeBool(1, success)
            w.writeString(2, message)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    success = try r.readBool()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    message = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let success: UInt32 = 1
            public static let message: UInt32 = 2
        }
    }

    /// Proto message `DisableToolRequest`.
    public struct DisableToolRequest: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var toolName: String
        public init(
            toolName: String = ""
        ) {
            self.toolName = toolName
        }
        public init() {
            self.toolName = ""
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeString(1, toolName)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    toolName = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let toolName: UInt32 = 1
        }
    }

    /// Proto message `DisableToolResponse`.
    public struct DisableToolResponse: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var success: Bool
        /// Field 2.
        public var message: String
        public init(
            success: Bool = false,
            message: String = ""
        ) {
            self.success = success
            self.message = message
        }
        public init() {
            self.success = false
            self.message = ""
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeBool(1, success)
            w.writeString(2, message)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    success = try r.readBool()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    message = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let success: UInt32 = 1
            public static let message: UInt32 = 2
        }
    }

    /// Proto message `SetToolOptionsRequest`.
    public struct SetToolOptionsRequest: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var toolName: String
        /// Field 2.
        public var optionsJson: String
        /// Field 3.
        public var replace: Bool
        public init(
            toolName: String = "",
            optionsJson: String = "",
            replace: Bool = false
        ) {
            self.toolName = toolName
            self.optionsJson = optionsJson
            self.replace = replace
        }
        public init() {
            self.toolName = ""
            self.optionsJson = ""
            self.replace = false
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeString(1, toolName)
            w.writeString(2, optionsJson)
            w.writeBool(3, replace)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    toolName = try r.readString()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    optionsJson = try r.readString()
                case 3:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    replace = try r.readBool()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let toolName: UInt32 = 1
            public static let optionsJson: UInt32 = 2
            public static let replace: UInt32 = 3
        }
    }

    /// Proto message `SetToolOptionsResponse`.
    public struct SetToolOptionsResponse: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var success: Bool
        /// Field 2.
        public var message: String
        /// Field 3.
        public var effectiveOptionsJson: String
        public init(
            success: Bool = false,
            message: String = "",
            effectiveOptionsJson: String = ""
        ) {
            self.success = success
            self.message = message
            self.effectiveOptionsJson = effectiveOptionsJson
        }
        public init() {
            self.success = false
            self.message = ""
            self.effectiveOptionsJson = ""
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeBool(1, success)
            w.writeString(2, message)
            w.writeString(3, effectiveOptionsJson)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    success = try r.readBool()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    message = try r.readString()
                case 3:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    effectiveOptionsJson = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let success: UInt32 = 1
            public static let message: UInt32 = 2
            public static let effectiveOptionsJson: UInt32 = 3
        }
    }

    /// Proto message `GetToolOptionsRequest`.
    public struct GetToolOptionsRequest: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var toolName: String
        /// Field 2.
        public var includeSchema: Bool
        public init(
            toolName: String = "",
            includeSchema: Bool = false
        ) {
            self.toolName = toolName
            self.includeSchema = includeSchema
        }
        public init() {
            self.toolName = ""
            self.includeSchema = false
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeString(1, toolName)
            w.writeBool(2, includeSchema)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    toolName = try r.readString()
                case 2:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    includeSchema = try r.readBool()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let toolName: UInt32 = 1
            public static let includeSchema: UInt32 = 2
        }
    }

    /// Proto message `GetToolOptionsResponse`.
    public struct GetToolOptionsResponse: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var toolName: String
        /// Field 2.
        public var effectiveOptionsJson: String
        /// Field 3.
        public var defaultOptionsJson: String
        /// Field 4.
        public var configuredOptionsJson: String
        /// Field 5.
        public var optionsSchemaJson: String?
        public init(
            toolName: String = "",
            effectiveOptionsJson: String = "",
            defaultOptionsJson: String = "",
            configuredOptionsJson: String = "",
            optionsSchemaJson: String? = nil
        ) {
            self.toolName = toolName
            self.effectiveOptionsJson = effectiveOptionsJson
            self.defaultOptionsJson = defaultOptionsJson
            self.configuredOptionsJson = configuredOptionsJson
            self.optionsSchemaJson = optionsSchemaJson
        }
        public init() {
            self.toolName = ""
            self.effectiveOptionsJson = ""
            self.defaultOptionsJson = ""
            self.configuredOptionsJson = ""
            self.optionsSchemaJson = nil
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeString(1, toolName)
            w.writeString(2, effectiveOptionsJson)
            w.writeString(3, defaultOptionsJson)
            w.writeString(4, configuredOptionsJson)
            if let v = optionsSchemaJson { w.writeStringPresence(5, v, has: true) }
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    toolName = try r.readString()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    effectiveOptionsJson = try r.readString()
                case 3:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    defaultOptionsJson = try r.readString()
                case 4:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    configuredOptionsJson = try r.readString()
                case 5:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    optionsSchemaJson = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let toolName: UInt32 = 1
            public static let effectiveOptionsJson: UInt32 = 2
            public static let defaultOptionsJson: UInt32 = 3
            public static let configuredOptionsJson: UInt32 = 4
            public static let optionsSchemaJson: UInt32 = 5
        }
    }

    /// Proto message `ResetToolOptionsRequest`.
    public struct ResetToolOptionsRequest: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var toolName: String
        /// Field 2.
        public var keysToReset: [String]
        public init(
            toolName: String = "",
            keysToReset: [String] = []
        ) {
            self.toolName = toolName
            self.keysToReset = keysToReset
        }
        public init() {
            self.toolName = ""
            self.keysToReset = []
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeString(1, toolName)
            for item in keysToReset { w.writeString(2, item) }
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    toolName = try r.readString()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    keysToReset.append(try r.readString())
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let toolName: UInt32 = 1
            public static let keysToReset: UInt32 = 2
        }
    }

    /// Proto message `ResetToolOptionsResponse`.
    public struct ResetToolOptionsResponse: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var success: Bool
        /// Field 2.
        public var message: String
        /// Field 3.
        public var effectiveOptionsJson: String
        public init(
            success: Bool = false,
            message: String = "",
            effectiveOptionsJson: String = ""
        ) {
            self.success = success
            self.message = message
            self.effectiveOptionsJson = effectiveOptionsJson
        }
        public init() {
            self.success = false
            self.message = ""
            self.effectiveOptionsJson = ""
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeBool(1, success)
            w.writeString(2, message)
            w.writeString(3, effectiveOptionsJson)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    success = try r.readBool()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    message = try r.readString()
                case 3:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    effectiveOptionsJson = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let success: UInt32 = 1
            public static let message: UInt32 = 2
            public static let effectiveOptionsJson: UInt32 = 3
        }
    }

    /// Proto message `SetToolOverrideRequest`.
    public struct SetToolOverrideRequest: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var toolName: String
        /// Field 2.
        public var toolNameForModel: String
        /// Field 3 (map).
        public var paramNameOverridesForModel: [String: String]
        public init(
            toolName: String = "",
            toolNameForModel: String = "",
            paramNameOverridesForModel: [String: String] = [:]
        ) {
            self.toolName = toolName
            self.toolNameForModel = toolNameForModel
            self.paramNameOverridesForModel = paramNameOverridesForModel
        }
        public init() {
            self.toolName = ""
            self.toolNameForModel = ""
            self.paramNameOverridesForModel = [:]
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeString(1, toolName)
            w.writeString(2, toolNameForModel)
            for (k, v) in paramNameOverridesForModel {
                var entry = ProtoWriter()
                entry.writeString(1, k)
                entry.writeString(2, v)
                w.writeMessagePresence(3, entry.data, has: true)
            }
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    toolName = try r.readString()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    toolNameForModel = try r.readString()
                case 3:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    var er = ProtoReader(try r.readLengthDelimited())
                    var k: String = ""
                    var v: String = ""
                    while let (ef, et) = try er.readTag() {
                        switch ef {
                        case 1:
                            guard et == 2 else { try er.skip(wireType: et); continue }
                            k = try er.readString()
                        case 2:
                            guard et == 2 else { try er.skip(wireType: et); continue }
                            v = try er.readString()
                        default: try er.skip(wireType: et)
                        }
                    }
                    paramNameOverridesForModel[k] = v
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let toolName: UInt32 = 1
            public static let toolNameForModel: UInt32 = 2
            public static let paramNameOverridesForModel: UInt32 = 3
        }
    }

    /// Proto message `SetToolOverrideResponse`.
    public struct SetToolOverrideResponse: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var success: Bool
        /// Field 2.
        public var message: String
        public init(
            success: Bool = false,
            message: String = ""
        ) {
            self.success = success
            self.message = message
        }
        public init() {
            self.success = false
            self.message = ""
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeBool(1, success)
            w.writeString(2, message)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    success = try r.readBool()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    message = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let success: UInt32 = 1
            public static let message: UInt32 = 2
        }
    }

    /// Proto message `ClearToolOverrideRequest`.
    public struct ClearToolOverrideRequest: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var toolName: String
        public init(
            toolName: String = ""
        ) {
            self.toolName = toolName
        }
        public init() {
            self.toolName = ""
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeString(1, toolName)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    toolName = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let toolName: UInt32 = 1
        }
    }

    /// Proto message `ClearToolOverrideResponse`.
    public struct ClearToolOverrideResponse: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var success: Bool
        /// Field 2.
        public var message: String
        public init(
            success: Bool = false,
            message: String = ""
        ) {
            self.success = success
            self.message = message
        }
        public init() {
            self.success = false
            self.message = ""
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeBool(1, success)
            w.writeString(2, message)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    success = try r.readBool()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    message = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let success: UInt32 = 1
            public static let message: UInt32 = 2
        }
    }

    /// Proto message `SetSystemRemindersRequest`.
    public struct SetSystemRemindersRequest: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var enabled: Bool
        public init(
            enabled: Bool = false
        ) {
            self.enabled = enabled
        }
        public init() {
            self.enabled = false
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeBool(1, enabled)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    enabled = try r.readBool()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let enabled: UInt32 = 1
        }
    }

    /// Proto message `SetSystemRemindersResponse`.
    public struct SetSystemRemindersResponse: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var success: Bool
        /// Field 2.
        public var message: String
        /// Field 3.
        public var enabled: Bool
        public init(
            success: Bool = false,
            message: String = "",
            enabled: Bool = false
        ) {
            self.success = success
            self.message = message
            self.enabled = enabled
        }
        public init() {
            self.success = false
            self.message = ""
            self.enabled = false
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeBool(1, success)
            w.writeString(2, message)
            w.writeBool(3, enabled)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    success = try r.readBool()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    message = try r.readString()
                case 3:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    enabled = try r.readBool()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let success: UInt32 = 1
            public static let message: UInt32 = 2
            public static let enabled: UInt32 = 3
        }
    }

    /// Proto message `GetSystemRemindersRequest`.
    public struct GetSystemRemindersRequest: ProtobufMessage, Codable, Sendable, Hashable {
        public init() {}
        public func protobufData() -> Data {
            var w = ProtoWriter()
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
        }
    }

    /// Proto message `GetSystemRemindersResponse`.
    public struct GetSystemRemindersResponse: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var enabled: Bool
        public init(
            enabled: Bool = false
        ) {
            self.enabled = enabled
        }
        public init() {
            self.enabled = false
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeBool(1, enabled)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    enabled = try r.readBool()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let enabled: UInt32 = 1
        }
    }

    /// Proto message `SetTruncationConfigRequest`.
    public struct SetTruncationConfigRequest: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var config: TruncationConfig?
        public init(
            config: TruncationConfig? = nil
        ) {
            self.config = config
        }
        public init() {
            self.config = nil
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            if let v = config { w.writeMessagePresence(1, v.protobufData(), has: true) }
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    config = try TruncationConfig(protobufBytes: try r.readLengthDelimited())
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let config: UInt32 = 1
        }
    }

    /// Proto message `SetTruncationConfigResponse`.
    public struct SetTruncationConfigResponse: ProtobufMessage, Codable, Sendable, Hashable {
        public init() {}
        public func protobufData() -> Data {
            var w = ProtoWriter()
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
        }
    }

    /// Proto message `GetTruncationConfigRequest`.
    public struct GetTruncationConfigRequest: ProtobufMessage, Codable, Sendable, Hashable {
        public init() {}
        public func protobufData() -> Data {
            var w = ProtoWriter()
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
        }
    }

    /// Proto message `GetTruncationConfigResponse`.
    public struct GetTruncationConfigResponse: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var config: TruncationConfig?
        public init(
            config: TruncationConfig? = nil
        ) {
            self.config = config
        }
        public init() {
            self.config = nil
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            if let v = config { w.writeMessagePresence(1, v.protobufData(), has: true) }
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    config = try TruncationConfig(protobufBytes: try r.readLengthDelimited())
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let config: UInt32 = 1
        }
    }

    /// Proto message `GetSystemPromptRequest`.
    public struct GetSystemPromptRequest: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var variant: String
        public init(
            variant: String = ""
        ) {
            self.variant = variant
        }
        public init() {
            self.variant = ""
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeString(1, variant)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    variant = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let variant: UInt32 = 1
        }
    }

    /// Proto message `GetSystemPromptResponse`.
    public struct GetSystemPromptResponse: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var systemPrompt: String
        /// Field 2.
        public var promptMode: String
        public init(
            systemPrompt: String = "",
            promptMode: String = ""
        ) {
            self.systemPrompt = systemPrompt
            self.promptMode = promptMode
        }
        public init() {
            self.systemPrompt = ""
            self.promptMode = ""
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeString(1, systemPrompt)
            w.writeString(2, promptMode)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    systemPrompt = try r.readString()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    promptMode = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let systemPrompt: UInt32 = 1
            public static let promptMode: UInt32 = 2
        }
    }

    /// Proto message `GetAgentInfoRequest`.
    public struct GetAgentInfoRequest: ProtobufMessage, Codable, Sendable, Hashable {
        public init() {}
        public func protobufData() -> Data {
            var w = ProtoWriter()
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
        }
    }

    /// Proto message `GetAgentInfoResponse`.
    public struct GetAgentInfoResponse: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var name: String
        /// Field 2.
        public var description: String
        /// Field 3.
        public var tools: [String]
        /// Field 4.
        public var disallowedTools: [String]
        /// Field 5.
        public var permissionMode: String
        /// Field 6.
        public var outputFormat: String
        /// Field 7.
        public var completionRequirement: AgentCompletionRequirement?
        /// Field 8 (map).
        public var toolConfig: [String: AgentToolExecConfig]
        public init(
            name: String = "",
            description: String = "",
            tools: [String] = [],
            disallowedTools: [String] = [],
            permissionMode: String = "",
            outputFormat: String = "",
            completionRequirement: AgentCompletionRequirement? = nil,
            toolConfig: [String: AgentToolExecConfig] = [:]
        ) {
            self.name = name
            self.description = description
            self.tools = tools
            self.disallowedTools = disallowedTools
            self.permissionMode = permissionMode
            self.outputFormat = outputFormat
            self.completionRequirement = completionRequirement
            self.toolConfig = toolConfig
        }
        public init() {
            self.name = ""
            self.description = ""
            self.tools = []
            self.disallowedTools = []
            self.permissionMode = ""
            self.outputFormat = ""
            self.completionRequirement = nil
            self.toolConfig = [:]
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeString(1, name)
            w.writeString(2, description)
            for item in tools { w.writeString(3, item) }
            for item in disallowedTools { w.writeString(4, item) }
            w.writeString(5, permissionMode)
            w.writeString(6, outputFormat)
            if let v = completionRequirement { w.writeMessagePresence(7, v.protobufData(), has: true) }
            for (k, v) in toolConfig {
                var entry = ProtoWriter()
                entry.writeString(1, k)
                entry.writeMessagePresence(2, v.protobufData(), has: true)
                w.writeMessagePresence(8, entry.data, has: true)
            }
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    name = try r.readString()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    description = try r.readString()
                case 3:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    tools.append(try r.readString())
                case 4:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    disallowedTools.append(try r.readString())
                case 5:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    permissionMode = try r.readString()
                case 6:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    outputFormat = try r.readString()
                case 7:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    completionRequirement = try AgentCompletionRequirement(protobufBytes: try r.readLengthDelimited())
                case 8:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    var er = ProtoReader(try r.readLengthDelimited())
                    var k: String = ""
                    var v: AgentToolExecConfig = AgentToolExecConfig()
                    while let (ef, et) = try er.readTag() {
                        switch ef {
                        case 1:
                            guard et == 2 else { try er.skip(wireType: et); continue }
                            k = try er.readString()
                        case 2:
                            guard et == 2 else { try er.skip(wireType: et); continue }
                            v = try AgentToolExecConfig(protobufBytes: try er.readLengthDelimited())
                        default: try er.skip(wireType: et)
                        }
                    }
                    toolConfig[k] = v
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let name: UInt32 = 1
            public static let description: UInt32 = 2
            public static let tools: UInt32 = 3
            public static let disallowedTools: UInt32 = 4
            public static let permissionMode: UInt32 = 5
            public static let outputFormat: UInt32 = 6
            public static let completionRequirement: UInt32 = 7
            public static let toolConfig: UInt32 = 8
        }
    }

    /// Proto message `AgentCompletionRequirement`.
    public struct AgentCompletionRequirement: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var tool: String
        /// Field 2.
        public var reminder: String
        public init(
            tool: String = "",
            reminder: String = ""
        ) {
            self.tool = tool
            self.reminder = reminder
        }
        public init() {
            self.tool = ""
            self.reminder = ""
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeString(1, tool)
            w.writeString(2, reminder)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    tool = try r.readString()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    reminder = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let tool: UInt32 = 1
            public static let reminder: UInt32 = 2
        }
    }

    /// Proto message `AgentToolExecConfig`.
    public struct AgentToolExecConfig: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var retry: AgentToolRetryConfig?
        public init(
            retry: AgentToolRetryConfig? = nil
        ) {
            self.retry = retry
        }
        public init() {
            self.retry = nil
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            if let v = retry { w.writeMessagePresence(1, v.protobufData(), has: true) }
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    retry = try AgentToolRetryConfig(protobufBytes: try r.readLengthDelimited())
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let retry: UInt32 = 1
        }
    }

    /// Proto message `AgentToolRetryConfig`.
    public struct AgentToolRetryConfig: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var maxRetries: UInt32
        /// Field 2.
        public var baseDelayMs: UInt64
        /// Field 3.
        public var maxDelayMs: UInt64
        public init(
            maxRetries: UInt32 = 0,
            baseDelayMs: UInt64 = 0,
            maxDelayMs: UInt64 = 0
        ) {
            self.maxRetries = maxRetries
            self.baseDelayMs = baseDelayMs
            self.maxDelayMs = maxDelayMs
        }
        public init() {
            self.maxRetries = 0
            self.baseDelayMs = 0
            self.maxDelayMs = 0
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeUInt32(1, maxRetries)
            w.writeUInt64(2, baseDelayMs)
            w.writeUInt64(3, maxDelayMs)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    maxRetries = try r.readUInt32()
                case 2:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    baseDelayMs = try r.readUInt64()
                case 3:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    maxDelayMs = try r.readUInt64()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let maxRetries: UInt32 = 1
            public static let baseDelayMs: UInt32 = 2
            public static let maxDelayMs: UInt32 = 3
        }
    }

    /// Proto message `GetCompletionStateRequest`.
    public struct GetCompletionStateRequest: ProtobufMessage, Codable, Sendable, Hashable {
        public init() {}
        public func protobufData() -> Data {
            var w = ProtoWriter()
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
        }
    }

    /// Proto message `GetCompletionStateResponse`.
    public struct GetCompletionStateResponse: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var hasRequirement: Bool
        /// Field 2.
        public var requiredTool: String
        /// Field 3.
        public var completed: Bool
        public init(
            hasRequirement: Bool = false,
            requiredTool: String = "",
            completed: Bool = false
        ) {
            self.hasRequirement = hasRequirement
            self.requiredTool = requiredTool
            self.completed = completed
        }
        public init() {
            self.hasRequirement = false
            self.requiredTool = ""
            self.completed = false
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeBool(1, hasRequirement)
            w.writeString(2, requiredTool)
            w.writeBool(3, completed)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    hasRequirement = try r.readBool()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    requiredTool = try r.readString()
                case 3:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    completed = try r.readBool()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let hasRequirement: UInt32 = 1
            public static let requiredTool: UInt32 = 2
            public static let completed: UInt32 = 3
        }
    }

    /// Proto message `ResetCompletionStateRequest`.
    public struct ResetCompletionStateRequest: ProtobufMessage, Codable, Sendable, Hashable {
        public init() {}
        public func protobufData() -> Data {
            var w = ProtoWriter()
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
        }
    }

    /// Proto message `ResetCompletionStateResponse`.
    public struct ResetCompletionStateResponse: ProtobufMessage, Codable, Sendable, Hashable {
        public init() {}
        public func protobufData() -> Data {
            var w = ProtoWriter()
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
        }
    }

    /// Proto message `FinalizeAgentRequest`.
    public struct FinalizeAgentRequest: ProtobufMessage, Codable, Sendable, Hashable {
        public init() {}
        public func protobufData() -> Data {
            var w = ProtoWriter()
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
        }
    }

    /// Proto message `FinalizeAgentResponse`.
    public struct FinalizeAgentResponse: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var success: Bool
        /// Field 2.
        public var systemPrompt: String
        public init(
            success: Bool = false,
            systemPrompt: String = ""
        ) {
            self.success = success
            self.systemPrompt = systemPrompt
        }
        public init() {
            self.success = false
            self.systemPrompt = ""
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeBool(1, success)
            w.writeString(2, systemPrompt)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 0 else { try r.skip(wireType: wireType); continue }
                    success = try r.readBool()
                case 2:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    systemPrompt = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let success: UInt32 = 1
            public static let systemPrompt: UInt32 = 2
        }
    }

    /// Proto message `GetToolStateRequest`.
    public struct GetToolStateRequest: ProtobufMessage, Codable, Sendable, Hashable {
        public init() {}
        public func protobufData() -> Data {
            var w = ProtoWriter()
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
        }
    }

    /// Proto message `GetToolStateResponse`.
    public struct GetToolStateResponse: ProtobufMessage, Codable, Sendable, Hashable {
        /// Field 1.
        public var stateJson: String
        public init(
            stateJson: String = ""
        ) {
            self.stateJson = stateJson
        }
        public init() {
            self.stateJson = ""
        }
        public func protobufData() -> Data {
            var w = ProtoWriter()
            w.writeString(1, stateJson)
            return w.data
        }
        public mutating func merge(from wire: Data) throws {
            var r = ProtoReader(wire)
            while let (field, wireType) = try r.readTag() {
                switch field {
                case 1:
                    guard wireType == 2 else { try r.skip(wireType: wireType); continue }
                    stateJson = try r.readString()
                default:
                    try r.skip(wireType: wireType)
                }
            }
        }
        public init(protobufBytes wire: Data) throws {
            self.init()
            try merge(from: wire)
        }
        public enum FieldNumber {
            public static let stateJson: UInt32 = 1
        }
    }

    public protocol GrokToolsService: Sendable {
        func executeTool(_ request: ExecuteToolRequest) async throws -> ExecuteToolResponse
        func executeToolStream(_ request: ExecuteToolRequest) async throws -> AsyncThrowingStream<ToolStreamChunk, Error>
        func listTools(_ request: ListToolsRequest) async throws -> ListToolsResponse
        func getToolInfo(_ request: GetToolInfoRequest) async throws -> ToolInfo
        func finalizeToolConfigRequest(_ request: FinalizeToolServerConfigRequest) async throws -> FinalizeToolServerConfigResponse
        func getToolState(_ request: GetToolStateRequest) async throws -> GetToolStateResponse
        func enableTool(_ request: EnableToolRequest) async throws -> EnableToolResponse
        func disableTool(_ request: DisableToolRequest) async throws -> DisableToolResponse
        func setToolOptions(_ request: SetToolOptionsRequest) async throws -> SetToolOptionsResponse
        func getToolOptions(_ request: GetToolOptionsRequest) async throws -> GetToolOptionsResponse
        func resetToolOptions(_ request: ResetToolOptionsRequest) async throws -> ResetToolOptionsResponse
        func setToolOverride(_ request: SetToolOverrideRequest) async throws -> SetToolOverrideResponse
        func clearToolOverride(_ request: ClearToolOverrideRequest) async throws -> ClearToolOverrideResponse
        func setSystemReminders(_ request: SetSystemRemindersRequest) async throws -> SetSystemRemindersResponse
        func getSystemReminders(_ request: GetSystemRemindersRequest) async throws -> GetSystemRemindersResponse
        func setTruncationConfig(_ request: SetTruncationConfigRequest) async throws -> SetTruncationConfigResponse
        func getTruncationConfig(_ request: GetTruncationConfigRequest) async throws -> GetTruncationConfigResponse
        func getSystemPrompt(_ request: GetSystemPromptRequest) async throws -> GetSystemPromptResponse
        func getAgentInfo(_ request: GetAgentInfoRequest) async throws -> GetAgentInfoResponse
        func getCompletionState(_ request: GetCompletionStateRequest) async throws -> GetCompletionStateResponse
        func resetCompletionState(_ request: ResetCompletionStateRequest) async throws -> ResetCompletionStateResponse
        func finalizeAgent(_ request: FinalizeAgentRequest) async throws -> FinalizeAgentResponse
    }
    public static let serviceRPCNames: [String] = [
        "ExecuteTool",
        "ExecuteToolStream",
        "ListTools",
        "GetToolInfo",
        "FinalizeToolConfigRequest",
        "GetToolState",
        "EnableTool",
        "DisableTool",
        "SetToolOptions",
        "GetToolOptions",
        "ResetToolOptions",
        "SetToolOverride",
        "ClearToolOverride",
        "SetSystemReminders",
        "GetSystemReminders",
        "SetTruncationConfig",
        "GetTruncationConfig",
        "GetSystemPrompt",
        "GetAgentInfo",
        "GetCompletionState",
        "ResetCompletionState",
        "FinalizeAgent",
    ]
    public static let streamingRPCNames: Set<String> = [
        "ExecuteToolStream",
    ]
}

// MARK: - Module-root re-exports (Rust `pub use pb::{...}`)
// Conflicting names stay under GrokToolsV1: ToolError, ToolCapabilities, ToolConfigEntry.
public typealias AgentCompletionRequirement = GrokToolsV1.AgentCompletionRequirement
public typealias AgentToolExecConfig = GrokToolsV1.AgentToolExecConfig
public typealias AgentToolRetryConfig = GrokToolsV1.AgentToolRetryConfig
public typealias ClearToolOverrideRequest = GrokToolsV1.ClearToolOverrideRequest
public typealias ClearToolOverrideResponse = GrokToolsV1.ClearToolOverrideResponse
public typealias DisableToolRequest = GrokToolsV1.DisableToolRequest
public typealias DisableToolResponse = GrokToolsV1.DisableToolResponse
public typealias EnableToolRequest = GrokToolsV1.EnableToolRequest
public typealias EnableToolResponse = GrokToolsV1.EnableToolResponse
public typealias ErrorCode = GrokToolsV1.ErrorCode
public typealias ExecuteToolRequest = GrokToolsV1.ExecuteToolRequest
public typealias ExecuteToolResponse = GrokToolsV1.ExecuteToolResponse
public typealias ExecutionMetadata = GrokToolsV1.ExecutionMetadata
public typealias ExecutionOptions = GrokToolsV1.ExecutionOptions
public typealias FinalizeAgentRequest = GrokToolsV1.FinalizeAgentRequest
public typealias FinalizeAgentResponse = GrokToolsV1.FinalizeAgentResponse
public typealias FinalizeConfigValidationDetails = GrokToolsV1.FinalizeConfigValidationDetails
public typealias FinalizeConfigViolation = GrokToolsV1.FinalizeConfigViolation
public typealias FinalizeToolServerConfigRequest = GrokToolsV1.FinalizeToolServerConfigRequest
public typealias FinalizeToolServerConfigResponse = GrokToolsV1.FinalizeToolServerConfigResponse
public typealias GetAgentInfoRequest = GrokToolsV1.GetAgentInfoRequest
public typealias GetAgentInfoResponse = GrokToolsV1.GetAgentInfoResponse
public typealias GetCompletionStateRequest = GrokToolsV1.GetCompletionStateRequest
public typealias GetCompletionStateResponse = GrokToolsV1.GetCompletionStateResponse
public typealias GetSystemPromptRequest = GrokToolsV1.GetSystemPromptRequest
public typealias GetSystemPromptResponse = GrokToolsV1.GetSystemPromptResponse
public typealias GetSystemRemindersRequest = GrokToolsV1.GetSystemRemindersRequest
public typealias GetSystemRemindersResponse = GrokToolsV1.GetSystemRemindersResponse
public typealias GetToolInfoRequest = GrokToolsV1.GetToolInfoRequest
public typealias GetToolOptionsRequest = GrokToolsV1.GetToolOptionsRequest
public typealias GetToolOptionsResponse = GrokToolsV1.GetToolOptionsResponse
public typealias GetToolStateRequest = GrokToolsV1.GetToolStateRequest
public typealias GetToolStateResponse = GrokToolsV1.GetToolStateResponse
public typealias GetTruncationConfigRequest = GrokToolsV1.GetTruncationConfigRequest
public typealias GetTruncationConfigResponse = GrokToolsV1.GetTruncationConfigResponse
public typealias ListToolsRequest = GrokToolsV1.ListToolsRequest
public typealias ListToolsResponse = GrokToolsV1.ListToolsResponse
public typealias OutputFieldSpec = GrokToolsV1.OutputFieldSpec
public typealias OutputFormat = GrokToolsV1.OutputFormat
public typealias OutputFormatSpec = GrokToolsV1.OutputFormatSpec
public typealias ResetCompletionStateRequest = GrokToolsV1.ResetCompletionStateRequest
public typealias ResetCompletionStateResponse = GrokToolsV1.ResetCompletionStateResponse
public typealias ResetToolOptionsRequest = GrokToolsV1.ResetToolOptionsRequest
public typealias ResetToolOptionsResponse = GrokToolsV1.ResetToolOptionsResponse
public typealias SetSystemRemindersRequest = GrokToolsV1.SetSystemRemindersRequest
public typealias SetSystemRemindersResponse = GrokToolsV1.SetSystemRemindersResponse
public typealias SetToolOptionsRequest = GrokToolsV1.SetToolOptionsRequest
public typealias SetToolOptionsResponse = GrokToolsV1.SetToolOptionsResponse
public typealias SetToolOverrideRequest = GrokToolsV1.SetToolOverrideRequest
public typealias SetToolOverrideResponse = GrokToolsV1.SetToolOverrideResponse
public typealias SetTruncationConfigRequest = GrokToolsV1.SetTruncationConfigRequest
public typealias SetTruncationConfigResponse = GrokToolsV1.SetTruncationConfigResponse
public typealias StreamDataChunk = GrokToolsV1.StreamDataChunk
public typealias StreamDataKind = GrokToolsV1.StreamDataKind
public typealias StreamFinalResult = GrokToolsV1.StreamFinalResult
public typealias ToolCategory = GrokToolsV1.ToolCategory
public typealias ToolInfo = GrokToolsV1.ToolInfo
public typealias ToolSource = GrokToolsV1.ToolSource
public typealias ToolStreamChunk = GrokToolsV1.ToolStreamChunk
public typealias ToolSuccess = GrokToolsV1.ToolSuccess
public typealias TruncationConfig = GrokToolsV1.TruncationConfig
public typealias VersionWarning = GrokToolsV1.VersionWarning
public typealias GrokToolsService = GrokToolsV1.GrokToolsService
public typealias ProtobufToolError = GrokToolsV1.ToolError
public typealias ProtobufToolCapabilities = GrokToolsV1.ToolCapabilities
public typealias ProtobufToolConfigEntry = GrokToolsV1.ToolConfigEntry
public let grokToolsServiceRPCNames: [String] = GrokToolsV1.serviceRPCNames
public let grokToolsServiceStreamingRPCs: Set<String> = GrokToolsV1.streamingRPCNames
