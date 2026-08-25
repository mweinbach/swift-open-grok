import Foundation
import OpenGrokTTY
import Testing

@testable import OpenGrokPTY

@Suite("Windows ConPTY launch parity")
struct WindowsPTYParityTests {
    @Test("CreateProcessW command lines preserve whitespace, quotes, and trailing backslashes")
    func windowsArgumentQuoting() {
        #expect(WindowsProcessLaunchSupport.quoteArgument("") == "\"\"")
        #expect(WindowsProcessLaunchSupport.quoteArgument("plain") == "plain")
        #expect(WindowsProcessLaunchSupport.quoteArgument("two words") == "\"two words\"")
        #expect(WindowsProcessLaunchSupport.quoteArgument(#"a\"b"#) == #""a\\\"b""#)
        #expect(WindowsProcessLaunchSupport.quoteArgument(#"path with space\"#) == #""path with space\\""#)
        #expect(WindowsProcessLaunchSupport.commandLine(
            command: #"C:\Program Files\wrap.exe"#,
            arguments: ["hello world", ""]
        ) == #""C:\Program Files\wrap.exe" "hello world" """#)
    }

    @Test("Windows child environments retain system variables and replace names case-insensitively")
    func windowsEnvironmentBlock() throws {
        let block = try WindowsProcessLaunchSupport.environmentBlock(
            inherited: ["SystemRoot": #"C:\Windows"#, "Path": "old"],
            overrides: ["PATH": "new", "GROK_OSC52_SINK": "1", "LC_GROK_OSC52_SINK": "1"]
        )
        #expect(block.suffix(2).elementsEqual([0, 0]))
        let entries = String(decoding: block, as: UTF16.self).split(separator: "\0")
        #expect(entries.contains(#"SystemRoot=C:\Windows"#))
        #expect(entries.contains("PATH=new"))
        #expect(!entries.contains("Path=old"))
        #expect(entries.contains("GROK_OSC52_SINK=1"))
        #expect(entries.contains("LC_GROK_OSC52_SINK=1"))

        #expect(throws: PTYError.self) {
            try WindowsProcessLaunchSupport.environmentBlock(
                inherited: [:],
                overrides: ["INVALID=NAME": "value"]
            )
        }
    }

    #if os(Windows)
    @Test("ConPTY children receive explicit clipboard sink environment overrides")
    func realWindowsChildReceivesEnvironment() async throws {
        let command = ProcessInfo.processInfo.environment["ComSpec"] ?? #"C:\Windows\System32\cmd.exe"#
        let process = try await PlatformPTYAdapter().spawn(ProcessSpec(
            command: command,
            arguments: ["/d", "/c", "echo %GROK_OSC52_SINK%-%LC_GROK_OSC52_SINK%"],
            environment: ["GROK_OSC52_SINK": "1", "LC_GROK_OSC52_SINK": "1"],
            usePTY: true,
            initialSize: TerminalSize(width: 80, height: 24)
        ))
        let output = Task {
            var bytes = Data()
            for try await chunk in process.output() {
                bytes.append(chunk)
            }
            return bytes
        }
        let exit = try await process.waitForExit()
        let text = try await String(decoding: output.value, as: UTF8.self)
        #expect(exit == .code(0), "ConPTY child exited with \(exit): \(text.debugDescription)")
        #expect(text.contains("1-1"), "ConPTY child output: \(text.debugDescription)")
    }
    #endif
}
