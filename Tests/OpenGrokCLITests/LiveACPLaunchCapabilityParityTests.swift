import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokHTTP
import OpenGrokSandbox
import OpenGrokShared
import OpenGrokWorkspace
import Testing

@testable import OpenGrokCLI

private struct ACPLaunchHandshakeCapture: Sendable {
    let registration: ACPLeaderClientCapabilities
    let initialize: InitializeRequest
    let resumedSession: String
}

private final class ACPLaunchConfigurationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LiveLeaderClientLaunchConfiguration?

    func record(_ configuration: LiveLeaderClientLaunchConfiguration) {
        lock.withLock { stored = configuration }
    }

    var value: LiveLeaderClientLaunchConfiguration? {
        lock.withLock { stored }
    }
}

@Suite("ACP root launch capability parity and authority")
struct LiveACPLaunchCapabilityParityTests {
    private func options(
        leader: Bool = true,
        mode: CLIRunMode = .interactive,
        terminal: Bool = false,
        fsRead: Bool = false,
        fsWrite: Bool = false,
        denyRules: [String] = [],
        permissionMode: CLIPermissionMode? = nil
    ) -> CLIExecutionOptions {
        CLIExecutionOptions(
            mode: mode,
            common: CLICommonOptions(
                leader: leader,
                permissions: CLIPermissionOptions(
                    denyRules: denyRules,
                    mode: permissionMode
                )
            ),
            advanced: CLIAdvancedOptions(
                terminal: terminal,
                fsRead: fsRead,
                fsWrite: fsWrite
            )
        )
    }

    private var fullyMediatedBackend: LiveACPLaunchCapabilities.Backing {
        LiveACPLaunchCapabilities.Backing(
            terminal: true,
            filesystem: .readWrite,
            permissionsEnforced: true,
            sandboxEnforced: true,
            sessionScoped: true
        )
    }

    private func trustedSecurity(
        rules: [PermissionRule] = [],
        permissionMode: DefaultPermissionMode = .default,
        sandboxProfile: ProfileName = .off
    ) -> LiveACPLaunchCapabilities.Security {
        LiveACPLaunchCapabilities.Security(
            projectTrusted: true,
            permissions: ResolvedPermissions(
                config: PermissionConfig(rules: rules),
                defaultMode: permissionMode
            ),
            sandboxProfile: sandboxProfile
        )
    }

    private func captureHandshake(
        capabilities: ACPLeaderClientCapabilities,
        sessionID: String
    ) async throws -> ACPLaunchHandshakeCapture {
        let pair = InMemoryWebSocketChannel.makePair()
        let client = ACPLeaderClient(
            channel: pair.a,
            clientType: "capability-test-client",
            capabilities: capabilities
        )
        let deadline = Task {
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                await pair.b.close()
            } catch {}
        }
        defer { deadline.cancel() }

        let server = Task { () throws -> ACPLaunchHandshakeCapture in
            let reader = ACPLeaderChannelReader(
                channel: pair.b,
                maximumMessageSize: ACPLeaderProtocolLimits.maximumMessageSize
            )
            guard let first = try await reader.next(ACPLeaderClientMessage.self),
                  case .register(_, _, let registeredCapabilities) = first
            else {
                throw ACPLeaderProtocolError.invalidJSON("expected leader registration")
            }
            try await pair.b.write(try ACPLeaderCodec.encode(
                ACPLeaderServerMessage.registered(
                    clientID: 41,
                    ready: true,
                    protocolVersion: 1,
                    binaryVersion: "leader-test",
                    capabilities: ACPLeaderCapabilities(controlV1: true)
                )
            ))

            guard let initializeFrame = try await reader.next(ACPLeaderClientMessage.self),
                  case .acp(let initializePayload) = initializeFrame
            else {
                throw ACPLeaderProtocolError.invalidJSON("expected ACP initialize request")
            }
            let initializeMessage = try ACPMessage(data: Data(initializePayload.utf8))
            guard case .request(let initializeID, let initializeMethod, let initializeParams)
                = initializeMessage,
                  initializeMethod == AgentMethodNames.initialize
            else {
                throw ACPLeaderProtocolError.invalidJSON("unexpected request before initialization")
            }
            let initialization = try initializeParams.decode(InitializeRequest.self)
            let initializationReply = ACPMessage.response(
                id: initializeID,
                result: try JSONValue.encode(InitializeResponse(protocolVersion: .v1)),
                error: nil
            )
            try await pair.b.write(try ACPLeaderCodec.encode(
                ACPLeaderServerMessage.acp(
                    payload: String(decoding: try initializationReply.encodedData(), as: UTF8.self)
                )
            ))

            guard let resumeFrame = try await reader.next(ACPLeaderClientMessage.self),
                  case .acp(let resumePayload) = resumeFrame
            else {
                throw ACPLeaderProtocolError.invalidJSON("expected the owned session resume request")
            }
            let resumeMessage = try ACPMessage(data: Data(resumePayload.utf8))
            guard case .request(let resumeID, let resumeMethod, let resumeParams) = resumeMessage,
                  resumeMethod == AgentMethodNames.sessionResume
            else {
                throw ACPLeaderProtocolError.invalidJSON("leader client contacted an unrelated session")
            }
            let resumed = try resumeParams.decode(ResumeSessionRequest.self)
            guard resumed.sessionId.rawValue == sessionID else {
                throw ACPLeaderProtocolError.invalidJSON("leader client selected an unrelated session")
            }
            let resumeReply = ACPMessage.response(
                id: resumeID,
                result: try JSONValue.encode(ResumeSessionResponse()),
                error: nil
            )
            try await pair.b.write(try ACPLeaderCodec.encode(
                ACPLeaderServerMessage.acp(
                    payload: String(decoding: try resumeReply.encodedData(), as: UTF8.self)
                )
            ))

            return ACPLaunchHandshakeCapture(
                registration: registeredCapabilities,
                initialize: initialization,
                resumedSession: resumed.sessionId.rawValue
            )
        }
        defer { server.cancel() }

        do {
            let registration = try await client.start()
            #expect(registration.clientID == 41)
            let adapter = LiveLeaderPagerRuntimeAdapter(
                client: client,
                workingDirectory: URL(fileURLWithPath: "/tmp/acp-capability-workspace")
            )
            #expect(try await adapter.resumeSession(sessionID: sessionID) == sessionID)
            let capture = try await server.value
            await client.close()
            return capture
        } catch {
            await client.close()
            throw error
        }
    }

    @Test("Rust's default leader registration and ACP initialize grant no reverse authority")
    func defaultCapabilitiesStayDeniedAcrossBothHandshakes() async throws {
        let resolved = try LiveACPLaunchCapabilities.resolve(
            options: options(),
            interactiveSurfaceAvailable: true,
            clientVersion: "2.4.6"
        )
        let captured = try await captureHandshake(
            capabilities: resolved,
            sessionID: "only-owned-session"
        )

        #expect(!captured.registration.terminal)
        #expect(!captured.registration.fsRead)
        #expect(!captured.registration.fsWrite)
        #expect(captured.registration.clientVersion == "2.4.6")
        #expect(!captured.initialize.clientCapabilities.terminal)
        #expect(!captured.initialize.clientCapabilities.fs.readTextFile)
        #expect(!captured.initialize.clientCapabilities.fs.writeTextFile)
        #expect(captured.initialize.clientInfo?.name == OpenGrokACPExtension.executable)
        #expect(captured.initialize.clientInfo?.version == "2.4.6")
        #expect(captured.resumedSession == "only-owned-session")
    }

    @Test("a registration without an explicit version uses the current compiled client version")
    func initializeNeverInventsVersionZero() async throws {
        let captured = try await captureHandshake(
            capabilities: ACPLeaderClientCapabilities(),
            sessionID: "version-owned-session"
        )

        #expect(captured.initialize.clientInfo?.version == OpenGrokCLIVersion.compiled)
        #expect(captured.initialize.clientInfo?.version != "0.0.0")
    }

    @Test("an authorized read-write backend is advertised identically at both handshake layers")
    func explicitlyBackedFilesystemCapabilitiesReachBothHandshakes() async throws {
        let resolved = try LiveACPLaunchCapabilities.resolve(
            options: options(fsRead: true, fsWrite: true),
            interactiveSurfaceAvailable: false,
            clientVersion: "4.3.2",
            backing: fullyMediatedBackend,
            security: trustedSecurity()
        )
        let captured = try await captureHandshake(
            capabilities: resolved,
            sessionID: "authorized-filesystem-session"
        )

        #expect(!captured.registration.terminal)
        #expect(captured.registration.fsRead)
        #expect(captured.registration.fsWrite)
        #expect(!captured.initialize.clientCapabilities.terminal)
        #expect(captured.initialize.clientCapabilities.fs.readTextFile)
        #expect(captured.initialize.clientCapabilities.fs.writeTextFile)
        #expect(captured.initialize.clientInfo?.version == "4.3.2")
        #expect(captured.resumedSession == "authorized-filesystem-session")
    }

    @Test("explicit unsupported reverse flags fail closed", arguments: [
        "--terminal", "--fs-read", "--fs-write",
    ])
    func explicitUnsupportedFlagsFailClosed(flag: String) {
        let requested = options(
            terminal: flag == "--terminal",
            fsRead: flag == "--fs-read",
            fsWrite: flag == "--fs-write"
        )

        do {
            let advertised = try LiveACPLaunchCapabilities.resolve(
                options: requested,
                interactiveSurfaceAvailable: true
            )
            Issue.record("unsupported \(flag) unexpectedly advertised \(advertised)")
        } catch let error as CLIApplicationError {
            guard case .unsupported(let route) = error else {
                Issue.record("\(flag) failed with the wrong error: \(error)")
                return
            }
            #expect(route.contains(flag))
        } catch {
            Issue.record("\(flag) failed with an unexpected error: \(error)")
        }
    }

    @Test("unsupported root flags never contact the shared leader", arguments: [
        "--terminal", "--fs-read", "--fs-write",
    ])
    func unsupportedLaunchFlagsFailBeforeLeaderContact(flag: String) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-unauthorized-leader-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("workspace")
        let home = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let environment = [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
            "GROK_FOLDER_TRUST": "0",
            "GROK_SANDBOX": "off",
        ]
        defer {
            LiveManagedPolicyLifecycle.stop(environment: environment)
            try? FileManager.default.removeItem(at: root)
        }

        let capture = ACPLaunchConfigurationCapture()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                throw CLIApplicationError.failed("an unauthorized launch reached sampling")
            },
            makeLeaderClient: { configuration in
                capture.record(configuration)
                throw CLIApplicationError.failed("an unauthorized launch contacted the leader")
            }
        )
        let command = try CLICommandParser.parseOrThrow([
            "headless", "--prompt", "reject unsupported authority", "--cwd", workspace.path,
            "--leader", "--sandbox", "off", flag,
        ], environment: environment)

        do {
            let session = try await OpenGrokLiveApplicationLauncher(dependencies: dependencies)
                .launcher.start(
                    command,
                    CLIApplicationContext(
                        environment: environment,
                        streams: CLIStreams(out: { _ in }, err: { _ in }),
                        control: .never
                    )
                )
            await session.shutdown()
            Issue.record("unsupported \(flag) unexpectedly started a leader session")
        } catch let error as CLIApplicationError {
            guard case .unsupported(let route) = error else {
                Issue.record("unsupported \(flag) failed with the wrong error: \(error)")
                return
            }
            #expect(route.contains(flag))
        }

        #expect(capture.value == nil)
    }

    @Test("a standalone launch cannot create leader-only reverse authority")
    func standaloneFlagsRequireLeader() {
        #expect(throws: CLIApplicationError.unsupported(
            route: "--fs-read, which requires a leader client with a reverse handler"
        )) {
            try LiveACPLaunchCapabilities.resolve(
                options: options(leader: false, fsRead: true),
                interactiveSurfaceAvailable: false,
                backing: fullyMediatedBackend,
                security: trustedSecurity()
            )
        }
    }

    @Test("a terminal flag never turns a headless or unavailable surface into a terminal")
    func terminalRequiresLiveInteractiveSurface() {
        for mode in [CLIRunMode.interactive, .headless] {
            #expect(throws: CLIApplicationError.unsupported(
                route: "--terminal, which requires an available interactive terminal surface"
            )) {
                try LiveACPLaunchCapabilities.resolve(
                    options: options(mode: mode, terminal: true),
                    interactiveSurfaceAvailable: mode == .headless,
                    backing: fullyMediatedBackend,
                    security: trustedSecurity()
                )
            }
        }
    }

    @Test("explicit read and write flags remain independent when a proven backend exists")
    func explicitFilesystemFlagsDoNotImplyEachOther() throws {
        let readOnly = try LiveACPLaunchCapabilities.resolve(
            options: options(fsRead: true),
            interactiveSurfaceAvailable: false,
            backing: LiveACPLaunchCapabilities.Backing(
                filesystem: .readOnly,
                permissionsEnforced: true,
                sandboxEnforced: true,
                sessionScoped: true
            ),
            security: trustedSecurity()
        )
        #expect(readOnly.fsRead)
        #expect(!readOnly.fsWrite)
        #expect(!readOnly.terminal)

        let writeOnly = try LiveACPLaunchCapabilities.resolve(
            options: options(fsWrite: true),
            interactiveSurfaceAvailable: false,
            backing: fullyMediatedBackend,
            security: trustedSecurity()
        )
        #expect(!writeOnly.fsRead)
        #expect(writeOnly.fsWrite)
        #expect(!writeOnly.terminal)

        let all = try LiveACPLaunchCapabilities.resolve(
            options: options(terminal: true, fsRead: true, fsWrite: true),
            interactiveSurfaceAvailable: true,
            backing: fullyMediatedBackend,
            security: trustedSecurity()
        )
        #expect(all.terminal)
        #expect(all.fsRead)
        #expect(all.fsWrite)
    }

    @Test("read-only and plan policies never grant general filesystem write authority")
    func restrictivePoliciesClampFilesystemWrites() throws {
        for (requested, policy) in [
            (options(fsWrite: true), trustedSecurity(sandboxProfile: .readOnly)),
            (options(fsWrite: true, permissionMode: .plan), trustedSecurity()),
            (options(fsWrite: true), trustedSecurity(permissionMode: .plan)),
        ] {
            #expect(throws: CLIApplicationError.self) {
                try LiveACPLaunchCapabilities.resolve(
                    options: requested,
                    interactiveSurfaceAvailable: false,
                    backing: fullyMediatedBackend,
                    security: policy
                )
            }
        }

        let read = try LiveACPLaunchCapabilities.resolve(
            options: options(fsRead: true),
            interactiveSurfaceAvailable: false,
            backing: fullyMediatedBackend,
            security: trustedSecurity(sandboxProfile: .readOnly)
        )
        #expect(read.fsRead)
        #expect(!read.fsWrite)
    }

    @Test("managed and explicit deny rules outrank requested reverse authority")
    func denyRulesCannotBeOverriddenByLaunchFlags() {
        let managedWriteDeny = PermissionRule(
            action: .deny,
            tool: .edit,
            source: .managedSettings
        )
        #expect(throws: CLIApplicationError.unsupported(
            route: "--fs-write, which filesystem writes are denied by effective permission policy"
        )) {
            try LiveACPLaunchCapabilities.resolve(
                options: options(fsWrite: true),
                interactiveSurfaceAvailable: false,
                backing: fullyMediatedBackend,
                security: trustedSecurity(rules: [managedWriteDeny])
            )
        }

        #expect(throws: CLIApplicationError.unsupported(
            route: "--fs-read, which filesystem reads are denied by effective permission policy"
        )) {
            try LiveACPLaunchCapabilities.resolve(
                options: options(fsRead: true, denyRules: ["Read(*)"]),
                interactiveSurfaceAvailable: false,
                backing: fullyMediatedBackend,
                security: trustedSecurity()
            )
        }
    }

    @Test("untrusted, unmediated, and cross-session backends never gain authority")
    func incompleteAuthorityProofFailsClosed() {
        var variations = [fullyMediatedBackend]
        var notScoped = fullyMediatedBackend
        notScoped.sessionScoped = false
        variations.append(notScoped)
        var noPermissions = fullyMediatedBackend
        noPermissions.permissionsEnforced = false
        variations.append(noPermissions)
        var noSandbox = fullyMediatedBackend
        noSandbox.sandboxEnforced = false
        variations.append(noSandbox)

        for (index, backing) in variations.enumerated() {
            let security = index == 0
                ? LiveACPLaunchCapabilities.Security(projectTrusted: false, sandboxProfile: .off)
                : trustedSecurity()
            #expect(throws: CLIApplicationError.self) {
                try LiveACPLaunchCapabilities.resolve(
                    options: options(fsRead: true),
                    interactiveSurfaceAvailable: false,
                    backing: backing,
                    security: security
                )
            }
        }
    }

    @Test("leader injection preserves separate clients and overwrites forged session authority")
    func capabilitiesNeverLeakIntoAnUnrelatedSession() throws {
        let writer = try LiveACPLaunchCapabilities.resolve(
            options: options(fsWrite: true),
            interactiveSurfaceAvailable: false,
            backing: fullyMediatedBackend,
            security: trustedSecurity()
        )
        let observer = try LiveACPLaunchCapabilities.resolve(
            options: options(),
            interactiveSurfaceAvailable: true
        )
        let request = ACPMessage.request(
            id: .number(1),
            method: AgentMethodNames.sessionNew,
            params: try JSONValue.encode(NewSessionRequest(
                cwd: "/tmp/owned-workspace",
                meta: [
                    "clientFsRead": .bool(true),
                    "clientFsWrite": .bool(true),
                    "clientTerminal": .bool(true),
                    ACPLeaderCapabilityInjection.clientIDKey: .number(.uint64(999)),
                ]
            ))
        )

        let writerRequest = ACPLeaderCapabilityInjection.inject(
            into: request,
            clientID: 11,
            clientType: "authorized-writer",
            capabilities: writer
        )
        let observerRequest = ACPLeaderCapabilityInjection.inject(
            into: request,
            clientID: 22,
            clientType: "unrelated-observer",
            capabilities: observer
        )
        guard case .request(_, _, let writerParams) = writerRequest,
              case .request(_, _, let observerParams) = observerRequest
        else {
            Issue.record("leader did not preserve the session request")
            return
        }

        #expect(writerParams["_meta"]?["clientFsWrite"] == .bool(true))
        #expect(writerParams["_meta"]?["clientFsRead"] == .bool(false))
        #expect(writerParams["_meta"]?["clientTerminal"] == .bool(false))
        #expect(writerParams["_meta"]?[ACPLeaderCapabilityInjection.clientIDKey]
            == .number(.uint64(11)))
        #expect(observerParams["_meta"]?["clientFsWrite"] == .bool(false))
        #expect(observerParams["_meta"]?["clientFsRead"] == .bool(false))
        #expect(observerParams["_meta"]?["clientTerminal"] == .bool(false))
        #expect(observerParams["_meta"]?[ACPLeaderCapabilityInjection.clientIDKey]
            == .number(.uint64(22)))
    }

    @Test("the production root leader launch sends only actually implemented capabilities")
    func productionLeaderConfigurationDoesNotOveradvertise() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-leader-capability-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("workspace")
        let home = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let environment = [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
            "GROK_FOLDER_TRUST": "0",
            "GROK_SANDBOX": "off",
            "GROK_TEST_VERSION": "8.7.6-launch",
            "XAI_API_KEY": "capability-parity-key",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
        defer {
            LiveManagedPolicyLifecycle.stop(environment: environment)
            try? FileManager.default.removeItem(at: root)
        }

        let capture = ACPLaunchConfigurationCapture()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                throw CLIApplicationError.failed("leader capability launch unexpectedly sampled")
            },
            makeLeaderClient: { configuration in
                capture.record(configuration)
                throw CLIApplicationError.failed("leader capabilities captured")
            }
        )
        let command = try CLICommandParser.parseOrThrow([
            "headless", "--prompt", "inspect capabilities", "--cwd", workspace.path,
            "--leader", "--sandbox", "off",
        ], environment: environment)
        let context = CLIApplicationContext(
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )

        do {
            let session = try await OpenGrokLiveApplicationLauncher(dependencies: dependencies)
                .launcher.start(command, context)
            await session.shutdown()
            Issue.record("capability capture unexpectedly returned a connected leader session")
        } catch let error as CLIApplicationError {
            #expect(error == .failed("leader capabilities captured"))
        }

        let configuration = try #require(capture.value)
        #expect(configuration.capabilities.clientVersion == "8.7.6-launch")
        #expect(!configuration.capabilities.terminal)
        #expect(!configuration.capabilities.fsRead)
        #expect(!configuration.capabilities.fsWrite)
    }
}
