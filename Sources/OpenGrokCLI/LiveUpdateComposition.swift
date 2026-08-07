// LiveUpdateComposition.swift
//
// Makes `open-grok update` reachable, and ports the startup version-policy
// gate. Before this file the `update` route parsed, was advertised in help, and
// then died in `LiveAuthComposition`'s `.utility` fallthrough as
// `unsupported(route:)` — an installed user could never upgrade.
//
// Ports:
//   * `xai-grok-pager-bin/src/main.rs:948-956` (`run_update_if_available`
//     NonBlocking) and `:2189-2207` (`should_check_for_updates`).
//   * `xai-grok-pager-bin/src/main.rs:2249-2296` (`run_update_command`) — flag
//     validation order and the exact refusal strings.
//   * `xai-grok-update/src/auto_update.rs:49-100` (`UpdateStatus`,
//     `print_update_status`) — the `--check` surface and its JSON field names.
//   * `xai-grok-update/src/auto_update.rs:457-668` (`check_update_background`,
//     `run_update_if_available`, cadence cache) — launch-time background check.
//   * `xai-grok-update/src/version_policy.rs:98-107`
//     (`enforce_version_policy_or_exit`) — the managed `required_minimum` /
//     `required_maximum` startup gate.
//
// The execution half (download, SHA-256, link swap, rollback) lives in
// `OpenGrokUpdate/UpdateService.swift`; this file is argument handling and
// presentation only.

import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokUpdate
import OpenGrokVersion

// MARK: - Launch-time background update check

/// Port of upstream's non-blocking launch update check
/// (`auto_update.rs:546-668`, fired from `main.rs:948-956`).
public enum LiveLaunchAutoUpdate {
    public struct Request: Sendable {
        public let noAutoUpdate: Bool
        public let services: LiveUpdateServices

        public init(noAutoUpdate: Bool, services: LiveUpdateServices) {
            self.noAutoUpdate = noAutoUpdate
            self.services = services
        }
    }

    private static let disableAutoUpdaterEnvironmentKeys = [
        "OPENGROK_DISABLE_AUTOUPDATER",
        "GROK_DISABLE_AUTOUPDATER",
    ]

    /// Gate automatic update checks without affecting an explicit
    /// `open-grok update` (`main.rs:2189-2207`).
    public static func shouldCheckForUpdates(
        noAutoUpdateFlag: Bool,
        environment: [String: String]
    ) -> Bool {
        let disabledByEnvironment = Self.disableAutoUpdaterEnvironmentKeys.contains { name in
            environment[name].map(envFlagEnabled) ?? false
        }
        let testLaunchUpdateOverride = environment["OPENGROK_TEST_LAUNCH_UPDATE"].map(envFlagEnabled) ?? false
        return updateChecksAllowed(
            noAutoUpdateFlag: noAutoUpdateFlag,
            debugBuild: _isDebugBuild() && !testLaunchUpdateOverride,
            disabledByEnvironment: disabledByEnvironment
        )
    }

    static func updateChecksAllowed(
        noAutoUpdateFlag: Bool,
        debugBuild: Bool,
        disabledByEnvironment: Bool
    ) -> Bool {
        !noAutoUpdateFlag && !debugBuild && !disabledByEnvironment
    }

    /// Reads `[cli].auto_update`. `nil`/absent defaults to enabled
    /// (`auto_update.rs:569`, registry default).
    static func cliAutoUpdateConfigValue(environment: [String: String]) -> Bool? {
        guard let layers = try? ConfigLayers.load(environment: environment),
              case .boolean(let value)? = layers.effectiveConfigBase()[path: ["cli", "auto_update"]]
        else { return nil }
        return value
    }

    /// Fire-and-forget after session readiness. Never awaited by callers; a slow
    /// or failing feed must not delay or fail launch (`auto_update.rs:457-467`).
    public static func spawnIfNeeded(
        request: Request?,
        environment: [String: String],
        streams: CLIStreams
    ) -> Task<Void, Never>? {
        guard let request else { return nil }
        guard shouldCheckForUpdates(
            noAutoUpdateFlag: request.noAutoUpdate,
            environment: environment
        ) else {
            return nil
        }
        let services = request.services
        return Task {
            await runUpdateIfAvailable(
                services: services,
                environment: environment,
                streams: streams
            )
        }
    }

    static func runUpdateIfAvailable(
        services: LiveUpdateServices,
        environment: [String: String],
        streams: CLIStreams
    ) async {
        if await isVersionCacheFresh(environment: environment) {
            return
        }
        if cliAutoUpdateConfigValue(environment: environment) == false {
            return
        }

        let current = OpenGrokCLIVersion.installed(environment: environment)
        let policy = LiveUpdateComposition.resolveVersionPolicy(environment: environment)
        let channel = UpdateChannel.stable

        let release: ReleaseCandidate
        do {
            release = try await services.fetchLatestRelease(environment)
        } catch {
            return
        }

        let decision = UpdatePlanner.decide(
            current: current,
            target: release.version,
            channel: channel,
            installer: .openGrok,
            policy: policy
        )
        guard decision.shouldUpdate else {
            try? await writeVersionCache(version: release.version, environment: environment)
            return
        }

        let channelLabel = " [\(channel.rawValue)]"
        streams.err(
            "A new version of Open Grok is available: "
                + "\(current) -> \(decision.targetVersion)\(channelLabel)\n"
        )
        await performBackgroundInstall(
            release: release,
            decision: decision,
            environment: environment,
            services: services
        )
    }

    static func performBackgroundInstall(
        release: ReleaseCandidate,
        decision: UpdateDecision,
        environment: [String: String],
        services: LiveUpdateServices
    ) async {
        let platform = ReleasePlatform.current
        guard platform.isSupportedForRelease else { return }
        guard let asset = try? ReleaseSelector.asset(named: platform.assetName, in: release) else {
            return
        }
        if (try? await services.install(
            decision.targetVersion,
            asset,
            environment,
            { _ in }
        )) != nil {
            try? await writeVersionCache(version: release.version, environment: environment)
        }
    }

    private static func _isDebugBuild() -> Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

// MARK: - Composition

public enum LiveUpdateComposition {
    /// Utility routes this composition owns.
    public static let routeNames: Set<String> = ["update"]

    /// Whether the launcher should delegate `command` here.
    public static func handles(_ command: CLICommand) -> Bool {
        guard case .utility(let options) = command else { return false }
        return routeNames.contains(options.name)
    }

    /// Launcher entry point, shaped like `LiveAuthComposition.session`.
    public static func session(
        for command: CLICommand,
        context: CLIApplicationContext,
        services: LiveUpdateServices = .production
    ) async throws -> CLIApplicationSession {
        guard case .utility(let options) = command, routeNames.contains(options.name) else {
            throw CLIApplicationError.unsupported(route: command.routeName)
        }
        try await run(
            options: options,
            environment: context.environment,
            streams: context.streams,
            services: services
        )
        return CLIApplicationSession(waitForExit: {}, shutdown: {})
    }

    // MARK: Run

    public static func run(
        options: CLIUtilityOptions,
        environment: [String: String],
        streams: CLIStreams,
        services: LiveUpdateServices = .production
    ) async throws {
        let check = options.isSet("--check")
        let json = options.isSet("--json")
        let forceReinstall = options.isSet("--force-reinstall") || options.isSet("--force")
        let pinnedVersion = options.options["--version"]

        // Validation order is load-bearing: Rust rejects in exactly this
        // sequence, so a command with two problems reports the same one.
        guard !(json && !check) else {
            throw CLIApplicationError.failed("--json requires --check")
        }
        if options.isSet("--alpha") || options.isSet("--stable") || options.isSet("--enterprise") {
            throw CLIApplicationError.failed("Open Grok releases do not use xAI update channels")
        }
        if let pinnedVersion {
            guard (try? UpdateVersion.normalize(pinnedVersion)) != nil else {
                throw CLIApplicationError.failed(
                    "'\(pinnedVersion)' is not a valid version. Expected semver like 0.1.150"
                )
            }
        }
        if check && (forceReinstall || pinnedVersion != nil) {
            throw CLIApplicationError.failed(
                "--check cannot be combined with --force-reinstall or --version"
            )
        }

        let current = OpenGrokCLIVersion.installed(environment: environment)
        let policy = resolveVersionPolicy(environment: environment)

        if check {
            let status = await checkStatus(
                current: current,
                policy: policy,
                environment: environment,
                services: services
            )
            writeStatus(status, json: json, streams: streams)
            if status.error != nil {
                throw CLIApplicationError.failed("Open Grok update check failed")
            }
            return
        }

        try await performUpdate(
            current: current,
            pinnedVersion: pinnedVersion,
            forceReinstall: forceReinstall,
            policy: policy,
            environment: environment,
            streams: streams,
            services: services
        )
    }

    // MARK: --check

    static func checkStatus(
        current: String,
        policy: VersionPolicy,
        environment: [String: String],
        services: LiveUpdateServices
    ) async -> UpdateStatus {
        do {
            let release = try await services.fetchLatestRelease(environment)
            let decision = UpdatePlanner.decide(
                current: current,
                target: release.version,
                channel: .stable,
                installer: .openGrok,
                policy: policy
            )
            return UpdateStatus(decision: decision, autoUpdate: nil)
        } catch {
            return UpdateStatus(
                currentVersion: current,
                latestVersion: nil,
                updateAvailable: false,
                installer: UpdateInstaller.openGrok.rawValue,
                channel: UpdateChannel.stable.rawValue,
                autoUpdate: nil,
                error: describe(error)
            )
        }
    }

    static func writeStatus(_ status: UpdateStatus, json: Bool, streams: CLIStreams) {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(status) {
                streams.out(String(decoding: data, as: UTF8.self) + "\n")
            }
            return
        }
        if let error = status.error {
            streams.out("Open Grok - v\(status.currentVersion) [\(status.channel)]\n")
            streams.out("Update check failed: \(error)\n")
            return
        }
        if status.updateAvailable {
            if let latest = status.latestVersion {
                streams.out(
                    "A new version of Open Grok is available: "
                        + "\(status.currentVersion) -> \(latest) [\(status.channel)]\n"
                )
            } else {
                streams.out("A new version of Open Grok is available.\n")
            }
            return
        }
        if let latest = status.latestVersion {
            streams.out(
                "Open Grok - v\(status.currentVersion) (latest: \(latest)) [\(status.channel)]\n"
            )
        } else {
            streams.out("Open Grok - v\(status.currentVersion) [\(status.channel)]\n")
        }
    }

    // MARK: install

    static func performUpdate(
        current: String,
        pinnedVersion: String?,
        forceReinstall: Bool,
        policy: VersionPolicy,
        environment: [String: String],
        streams: CLIStreams,
        services: LiveUpdateServices
    ) async throws {
        let platform = ReleasePlatform.current
        guard platform.isSupportedForRelease else {
            throw CLIApplicationError.failed(ReleasePlatform.unsupportedPlatformMessage)
        }

        let release: ReleaseCandidate
        do {
            release = try await services.fetchLatestRelease(environment)
        } catch {
            throw CLIApplicationError.failed(describe(error))
        }

        let target: String
        if let pinnedVersion {
            let normalized = try UpdateVersion.normalize(pinnedVersion)
            // A pin below a hard organizational floor is refused; a pin *above*
            // a ceiling is deliberately allowed so a too-new install can
            // recover (`version_policy.rs:62-76`).
            if let floor = policy.requiredMinimum,
               !policy.hasContradictoryRequiredRange,
               let parsed = try? SemVerVersion.parse(normalized),
               !UpdateVersion.satisfiesFloor(parsed, floor) {
                throw CLIApplicationError.failed(
                    "Cannot install Grok \(normalized): the minimum allowed version is "
                        + "\(floor). Run `open-grok update` to install the latest allowed version."
                )
            }
            target = normalized
            streams.out("Installing Open Grok \(target) (current: \(current))...\n")
        } else {
            let decision = UpdatePlanner.decide(
                current: current,
                target: release.version,
                channel: .stable,
                installer: .openGrok,
                policy: policy
            )
            guard decision.shouldUpdate || forceReinstall else {
                streams.out("Already up to date (\(current)).\n")
                return
            }
            target = decision.targetVersion
            if decision.shouldUpdate {
                streams.out("Updating Open Grok \(current) → \(target)\n")
            } else {
                streams.out("Forcing reinstall of Open Grok \(target) (already up to date)\n")
            }
        }

        // The pinned path may name a version the *latest* release does not
        // carry; refuse rather than silently installing whatever latest holds.
        guard release.version == target else {
            throw CLIApplicationError.failed(
                "release \(release.tagName) publishes \(release.version), not \(target); "
                    + "only the latest release is installable"
            )
        }
        let asset: ReleaseAsset
        do {
            asset = try ReleaseSelector.asset(named: platform.assetName, in: release)
        } catch {
            throw CLIApplicationError.failed(describe(error))
        }

        do {
            let result = try await services.install(target, asset, environment, streams.out)
            streams.out("  ✓ Open Grok v\(result.version) installed successfully!\n")
            streams.out("  Please restart Open Grok.\n")
        } catch {
            throw CLIApplicationError.failed(
                "Auto-update failed: \(describe(error))\n\n"
                    + "Please reinstall Open Grok via:\n  \(manualInstallCommand())"
            )
        }
    }

    static func manualInstallCommand() -> String {
        #if os(Windows)
        return "irm https://github.com/mweinbach/open-grok/releases/latest/download/install.ps1 | iex"
        #else
        return "curl -fsSL https://github.com/mweinbach/open-grok/releases/latest/download/install.sh | bash"
        #endif
    }

    static func describe(_ error: Error) -> String {
        if let update = error as? UpdateServiceError { return update.description }
        if let update = error as? OpenGrokUpdateError { return update.description }
        if let cli = error as? CLIApplicationError { return cli.description }
        return "\(error)"
    }
}

// MARK: - Services seam

/// Injection seam so tests can drive the route without network or filesystem.
public struct LiveUpdateServices: Sendable {
    public let fetchLatestRelease: @Sendable ([String: String]) async throws -> ReleaseCandidate
    public let install: @Sendable (
        String, ReleaseAsset, [String: String], @Sendable (String) -> Void
    ) async throws -> ReleaseInstallService.InstallResult

    public init(
        fetchLatestRelease: @escaping @Sendable ([String: String]) async throws -> ReleaseCandidate,
        install: @escaping @Sendable (
            String, ReleaseAsset, [String: String], @Sendable (String) -> Void
        ) async throws -> ReleaseInstallService.InstallResult
    ) {
        self.fetchLatestRelease = fetchLatestRelease
        self.install = install
    }

    public static let production = LiveUpdateServices(
        fetchLatestRelease: { _ in
            guard let apiURL = URL(string: OpenGrokUpdateConstants.releaseAPIURL) else {
                throw UpdateServiceError.releaseFetchFailed("release API URL is malformed")
            }
            return try await UpdateReleaseClient.production().fetchLatestRelease(apiURL: apiURL)
        },
        install: { version, asset, environment, progress in
            let service = ReleaseInstallService(
                client: .production(),
                paths: UpdatePaths(environment: environment)
            )
            return try await service.install(
                version: version,
                asset: asset,
                progress: progress
            )
        }
    )
}

// MARK: - Startup version policy gate

/// Port of `enforce_version_policy_or_exit()` (`version_policy.rs:98-107`).
///
/// Rust calls this on the three *session* entry points only — `version`,
/// `doctor`, `setup`, `update` and `login` return before it so a machine pinned
/// outside the allowed range can still recover itself.
public enum LiveVersionPolicyGate {
    public enum Decision: Sendable, Equatable {
        case inRange
        case below(current: String, minimum: String)
        case above(current: String, maximum: String)
    }

    /// Routes exempt from the gate, so a blocked install can still be repaired.
    public static let exemptUtilityRoutes: Set<String> = [
        "update", "login", "logout", "setup", "doctor"
    ]

    public static func isExempt(_ command: CLICommand) -> Bool {
        switch command {
        case .launch, .serve, .leader:
            return false
        default:
            // Rust returns from every direct management/inspection command
            // before the later default startup check. Swift routes those
            // commands through the async application seam, so exempting all
            // non-session commands preserves that boundary instead of
            // accidentally blocking recovery or management operations.
            return true
        }
    }

    public static func evaluate(
        current: String,
        policy: VersionPolicy
    ) -> Decision {
        // A contradictory managed range fails open rather than bricking every
        // session on a misconfigured policy file.
        guard !policy.hasContradictoryRequiredRange else { return .inRange }
        // An unparseable current version (dev builds) also fails open.
        guard let parsed = try? SemVerVersion.parse((try? UpdateVersion.normalize(current)) ?? current)
        else { return .inRange }

        if let minimum = policy.requiredMinimum,
           !UpdateVersion.satisfiesFloor(parsed, minimum) {
            return .below(current: "\(parsed)", minimum: "\(minimum)")
        }
        if let maximum = policy.requiredMaximum, parsed > maximum {
            return .above(current: "\(parsed)", maximum: "\(maximum)")
        }
        return .inRange
    }

    public static func message(for decision: Decision) -> String? {
        switch decision {
        case .inRange:
            return nil
        case .below(let current, let minimum):
            return """
                This version of Grok (\(current)) is older than the minimum required by your \
                organization (\(minimum)).

                Update to an approved version through your organization's approved method \
                (for example, run `open-grok update`).
                """
        case .above(let current, let maximum):
            return """
                This version of Grok (\(current)) is newer than the maximum allowed by your \
                organization (\(maximum)).

                Install an approved version through your organization's approved method \
                (for example, run `open-grok update --version \(maximum)`).
                """
        }
    }

    /// Returns the refusal message when startup must be blocked, `nil` to
    /// proceed. Callers print to stderr and exit 1.
    public static func refusal(
        for command: CLICommand,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard !isExempt(command) else { return nil }
        let policy = LiveUpdateComposition.resolveVersionPolicy(environment: environment)
        return message(for: evaluate(
            current: OpenGrokCLIVersion.installed(environment: environment),
            policy: policy
        ))
    }
}

// MARK: - Policy resolution

extension LiveUpdateComposition {
    /// Fold the four version bounds across the config layers.
    ///
    /// Floors take the maximum and ceilings the minimum across layers, so a
    /// user layer or an environment variable can only ever *tighten* what an
    /// administrator set — never loosen it (`resolve/version.rs:136-160`).
    public static func resolveVersionPolicy(
        environment: [String: String]
    ) -> VersionPolicy {
        let layers = (try? ConfigLayers.load(environment: environment)) ?? ConfigLayers()
        var candidates: [TOMLValue] = [layers.systemManaged, layers.managed, layers.user]
        if let req = layers.userRequirements { candidates.append(req) }
        if let req = layers.systemRequirements { candidates.append(req) }
        if let req = layers.mdmRequirements { candidates.append(req) }

        var policy = VersionPolicy()
        for layer in candidates {
            fold(&policy, layer: layer)
        }
        foldEnvironment(&policy, environment: environment)

        // A contradiction introduced by the user layer or the environment must
        // not be able to fabricate organizational policy, so re-resolve the
        // required range from managed layers alone when it happens.
        if policy.hasContradictoryRequiredRange {
            var managedOnly = VersionPolicy()
            fold(&managedOnly, layer: layers.systemManaged)
            fold(&managedOnly, layer: layers.managed)
            if let req = layers.systemRequirements { fold(&managedOnly, layer: req) }
            if let req = layers.mdmRequirements { fold(&managedOnly, layer: req) }
            policy.requiredMinimum = managedOnly.requiredMinimum
            policy.requiredMaximum = managedOnly.requiredMaximum
        }
        return policy
    }

    private static func fold(_ policy: inout VersionPolicy, layer: TOMLValue) {
        raiseFloor(&policy.minimum, string(layer, "minimum_version"))
        lowerCeiling(&policy.maximum, string(layer, "maximum_version"))
        raiseFloor(&policy.requiredMinimum, string(layer, "required_minimum_version"))
        lowerCeiling(&policy.requiredMaximum, string(layer, "required_maximum_version"))
    }

    private static func foldEnvironment(
        _ policy: inout VersionPolicy,
        environment: [String: String]
    ) {
        raiseFloor(&policy.minimum, environment["GROK_MINIMUM_VERSION"])
        lowerCeiling(&policy.maximum, environment["GROK_MAXIMUM_VERSION"])
        raiseFloor(&policy.requiredMinimum, environment["GROK_REQUIRED_MINIMUM_VERSION"])
        lowerCeiling(&policy.requiredMaximum, environment["GROK_REQUIRED_MAXIMUM_VERSION"])
    }

    private static func string(_ layer: TOMLValue, _ key: String) -> String? {
        guard case .string(let value)? = layer[path: ["cli", key]] else { return nil }
        return value
    }

    private static func raiseFloor(_ slot: inout SemVerVersion?, _ candidate: String?) {
        guard let candidate,
              let normalized = try? UpdateVersion.normalize(candidate),
              let parsed = try? SemVerVersion.parse(normalized) else { return }
        if let existing = slot { slot = Swift.max(existing, parsed) } else { slot = parsed }
    }

    private static func lowerCeiling(_ slot: inout SemVerVersion?, _ candidate: String?) {
        guard let candidate,
              let normalized = try? UpdateVersion.normalize(candidate),
              let parsed = try? SemVerVersion.parse(normalized) else { return }
        if let existing = slot { slot = Swift.min(existing, parsed) } else { slot = parsed }
    }
}
