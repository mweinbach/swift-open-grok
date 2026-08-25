import Foundation
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokUpdate
import Testing
@testable import OpenGrokCLI

private struct LiveInstallerLaunchFixture: Sendable {
    let root: URL
    let ownerHome: URL
    let workspace: URL
    let environment: [String: String]

    init(currentVersion: String = "1.0.0") throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-installer-launch-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let resolved = temporary.standardizedFileURL.resolvingSymlinksInPath()
        #if os(macOS)
        if resolved.path.hasPrefix("/var/") {
            root = URL(fileURLWithPath: "/private\(resolved.path)", isDirectory: true)
        } else {
            root = resolved
        }
        #else
        root = resolved
        #endif
        let userHome = root.appendingPathComponent("owner", isDirectory: true)
        ownerHome = userHome.appendingPathComponent(".opengrok", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        for directory in [userHome, ownerHome, workspace] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        environment = [
            "HOME": userHome.path,
            "OPENGROK_HOME": ownerHome.path,
            "GROK_SANDBOX": "off",
            "GROK_TEST_VERSION": currentVersion,
            "XAI_API_KEY": "installer-parity-key",
        ]
    }

    var config: URL { ownerHome.appendingPathComponent("config.toml") }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func document() throws -> TOMLValue {
        try parseTOML(String(contentsOf: config, encoding: .utf8))
    }

    func services(
        releaseVersion: String,
        recorder: LiveInstallerUpdateRecorder
    ) throws -> LiveUpdateServices {
        let platform = ReleasePlatform.current
        let release = try ReleaseCandidate(
            tagName: "v\(releaseVersion)",
            version: releaseVersion,
            assets: [
                ReleaseAsset(
                    name: platform.assetName,
                    downloadURL: URL(string: "https://example.invalid/\(platform.assetName)")!
                ),
            ]
        )
        return LiveUpdateServices(
            fetchLatestRelease: { _ in
                await recorder.recordFetch()
                return release
            },
            install: { _, _, _, _ in
                await recorder.recordInstall()
                throw CLIApplicationError.failed("installer boundary unexpectedly crossed")
            }
        )
    }
}

private actor LiveInstallerUpdateRecorder {
    private var fetches = 0
    private var installs = 0

    func recordFetch() { fetches += 1 }
    func recordInstall() { installs += 1 }
    func counts() -> (fetches: Int, installs: Int) { (fetches, installs) }
}

@Suite("pinned Rust owner-only installer launch parity")
struct LiveInstallerLaunchParityTests {
    @Test("missing installer flag never creates or mutates owner configuration")
    func absentFlagDoesNotWrite() throws {
        let fixture = try LiveInstallerLaunchFixture()
        defer { fixture.dispose() }

        try LiveInstallerLaunchConfiguration.apply(installer: nil, environment: fixture.environment)

        #expect(FileManager.default.fileExists(atPath: fixture.config.path) == false)
    }

    @Test("installer writes preserve unrelated values, existing comments, and private permissions")
    func preservesOwnerConfiguration() throws {
        let fixture = try LiveInstallerLaunchFixture()
        defer { fixture.dispose() }
        try """
        # owner note that must survive
        [cli]
        auto_update = false
        installer = "open-grok" # existing installer note

        [provider]
        token_name = "keep-this"
        """.write(to: fixture.config, atomically: true, encoding: .utf8)

        try LiveInstallerLaunchConfiguration.apply(installer: "brew", environment: fixture.environment)

        let updated = try String(contentsOf: fixture.config, encoding: .utf8)
        let document = try fixture.document()
        #expect(document[path: ["cli", "installer"]] == .string("brew"))
        #expect(document[path: ["cli", "auto_update"]] == .boolean(false))
        #expect(document[path: ["provider", "token_name"]] == .string("keep-this"))
        #expect(updated.contains("# owner note that must survive"))
        #expect(updated.contains("# existing installer note"))
        #expect(try SecureFile.isOwnerOnly(at: fixture.config))
        #expect(try LiveInstallerLaunchConfiguration.effectiveInstaller(environment: fixture.environment)
            == .unknown("brew"))
    }

    @Test("new cli tables preserve the existing TOML document")
    func insertsMissingCLITable() throws {
        let fixture = try LiveInstallerLaunchFixture()
        defer { fixture.dispose() }
        try "# owner setting\n[ui]\ntheme = \"dark\"\n".write(
            to: fixture.config,
            atomically: true,
            encoding: .utf8
        )

        try LiveInstallerLaunchConfiguration.apply(installer: "npm", environment: fixture.environment)

        let document = try fixture.document()
        #expect(document[path: ["ui", "theme"]] == .string("dark"))
        #expect(document[path: ["cli", "installer"]] == .string("npm"))
        #expect(try String(contentsOf: fixture.config, encoding: .utf8).contains("# owner setting"))
        #expect(try SecureFile.isOwnerOnly(at: fixture.config))
    }

    @Test("a fresh owner state root is created privately before its first installer write")
    func createsFreshOwnerStateRoot() throws {
        let fixture = try LiveInstallerLaunchFixture()
        defer { fixture.dispose() }
        let fresh = fixture.root.appendingPathComponent("fresh/nested/owner", isDirectory: true)
        var environment = fixture.environment
        environment["OPENGROK_HOME"] = fresh.path

        try LiveInstallerLaunchConfiguration.apply(installer: "brew", environment: environment)

        let config = fresh.appendingPathComponent("config.toml")
        let document = try parseTOML(String(contentsOf: config, encoding: .utf8))
        #expect(document[path: ["cli", "installer"]] == .string("brew"))
        #expect(try SecureFile.isOwnerOnly(at: config))
    }

    @Test("relative owner state overrides cannot resolve into the process working directory")
    func rejectsRelativeOwnerStateDirectory() throws {
        let fixture = try LiveInstallerLaunchFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["OPENGROK_HOME"] = "relative-installer-owner"

        #expect(throws: (any Error).self) {
            try LiveInstallerLaunchConfiguration.apply(installer: "brew", environment: environment)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.config.path) == false)
    }

    @Test("control characters, whitespace, traversal, and oversized installer names fail before writes")
    func rejectsInstallerInjection() throws {
        for installer in [
            "", " ", "brew\n[permission]\nmode = \"allow\"",
            "brew\radmin", "../brew", "brew/tool", "-brew",
            String(repeating: "a", count: 65),
        ] {
            let fixture = try LiveInstallerLaunchFixture()
            defer { fixture.dispose() }
            #expect(throws: (any Error).self) {
                try LiveInstallerLaunchConfiguration.apply(
                    installer: installer,
                    environment: fixture.environment
                )
            }
            #expect(FileManager.default.fileExists(atPath: fixture.config.path) == false)
        }
    }

    @Test("malformed owner configuration is never overwritten or silently reset")
    func malformedConfigurationFailsClosed() throws {
        let fixture = try LiveInstallerLaunchFixture()
        defer { fixture.dispose() }
        let original = "[provider]\napi_key = \"never-erase-this\n"
        try original.write(to: fixture.config, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try LiveInstallerLaunchConfiguration.apply(installer: "brew", environment: fixture.environment)
        }

        #expect(try String(contentsOf: fixture.config, encoding: .utf8) == original)
    }

    @Test("a non-table cli value is rejected without replacing unrelated settings")
    func invalidCLITableFailsClosed() throws {
        let fixture = try LiveInstallerLaunchFixture()
        defer { fixture.dispose() }
        let original = "cli = \"hostile\"\nretained = true\n"
        try original.write(to: fixture.config, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try LiveInstallerLaunchConfiguration.apply(installer: "npm", environment: fixture.environment)
        }

        #expect(try String(contentsOf: fixture.config, encoding: .utf8) == original)
    }

    @Test("symlinked owner configuration never reads or modifies its target")
    func rejectsConfigSymlink() throws {
        let fixture = try LiveInstallerLaunchFixture()
        defer { fixture.dispose() }
        let target = fixture.root.appendingPathComponent("sensitive.toml")
        let secret = "[secrets]\ntoken = \"do-not-touch\"\n"
        try secret.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: fixture.config, withDestinationURL: target)

        #expect(throws: (any Error).self) {
            try LiveInstallerLaunchConfiguration.apply(installer: "brew", environment: fixture.environment)
        }

        #expect(try String(contentsOf: target, encoding: .utf8) == secret)
        #expect(try PathSecurity.isSymlink(fixture.config))
    }

    @Test("a symlinked owner home is refused before files can escape into its target")
    func rejectsOwnerHomeSymlink() throws {
        let fixture = try LiveInstallerLaunchFixture()
        defer { fixture.dispose() }
        let link = fixture.root.appendingPathComponent("hostile-owner-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.ownerHome)
        var hostile = fixture.environment
        hostile["OPENGROK_HOME"] = link.path

        #expect(throws: (any Error).self) {
            try LiveInstallerLaunchConfiguration.apply(installer: "brew", environment: hostile)
        }

        #expect(FileManager.default.fileExists(atPath: fixture.config.path) == false)
    }

    @Test("the actual launch persists the exact installer flag into the owner's config")
    func liveLaunchPersistsInstaller() async throws {
        let fixture = try LiveInstallerLaunchFixture()
        defer { fixture.dispose() }
        let application = OpenGrokApplication.live(
            dependencies: OpenGrokLiveCompositionDependencies(
                makeSampler: { _ in
                    OpenGrokLiveSampler { _, emit in
                        await emit(.output("installer parity"))
                        return OpenGrokLiveSamplingResponse(output: "installer parity")
                    }
                }
            ),
            control: .never
        )
        let (streams, _, errors) = CLIStreams.buffered()

        let exitCode = await CLIRunner.run(
            [
                "headless", "--prompt", "installer parity", "--cwd", fixture.workspace.path,
                "--installer", "brew",
            ],
            environment: fixture.environment,
            streams: streams,
            application: application
        )

        #expect(exitCode == CLIRunner.ExitCode.success.rawValue, "\(errors.contents)")
        #expect(try fixture.document()[path: ["cli", "installer"]] == .string("brew"))
        #expect(try SecureFile.isOwnerOnly(at: fixture.config))
    }

    @Test("update --check reports the real configured installer and never downgrades npm")
    func actualUpdateStatusHonorsInstallerDowngradeBoundary() async throws {
        let fixture = try LiveInstallerLaunchFixture(currentVersion: "2.0.0")
        defer { fixture.dispose() }
        try LiveInstallerLaunchConfiguration.apply(installer: "npm", environment: fixture.environment)
        let recorder = LiveInstallerUpdateRecorder()
        let services = try fixture.services(releaseVersion: "1.0.0", recorder: recorder)
        let application = OpenGrokApplication(
            launcher: OpenGrokLiveApplicationLauncher(updateServices: services).launcher,
            control: .never
        )
        let (streams, output, errors) = CLIStreams.buffered()

        let exitCode = await CLIRunner.run(
            ["update", "--check", "--json"],
            environment: fixture.environment,
            streams: streams,
            application: application
        )

        #expect(exitCode == CLIRunner.ExitCode.success.rawValue, "\(errors.contents)")
        let status = try JSONDecoder().decode(UpdateStatus.self, from: Data(output.contents.utf8))
        #expect(status.installer == "npm")
        #expect(status.latestVersion == "1.0.0")
        #expect(status.updateAvailable == false)
        let counts = await recorder.counts()
        #expect(counts.fetches == 1)
        #expect(counts.installs == 0)
    }

    @Test("protected installer policy cannot be replaced by an owner launch flag")
    func managedInstallerWinsOverPersistedOwnerChoice() async throws {
        let fixture = try LiveInstallerLaunchFixture(currentVersion: "2.0.0")
        defer { fixture.dispose() }
        try "[cli]\ninstaller = \"npm\"\n".write(
            to: fixture.ownerHome.appendingPathComponent("managed_config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try LiveInstallerLaunchConfiguration.apply(installer: "open-grok", environment: fixture.environment)

        #expect(try fixture.document()[path: ["cli", "installer"]] == .string("open-grok"))
        #expect(try LiveInstallerLaunchConfiguration.effectiveInstaller(environment: fixture.environment) == .npm)
        let recorder = LiveInstallerUpdateRecorder()
        let services = try fixture.services(releaseVersion: "1.0.0", recorder: recorder)
        let status = await LiveUpdateComposition.checkStatus(
            current: "2.0.0",
            policy: VersionPolicy(),
            installer: try LiveInstallerLaunchConfiguration.effectiveInstaller(environment: fixture.environment),
            environment: fixture.environment,
            services: services
        )
        #expect(status.installer == "npm")
        #expect(status.updateAvailable == false)
    }

    @Test("unsupported installer backends cannot run the Open Grok release installer")
    func unsupportedBackendNeverInstallsAcrossProviderBoundary() async throws {
        let fixture = try LiveInstallerLaunchFixture(currentVersion: "1.0.0")
        defer { fixture.dispose() }
        try LiveInstallerLaunchConfiguration.apply(installer: "brew", environment: fixture.environment)
        let recorder = LiveInstallerUpdateRecorder()
        let services = try fixture.services(releaseVersion: "2.0.0", recorder: recorder)
        let application = OpenGrokApplication(
            launcher: OpenGrokLiveApplicationLauncher(updateServices: services).launcher,
            control: .never
        )
        let (streams, _, errors) = CLIStreams.buffered()

        let exitCode = await CLIRunner.run(
            ["update"],
            environment: fixture.environment,
            streams: streams,
            application: application
        )

        #expect(exitCode != CLIRunner.ExitCode.success.rawValue)
        let counts = await recorder.counts()
        if ReleasePlatform.current.isSupportedForRelease {
            #expect(errors.contents.contains("no verified Open Grok release backend"))
            #expect(counts.fetches == 1)
        } else {
            #expect(errors.contents.contains(ReleasePlatform.unsupportedPlatformMessage))
            #expect(counts.fetches == 0)
        }
        #expect(counts.installs == 0)
    }

    @Test("automatic updates do not fetch or install through unsupported installer lanes")
    func automaticUpdateDoesNotCrossInstallerBoundary() async throws {
        let fixture = try LiveInstallerLaunchFixture(currentVersion: "1.0.0")
        defer { fixture.dispose() }
        try LiveInstallerLaunchConfiguration.apply(installer: "npm", environment: fixture.environment)
        let recorder = LiveInstallerUpdateRecorder()
        let services = try fixture.services(releaseVersion: "2.0.0", recorder: recorder)
        let (streams, _, _) = CLIStreams.buffered()

        await LiveLaunchAutoUpdate.runUpdateIfAvailable(
            services: services,
            environment: fixture.environment,
            streams: streams
        )

        let counts = await recorder.counts()
        #expect(counts.fetches == 0)
        #expect(counts.installs == 0)
    }
}
