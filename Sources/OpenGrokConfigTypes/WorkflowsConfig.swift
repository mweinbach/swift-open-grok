import Foundation

/// Local workflow feature configuration from `[workflows]`.
///
/// This is deliberately separate from `RemoteSettings.workflowsEnabled`: the
/// pinned Open Grok behavior treats the remote rollout field as wire-only and
/// resolves the local kill-switch from environment/config/default instead.
public struct WorkflowsConfig: Hashable, Sendable, Codable, Equatable {
    public var enabled: Bool?

    public init(enabled: Bool? = nil) {
        self.enabled = enabled
    }
}
