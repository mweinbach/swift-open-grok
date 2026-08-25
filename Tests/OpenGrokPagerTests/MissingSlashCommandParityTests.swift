import Foundation
@testable import OpenGrokPager
import OpenGrokPagerCommandUI
import OpenGrokTerminalCore
import Testing

@Suite("Rust .82 backed slash commands")
struct MissingSlashCommandParityTests {
    @Test("Registry copies and display order match the Rust command list")
    func upstreamRegistryMetadata() {
        let commands = OpenGrokPagerInteractiveController.builtinCommands
        let expectations: [(String, String, String)] = [
            ("edit-prompt",
             "Open an external editor for an empty prompt; use the command palette to preserve a draft",
             "/edit-prompt"),
            ("yolo-2", "Toggle always-approve mode while an OS sandbox is active", "/yolo-2"),
            ("auto", "Toggle auto mode (classifier approves safe tools)", "/auto"),
            ("share", "Share this session via URL", "/share"),
            ("add-dir", "Add a directory to this session's working set", "/add-dir <path>"),
            ("remove-dir", "Remove a directory from this session's working set", "/remove-dir <path>"),
            ("import-claude", "Open the Claude settings import modal", "/import-claude"),
        ]
        for (name, summary, usage) in expectations {
            let command = commands.first { $0.name == name }
            #expect(command?.summary == summary)
            #expect(command?.usage == usage)
        }

        let names = commands.map(\.name)
        let transcript = names.firstIndex(of: "transcript")!
        #expect(Array(names[(transcript + 1)...(transcript + 2)]) == ["edit-prompt", "expand"])
        let alwaysApprove = names.firstIndex(of: "always-approve")!
        #expect(Array(names[(alwaysApprove + 1)...(alwaysApprove + 2)]) == ["yolo-2", "auto"])
        let skills = names.firstIndex(of: "skills")!
        #expect(Array(names[(skills + 1)...(skills + 2)]) == ["share", "session-info"])
        let dashboard = names.firstIndex(of: "dashboard")!
        #expect(Array(names[(dashboard + 1)...(dashboard + 3)])
            == ["add-dir", "remove-dir", "theme"])
        let logout = names.firstIndex(of: "logout")!
        #expect(names[logout + 1] == "import-claude")
    }

    @Test("Auto is hard-hidden when its session feature gate is off")
    func autoFeatureGateHidesCommand() async throws {
        let renderer = BackedSlashRecordingRenderer(autoPermissionModeAvailable: false)
        let result = try await runBackedSlashCommands(
            ["/auto"],
            renderer: renderer,
            sessionID: "session"
        )
        #expect(result.submittedPrompts.isEmpty)
        #expect(await renderer.commands.isEmpty)
        #expect(await renderer.notices == ["unknown command: /auto"])

        let advertised = OpenGrokPagerInteractiveController.visibleBuiltinCommandCatalog(
            autoPermissionModeAvailable: false
        )
        #expect(!advertised.contains { $0.name == "auto" })
        #expect(!OpenGrokPagerInteractiveController.helpText(
            autoPermissionModeAvailable: false
        ).contains("/auto"))
    }

    @Test("Auto, sandboxed always-approve, and sharing reach the live capability")
    func backedCommandsDispatchAndIgnoreArguments() async throws {
        let renderer = BackedSlashRecordingRenderer()
        let result = try await runBackedSlashCommands(
            ["/auto unused", "/yolo-2 unused", "/share unused", "/import-claude unused"],
            renderer: renderer,
            sessionID: "active-session"
        )
        #expect(result.submittedPrompts.isEmpty)
        #expect(await renderer.commands == [
            .toggleAuto,
            .toggleSandboxedAlwaysApprove,
            .shareSession(sessionID: "active-session"),
            .importClaudeSettings,
        ])
    }

    @Test("Directory commands remain invisible until a verified live backend is installed")
    func directoryCommandsFailClosedWithoutBackend() async throws {
        let renderer = BackedSlashRecordingRenderer()
        _ = try await runBackedSlashCommands(
            ["/add-dir /tmp", "/remove-dir /tmp"],
            renderer: renderer,
            sessionID: "active-session"
        )
        #expect(await renderer.commands.isEmpty)
        #expect(await renderer.notices == [
            "unknown command: /add-dir",
            "unknown command: /remove-dir",
        ])

        let advertised = OpenGrokPagerInteractiveController.visibleBuiltinCommandCatalog()
        #expect(!advertised.contains { ["add-dir", "remove-dir"].contains($0.name) })
        let help = OpenGrokPagerInteractiveController.helpText()
        #expect(!help.contains("/add-dir"))
        #expect(!help.contains("/remove-dir"))
    }

    @Test("Verified directory commands preserve the raw path and authenticated session")
    func directoryCommandsReachSecureBackend() async throws {
        let renderer = BackedSlashRecordingRenderer(workingDirectoryCommandsAvailable: true)
        _ = try await runBackedSlashCommands(
            ["/add-dir ~/Projects/example folder", "/remove-dir ../old folder"],
            renderer: renderer,
            sessionID: "active-session"
        )
        #expect(await renderer.commands == [
            .addWorkingDirectory(path: "~/Projects/example folder", sessionID: "active-session"),
            .removeWorkingDirectory(path: "../old folder", sessionID: "active-session"),
        ])
    }

    @Test("Sharing refuses before touching the backend without an active session")
    func sharingRequiresSession() async throws {
        let renderer = BackedSlashRecordingRenderer()
        _ = try await runBackedSlashCommands(["/share"], renderer: renderer, sessionID: nil)
        #expect(await renderer.commands.isEmpty)
        #expect(await renderer.notices == ["No active session to share"])
    }

    @Test("Typed minimal-mode external edit replaces the actual composer draft")
    func externalEditorReplacesComposer() async throws {
        let renderer = BackedSlashRecordingRenderer(editedPrompt: "edited\nsecond line")
        let result = try await runBackedSlashCommands(
            ["/edit-prompt"],
            renderer: renderer,
            mode: .minimal,
            sessionID: "editing-session"
        )
        #expect(result.submittedPrompts.isEmpty)
        #expect(await renderer.commands == [.editPrompt(draft: "")])
        #expect(await renderer.latestPrompt == "edited\nsecond line")
    }

    @Test("A command-palette dispatch passes the preexisting composer draft")
    func palettePreservesExistingDraft() async throws {
        let renderer = BackedSlashRecordingRenderer(editedPrompt: "draft after editor")
        await renderer.stagePaletteCommand("/edit-prompt")
        let controller = OpenGrokPagerInteractiveController(
            input: AsyncStream { continuation in
                continuation.yield(.paste("draft before editor"))
                continuation.yield(.key(KeyEvent(key: .f(1))))
                continuation.finish()
            },
            runtime: BackedSlashRuntime(),
            renderer: renderer,
            output: BackedSlashSilentOutput()
        )
        _ = try await controller.run(.init(
            prompt: "",
            mode: .minimal,
            sessionID: "editing-session"
        ))
        #expect(await renderer.commands == [.editPrompt(draft: "draft before editor")])
        #expect(await renderer.latestPrompt == "draft after editor")
    }

    @Test("External editing refuses fullscreen with the upstream mode remedy")
    func externalEditorRequiresMinimalMode() async throws {
        let renderer = BackedSlashRecordingRenderer()
        _ = try await runBackedSlashCommands(
            ["/edit-prompt"],
            renderer: renderer,
            mode: .fullScreen,
            sessionID: "editing-session"
        )
        #expect(await renderer.commands.isEmpty)
        #expect(await renderer.notices == [
            "/edit-prompt isn't available in fullscreen mode "
            + "(the full TUI has no external-editor path — Ctrl+G is the tasks pane there). "
            + "Run /minimal to switch this session."
        ])
    }
}

private func runBackedSlashCommands(
    _ lines: [String],
    renderer: BackedSlashRecordingRenderer,
    mode: OpenGrokPagerMode = .inline,
    sessionID: String?
) async throws -> OpenGrokPagerInteractiveResult {
    let controller = OpenGrokPagerInteractiveController(
        input: AsyncStream { continuation in
            for line in lines {
                continuation.yield(.paste(line))
                continuation.yield(.key(KeyEvent(key: .escape)))
                continuation.yield(.key(KeyEvent(key: .enter)))
            }
            continuation.finish()
        },
        runtime: BackedSlashRuntime(),
        renderer: renderer,
        output: BackedSlashSilentOutput()
    )
    return try await controller.run(.init(prompt: "", mode: mode, sessionID: sessionID))
}

private actor BackedSlashRecordingRenderer: OpenGrokPagerBackedSlashRenderAdapter {
    nonisolated let autoPermissionModeAvailable: Bool
    nonisolated let workingDirectoryCommandsAvailable: Bool
    private let editedPrompt: String
    private(set) var commands: [OpenGrokPagerBackedSlashCommand] = []
    private var events: [OpenGrokPagerInteractiveEvent] = []
    private var stagedPaletteCommand: String?

    init(
        autoPermissionModeAvailable: Bool = true,
        workingDirectoryCommandsAvailable: Bool = false,
        editedPrompt: String = "edited prompt"
    ) {
        self.autoPermissionModeAvailable = autoPermissionModeAvailable
        self.workingDirectoryCommandsAvailable = workingDirectoryCommandsAvailable
        self.editedPrompt = editedPrompt
    }

    func begin() {}
    func restoreTerminal() {}

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }

    func handleInput(_ event: InputEvent) -> OpenGrokPagerInputRouting {
        guard case .key(let key) = event,
              key.key == .f(1),
              let command = stagedPaletteCommand else { return .notHandled }
        stagedPaletteCommand = nil
        return .runCommand(command)
    }

    func stagePaletteCommand(_ command: String) {
        stagedPaletteCommand = command
    }

    func performBackedSlashCommand(
        _ command: OpenGrokPagerBackedSlashCommand
    ) -> OpenGrokPagerBackedSlashOutcome {
        commands.append(command)
        if case .editPrompt = command {
            return .editedPrompt(editedPrompt)
        }
        return .completed
    }

    var notices: [String] {
        events.compactMap { event in
            if case .notice(let message) = event { return message }
            return nil
        }
    }

    var latestPrompt: String? {
        events.reversed().compactMap { event in
            if case .promptChanged(let prompt) = event { return prompt.text }
            return nil
        }.first
    }
}

private struct BackedSlashSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

private actor BackedSlashRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw BackedSlashRuntimeError.unexpectedTurn
    }

    func replaceSession(from request: OpenGrokPagerRequest) async throws -> String {
        _ = request
        throw BackedSlashRuntimeError.unexpectedTurn
    }
}

private enum BackedSlashRuntimeError: Error {
    case unexpectedTurn
}
