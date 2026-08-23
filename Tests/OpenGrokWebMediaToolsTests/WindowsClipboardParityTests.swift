import Foundation
import Testing
@testable import OpenGrokWebMediaTools

private final class WindowsClipboardRecordingRunner: ClipboardCommandRunner, @unchecked Sendable {
    struct Invocation: Sendable {
        let executable: String
        let arguments: [String]
        let input: Data?
        let timeout: TimeInterval
    }

    enum Outcome: Sendable {
        case result(ClipboardCommandResult)
        case failure(ClipboardError)
    }

    private let lock = NSLock()
    private var recorded: [Invocation] = []
    private let outcome: Outcome

    init(outcome: Outcome = .result(ClipboardCommandResult(status: 0))) {
        self.outcome = outcome
    }

    var invocations: [Invocation] {
        lock.withLock { recorded }
    }

    func run(
        executable: String,
        arguments: [String],
        input: Data?,
        timeout: TimeInterval
    ) throws -> ClipboardCommandResult {
        lock.withLock {
            recorded.append(Invocation(
                executable: executable,
                arguments: arguments,
                input: input,
                timeout: timeout
            ))
        }
        switch outcome {
        case .result(let result):
            return result
        case .failure(let error):
            throw error
        }
    }
}

@Suite("Native Windows text clipboard parity")
struct WindowsClipboardParityTests {
    @Test("Windows publishes only text clipboard capability from a trusted SystemRoot")
    func windowsClipboardCapabilitiesAreTruthful() {
        let available = SystemClipboardProvider(
            platform: .windows,
            environment: ["SystemRoot": #"C:\Windows"#]
        )
        let unavailable = SystemClipboardProvider(platform: .windows, environment: [:])

        #expect(available.capabilityStatus()[.clipboardText] == true)
        #expect(available.capabilityStatus()[.clipboardImage] == false)
        #expect(available.capabilityStatus()[.clipboardFileURLs] == false)
        #expect(unavailable.capabilityStatus()[.clipboardText] == false)
    }

    @Test("Windows clipboard writes invoke only the absolute System32 clip.exe")
    func windowsTextWritesUseTrustedExecutable() async throws {
        let recorder = WindowsClipboardRecordingRunner()
        let provider = SystemClipboardProvider(
            platform: .windows,
            environment: [
                "SystemRoot": #"D:\Operating System"#,
                "PATH": #"C:\attacker;D:\untrusted"#,
            ],
            commandRunner: recorder,
            commandTimeout: 3
        )

        try await provider.write(.text("Swift café 会話"))

        let invocation = try #require(recorder.invocations.first)
        #expect(recorder.invocations.count == 1)
        #expect(invocation.executable == #"D:\Operating System\System32\clip.exe"#)
        #expect(invocation.arguments.isEmpty)
        #expect(invocation.input == Data("Swift café 会話".utf8))
        #expect(invocation.timeout == 3)
    }

    @Test("SystemRoot aliases normalize valid drive paths without searching PATH")
    func systemRootAliasesAndSeparators() {
        #expect(
            SystemClipboardProvider.windowsClipboardExecutable(
                environment: ["SYSTEMROOT": "c:/Windows/"]
            ) == #"c:\Windows\System32\clip.exe"#
        )
        #expect(
            SystemClipboardProvider.windowsClipboardExecutable(
                environment: ["windir": #"E:\Trusted\Windows"#]
            ) == #"E:\Trusted\Windows\System32\clip.exe"#
        )
    }

    @Test(arguments: [
        "",
        "Windows",
        #"C:Windows"#,
        #"\\server\share\Windows"#,
        #"\\?\C:\Windows"#,
        #"C:\Windows\..\attacker"#,
        #"C:\Windows\.\System32"#,
        #"C:\Windows\other:stream"#,
        "C:\\Windows\0attacker",
    ])
    func invalidSystemRootsFailClosed(_ root: String) async {
        let recorder = WindowsClipboardRecordingRunner()
        let provider = SystemClipboardProvider(
            platform: .windows,
            environment: [
                "SystemRoot": root,
                "PATH": #"C:\attacker"#,
            ],
            commandRunner: recorder
        )

        #expect(provider.capabilityStatus()[.clipboardText] == false)
        do {
            try await provider.write(.text("never execute PATH clip.exe"))
            Issue.record("invalid Windows SystemRoot unexpectedly authorized a clipboard write")
        } catch ClipboardError.capabilityUnavailable(let capability, let platform, _) {
            #expect(capability == .clipboardText)
            #expect(platform == .windows)
        } catch {
            Issue.record("unexpected clipboard failure: \(error)")
        }
        #expect(recorder.invocations.isEmpty)
    }

    @Test("Windows PATH uses semicolons while Unix retains colon-separated entries")
    func executableSearchRespectsPlatformSeparators() {
        #expect(
            SystemClipboardCommandRunner.executableSearchDirectories(
                #"C:\Windows\System32;D:\Tools;;E:\Other"#,
                platform: .windows
            ) == [#"C:\Windows\System32"#, #"D:\Tools"#, #"E:\Other"#]
        )
        #expect(
            SystemClipboardCommandRunner.executableSearchDirectories(
                "/usr/bin:/bin:",
                platform: .linux
            ) == ["/usr/bin", "/bin", ""]
        )
        #expect(SystemClipboardCommandRunner.isExplicitExecutablePath(
            #"C:\Windows\System32\clip.exe"#,
            platform: .windows
        ))
        #expect(SystemClipboardCommandRunner.isExplicitExecutablePath(
            #"relative\clip.exe"#,
            platform: .windows
        ))
        #expect(!SystemClipboardCommandRunner.isExplicitExecutablePath(
            "clip.exe",
            platform: .windows
        ))
    }

    @Test("Nonzero native exits and timeout errors never claim clipboard success")
    func failedClipboardCommandsArePropagated() async {
        let failure = WindowsClipboardRecordingRunner(
            outcome: .result(ClipboardCommandResult(status: 9))
        )
        let provider = SystemClipboardProvider(
            platform: .windows,
            environment: ["SystemRoot": #"C:\Windows"#],
            commandRunner: failure
        )
        do {
            try await provider.write(.text("must fail"))
            Issue.record("nonzero Windows clip.exe exit was reported as success")
        } catch ClipboardError.commandFailed(let executable) {
            #expect(executable == #"C:\Windows\System32\clip.exe"#)
        } catch {
            Issue.record("unexpected clipboard failure: \(error)")
        }

        let timeout = WindowsClipboardRecordingRunner(
            outcome: .failure(.timedOut("clip.exe"))
        )
        let timingOut = SystemClipboardProvider(
            platform: .windows,
            environment: ["SystemRoot": #"C:\Windows"#],
            commandRunner: timeout
        )
        do {
            try await timingOut.write(.text("must time out"))
            Issue.record("timed-out Windows clip.exe was reported as success")
        } catch ClipboardError.timedOut(let command) {
            #expect(command == "clip.exe")
        } catch {
            Issue.record("unexpected clipboard timeout: \(error)")
        }
    }

    #if os(Windows)
    @Test("The real trusted clip.exe updates the native Windows clipboard")
    func nativeWindowsClipboardRoundTrip() async throws {
        let environment = ProcessInfo.processInfo.environment
        let executable = try #require(
            SystemClipboardProvider.windowsClipboardExecutable(environment: environment)
        )
        let runner = SystemClipboardCommandRunner(environment: environment, platform: .windows)
        let provider = SystemClipboardProvider(
            platform: .windows,
            environment: environment,
            commandRunner: runner,
            commandTimeout: 5
        )
        let marker = "open-grok-native-clipboard-\(UUID().uuidString)"
        try await provider.write(.text(marker))

        let powershell = URL(fileURLWithPath: executable)
            .deletingLastPathComponent()
            .appendingPathComponent("WindowsPowerShell")
            .appendingPathComponent("v1.0")
            .appendingPathComponent("powershell.exe")
            .path
        let response = try runner.run(
            executable: powershell,
            arguments: [
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "[Console]::Out.Write([string](Get-Clipboard -Raw))",
            ],
            input: nil,
            timeout: 10
        )

        #expect(response.succeeded)
        #expect(String(data: response.standardOutput, encoding: .utf8) == marker)
    }
    #endif
}
