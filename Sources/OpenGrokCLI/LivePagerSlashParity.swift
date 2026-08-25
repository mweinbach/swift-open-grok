import Foundation
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokPager
import OpenGrokSandbox
import OpenGrokShellSessionSupport

enum LivePagerSlashParity {
    static let promptEditorMaximumBytes = 4 * 1024 * 1024

    static let sandboxRequiredMessage =
        "YOLO-2 requires an active OS sandbox. Restart Open Grok with "
        + "`--sandbox workspace` before enabling it."

    /// Requirements outrank environment, local config, and authenticated
    /// allowlisted remote settings; an entirely absent gate defaults on.
    static func autoModeAvailable(
        environment: [String: String],
        remoteEnabled: Bool? = nil
    ) -> Bool {
        if let required = loadMergedRequirements(environment: environment)?[
            path: ["auto_mode", "enabled"]
        ]?.boolValue {
            return required
        }
        if let override = OpenGrokConfig.envBool(
            "GROK_AUTO_PERMISSION_MODE",
            environment: environment
        ) {
            return override
        }
        do {
            let effective = try loadEffectiveConfigDiskOnly(environment: environment)
            return effective[path: ["auto_mode", "enabled"]]?.boolValue
                ?? remoteEnabled
                ?? true
        } catch {
            // A malformed authority layer must never silently expose an
            // approval-bypassing feature whose administrator gate is unknown.
            return false
        }
    }

    enum EditorChildError: Error, Sendable {
        case unsuccessfulExit(Int32)
    }

    /// Unlike the transcript pager, prompt editing may apply bytes only when
    /// the editor exits successfully (`external_editor.rs:284-303`).
    static func runPromptEditorChild(
        program: String,
        arguments: [String],
        environment: [String: String]
    ) async -> (any Error)? {
        let process = Process()
        #if os(Windows)
        let systemRoot = environment["SystemRoot"] ?? #"C:\Windows"#
        let commandInterpreter = environment["COMSPEC"]
            ?? (systemRoot as NSString).appendingPathComponent(#"System32\cmd.exe"#)
        process.executableURL = URL(fileURLWithPath: commandInterpreter)
        process.arguments = ["/d", "/c", program] + arguments
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [program] + arguments
        #endif
        process.environment = environment

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { completed in
                if completed.terminationStatus == 0 {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: EditorChildError.unsuccessfulExit(
                        completed.terminationStatus
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: error)
            }
        }
    }
}

extension LiveInteractiveControllerRenderer: OpenGrokPagerBackedSlashRenderAdapter {
    func performBackedSlashCommand(
        _ command: OpenGrokPagerBackedSlashCommand
    ) async throws -> OpenGrokPagerBackedSlashOutcome {
        switch command {
        case .toggleAuto:
            guard autoPermissionModeAvailable, let permissionMode else {
                return .notice("Auto mode is unavailable in this session.")
            }
            let message = await permissionMode.toggleAutoMode()
            permissionModeFlags = await permissionMode.composerFlags()
            return .notice(message)

        case .toggleSandboxedAlwaysApprove:
            guard OpenGrokSandbox.isSandboxActive(),
                  toolExecutor?.sandbox.enforced == true else {
                return .notice(LivePagerSlashParity.sandboxRequiredMessage)
            }
            guard let permissionMode else {
                return .notice("Always-approve mode is unavailable in this session.")
            }
            let message = await permissionMode.toggleAlwaysApprove()
            permissionModeFlags = await permissionMode.composerFlags()
            return message.map(OpenGrokPagerBackedSlashOutcome.notice) ?? .completed

        case .shareSession(let requestedSessionID):
            guard !sessionID.isEmpty, requestedSessionID == sessionID else {
                return .notice("No active session to share")
            }
            let transport = URLSessionHTTPTransport()
            let uploadClient = shareRoute.makeSignedUploadClient(environment, transport)
            let backendClient = shareRoute.makeBackendClient(environment, transport)
            let remoteSettings = await shareRoute.loadRemoteSettings(environment)
            let boundary = await conversationHistory?.sharedExportBoundary
            let liveBoundaries: (@Sendable (String) -> ExportBoundary?)?
            if let boundary {
                liveBoundaries = { requested in
                    requested == requestedSessionID ? boundary : nil
                }
            } else {
                liveBoundaries = nil
            }

            do {
                let url = try await LiveShareComposition.shareURL(
                    sessionID: requestedSessionID,
                    environment: environment,
                    remoteSettings: remoteSettings,
                    liveBoundaries: liveBoundaries,
                    signedUploadClient: uploadClient,
                    backendClient: backendClient
                )
                return .notice(url)
            } catch let refusal as ShareRefusal {
                return .notice(refusal.message)
            } catch let failure as CLIApplicationError {
                return .notice(failure.description)
            }

        case .editPrompt(let draft):
            return try await editPromptInExternalEditor(draft)

        case .addWorkingDirectory(let path, let requestedSessionID):
            return await updateSessionWorkingDirectory(
                path: path,
                requestedSessionID: requestedSessionID,
                remove: false
            )

        case .removeWorkingDirectory(let path, let requestedSessionID):
            return await updateSessionWorkingDirectory(
                path: path,
                requestedSessionID: requestedSessionID,
                remove: true
            )

        case .importClaudeSettings:
            try presentClaudeSettingsImport()
            return .completed
        }
    }

    private func updateSessionWorkingDirectory(
        path: String,
        requestedSessionID: String,
        remove: Bool
    ) async -> OpenGrokPagerBackedSlashOutcome {
        guard workingDirectoryCommandsAvailable,
              !sessionID.isEmpty,
              requestedSessionID == sessionID else {
            return .notice(
                "working-directory changes are unavailable for session \(requestedSessionID)"
            )
        }

        do {
            let registry = LiveSessionWorkingDirectoryRegistry.shared
            let cwd = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            let result: LiveSessionWorkingDirectoryChange
            if remove {
                result = try await registry.remove(
                    path: path,
                    sessionID: requestedSessionID,
                    workingDirectory: cwd,
                    environment: environment
                )
            } else {
                result = try await registry.add(
                    path: path,
                    sessionID: requestedSessionID,
                    workingDirectory: cwd,
                    environment: environment
                )
            }

            if !result.changed {
                return .notice(remove
                    ? "Directory was not in the working set"
                    : "Directory already in the working set")
            }
            if result.directories.isEmpty {
                return .notice("Working set is back to the session directory only")
            }
            let noun = result.directories.count == 1 ? "directory" : "directories"
            let paths = result.directories.map(\.path).joined(separator: ", ")
            return .notice("Working \(noun): \(paths)")
        } catch {
            return .notice("Couldn't \(remove ? "remove" : "add") working directory: \(error)")
        }
    }

    private func editPromptInExternalEditor(
        _ draft: String
    ) async throws -> OpenGrokPagerBackedSlashOutcome {
        guard !voiceState.isListening else {
            return .notice(
                "External prompt editing is not available while voice input is active."
            )
        }
        guard let suspendHost else {
            return .notice(
                "This session has no suspendable terminal input, so $EDITOR cannot open."
            )
        }
        guard let editor = LiveTUISuspendHost.resolveEditor(
            environment: suspendHost.environment
        ) else {
            return .notice("could not parse $VISUAL or $EDITOR")
        }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-prompt-\(UUID().uuidString).md")
        guard FileManager.default.createFile(
            atPath: file.path,
            contents: Data(draft.utf8),
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            return .notice(
                "Could not open the draft in an external editor; the original draft was kept."
            )
        }
        defer { try? FileManager.default.removeItem(at: file) }

        let outcome = try await runSuspendedChild(
            host: suspendHost,
            program: editor.program,
            arguments: editor.arguments + [file.path],
            suspendFailPrefix: "Could not suspend the terminal for $EDITOR",
            childRunner: { program, arguments, environment in
                await LivePagerSlashParity.runPromptEditorChild(
                    program: program,
                    arguments: arguments,
                    environment: environment
                )
            }
        )
        switch outcome {
        case .parkTimedOut:
            return .notice("terminal input reader did not park before suspend")
        case .suspendFailed:
            // `runSuspendedChild` already recorded the terminal failure.
            return .completed
        case .completed(let failure):
            if failure is LivePagerSlashParity.EditorChildError {
                return .notice(
                    "External prompt editor exited unsuccessfully; the original draft was kept."
                )
            }
            if failure != nil {
                return .notice(
                    "External prompt editor failed; the original draft was kept."
                )
            }
        }

        let bytes: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            if let size = attributes[.size] as? NSNumber,
               size.intValue > LivePagerSlashParity.promptEditorMaximumBytes {
                return .notice(
                    "External prompt editor saved a draft larger than 4 MiB; the original draft was kept."
                )
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            bytes = try handle.read(upToCount: LivePagerSlashParity.promptEditorMaximumBytes + 1)
                ?? Data()
        } catch {
            return .notice("External prompt editor failed; the original draft was kept.")
        }
        guard bytes.count <= LivePagerSlashParity.promptEditorMaximumBytes else {
            return .notice(
                "External prompt editor saved a draft larger than 4 MiB; the original draft was kept."
            )
        }
        guard let edited = String(data: bytes, encoding: .utf8) else {
            return .notice(
                "External prompt editor saved invalid UTF-8; the original draft was kept."
            )
        }
        return .editedPrompt(edited)
    }
}
