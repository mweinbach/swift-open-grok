import Foundation
import OpenGrokACPRuntime
import OpenGrokSandbox
import OpenGrokWorkspace

/// Authority a leader client can actually serve on its own reverse channel.
///
/// Rust copies these values directly from explicit root flags
/// (`xai-grok-pager/src/app/mod.rs:842-844`). A TUI is not itself a reverse
/// terminal backend, and access to this process's workspace is not evidence
/// that a shared leader may read or edit it through an unimplemented client.
enum LiveACPLaunchCapabilities {
    enum FilesystemAccess: Sendable, Equatable {
        case unavailable
        case readOnly
        case readWrite
    }

    /// Future reverse handlers must prove all three mediation boundaries.
    /// Until they exist, production uses the all-false default.
    struct Backing: Sendable, Equatable {
        var terminal: Bool
        var filesystem: FilesystemAccess
        var permissionsEnforced: Bool
        var sandboxEnforced: Bool
        var sessionScoped: Bool

        init(
            terminal: Bool = false,
            filesystem: FilesystemAccess = .unavailable,
            permissionsEnforced: Bool = false,
            sandboxEnforced: Bool = false,
            sessionScoped: Bool = false
        ) {
            self.terminal = terminal
            self.filesystem = filesystem
            self.permissionsEnforced = permissionsEnforced
            self.sandboxEnforced = sandboxEnforced
            self.sessionScoped = sessionScoped
        }

        static let unavailable = Backing()
    }

    /// The already-resolved owner/admin policy, never project-provided wishes.
    struct Security: Sendable {
        var projectTrusted: Bool
        var permissions: ResolvedPermissions
        var sandboxProfile: ProfileName
        var configurationLoadFailure: String?

        init(
            projectTrusted: Bool,
            permissions: ResolvedPermissions = ResolvedPermissions(),
            sandboxProfile: ProfileName,
            configurationLoadFailure: String? = nil
        ) {
            self.projectTrusted = projectTrusted
            self.permissions = permissions
            self.sandboxProfile = sandboxProfile
            self.configurationLoadFailure = configurationLoadFailure
        }
    }

    static func resolve(
        options: CLIExecutionOptions,
        interactiveSurfaceAvailable: Bool,
        clientVersion: String = OpenGrokCLIVersion.compiled,
        backing: Backing = .unavailable,
        security: Security? = nil
    ) throws -> ACPLeaderClientCapabilities {
        let requested: [(enabled: Bool, flag: String)] = [
            (options.advanced.terminal, "--terminal"),
            (options.advanced.fsRead, "--fs-read"),
            (options.advanced.fsWrite, "--fs-write"),
        ]

        guard let firstRequested = requested.first(where: { $0.enabled }) else {
            return ACPLeaderClientCapabilities(clientVersion: clientVersion)
        }

        guard options.common.leader else {
            throw unsupported(firstRequested.flag, "requires a leader client with a reverse handler")
        }

        if options.advanced.terminal {
            guard options.mode == .interactive, interactiveSurfaceAvailable else {
                throw unsupported("--terminal", "requires an available interactive terminal surface")
            }
            guard backing.terminal else {
                throw unsupported("--terminal", "no reverse terminal handler is installed")
            }
        }

        if options.advanced.fsRead, backing.filesystem == .unavailable {
            throw unsupported("--fs-read", "no reverse filesystem read handler is installed")
        }
        if options.advanced.fsWrite, backing.filesystem != .readWrite {
            throw unsupported("--fs-write", "no writable reverse filesystem handler is installed")
        }

        guard backing.sessionScoped else {
            throw unsupported(firstRequested.flag, "reverse operations are not isolated to this session")
        }
        guard backing.permissionsEnforced else {
            throw unsupported(firstRequested.flag, "reverse operations bypass the permission pipeline")
        }
        guard backing.sandboxEnforced else {
            throw unsupported(firstRequested.flag, "reverse operations bypass sandbox confinement")
        }
        guard let security else {
            throw unsupported(firstRequested.flag, "effective security policy is unavailable")
        }
        guard security.configurationLoadFailure == nil else {
            throw unsupported(firstRequested.flag, "effective security policy could not be loaded")
        }
        guard security.projectTrusted else {
            throw unsupported(firstRequested.flag, "the workspace is not trusted")
        }

        if options.advanced.terminal,
           try denied(.bash, options: options, security: security) {
            throw unsupported("--terminal", "execution is denied by effective permission policy")
        }
        if options.advanced.fsRead,
           try denied(.read, options: options, security: security) {
            throw unsupported("--fs-read", "filesystem reads are denied by effective permission policy")
        }
        if options.advanced.fsWrite {
            guard security.sandboxProfile != .readOnly else {
                throw unsupported("--fs-write", "the effective sandbox profile is read-only")
            }
            guard options.common.permissions.mode != .plan,
                  security.permissions.defaultMode != .plan
            else {
                throw unsupported("--fs-write", "plan mode does not authorize general filesystem writes")
            }
            guard try !denied(.edit, options: options, security: security) else {
                throw unsupported("--fs-write", "filesystem writes are denied by effective permission policy")
            }
        }

        return ACPLeaderClientCapabilities(
            clientVersion: clientVersion,
            terminal: options.advanced.terminal,
            fsRead: options.advanced.fsRead,
            fsWrite: options.advanced.fsWrite
        )
    }

    private static func denied(
        _ access: ToolFilter,
        options: CLIExecutionOptions,
        security: Security
    ) throws -> Bool {
        var rules = security.permissions.config.rules
        for raw in options.common.permissions.denyRules {
            do {
                rules.append(try parsePermissionRule(raw, action: .deny, source: .cli))
            } catch {
                throw unsupported(
                    access == .edit ? "--fs-write" : access == .read ? "--fs-read" : "--terminal",
                    "an explicit deny rule could not be safely evaluated"
                )
            }
        }
        return rules.contains { rule in
            guard rule.action == .deny,
                  rule.tool == .any || rule.tool == access
            else { return false }
            guard let pattern = rule.pattern else { return true }
            return pattern == "*" || pattern == "**"
        }
    }

    private static func unsupported(_ flag: String, _ reason: String) -> CLIApplicationError {
        .unsupported(route: "\(flag), which \(reason)")
    }
}
