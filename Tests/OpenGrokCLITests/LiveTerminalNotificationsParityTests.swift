import Foundation
import OpenGrokConfig
import OpenGrokDiagnostics
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private struct NotificationSinkFailure: Error {}

private final class NotificationCapturingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [UInt8] = []
    private var nextFailingWrite: [UInt8]?
    private var failFollowingFlush = false

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes: [UInt8]) throws {
        lock.lock()
        defer { lock.unlock() }
        if let needle = nextFailingWrite,
           !needle.isEmpty,
           bytes.count >= needle.count,
           (0...(bytes.count - needle.count)).contains(where: { index in
               bytes[index..<(index + needle.count)].elementsEqual(needle)
           }) {
            nextFailingWrite = nil
            throw NotificationSinkFailure()
        }
        captured.append(contentsOf: bytes)
    }

    func flush() throws {
        lock.lock()
        defer { lock.unlock() }
        if failFollowingFlush {
            failFollowingFlush = false
            throw NotificationSinkFailure()
        }
    }

    func failNextWrite(containing sequence: String) {
        lock.lock()
        defer { lock.unlock() }
        nextFailingWrite = Array(sequence.utf8)
    }

    func failNextFlush() {
        lock.lock()
        defer { lock.unlock() }
        failFollowingFlush = true
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: captured, as: UTF8.self)
    }

    func offsets(of sequence: String) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        let needle = Array(sequence.utf8)
        guard !needle.isEmpty, captured.count >= needle.count else { return [] }
        return (0...(captured.count - needle.count)).filter { index in
            captured[index..<(index + needle.count)].elementsEqual(needle)
        }
    }

    func count(_ sequence: String) -> Int {
        offsets(of: sequence).count
    }
}

private struct NotificationFixture {
    let home: URL
    let sink: NotificationCapturingSink
    let renderer: LiveInteractiveControllerRenderer
    let mode: OpenGrokPagerMode

    init(
        configuration: String? = nil,
        projectConfiguration: String? = nil,
        environmentExtras: [String: String] = [:],
        mode: OpenGrokPagerMode = .fullScreen,
        isTTY: Bool = true,
        modelName: String = "notification-model"
    ) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-notifications-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let configuration {
            try configuration.write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }

        let workingDirectory: URL
        if let projectConfiguration {
            workingDirectory = home.appendingPathComponent("project", isDirectory: true)
            let projectConfig = workingDirectory.appendingPathComponent(
                ".opengrok", isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: projectConfig,
                withIntermediateDirectories: true
            )
            try projectConfiguration.write(
                to: projectConfig.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        } else {
            workingDirectory = home
        }

        var environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "TERM": "xterm-256color",
            "GROK_NO_MOTION": "1",
        ]
        for (key, value) in environmentExtras {
            environment[key] = value
        }

        self.mode = mode
        sink = NotificationCapturingSink()
        renderer = LiveInteractiveControllerRenderer(
            mode: mode,
            terminal: OpenGrokLiveTerminal(
                isTTY: { isTTY },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: workingDirectory.path,
            modelName: modelName,
            sessionID: "notification-live",
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    func startTurn(_ prompt: String = "hello") async throws {
        try await renderer.render(.turnStarted(OpenGrokPagerRequest(
            prompt: prompt,
            mode: mode
        )))
    }

    func finishTurn(cancelled: Bool = false) async throws {
        try await renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
            lifecycle: cancelled ? .cancelled : .completed,
            sessionID: "notification-live",
            forwardedEventCount: 1,
            terminalRestored: false
        )))
    }
}

private func withNotificationFixture(
    configuration: String? = nil,
    projectConfiguration: String? = nil,
    environmentExtras: [String: String] = [:],
    mode: OpenGrokPagerMode = .fullScreen,
    isTTY: Bool = true,
    modelName: String = "notification-model",
    _ body: (NotificationFixture) async throws -> Void
) async throws {
    let fixture = try NotificationFixture(
        configuration: configuration,
        projectConfiguration: projectConfiguration,
        environmentExtras: environmentExtras,
        mode: mode,
        isTTY: isTTY,
        modelName: modelName
    )
    do {
        try await fixture.renderer.begin()
        try await body(fixture)
        try await fixture.renderer.restoreTerminal()
        fixture.dispose()
    } catch {
        try? await fixture.renderer.restoreTerminal()
        fixture.dispose()
        throw error
    }
}

private let quietAlwaysOSC99Configuration = """
[ui.notifications]
method = "osc99"
condition = "always"
progress_bar = false

[ui.notifications.title]
enabled = false
"""

@Suite("Live terminal notification Rust parity")
struct LiveTerminalNotificationsParityTests {
    @Test("configuration defaults, partial inheritance, title alias, and inert hooks match Rust")
    func configurationDefaultsAndInheritance() throws {
        let defaults = LiveTerminalNotificationConfiguration()
        #expect(defaults.method == .auto)
        #expect(defaults.condition == .unfocused)
        #expect(defaults.idleThresholdSeconds == 3)
        #expect(defaults.events == [.turnComplete, .approvalRequired])
        #expect(defaults.progressBar)
        #expect(defaults.title.enabled)

        let document = try parseTOML("""
        [ui.notifications]
        method = "osc777"
        idle_threshold_secs = 0

        [ui.notifications.title]
        items = ["grok", "model"]

        [[ui.notifications.hooks]]
        command = "printf notification"
        events = ["turn_complete"]
        """)
        let subtree = try #require(document[path: ["ui", "notifications"]])
        let resolved = try #require(LiveTerminalNotificationConfiguration(
            notificationTable: subtree
        ))
        #expect(resolved.method == .osc777)
        #expect(resolved.condition == .unfocused)
        #expect(resolved.idleThresholdSeconds == 0)
        #expect(resolved.title.items == [.openGrok, .model])
        #expect(resolved.hooks.count == 1)
        #expect(resolved.hooks.first?.onlyUnfocused == true)
        #expect(resolved.hooks.first?.timeoutSeconds == 10)
    }

    @Test("a malformed notification member rejects the whole section")
    func malformedConfigurationFallsBackWholesale() async throws {
        try await withNotificationFixture(configuration: """
        [ui.notifications]
        method = "osc99"
        condition = "definitely-not-supported"
        events = ["turn_complete"]
        """) { fixture in
            let configuration = await fixture.renderer.terminalNotifications.configuration
            #expect(configuration == LiveTerminalNotificationConfiguration())
        }
    }

    @Test("automatic protocol selection matches every upstream terminal family")
    func automaticProtocolSelection() {
        let expected: [
            (OpenGrokDiagnostics.TerminalName, LiveTerminalNotifications.NotificationProtocol)
        ] = [
            (.iterm2, .osc9),
            (.wezTerm, .osc9),
            (.warpTerminal, .osc9),
            (.kitty, .osc99),
            (.ghostty, .osc777),
            (.vte, .osc777),
            (.terminator, .osc777),
            (.foot, .osc777),
            (.grokDesktop, .none),
            (.appleTerminal, .bel),
            (.alacritty, .bel),
            (.windowsTerminal, .bel),
            (.unknown, .bel),
        ]
        for (brand, protocolName) in expected {
            #expect(LiveTerminalNotifications.resolveProtocol(
                method: .auto,
                context: TerminalContext(brand: brand)
            ) == protocolName)
        }
        let zellij = TerminalContext(brand: .kitty, multiplexer: .zellij)
        #expect(LiveTerminalNotifications.resolveProtocol(method: .auto, context: zellij) == .bel)
        #expect(LiveTerminalNotifications.resolveProtocol(method: .osc99, context: zellij) == .osc99)
    }

    @Test("all notification protocols exactly sanitize C0 and C1 control characters")
    func notificationProtocolsAndControlSanitization() {
        let cases: [(LiveTerminalNotificationConfiguration.Method, String)] = [
            (.osc9, "\u{1B}]9;body]9;evil · title]0;pwned\u{07}"),
            (.osc99, "\u{1B}]99;i=open-grok;body]9;evil · title]0;pwned\u{1B}\\"),
            (.osc777, "\u{1B}]777;notify;Open Grok;body]9;evil\u{1B}\\"),
            (.bel, "\u{07}"),
        ]
        for (method, expected) in cases {
            var configuration = LiveTerminalNotificationConfiguration()
            configuration.method = method
            configuration.condition = .always
            let notifications = LiveTerminalNotifications(
                configuration: configuration,
                terminalContext: TerminalContext()
            )
            #expect(notifications.notificationSequence(
                event: .turnComplete,
                title: "title\u{1B}]0;\u{07}pwned\u{0085}",
                body: "body\u{1B}]9;\r\nevil"
            ) == expected)
        }
    }

    @Test("tmux wraps every escape and also wraps BEL notifications")
    func tmuxPassthroughEscaping() {
        var configuration = LiveTerminalNotificationConfiguration()
        configuration.method = .osc99
        configuration.condition = .always
        let context = TerminalContext(brand: .kitty, multiplexer: .tmux)
        let notifications = LiveTerminalNotifications(
            configuration: configuration,
            terminalContext: context
        )
        #expect(notifications.notificationSequence(
            event: .turnComplete,
            title: "Open Grok",
            body: "Done"
        ) == "\u{1B}Ptmux;\u{1B}\u{1B}]99;i=open-grok;Done · Open Grok"
            + "\u{1B}\u{1B}\\\u{1B}\\")

        configuration.method = .bel
        let bell = LiveTerminalNotifications(configuration: configuration, terminalContext: context)
        #expect(bell.notificationSequence(
            event: .turnComplete,
            title: "Open Grok",
            body: "Done"
        ) == "\u{1B}Ptmux;\u{07}\u{1B}\\")
    }

    @Test("focus conditions use monotonic time, inclusive thresholds, and fail closed on overflow")
    func focusThresholdAndRefocus() {
        var configuration = LiveTerminalNotificationConfiguration()
        configuration.idleThresholdSeconds = 3
        var notifications = LiveTerminalNotifications(
            configuration: configuration,
            terminalContext: TerminalContext()
        )
        #expect(!notifications.shouldEmit(nowNanoseconds: 100))
        notifications.focusLost(nowNanoseconds: 100)
        #expect(!notifications.shouldEmit(nowNanoseconds: 3_000_000_099))
        #expect(notifications.shouldEmit(nowNanoseconds: 3_000_000_100))
        notifications.focusGained()
        #expect(!notifications.shouldEmit(nowNanoseconds: 9_000_000_100))

        configuration.idleThresholdSeconds = UInt64.max
        var overflow = LiveTerminalNotifications(
            configuration: configuration,
            terminalContext: TerminalContext()
        )
        overflow.focusLost(nowNanoseconds: 0)
        #expect(!overflow.shouldEmit(nowNanoseconds: UInt64.max))
    }

    @Test("real fullscreen and minimal frontends enable focus and restore it safely")
    func focusReportingLifecycleInBothScreenModes() async throws {
        for mode in [OpenGrokPagerMode.fullScreen, .minimal] {
            try await withNotificationFixture(
                configuration: quietAlwaysOSC99Configuration,
                mode: mode
            ) { fixture in
                #expect(fixture.sink.count(ANSIMouse.enableFocusReporting) == 1)
                try await fixture.renderer.restoreTerminal()
                #expect(fixture.sink.count(ANSIMouse.disableFocusReporting) == 1)
                if mode == .fullScreen {
                    let focusDisable = try #require(
                        fixture.sink.offsets(of: ANSIMouse.disableFocusReporting).first
                    )
                    let alternateLeave = try #require(
                        fixture.sink.offsets(of: "\u{1B}[?1049l").first
                    )
                    #expect(focusDisable < alternateLeave)
                }
            }
        }
    }

    @Test("focus startup failures roll back reporting and the already-entered alternate screen")
    func focusStartupFailureRestoresFrontend() async throws {
        let fixture = try NotificationFixture()
        defer { fixture.dispose() }
        fixture.sink.failNextWrite(containing: "\u{1B}]0;Open Grok\u{07}")

        await #expect(throws: NotificationSinkFailure.self) {
            try await fixture.renderer.begin()
        }
        #expect(fixture.sink.count(ANSIMouse.enableFocusReporting) == 1)
        #expect(fixture.sink.count(ANSIMouse.disableFocusReporting) == 1)
        #expect(fixture.sink.count("\u{1B}[?1049h") == 1)
        #expect(fixture.sink.count("\u{1B}[?1049l") == 1)
    }

    @Test("non-interactive sinks never receive forged terminal capabilities")
    func nonTTYNeverEnablesFocusOrNotifications() async throws {
        try await withNotificationFixture(
            configuration: quietAlwaysOSC99Configuration,
            isTTY: false
        ) { fixture in
            try await fixture.startTurn()
            try await fixture.finishTurn()
            #expect(fixture.sink.count(ANSIMouse.enableFocusReporting) == 0)
            #expect(fixture.sink.count("\u{1B}]99;") == 0)
        }
    }

    @Test("actual focus input controls live completion delivery and refocus suppresses it")
    func focusEventsReachRealRendererNotificationSeam() async throws {
        try await withNotificationFixture(configuration: """
        [ui.notifications]
        method = "osc9"
        condition = "unfocused"
        idle_threshold_secs = 0
        progress_bar = false

        [ui.notifications.title]
        enabled = false
        """) { fixture in
            try await fixture.startTurn("focused")
            try await fixture.finishTurn()
            #expect(fixture.sink.count("\u{1B}]9;Turn complete") == 0)

            let lost = try await fixture.renderer.handleInput(.focusLost)
            #expect(lost == .consumed)
            try await fixture.startTurn("away")
            try await fixture.finishTurn()
            #expect(fixture.sink.count("\u{1B}]9;Turn complete") == 1)
            #expect(fixture.sink.text.contains(" · Open Grok\u{07}"))

            let gained = try await fixture.renderer.handleInput(.focusGained)
            #expect(gained == .consumed)
            try await fixture.startTurn("refocused")
            try await fixture.finishTurn()
            #expect(fixture.sink.count("\u{1B}]9;Turn complete") == 1)
        }
    }

    @Test("upstream terminal events before turn-finished do not duplicate notifications")
    func realSessionCompletionEmitsExactlyOnce() async throws {
        try await withNotificationFixture(
            configuration: quietAlwaysOSC99Configuration
        ) { fixture in
            try await fixture.startTurn()
            try await fixture.renderer.render(.session(.completed(.init())))
            #expect(fixture.sink.count("\u{1B}]99;") == 0)
            try await fixture.finishTurn()
            #expect(fixture.sink.count("\u{1B}]99;") == 1)
            try await fixture.finishTurn()
            #expect(fixture.sink.count("\u{1B}]99;") == 1)
        }
    }

    @Test("queued followups, cancelled results, and cancelled-completed races never notify")
    func queuedAndCancelledTurnsStaySilent() async throws {
        try await withNotificationFixture(
            configuration: quietAlwaysOSC99Configuration
        ) { fixture in
            try await fixture.startTurn("queued")
            try await fixture.renderer.render(.queueChanged(queuedPromptCount: 1))
            try await fixture.finishTurn()
            #expect(fixture.sink.count("\u{1B}]99;") == 0)

            try await fixture.renderer.render(.queueChanged(queuedPromptCount: 0))
            try await fixture.startTurn("cancelled-result")
            try await fixture.renderer.render(.session(.cancelled))
            try await fixture.finishTurn(cancelled: true)
            #expect(fixture.sink.count("\u{1B}]99;") == 0)

            try await fixture.startTurn("cancel-race")
            try await fixture.renderer.render(.session(.lifecycle(.cancelling)))
            try await fixture.renderer.render(.session(.completed(.init())))
            try await fixture.finishTurn()
            #expect(fixture.sink.count("\u{1B}]99;") == 0)

            try await fixture.startTurn("cancel-event")
            try await fixture.renderer.render(.turnCancelled)
            #expect(fixture.sink.count("\u{1B}]99;") == 0)
        }
    }

    @Test("actual permission overlay notifications fire only once per queued batch")
    func permissionNotificationDeduplicatesQueueTransitions() async throws {
        try await withNotificationFixture(
            configuration: quietAlwaysOSC99Configuration
        ) { fixture in
            await fixture.renderer.showPermission(PagerPermissionRequest(
                id: "first", toolName: "bash"
            ))
            #expect(fixture.sink.count("\u{1B}]99;i=open-grok;Approval required") == 1)

            await fixture.renderer.showPermission(PagerPermissionRequest(
                id: "replacement", toolName: "bash"
            ))
            #expect(fixture.sink.count("\u{1B}]99;i=open-grok;Approval required") == 1)

            await fixture.renderer.showPermission(nil)
            #expect(fixture.sink.count("\u{1B}]99;i=open-grok;Approval required") == 1)

            await fixture.renderer.showPermission(PagerPermissionRequest(
                id: "next-batch", toolName: "edit_file"
            ))
            #expect(fixture.sink.count("\u{1B}]99;i=open-grok;Approval required") == 2)
        }
    }

    @Test("condition never, method none, and event allowlists all fail closed")
    func configuredSuppressionAndEventFiltering() async throws {
        let configurations = [
            """
            [ui.notifications]
            method = "osc99"
            condition = "never"
            progress_bar = false
            [ui.notifications.title]
            enabled = false
            """,
            """
            [ui.notifications]
            method = "none"
            condition = "always"
            progress_bar = false
            [ui.notifications.title]
            enabled = false
            """,
            """
            [ui.notifications]
            method = "osc99"
            condition = "always"
            events = ["approval_required"]
            progress_bar = false
            [ui.notifications.title]
            enabled = false
            """,
        ]
        for configuration in configurations {
            try await withNotificationFixture(configuration: configuration) { fixture in
                try await fixture.startTurn()
                try await fixture.finishTurn()
                #expect(fixture.sink.count("\u{1B}]99;") == 0)
            }
        }
    }

    @Test("agent errors notify only when explicitly present in the event allowlist")
    func agentErrorAllowlist() async throws {
        try await withNotificationFixture(configuration: """
        [ui.notifications]
        method = "osc777"
        condition = "always"
        events = ["agent_error"]
        progress_bar = false
        [ui.notifications.title]
        enabled = false
        """) { fixture in
            try await fixture.startTurn()
            try await fixture.renderer.render(.turnFailed(message: "provider\u{1B} failed"))
            #expect(fixture.sink.text.contains(
                "\u{1B}]777;notify;Open Grok;Error: provider failed\u{1B}\\"
            ))
            #expect(fixture.sink.count("\u{1B}]777;notify;") == 1)
        }
    }

    @Test("project notification configuration overrides user config through the live authority chain")
    func effectiveProjectConfigurationControlsLiveProtocol() async throws {
        try await withNotificationFixture(
            configuration: """
            [ui.notifications]
            method = "none"
            condition = "always"
            progress_bar = false
            [ui.notifications.title]
            enabled = false
            """,
            projectConfiguration: """
            [ui.notifications]
            method = "osc99"
            """
        ) { fixture in
            #expect(await fixture.renderer.terminalNotifications.notificationProtocol == .osc99)
            try await fixture.startTurn()
            try await fixture.finishTurn()
            #expect(fixture.sink.count("\u{1B}]99;") == 1)
        }
    }

    @Test("OSC 9;4 progress requires a verified capable terminal and clears on completion")
    func progressCapabilitiesAndLifecycle() async throws {
        let configuration = """
        [ui.notifications]
        method = "none"
        condition = "never"
        progress_bar = true
        [ui.notifications.title]
        enabled = false
        """

        try await withNotificationFixture(
            configuration: configuration,
            environmentExtras: ["TERM_PROGRAM": "iTerm.app", "TERM_PROGRAM_VERSION": "3.5.0"]
        ) { fixture in
            try await fixture.startTurn()
            #expect(!fixture.sink.text.contains("\u{1B}]9;4;1;-1\u{07}"))
            try await fixture.finishTurn()
        }

        try await withNotificationFixture(
            configuration: configuration,
            environmentExtras: ["TERM_PROGRAM": "iTerm.app", "TERM_PROGRAM_VERSION": "3.6.0"]
        ) { fixture in
            try await fixture.startTurn()
            #expect(fixture.sink.count("\u{1B}]9;4;1;-1\u{07}") == 1)
            try await fixture.finishTurn()
            #expect(fixture.sink.count("\u{1B}]9;4;0;0\u{07}") == 1)
        }
    }

    @Test("malformed iTerm versions never claim unsafe OSC 9;4 progress support")
    func malformedITermVersionFailsClosed() {
        let versions = ["3.6beta", "3.x", "3.", "3.4294967296", "garbage"]
        for version in versions {
            let notifications = LiveTerminalNotifications(
                configuration: LiveTerminalNotificationConfiguration(),
                terminalContext: TerminalContext(
                    brand: .iterm2,
                    termProgramVersion: version
                )
            )
            #expect(!notifications.supportsProgressBar)
        }
    }

    @Test("supported progress indicators refresh every five monotonic seconds")
    func progressKeepaliveUsesMonotonicTime() {
        var configuration = LiveTerminalNotificationConfiguration()
        configuration.title.enabled = false
        var notifications = LiveTerminalNotifications(
            configuration: configuration,
            terminalContext: TerminalContext(brand: .ghostty)
        )

        func presentation(_ now: UInt64, busy: Bool = true) -> String? {
            notifications.presentationSequence(
                sessionName: nil,
                model: nil,
                activity: nil,
                pendingApproval: false,
                workingDirectory: nil,
                turnElapsed: nil,
                busy: busy,
                nowNanoseconds: now
            )
        }

        #expect(presentation(100) == "\u{1B}]9;4;1;-1\u{07}")
        #expect(presentation(5_000_000_099) == nil)
        #expect(presentation(5_000_000_100) == "\u{1B}]9;4;1;-1\u{07}")
        #expect(presentation(5_000_000_101, busy: false) == "\u{1B}]9;4;0;0\u{07}")
        #expect(presentation(5_000_000_102, busy: false) == nil)
    }

    @Test("real session names appear in both terminal titles and completion popups")
    func activeSessionNameFlowsToTitleAndNotification() async throws {
        try await withNotificationFixture(configuration: """
        [ui.notifications]
        method = "osc9"
        condition = "always"
        progress_bar = false
        [ui.notifications.title]
        items = ["session-name", "open-grok"]
        """) { fixture in
            await fixture.renderer.touchSessionTab(
                "notification-live",
                title: "Ship release"
            )
            try await fixture.startTurn()
            #expect(fixture.sink.text.contains("\u{1B}]0;Ship release - Open Grok\u{07}"))
            try await fixture.finishTurn()
            #expect(fixture.sink.text.contains(" · Ship release\u{07}"))
        }
    }

    @Test("terminal title updates on real turn/permission transitions and sanitizes model data")
    func liveTitleTransitionsAndSanitization() async throws {
        try await withNotificationFixture(
            configuration: """
            [ui.notifications]
            method = "none"
            condition = "never"
            progress_bar = false
            [ui.notifications.title]
            enabled = true
            items = ["action-required", "spinner", "activity", "model", "open-grok"]
            """,
            modelName: "safe\u{1B}]0;evil\u{07}model"
        ) { fixture in
            #expect(fixture.sink.text.contains("\u{1B}]0;safe]0;evilmodel - Open Grok\u{07}"))
            try await fixture.startTurn()
            #expect(fixture.sink.text.contains("⠋ - Thinking - safe]0;evilmodel - Open Grok"))
            await fixture.renderer.showPermission(PagerPermissionRequest(
                id: "title-permission", toolName: "bash"
            ))
            #expect(fixture.sink.text.contains("⚠ Action Required - ⠋ - Thinking"))
            try await fixture.renderer.restoreTerminal()
            #expect(fixture.sink.text.contains("\u{1B}]0;Open Grok\u{07}"))
        }
    }

    @Test("terminal focus reporting is disabled around child ownership and reenabled afterwards")
    func focusReportingSuspendsAndResumesWithChild() async throws {
        try await withNotificationFixture(
            configuration: quietAlwaysOSC99Configuration
        ) { fixture in
            try await fixture.renderer.frontendSuspendToChild()
            #expect(fixture.sink.count(ANSIMouse.disableFocusReporting) == 1)
            try await fixture.renderer.frontendResumeFromChild()
            #expect(fixture.sink.count(ANSIMouse.enableFocusReporting) == 2)
        }
    }

    @Test("suspend flush failures restore focus reporting before surfacing the error")
    func failedSuspendRearmsFocusReporting() async throws {
        try await withNotificationFixture(
            configuration: quietAlwaysOSC99Configuration
        ) { fixture in
            fixture.sink.failNextFlush()
            await #expect(throws: NotificationSinkFailure.self) {
                try await fixture.renderer.frontendSuspendToChild()
            }
            #expect(fixture.sink.count(ANSIMouse.disableFocusReporting) == 1)
            #expect(fixture.sink.count(ANSIMouse.enableFocusReporting) == 2)
            #expect(await fixture.renderer.terminalNotifications.focusReportingEnabled)
        }
    }

    @Test("progress clears when a child takes the terminal and resumes only after reentry")
    func progressClearsDuringSuspendAndReturnsAfterResume() async throws {
        try await withNotificationFixture(
            configuration: """
            [ui.notifications]
            method = "none"
            condition = "never"
            progress_bar = true
            [ui.notifications.title]
            enabled = false
            """,
            environmentExtras: ["TERM_PROGRAM": "ghostty"]
        ) { fixture in
            try await fixture.startTurn()
            #expect(fixture.sink.count("\u{1B}]9;4;1;-1\u{07}") == 1)
            try await fixture.renderer.frontendSuspendToChild()
            #expect(fixture.sink.count("\u{1B}]9;4;0;0\u{07}") == 1)
            try await fixture.renderer.frontendResumeFromChild()
            #expect(fixture.sink.count("\u{1B}]9;4;1;-1\u{07}") == 2)
            try await fixture.renderer.frontendSuspendToChild()
            #expect(fixture.sink.count("\u{1B}]9;4;0;0\u{07}") == 2)
            try await fixture.renderer.restoreTerminal()
            #expect(fixture.sink.text.contains("\u{1B}]0;Open Grok\u{07}"))
        }
    }
}
