import Foundation

/// Coarse session activity carried by the leader roster protocol.
///
/// Rust reference: `crates/codegen/xai-grok-shell/src/agent/roster.rs:20-41`.
public enum ACPLeaderRosterActivity: String, Sendable, Hashable, Codable {
    case working
    case idle
    case needsInput = "needs_input"
    case dormant
    case completed
    case dead
}

/// Where a roster session is hosted.
///
/// Rust reference: `crates/codegen/xai-grok-shell/src/agent/roster.rs:43-50`.
public enum ACPLeaderRosterOrigin: Sendable, Hashable {
    case local
    case remote(host: String)
}

extension ACPLeaderRosterOrigin: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case host
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "local":
            self = .local
        case "remote":
            self = .remote(host: try container.decode(String.self, forKey: .host))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "unknown leader roster origin"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try container.encode("local", forKey: .kind)
        case .remote(let host):
            try container.encode("remote", forKey: .kind)
            try container.encode(host, forKey: .host)
        }
    }
}

/// One dashboard-sized summary of a leader-hosted session.
///
/// Rust reference: `crates/codegen/xai-grok-shell/src/agent/roster.rs:52-77`.
public struct ACPLeaderRosterEntry: Sendable, Hashable, Codable {
    public var sessionId: String
    public var title: String?
    public var cwd: String
    public var isWorktree: Bool
    public var modelId: String?
    public var reasoningEffort: String?
    public var yolo: Bool
    public var activity: ACPLeaderRosterActivity
    public var resident: Bool
    public var lastChangeUnixMs: Int64
    public var origin: ACPLeaderRosterOrigin

    public init(
        sessionId: String,
        title: String? = nil,
        cwd: String,
        isWorktree: Bool,
        modelId: String? = nil,
        reasoningEffort: String? = nil,
        yolo: Bool,
        activity: ACPLeaderRosterActivity,
        resident: Bool,
        lastChangeUnixMs: Int64,
        origin: ACPLeaderRosterOrigin
    ) {
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.isWorktree = isWorktree
        self.modelId = modelId
        self.reasoningEffort = reasoningEffort
        self.yolo = yolo
        self.activity = activity
        self.resident = resident
        self.lastChangeUnixMs = lastChangeUnixMs
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, title, cwd, isWorktree, modelId, reasoningEffort
        case yolo, activity, resident, lastChangeUnixMs, origin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        cwd = try container.decode(String.self, forKey: .cwd)
        isWorktree = try container.decode(Bool.self, forKey: .isWorktree)
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        yolo = try container.decode(Bool.self, forKey: .yolo)
        activity = try container.decode(ACPLeaderRosterActivity.self, forKey: .activity)
        resident = try container.decode(Bool.self, forKey: .resident)
        lastChangeUnixMs = try container.decode(Int64.self, forKey: .lastChangeUnixMs)
        origin = try container.decode(ACPLeaderRosterOrigin.self, forKey: .origin)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        if let title {
            try container.encode(title, forKey: .title)
        } else {
            try container.encodeNil(forKey: .title)
        }
        try container.encode(cwd, forKey: .cwd)
        try container.encode(isWorktree, forKey: .isWorktree)
        if let modelId {
            try container.encode(modelId, forKey: .modelId)
        } else {
            try container.encodeNil(forKey: .modelId)
        }
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try container.encode(yolo, forKey: .yolo)
        try container.encode(activity, forKey: .activity)
        try container.encode(resident, forKey: .resident)
        try container.encode(lastChangeUnixMs, forKey: .lastChangeUnixMs)
        try container.encode(origin, forKey: .origin)
    }
}

/// Snapshot response for `x.ai/sessions/list`.
///
/// Rust reference: `crates/codegen/xai-grok-shell/src/agent/roster.rs:79-83`.
public struct ACPLeaderRosterListResponse: Sendable, Hashable, Codable {
    public var sessions: [ACPLeaderRosterEntry]

    public init(sessions: [ACPLeaderRosterEntry]) {
        self.sessions = sessions
    }
}

/// Delta notification params for `x.ai/sessions/changed`.
///
/// Rust reference: `crates/codegen/xai-grok-shell/src/agent/roster.rs:85-92`.
public struct ACPLeaderRosterChanged: Sendable, Hashable, Codable {
    public var upserted: [ACPLeaderRosterEntry]
    public var removed: [String]

    public init(
        upserted: [ACPLeaderRosterEntry] = [],
        removed: [String] = []
    ) {
        self.upserted = upserted
        self.removed = removed
    }
}

public enum ACPLeaderRosterMethods {
    public static let sessionsList = "x.ai/sessions/list"
    public static let sessionsChanged = "x.ai/sessions/changed"
}
