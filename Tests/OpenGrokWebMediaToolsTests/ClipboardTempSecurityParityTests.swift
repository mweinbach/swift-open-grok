import Foundation
import Testing
@testable import OpenGrokWebMediaTools

private final class ClipboardParityRecordingRunner: ClipboardCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedExecutables: [String] = []
    private let failingExecutables: Set<String>

    init(failingExecutables: Set<String> = []) {
        self.failingExecutables = failingExecutables
    }

    var executables: [String] {
        lock.withLock { recordedExecutables }
    }

    func run(
        executable: String,
        arguments: [String],
        input: Data?,
        timeout: TimeInterval
    ) throws -> ClipboardCommandResult {
        lock.withLock { recordedExecutables.append(executable) }
        return ClipboardCommandResult(status: failingExecutables.contains(executable) ? 1 : 0)
    }
}

@Suite("Clipboard private spool and hybrid Linux parity")
struct ClipboardTempSecurityParityTests {
    @Test("Clipboard temporary directories and files are private from creation")
    func spoolPermissionsArePrivate() throws {
        let directory = try SystemClipboardCommandRunner.makePrivateTemporaryDirectory(
            prefix: "open-grok-clipboard-security-"
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("secret")
        let handle = try SystemClipboardCommandRunner.makePrivateFile(at: file)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data("clipboard credential".utf8))

        #if canImport(Darwin) || os(Linux)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let directoryMode = try #require(directoryAttributes[.posixPermissions] as? NSNumber)
        let fileMode = try #require(fileAttributes[.posixPermissions] as? NSNumber)
        #expect(directoryMode.intValue & 0o777 == 0o700)
        #expect(fileMode.intValue & 0o777 == 0o600)
        #endif
    }

    @Test("Clipboard spool creation rejects pre-existing files and symlink targets")
    func spoolNeverFollowsSymlinksOrClobbersFiles() throws {
        let directory = try SystemClipboardCommandRunner.makePrivateTemporaryDirectory(
            prefix: "open-grok-clipboard-symlink-"
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let protectedFile = directory.appendingPathComponent("protected")
        let protectedContents = Data("must not change".utf8)
        try protectedContents.write(to: protectedFile)
        let symlink = directory.appendingPathComponent("stdin")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: protectedFile)

        #expect(throws: (any Error).self) {
            _ = try SystemClipboardCommandRunner.makePrivateFile(at: symlink)
        }
        #expect(throws: (any Error).self) {
            _ = try SystemClipboardCommandRunner.makePrivateFile(at: protectedFile)
        }
        #expect(try Data(contentsOf: protectedFile) == protectedContents)
    }

    @Test("Default command runner inherits the provider's exact injected environment and platform")
    func defaultRunnerUsesProviderEnvironment() throws {
        let environment = [
            "PATH": "/trusted/clipboard/bin",
            "DISPLAY": ":91",
            "OPENGROK_CLIPBOARD_SENTINEL": "session-specific",
        ]
        let provider = SystemClipboardProvider(platform: .linux, environment: environment)
        let runner = try #require(provider.commandRunner as? SystemClipboardCommandRunner)

        #expect(runner.environment == environment)
        #expect(runner.platform == .linux)
    }

    #if !os(Windows)
    @Test("Large clipboard payloads round-trip through their private unlinked spool")
    func largePayloadRoundTrips() throws {
        let payload = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) })
        let runner = SystemClipboardCommandRunner(environment: ["PATH": "/bin:/usr/bin"])
        let result = try runner.run(
            executable: "/bin/cat",
            arguments: [],
            input: payload,
            timeout: 5
        )

        #expect(result.succeeded)
        #expect(result.standardOutput == payload)
        #expect(result.standardError.isEmpty)
    }
    #endif

    @Test("Hybrid Linux sessions populate both Wayland and one preferred X11 clipboard")
    func hybridDesktopWritesBothSelections() async throws {
        let recorder = ClipboardParityRecordingRunner()
        let provider = SystemClipboardProvider(
            platform: .linux,
            environment: ["WAYLAND_DISPLAY": "wayland-0", "DISPLAY": ":0"],
            commandRunner: recorder
        )

        try await provider.write(.text("both selections"))

        #expect(recorder.executables == ["wl-copy", "xclip"])
    }

    @Test("Hybrid Linux retries xsel when xclip fails without discarding a Wayland success")
    func hybridDesktopFallsBackToXsel() async throws {
        let recorder = ClipboardParityRecordingRunner(failingExecutables: ["xclip"])
        let provider = SystemClipboardProvider(
            platform: .linux,
            environment: ["WAYLAND_DISPLAY": "wayland-0", "DISPLAY": ":0"],
            commandRunner: recorder
        )

        try await provider.write(.text("Wayland and fallback X11"))

        #expect(recorder.executables == ["wl-copy", "xclip", "xsel"])
    }

    @Test("Hybrid Linux image writes populate Wayland and X11")
    func hybridDesktopWritesImagesToBothSelections() async throws {
        let recorder = ClipboardParityRecordingRunner()
        let provider = SystemClipboardProvider(
            platform: .linux,
            environment: ["WAYLAND_DISPLAY": "wayland-0", "DISPLAY": ":0"],
            commandRunner: recorder
        )
        let image = try ClipboardImage(data: Data([0x89, 0x50, 0x4e, 0x47]), mimeType: "image/png")

        try await provider.writeImage(image)

        #expect(recorder.executables == ["wl-copy", "xclip"])
    }
}
