// CodexPermissions.swift
//
// Session-scoped execution policy projected exclusively onto Codex requests.
// Mirrors `xai-grok-sampler/src/config.rs:29-52`.

import Foundation

/// The approval behavior actually enforced by the local tool runtime.
public enum CodexApprovalPolicy: String, Codable, Sendable, Equatable, Hashable {
    case onRequest = "on-request"
    case never = "never"
}

/// Truthful execution policy exposed to the Codex provider.
///
/// Callers must derive this from successfully applied sandbox state and the
/// active permission handle, never from a requested profile or a UI label.
public struct CodexPermissions: Codable, Sendable, Equatable, Hashable {
    public var sandbox: String
    public var sandboxMode: String
    public var sandboxProfile: String?
    public var networkAccess: Bool
    public var writableRoots: [String]
    public var approvalPolicy: CodexApprovalPolicy
    public var autoReviewEnabled: Bool

    public init(
        sandbox: String,
        sandboxMode: String,
        sandboxProfile: String? = nil,
        networkAccess: Bool,
        writableRoots: [String],
        approvalPolicy: CodexApprovalPolicy,
        autoReviewEnabled: Bool
    ) {
        self.sandbox = sandbox
        self.sandboxMode = sandboxMode
        self.sandboxProfile = sandboxProfile
        self.networkAccess = networkAccess
        self.writableRoots = writableRoots
        self.approvalPolicy = approvalPolicy
        self.autoReviewEnabled = autoReviewEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case sandbox
        case sandboxMode = "sandbox_mode"
        case sandboxProfile = "sandbox_profile"
        case networkAccess = "network_access"
        case writableRoots = "writable_roots"
        case approvalPolicy = "approval_policy"
        case autoReviewEnabled = "auto_review_enabled"
    }

    var renderedInstructions: String {
        let sandboxDescription: String
        switch sandboxMode {
        case "read-only":
            sandboxDescription =
                "The filesystem sandbox permits reading files; workspace files cannot be modified."
        case "workspace-write":
            sandboxDescription =
                "The filesystem sandbox permits reading files and writing only within its allowed roots."
        default:
            sandboxDescription =
                "No filesystem sandbox is active; commands have unrestricted filesystem access subject to local permission rules."
        }

        let approvalDescription: String
        switch approvalPolicy {
        case .never:
            approvalDescription =
                "Approval policy is `never`: Open Grok automatically permits tool executions unless a hard deny rule or plan-mode restriction applies. Do not claim that approval is required."
        case .onRequest where autoReviewEnabled:
            approvalDescription =
                "Approval policy is `on-request` and `approvals_reviewer` is `auto_review`: Open Grok's permission classifier reviews tool actions automatically; hard deny rules and the actual sandbox remain enforced."
        case .onRequest:
            approvalDescription =
                "Approval policy is `on-request`: Open Grok requests user approval when its local permission policy requires it. Permission prompts are managed by the tool runtime."
        }

        let rootsDescription: String
        if writableRoots.isEmpty {
            rootsDescription = ""
        } else {
            let roots = writableRoots.map { "`\($0)`" }.joined(separator: ", ")
            rootsDescription = "\nThe writable roots are \(roots)."
        }

        let networkDescription = networkAccess ? "enabled" : "restricted"
        return """
            <permissions instructions>
            Filesystem sandboxing: `sandbox_mode` is `\(sandboxMode)`. \(sandboxDescription) Network access is \(networkDescription).
            \(approvalDescription)\(rootsDescription)
            </permissions instructions>
            """
    }

    func turnMetadata(sessionID: String?, turnID: String?) -> String {
        let metadata = TurnMetadata(
            sandbox: sandbox,
            sandboxMode: sandboxMode,
            autoReviewEnabled: autoReviewEnabled,
            sessionID: sessionID,
            threadID: sessionID,
            turnID: turnID,
            sandboxProfile: sandboxProfile
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return String(decoding: try encoder.encode(metadata), as: UTF8.self)
        } catch {
            // Every field is String, Bool, or Optional thereof, so JSONEncoder
            // cannot reject a value here. An impossible failure must not turn
            // an enforced policy into a silently policy-free Codex request.
            preconditionFailure("Could not encode Codex execution-policy metadata: \(error)")
        }
    }

    private struct TurnMetadata: Encodable {
        var sandbox: String
        var sandboxMode: String
        var autoReviewEnabled: Bool
        var sessionID: String?
        var threadID: String?
        var turnID: String?
        var sandboxProfile: String?

        private enum CodingKeys: String, CodingKey {
            case sandbox
            case sandboxMode = "sandbox_mode"
            case autoReviewEnabled = "auto_review_enabled"
            case sessionID = "session_id"
            case threadID = "thread_id"
            case turnID = "turn_id"
            case sandboxProfile = "open_grok_sandbox_profile"
        }
    }
}
