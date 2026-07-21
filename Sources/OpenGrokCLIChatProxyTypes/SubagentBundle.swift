// SubagentBundle.swift
//
// Shared bundle payload for subagent persona, role, and agent definitions.
// Ported from prod/mc/cli-chat-proxy-types/src/subagent_bundle.rs.

import Foundation

/// Shared bundle payload for subagent persona, role, and agent definitions.
public struct SubagentBundle: Hashable, Sendable, Codable, Equatable {
    public var version: String
    public var personas: [String: String]
    public var roles: [String: String]
    public var agents: [String: String]
    public var skills: [String: String]

    public init(
        version: String,
        personas: [String: String] = [:],
        roles: [String: String] = [:],
        agents: [String: String] = [:],
        skills: [String: String] = [:]
    ) {
        self.version = version
        self.personas = personas
        self.roles = roles
        self.agents = agents
        self.skills = skills
    }

    /// Create an empty bundle with the given version.
    public static func empty(_ version: String) -> SubagentBundle {
        SubagentBundle(version: version)
    }

    enum CodingKeys: String, CodingKey {
        case version
        case personas
        case roles
        case agents
        case skills
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        personas = try container.decodeIfPresent([String: String].self, forKey: .personas) ?? [:]
        roles = try container.decodeIfPresent([String: String].self, forKey: .roles) ?? [:]
        agents = try container.decodeIfPresent([String: String].self, forKey: .agents) ?? [:]
        skills = try container.decodeIfPresent([String: String].self, forKey: .skills) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(personas, forKey: .personas)
        try container.encode(roles, forKey: .roles)
        try container.encode(agents, forKey: .agents)
        if !skills.isEmpty {
            try container.encode(skills, forKey: .skills)
        }
    }
}
