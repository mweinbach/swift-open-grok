import Foundation
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokCrashHandler
import OpenGrokFileUtils

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Injectable so an in-process CLI test never replaces process-global signal handlers.
struct LiveCrashBootstrapServices: Sendable {
    let installTerminalRestoration: @Sendable () -> Void
    let prepareCrashDirectory: @Sendable (URL) throws -> URL
    let recoverPreviousCrash: @Sendable (URL) -> PreviousCrashReport?
    let installCrashCapture: @Sendable (CrashHandlerConfig, URL) -> Bool

    static let production = LiveCrashBootstrapServices(
        installTerminalRestoration: {
            installTerminalRestoreOnly()
        },
        prepareCrashDirectory: { home in
            try LiveCrashBootstrap.prepareCrashDirectory(openGrokHome: home)
        },
        recoverPreviousCrash: { directory in
            checkPreviousCrash(crashDir: directory)
        },
        installCrashCapture: { configuration, home in
            installCrashHandler(configuration, openGrokHome: home)
        }
    )
}

enum LiveCrashBootstrapDirectoryError: Error, Equatable {
    case insecureDirectory(String)
    case insecureReport(String)
}

/// Owns the one process-wide installation described by pager-bin/main.rs:1737-1754.
final class LiveCrashBootstrap: @unchecked Sendable {
    static let shared = LiveCrashBootstrap()

    private let services: LiveCrashBootstrapServices
    private let loadConfiguration: @Sendable ([String: String]) throws -> ConfigLayers
    private let remoteCrashHandlerEnabled: @Sendable () -> Bool?
    private let lock = NSLock()
    private var installedResult: CrashBootstrapResult?

    init(
        services: LiveCrashBootstrapServices = .production,
        loadConfiguration: @escaping @Sendable ([String: String]) throws -> ConfigLayers = {
            try ConfigLayers.load(environment: $0)
        },
        remoteCrashHandlerEnabled: @escaping @Sendable () -> Bool? = { nil }
    ) {
        self.services = services
        self.loadConfiguration = loadConfiguration
        self.remoteCrashHandlerEnabled = remoteCrashHandlerEnabled
    }

    @discardableResult
    func start(environment: [String: String], streams: CLIStreams) -> CrashBootstrapResult {
        lock.withLock {
            if let installedResult {
                return installedResult
            }

            // This is unrelated to crash-report consent and must precede disk/config I/O.
            services.installTerminalRestoration()

            let layers: ConfigLayers
            do {
                layers = try loadConfiguration(environment)
            } catch {
                streams.err(
                    "warning: crash handler configuration could not be loaded; "
                        + "local crash capture remains disabled.\n"
                )
                return remember(captureInstalled: false, previousCrash: nil)
            }

            let setting = Self.resolveReportingEnabled(
                layers: layers,
                environment: environment,
                remoteCrashHandlerEnabled: remoteCrashHandlerEnabled()
            )
            guard setting.value else {
                return remember(captureInstalled: false, previousCrash: nil)
            }

            let home = OpenGrokHomeResolver.resolve(environment: environment)
                .standardizedFileURL
            let crashDirectory: URL
            do {
                crashDirectory = try services.prepareCrashDirectory(home)
            } catch {
                reportInstallationFailure(streams: streams)
                return remember(captureInstalled: false, previousCrash: nil)
            }

            // installCrashHandler truncates last-crash.bin, so report before installation.
            let previousCrash = services.recoverPreviousCrash(crashDirectory)
            if let previousCrash {
                reportPreviousCrash(previousCrash, openGrokHome: home, streams: streams)
            }

            let configuration = CrashHandlerConfig(
                appVersion: OpenGrokCLIVersion.installedWithCommit(environment: environment),
                crashDir: crashDirectory
            )
            let captureInstalled = services.installCrashCapture(configuration, home)
            if !captureInstalled {
                reportInstallationFailure(streams: streams)
            }
            return remember(captureInstalled: captureInstalled, previousCrash: previousCrash)
        }
    }

    /// `resolve/crash_handler.rs:12-32`: requirements > env > user > managed > remote > off.
    static func resolveReportingEnabled(
        layers: ConfigLayers,
        environment: [String: String],
        remoteCrashHandlerEnabled: Bool? = nil
    ) -> Resolved<Bool> {
        let requirements = [
            layers.mdmRequirements,
            layers.systemRequirements,
            layers.userRequirements,
        ].compactMap(crashHandlerValue).first

        let managed = crashHandlerValue(layers.managed)
            ?? crashHandlerValue(layers.systemManaged)

        var normalizedEnvironment = environment
        if let override = GrokEnvGates.crashHandler(environment: environment) {
            normalizedEnvironment["GROK_CRASH_HANDLER"] = override ? "true" : "false"
        } else if !CrashBootstrap.reportingEnabled(
            configuredValue: true,
            environment: environment
        ) {
            normalizedEnvironment["GROK_CRASH_HANDLER"] = "false"
        }

        return BoolFlag(envVar: "GROK_CRASH_HANDLER")
            .requirement(requirements)
            .config(crashHandlerValue(layers.user))
            .managed(managed)
            .featureFlag(remoteCrashHandlerEnabled)
            .defaultValue(false)
            .resolve(environment: normalizedEnvironment)
    }

    static func prepareCrashDirectory(openGrokHome: URL) throws -> URL {
        let home = openGrokHome.standardizedFileURL
        try PathSecurity.rejectHostileLexical(home.path)
        try secureDirectory(home, stateRoot: home)

        let crashDirectory = home.appendingPathComponent("crash", isDirectory: true)
        try secureDirectory(crashDirectory, stateRoot: home)

        let history = crashDirectory.appendingPathComponent("history", isDirectory: true)
        try secureDirectory(history, stateRoot: home)

        for filename in ["last-crash.bin", "last-crash-report.txt"] {
            try validateExistingReport(crashDirectory.appendingPathComponent(filename))
        }

        let archivedReports = try FileManager.default.contentsOfDirectory(
            at: history,
            includingPropertiesForKeys: nil
        )
        for report in archivedReports {
            try validateExistingReport(report)
        }
        return crashDirectory
    }

    private static func crashHandlerValue(_ document: TOMLValue?) -> Bool? {
        document?[path: ["diagnostics", "crash_handler"]]?.boolValue
    }

    private func remember(
        captureInstalled: Bool,
        previousCrash: PreviousCrashReport?
    ) -> CrashBootstrapResult {
        let result = CrashBootstrapResult(
            captureInstalled: captureInstalled,
            previousCrash: previousCrash
        )
        installedResult = result
        return result
    }

    private func reportPreviousCrash(
        _ report: PreviousCrashReport,
        openGrokHome: URL,
        streams: CLIStreams
    ) {
        let homePath = openGrokHome.standardizedFileURL.path
        let reportPath = report.reportPath.standardizedFileURL.path
        let safePath: String
        if reportPath.hasPrefix(homePath + "/") {
            safePath = "$OPENGROK_HOME" + reportPath.dropFirst(homePath.count)
        } else {
            safePath = "$OPENGROK_HOME/crash/[redacted]"
        }

        streams.err(
            "Open Grok crashed during your last session.\n"
                + "  Signal:  \(redactSecrets(report.signalName))\n"
                + "  Version: \(redactSecrets(report.appVersion))\n"
                + "  Report:  \(safePath)\n\n"
        )
    }

    private func reportInstallationFailure(streams: CLIStreams) {
        streams.err(
            "warning: crash handler enabled but failed to install "
                + "(check permissions on $OPENGROK_HOME/crash).\n"
        )
    }

    private static func secureDirectory(_ directory: URL, stateRoot: URL) throws {
        #if os(Windows)
        try createDirAllOwnerOnly(directory, stateRoot: stateRoot)
        #else
        var information = stat()
        let existing = directory.path.withCString { lstat($0, &information) }
        if existing != 0 {
            guard errno == ENOENT else {
                throw LiveCrashBootstrapDirectoryError.insecureDirectory(directory.path)
            }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard directory.path.withCString({ lstat($0, &information) }) == 0 else {
                throw LiveCrashBootstrapDirectoryError.insecureDirectory(directory.path)
            }
        }

        guard information.st_uid == getuid(),
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            throw LiveCrashBootstrapDirectoryError.insecureDirectory(directory.path)
        }

        if information.st_mode & 0o777 != 0o700,
           directory.path.withCString({ chmod($0, mode_t(0o700)) }) != 0 {
            throw LiveCrashBootstrapDirectoryError.insecureDirectory(directory.path)
        }
        #endif
    }

    private static func validateExistingReport(_ report: URL) throws {
        #if os(Windows)
        guard FileManager.default.fileExists(atPath: report.path) else { return }
        guard !((try? PathSecurity.isSymlink(report)) ?? true),
              try SecureFile.isOwnerOnly(at: report)
        else {
            throw LiveCrashBootstrapDirectoryError.insecureReport(report.path)
        }
        #else
        var information = stat()
        guard report.path.withCString({ lstat($0, &information) }) == 0 else {
            if errno == ENOENT { return }
            throw LiveCrashBootstrapDirectoryError.insecureReport(report.path)
        }
        guard information.st_uid == getuid(),
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_mode & 0o777 == 0o600
        else {
            throw LiveCrashBootstrapDirectoryError.insecureReport(report.path)
        }
        #endif
    }
}
