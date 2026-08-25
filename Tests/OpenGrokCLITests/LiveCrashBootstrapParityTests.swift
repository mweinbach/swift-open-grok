import Foundation
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokCrashHandler
import Testing
@testable import OpenGrokCLI

private enum CrashBootstrapEvent: Sendable, Equatable {
    case terminalRestored
    case previousCrashChecked
    case previousCrashReported
    case captureInstalled
    case warningReported
}

private final class CrashBootstrapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CrashBootstrapEvent] = []
    private var errors: [String] = []
    private var configurations: [CrashHandlerConfig] = []

    var recordedEvents: [CrashBootstrapEvent] {
        lock.withLock { events }
    }

    var recordedErrors: [String] {
        lock.withLock { errors }
    }

    var recordedConfigurations: [CrashHandlerConfig] {
        lock.withLock { configurations }
    }

    func record(_ event: CrashBootstrapEvent) {
        lock.withLock { events.append(event) }
    }

    func recordError(_ output: String) {
        lock.withLock {
            errors.append(output)
            events.append(
                output.contains("crashed during your last session")
                    ? .previousCrashReported
                    : .warningReported
            )
        }
    }

    func recordCapture(_ configuration: CrashHandlerConfig) {
        lock.withLock {
            configurations.append(configuration)
            events.append(.captureInstalled)
        }
    }

    func services(
        captureSucceeds: Bool = true,
        prepareDirectory: (@Sendable (URL) throws -> URL)? = nil
    ) -> LiveCrashBootstrapServices {
        LiveCrashBootstrapServices(
            installTerminalRestoration: { [self] in
                record(.terminalRestored)
            },
            prepareCrashDirectory: { home in
                if let prepareDirectory {
                    return try prepareDirectory(home)
                }
                return home.appendingPathComponent("crash", isDirectory: true)
            },
            recoverPreviousCrash: { [self] directory in
                record(.previousCrashChecked)
                return OpenGrokCrashHandler.checkPreviousCrash(crashDir: directory)
            },
            installCrashCapture: { [self] configuration, _ in
                recordCapture(configuration)
                return captureSucceeds
            }
        )
    }

    var streams: CLIStreams {
        CLIStreams(out: { _ in }, err: { [self] output in recordError(output) })
    }
}

private struct CrashBootstrapFixture: Sendable {
    let root: URL
    let home: URL
    let workspace: URL

    var environment: [String: String] {
        [
            "HOME": root.appendingPathComponent("user").path,
            "OPENGROK_HOME": home.path,
            "PWD": workspace.path,
            "GROK_TEST_VERSION": "1.2.3-crash-parity",
        ]
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-crash-bootstrap-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("state", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        for directory in [root, home, workspace, root.appendingPathComponent("user")] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    @discardableResult
    func seedPreviousCrash() throws -> URL {
        let directory = home.appendingPathComponent("crash", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let path = directory.appendingPathComponent("last-crash.bin")
        let crash = CrashBlob(
            signal: 11,
            siCode: 1,
            siAddr: 0,
            pid: 42,
            timestamp: 1_700_000_000,
            frames: [],
            appVersion: "0.9.0-previous"
        )
        try writeOwnerOnly(path: path, contents: crash.serialize())
        return path
    }

    func clean() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func crashBootstrapDocument(_ enabled: Bool?) -> TOMLValue {
    guard let enabled else { return .table(TOMLTable()) }
    var diagnostics = TOMLTable()
    diagnostics["crash_handler"] = .boolean(enabled)
    var root = TOMLTable()
    root["diagnostics"] = .table(diagnostics)
    return .table(root)
}

private func crashBootstrapLayers(
    requirement: Bool? = nil,
    user: Bool? = nil,
    managed: Bool? = nil,
    systemManaged: Bool? = nil
) -> ConfigLayers {
    ConfigLayers(
        systemManaged: crashBootstrapDocument(systemManaged),
        managed: crashBootstrapDocument(managed),
        user: crashBootstrapDocument(user),
        userRequirements: requirement.map { crashBootstrapDocument($0) }
    )
}

@Suite("Live crash bootstrap Rust parity")
struct LiveCrashBootstrapParityTests {
    @Test("enabled launch restores, recovers and reports, then installs capture")
    func enabledStartupOrdering() throws {
        let fixture = try CrashBootstrapFixture()
        defer { fixture.clean() }
        let previousBlob = try fixture.seedPreviousCrash()
        let recorder = CrashBootstrapRecorder()
        let bootstrap = LiveCrashBootstrap(
            services: recorder.services(),
            loadConfiguration: { _ in crashBootstrapLayers(user: true) }
        )

        let result = bootstrap.start(environment: fixture.environment, streams: recorder.streams)

        #expect(result.captureInstalled)
        #expect(result.previousCrash?.signalName.contains("SIGSEGV") == true)
        #expect(!FileManager.default.fileExists(atPath: previousBlob.path))
        #expect(recorder.recordedEvents == [
            .terminalRestored,
            .previousCrashChecked,
            .previousCrashReported,
            .captureInstalled,
        ])
        #expect(recorder.recordedConfigurations.first?.appVersion == "1.2.3-crash-parity")
        #expect(
            recorder.recordedConfigurations.first?.crashDir.path
                == fixture.home.appendingPathComponent("crash").path
        )
        #expect(recorder.recordedErrors.first?.contains("$OPENGROK_HOME/crash/last-crash-report.txt") == true)
        #expect(recorder.recordedErrors.first?.contains(fixture.home.path) == false)
    }

    @Test("capture defaults off while terminal restoration remains unconditional")
    func captureDefaultsOff() throws {
        let fixture = try CrashBootstrapFixture()
        defer { fixture.clean() }
        let previousBlob = try fixture.seedPreviousCrash()
        let recorder = CrashBootstrapRecorder()
        let bootstrap = LiveCrashBootstrap(
            services: recorder.services(),
            loadConfiguration: { _ in crashBootstrapLayers() }
        )

        let result = bootstrap.start(environment: fixture.environment, streams: recorder.streams)

        #expect(!result.captureInstalled)
        #expect(result.previousCrash == nil)
        #expect(recorder.recordedEvents == [.terminalRestored])
        #expect(recorder.recordedErrors.isEmpty)
        #expect(FileManager.default.fileExists(atPath: previousBlob.path))
    }

    @Test("an administrator requirement overrides enabling environment and remote tiers")
    func requirementCannotBeBypassed() throws {
        let fixture = try CrashBootstrapFixture()
        defer { fixture.clean() }
        let recorder = CrashBootstrapRecorder()
        let bootstrap = LiveCrashBootstrap(
            services: recorder.services(),
            loadConfiguration: { _ in
                crashBootstrapLayers(requirement: false, user: true, managed: true)
            },
            remoteCrashHandlerEnabled: { true }
        )
        var environment = fixture.environment
        environment["OPENGROK_CRASH_HANDLER"] = "true"
        environment["GROK_CRASH_HANDLER"] = "true"

        let result = bootstrap.start(environment: environment, streams: recorder.streams)

        #expect(!result.captureInstalled)
        #expect(recorder.recordedEvents == [.terminalRestored])
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("crash").path))
    }

    @Test("trusted setting tiers match requirement, environment, user, managed, remote, off")
    func trustedConfigurationPrecedence() {
        let requirement = LiveCrashBootstrap.resolveReportingEnabled(
            layers: crashBootstrapLayers(requirement: false, user: true, managed: true),
            environment: ["GROK_CRASH_HANDLER": "true"],
            remoteCrashHandlerEnabled: true
        )
        #expect(requirement == Resolved(value: false, source: .requirement))

        let environment = LiveCrashBootstrap.resolveReportingEnabled(
            layers: crashBootstrapLayers(user: false, managed: false),
            environment: ["OPENGROK_CRASH_HANDLER": "true"]
        )
        #expect(environment == Resolved(value: true, source: .env))

        let user = LiveCrashBootstrap.resolveReportingEnabled(
            layers: crashBootstrapLayers(user: false, managed: true),
            environment: [:],
            remoteCrashHandlerEnabled: true
        )
        #expect(user == Resolved(value: false, source: .config))

        let managed = LiveCrashBootstrap.resolveReportingEnabled(
            layers: crashBootstrapLayers(managed: false, systemManaged: true),
            environment: [:],
            remoteCrashHandlerEnabled: true
        )
        #expect(managed == Resolved(value: false, source: .managedConfig))

        let remote = LiveCrashBootstrap.resolveReportingEnabled(
            layers: crashBootstrapLayers(),
            environment: [:],
            remoteCrashHandlerEnabled: true
        )
        #expect(remote == Resolved(value: true, source: .remote))

        let disabled = LiveCrashBootstrap.resolveReportingEnabled(
            layers: crashBootstrapLayers(),
            environment: [:]
        )
        #expect(disabled == Resolved(value: false, source: .default))

        let legacyDisable = LiveCrashBootstrap.resolveReportingEnabled(
            layers: crashBootstrapLayers(user: true),
            environment: ["OPENGROK_DISABLE_CRASH_HANDLER": "true"]
        )
        #expect(legacyDisable == Resolved(value: false, source: .env))
    }

    @Test("untrusted workspace configuration cannot opt into crash capture")
    func projectConfigurationIsNeverRead() throws {
        let fixture = try CrashBootstrapFixture()
        defer { fixture.clean() }
        let projectConfiguration = fixture.workspace.appendingPathComponent(
            ".opengrok/config.toml"
        )
        try FileManager.default.createDirectory(
            at: projectConfiguration.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "[diagnostics]\ncrash_handler = true\n".write(
            to: projectConfiguration,
            atomically: true,
            encoding: .utf8
        )
        let recorder = CrashBootstrapRecorder()
        let bootstrap = LiveCrashBootstrap(services: recorder.services())

        let result = bootstrap.start(environment: fixture.environment, streams: recorder.streams)

        #expect(!result.captureInstalled)
        #expect(recorder.recordedEvents == [.terminalRestored])
    }

    @Test("concurrent launch attempts install and emit startup notices exactly once")
    func concurrentInitializationRunsOnce() throws {
        let fixture = try CrashBootstrapFixture()
        defer { fixture.clean() }
        try fixture.seedPreviousCrash()
        let recorder = CrashBootstrapRecorder()
        let bootstrap = LiveCrashBootstrap(
            services: recorder.services(),
            loadConfiguration: { _ in crashBootstrapLayers(user: true) }
        )
        let streams = recorder.streams
        let environment = fixture.environment

        DispatchQueue.concurrentPerform(iterations: 24) { _ in
            bootstrap.start(environment: environment, streams: streams)
        }

        #expect(recorder.recordedEvents == [
            .terminalRestored,
            .previousCrashChecked,
            .previousCrashReported,
            .captureInstalled,
        ])
        #expect(recorder.recordedConfigurations.count == 1)
    }

    @Test("failed capture retains terminal protection and warns without exposing local paths")
    func captureFailurePreservesTerminalRestoration() throws {
        let fixture = try CrashBootstrapFixture()
        defer { fixture.clean() }
        let recorder = CrashBootstrapRecorder()
        let bootstrap = LiveCrashBootstrap(
            services: recorder.services(captureSucceeds: false),
            loadConfiguration: { _ in crashBootstrapLayers(user: true) }
        )

        let result = bootstrap.start(environment: fixture.environment, streams: recorder.streams)

        #expect(!result.captureInstalled)
        #expect(recorder.recordedEvents == [
            .terminalRestored,
            .previousCrashChecked,
            .captureInstalled,
            .warningReported,
        ])
        #expect(recorder.recordedErrors.first?.contains("$OPENGROK_HOME/crash") == true)
        #expect(recorder.recordedErrors.first?.contains(fixture.home.path) == false)
    }

    @Test("unreadable configuration fails closed after restoring terminal behavior")
    func configurationFailurePreservesTerminalRestoration() throws {
        let fixture = try CrashBootstrapFixture()
        defer { fixture.clean() }
        let recorder = CrashBootstrapRecorder()
        let bootstrap = LiveCrashBootstrap(
            services: recorder.services(),
            loadConfiguration: { _ in
                throw LiveCrashBootstrapDirectoryError.insecureDirectory("fixture")
            }
        )

        let result = bootstrap.start(environment: fixture.environment, streams: recorder.streams)

        #expect(!result.captureInstalled)
        #expect(recorder.recordedEvents == [.terminalRestored, .warningReported])
        #expect(recorder.recordedErrors.first?.contains("capture remains disabled") == true)
    }

    @Test("production crash directories and archives are private to their owner")
    func productionDirectoriesAreOwnerPrivate() throws {
        let fixture = try CrashBootstrapFixture()
        defer { fixture.clean() }

        let directory = try LiveCrashBootstrap.prepareCrashDirectory(openGrokHome: fixture.home)

        #expect(directory.path == fixture.home.appendingPathComponent("crash").path)
        #if os(macOS) || os(Linux)
        for path in [fixture.home, directory, directory.appendingPathComponent("history")] {
            let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[
                .posixPermissions
            ] as? NSNumber
            #expect(permissions?.intValue == 0o700)
        }
        #endif
    }

    @Test("a symlinked crash directory cannot redirect report recovery or writes")
    func productionPreparationRejectsSymlink() throws {
        #if os(macOS) || os(Linux)
        let fixture = try CrashBootstrapFixture()
        defer { fixture.clean() }
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = fixture.home.appendingPathComponent("crash")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        do {
            try LiveCrashBootstrap.prepareCrashDirectory(openGrokHome: fixture.home)
            Issue.record("symlinked crash directory should have been rejected")
        } catch LiveCrashBootstrapDirectoryError.insecureDirectory(let path) {
            #expect(path == link.path)
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #endif
    }

    @Test("a preexisting report symlink cannot overwrite files outside crash state")
    func productionPreparationRejectsReportSymlink() throws {
        #if os(macOS) || os(Linux)
        let fixture = try CrashBootstrapFixture()
        defer { fixture.clean() }
        let crash = try LiveCrashBootstrap.prepareCrashDirectory(openGrokHome: fixture.home)
        let outside = fixture.root.appendingPathComponent("outside.txt")
        try "untouched".write(to: outside, atomically: true, encoding: .utf8)
        let link = crash.appendingPathComponent("last-crash-report.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        do {
            try LiveCrashBootstrap.prepareCrashDirectory(openGrokHome: fixture.home)
            Issue.record("symlinked crash report should have been rejected")
        } catch LiveCrashBootstrapDirectoryError.insecureReport(let path) {
            #expect(path == link.path)
        }

        #expect(try String(contentsOf: outside, encoding: .utf8) == "untouched")
        #endif
    }
}
