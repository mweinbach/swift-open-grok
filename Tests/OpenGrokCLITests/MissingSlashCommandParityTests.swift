import Foundation
import OpenGrokAuth
import OpenGrokConfigTypes
import OpenGrokFileTools
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokShellSessionSupport
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

@Suite("Live Rust .82 backed slash-command parity", .serialized)
struct LiveMissingSlashCommandParityTests {
    @Test("Auto toggles the same live permission handle and exits always-approve")
    func autoMutatesLivePermissionPipeline() async throws {
        let resolved = ResolvedPermissions(alwaysApprove: true)
        let pipeline = FileToolSession.makePipeline(
            policy: .allowAll,
            workspaceRoot: "/workspace",
            resolved: resolved
        )
        let mode = LiveSessionPermissionMode(pipeline: pipeline, resolved: resolved)
        let fixture = try LiveSlashFixture(permissionMode: mode)
        defer { fixture.dispose() }

        let enabled = try await fixture.renderer.performBackedSlashCommand(.toggleAuto)
        #expect(enabled == .notice("Mode: Auto"))
        #expect(await pipeline.permissions.autoMode)
        #expect(await pipeline.permissions.yoloMode == false)
        #expect(await mode.composerFlags().map(\.label) == ["auto"])

        let disabled = try await fixture.renderer.performBackedSlashCommand(.toggleAuto)
        #expect(disabled == .notice("Mode: Normal"))
        #expect(await pipeline.permissions.autoMode == false)
        #expect(await pipeline.permissions.yoloMode == false)
    }

    @Test("Environment and requirements pins hard-disable auto")
    func autoGateRespectsProtectedPrecedence() throws {
        let fixture = try LiveSlashFixture(environmentOverrides: [
            "GROK_AUTO_PERMISSION_MODE": "false"
        ])
        defer { fixture.dispose() }
        #expect(fixture.renderer.autoPermissionModeAvailable == false)

        let pinned = try LiveSlashFixture(environmentOverrides: [
            "GROK_AUTO_PERMISSION_MODE": "true"
        ])
        defer { pinned.dispose() }
        try "[auto_mode]\nenabled = false\n".write(
            to: pinned.home.appendingPathComponent("requirements.toml"),
            atomically: true,
            encoding: .utf8
        )
        #expect(LivePagerSlashParity.autoModeAvailable(environment: pinned.environment) == false)

        let remote = try LiveSlashFixture()
        defer { remote.dispose() }
        #expect(LivePagerSlashParity.autoModeAvailable(
            environment: remote.environment,
            remoteEnabled: false
        ) == false)
        var overridingRemote = remote.environment
        overridingRemote["GROK_AUTO_PERMISSION_MODE"] = "true"
        #expect(LivePagerSlashParity.autoModeAvailable(
            environment: overridingRemote,
            remoteEnabled: false
        ))
    }

    @Test("YOLO-2 refuses absent process enforcement without mutating permission state")
    func sandboxedAlwaysApproveFailsClosed() async throws {
        let resolved = ResolvedPermissions()
        let pipeline = FileToolSession.makePipeline(
            policy: .allowAll,
            workspaceRoot: "/workspace",
            resolved: resolved
        )
        let mode = LiveSessionPermissionMode(pipeline: pipeline, resolved: resolved)
        let fixture = try LiveSlashFixture(permissionMode: mode)
        defer { fixture.dispose() }

        let outcome = try await fixture.renderer.performBackedSlashCommand(
            .toggleSandboxedAlwaysApprove
        )
        #expect(outcome == .notice(LivePagerSlashParity.sandboxRequiredMessage))
        #expect(await pipeline.permissions.yoloMode == false)
        #expect(await mode.permissionModeLabel() == "ask")
    }

    @Test("Directory mutation cannot use a stale advertised gate or a different session")
    func directoryMutationsRequireRegisteredMatchingSession() async throws {
        let fixture = try LiveSlashFixture(workingDirectoryCommandsAvailable: true)
        defer { fixture.dispose() }

        let missingBackend = try await fixture.renderer.performBackedSlashCommand(
            .addWorkingDirectory(path: fixture.home.path, sessionID: fixture.sessionID)
        )
        #expect(missingBackend == .notice(
            "Couldn't add working directory: working-directory changes are unavailable "
            + "for session \(fixture.sessionID)"
        ))

        let wrongSession = try await fixture.renderer.performBackedSlashCommand(
            .removeWorkingDirectory(path: fixture.home.path, sessionID: "different-session")
        )
        #expect(wrongSession == .notice(
            "working-directory changes are unavailable for session different-session"
        ))
    }

    @Test("Share reaches the authenticated export gate and never fabricates a URL")
    func sharingFailsClosedWithoutAuthentication() async throws {
        let routes = LiveShareRouteDependencies(
            loadRemoteSettings: { _ in nil },
            makeSignedUploadClient: { _, _ in nil },
            makeBackendClient: { _, _ in nil }
        )
        let fixture = try LiveSlashFixture(shareRoute: routes)
        defer { fixture.dispose() }

        let outcome = try await fixture.renderer.performBackedSlashCommand(
            .shareSession(sessionID: fixture.sessionID)
        )
        #expect(outcome == .notice("Authentication required to share session"))
    }

    @Test("Authenticated share uploads the persisted session through the real backend seam")
    func sharingDeliversRealBackendURL() async throws {
        let backend = LiveSlashShareBackend(url: "https://grok.com/build/share/slash-parity")
        let settings = try JSONDecoder().decode(
            RemoteSettings.self,
            from: Data(#"{"sharing_enabled":true}"#.utf8)
        )
        let routes = LiveShareRouteDependencies(
            loadRemoteSettings: { _ in settings },
            makeSignedUploadClient: { _, _ in nil },
            makeBackendClient: { _, _ in backend }
        )
        let auth = GrokAuth(
            key: "slash-auth-token",
            authMode: .oidc,
            userID: "slash-user",
            teamBlockedReasons: [],
            codingDataRetentionOptOut: false,
            oidcIssuer: "https://auth.x.ai"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        let fixture = try LiveSlashFixture(
            environmentOverrides: [
                "OPENGROK_AUTH": String(decoding: try encoder.encode(auth), as: UTF8.self)
            ],
            shareRoute: routes
        )
        defer { fixture.dispose() }

        var record = LiveConversationRecord.new(
            sessionID: fixture.sessionID,
            workingDirectory: fixture.home
        )
        record.items = [.user("real transcript")]
        record.everUsedNonXAI = false
        try await LiveConversationStore(openGrokHome: fixture.home).save(record)

        let outcome = try await fixture.renderer.performBackedSlashCommand(
            .shareSession(sessionID: fixture.sessionID)
        )
        #expect(outcome == .notice("https://grok.com/build/share/slash-parity"))
        #expect(await backend.calls == [fixture.sessionID])

        record.everUsedNonXAI = true
        try await LiveConversationStore(openGrokHome: fixture.home).save(record)
        let refused = try await fixture.renderer.performBackedSlashCommand(
            .shareSession(sessionID: fixture.sessionID)
        )
        #expect(refused == .notice("Codex-backed sessions cannot be shared through xAI services."))
        #expect(await backend.calls == [fixture.sessionID])
    }

    @Test("External editor suspends the terminal, edits the real draft, and removes its temp file")
    func externalEditorRoundTrip() async throws {
        let fixture = try LiveSlashFixture(editorBehavior: .replace("edited from external editor"))
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        await fixture.installSuspendHost()

        let outcome = try await fixture.renderer.performBackedSlashCommand(
            .editPrompt(draft: "original draft")
        )
        #expect(outcome == .editedPrompt("edited from external editor"))
        #expect(await fixture.suspension.events == ["park", "resume"])

        let handedPath = try String(
            contentsOf: fixture.home.appendingPathComponent("editor-path.txt"),
            encoding: .utf8
        )
        #expect(handedPath.contains("open-grok-prompt-"))
        #expect(FileManager.default.fileExists(atPath: handedPath) == false)
        try await fixture.renderer.restoreTerminal()
    }

    @Test("Nonzero editor exits keep the original draft")
    func failedEditorDoesNotApplyDraft() async throws {
        let fixture = try LiveSlashFixture(editorBehavior: .exitFailure)
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        await fixture.installSuspendHost()

        let outcome = try await fixture.renderer.performBackedSlashCommand(
            .editPrompt(draft: "original draft")
        )
        #expect(outcome == .notice(
            "External prompt editor exited unsuccessfully; the original draft was kept."
        ))
        #expect(await fixture.suspension.events == ["park", "resume"])
        try await fixture.renderer.restoreTerminal()
    }

    @Test("Remembered bash approvals are hidden when trusted settings disable them")
    func rememberedApprovalGateShapesLiveModal() async {
        let disabled = await capturePermissionOptions(
            access: .bash("git status"),
            rememberToolApprovals: false
        )
        #expect(disabled.map(\.decision) == [.allowOnce, .deny])

        let enabled = await capturePermissionOptions(
            access: .bash("git status"),
            rememberToolApprovals: true
        )
        #expect(enabled.map(\.decision) == [.allowSession, .allowOnce, .deny])
        #expect(enabled.first?.label == "Yes, always allow this command: git status")

        let unsafe = await capturePermissionOptions(
            access: .bash("git status; rm -rf /tmp/not-authorized"),
            rememberToolApprovals: true
        )
        #expect(unsafe.map(\.decision) == [.allowOnce, .deny])

        let edits = await capturePermissionOptions(
            access: .edit("/workspace/file.swift"),
            rememberToolApprovals: false
        )
        #expect(edits.map(\.decision) == [.allowSession, .allowOnce, .deny])
    }
}

private enum LiveSlashEditorBehavior {
    case replace(String)
    case exitFailure
}

private struct LiveSlashFixture {
    let home: URL
    let sessionID = "slash-parity-session"
    let environment: [String: String]
    let renderer: LiveInteractiveControllerRenderer
    let suspension = LiveSlashSuspensionLog()

    init(
        environmentOverrides: [String: String] = [:],
        permissionMode: LiveSessionPermissionMode? = nil,
        shareRoute: LiveShareRouteDependencies? = nil,
        editorBehavior: LiveSlashEditorBehavior? = nil,
        workingDirectoryCommandsAvailable: Bool = false
    ) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-live-slash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        var env = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
        for (key, value) in environmentOverrides {
            env[key] = value
        }
        if let editorBehavior {
            env["EDITOR"] = try Self.makeEditor(in: home, behavior: editorBehavior).path
        }
        environment = env
        renderer = LiveInteractiveControllerRenderer(
            mode: editorBehavior == nil ? .fullScreen : .minimal,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
                write: { _ in }
            ),
            sink: LiveSlashSink(),
            workingDirectory: home.path,
            permissionMode: permissionMode,
            sessionID: sessionID,
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: env,
            shareRoute: shareRoute ?? .production(),
            workingDirectoryCommandsAvailable: workingDirectoryCommandsAvailable
        )
    }

    func installSuspendHost() async {
        let log = suspension
        await renderer.setSuspendHost(LiveTUISuspendHost(
            beginInputSuspension: {
                await log.record("park")
                return LiveInputSuspension(end: {
                    await log.record("resume")
                })
            },
            environment: environment
        ))
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    private static func makeEditor(
        in home: URL,
        behavior: LiveSlashEditorBehavior
    ) throws -> URL {
        #if os(Windows)
        let script = home.appendingPathComponent("editor.cmd")
        let content: String
        switch behavior {
        case .replace(let text):
            content = "@echo off\r\n> \"%~dp0editor-path.txt\" <nul set /p =%~1\r\n> \"%~1\" <nul set /p =\(text)\r\n"
        case .exitFailure:
            content = "@echo off\r\nexit /b 9\r\n"
        }
        #else
        let script = home.appendingPathComponent("editor.sh")
        let content: String
        switch behavior {
        case .replace(let text):
            content = """
            #!/bin/sh
            printf '%s' "$1" > "\(home.path)/editor-path.txt"
            printf '%s' '\(text)' > "$1"
            """
        case .exitFailure:
            content = """
            #!/bin/sh
            printf '%s' 'do not apply' > "$1"
            exit 9
            """
        }
        #endif
        try content.write(to: script, atomically: true, encoding: .utf8)
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        #endif
        return script
    }
}

private actor LiveSlashSuspensionLog {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

private actor LiveSlashShareBackend: ShareBackendClient {
    private let url: String
    private(set) var calls: [String] = []

    init(url: String) {
        self.url = url
    }

    func shareSession(
        sessionID: String,
        items: [ConversationItem],
        title: String?,
        cwd: String
    ) async throws -> String {
        _ = (items, title, cwd)
        calls.append(sessionID)
        return url
    }
}

private final class LiveSlashSink: PagerTerminalSink, @unchecked Sendable {
    var capabilities: PagerTerminalCapabilities { .standard }
    func write(bytes: [UInt8]) throws { _ = bytes }
    func flush() throws {}
}

private actor LivePermissionOptionsCapture {
    private(set) var options: [PagerPermissionOption] = []

    func capture(_ request: PagerPermissionRequest) {
        options = request.options
    }
}

private func capturePermissionOptions(
    access: AccessKind,
    rememberToolApprovals: Bool
) async -> [PagerPermissionOption] {
    let coordinator = PagerPermissionCoordinator()
    let capture = LivePermissionOptionsCapture()
    await coordinator.setPresenter { request in
        guard let request else { return }
        await capture.capture(request)
        await coordinator.resolve(requestID: request.id, decision: .allowOnce)
    }
    let prompter = LivePermissionModalPrompter(
        coordinator: coordinator,
        sessionPolicy: LiveSessionWritePolicy(),
        rememberToolApprovals: rememberToolApprovals
    )
    let decision = await prompter.prompt(
        access: access,
        toolName: "parity-tool",
        toolCallId: UUID().uuidString
    )
    #expect(decision == .allow)
    return await capture.options
}
