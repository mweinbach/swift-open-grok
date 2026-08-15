import Foundation
import Testing
import OpenGrokShared
import OpenGrokShellBase
@testable import OpenGrokShell

@Test("OpenGrokShellToolCallResult defaults displayState to succeeded")
func toolCallResultDisplayStateDefaultsSucceeded() {
    let result = OpenGrokShellToolCallResult(
        value: .string("ok"),
        promptText: "ok"
    )
    #expect(result.displayState == .succeeded)
    #expect(result.promptText == "ok")
}

@Test("OpenGrokShellToolCallResult accepts failed displayState without dropping promptText")
func toolCallResultFailedDisplayStateKeepsPromptText() {
    let prompt = "stdout line\nExit code: 7"
    let result = OpenGrokShellToolCallResult(
        value: .object([
            "exit_code": .number(.int64(7)),
            "combined_output": .string("stdout line")
        ]),
        promptText: prompt,
        displayState: .failed
    )
    #expect(result.displayState == .failed)
    #expect(result.promptText == prompt)
    #expect(!result.promptText.hasPrefix("Tool failed:"))
}

@Test("OpenGrokShellToolCallResult equatable includes displayState")
func toolCallResultEquatableIncludesDisplayState() {
    let a = OpenGrokShellToolCallResult(
        value: .string("x"),
        promptText: "x",
        displayState: .succeeded
    )
    let b = OpenGrokShellToolCallResult(
        value: .string("x"),
        promptText: "x",
        displayState: .failed
    )
    #expect(a != b)
}

@Test("UTF-8 delta decoder holds incomplete multibyte sequences across chunks")
func utf8DeltaDecoderSplitsMultibyteSafely() {
    // U+00E9 LATIN SMALL LETTER E WITH ACUTE is C3 A9
    var decoder = OpenGrokShellUTF8DeltaDecoder()
    let first = decoder.push(Data([0xC3]))
    #expect(first.isEmpty)
    let second = decoder.push(Data([0xA9]))
    #expect(second == "é")
    #expect(decoder.finish().isEmpty)
}

@Test("UTF-8 delta decoder passes ASCII through immediately")
func utf8DeltaDecoderASCIIPassthrough() {
    var decoder = OpenGrokShellUTF8DeltaDecoder()
    #expect(decoder.push(Data("one\n".utf8)) == "one\n")
    #expect(decoder.push(Data("two".utf8)) == "two")
}

@Test("protocol default run(_:onOutput:) ignores sink and still returns")
func processExecutionDefaultOnOutputIgnored() async throws {
    let process = try OpenGrokShellOwnedProcessExecution(
        sessionID: "session-wave-a",
        workingDirectory: URL(fileURLWithPath: "/tmp"),
        backend: ImmediateZeroExitBackend(output: "hello")
    )
    actor SinkState {
        var count = 0
        func note() { count += 1 }
        func value() -> Int { count }
    }
    let state = SinkState()
    // Non-local backend path cannot stream; sink must not be required.
    let result = try await process.run(
        ShellCommandRequest(
            command: "printf hello",
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            timeout: .seconds(1),
            toolCallID: "call-wave-a",
            ownerSessionID: "session-wave-a"
        ),
        onOutput: { _ in await state.note() }
    )
    #expect(result.exitCode == 0)
    #expect(result.combinedOutput == "hello")
    #expect(await state.value() == 0)
}

/// Backend that is not `LocalShellProcessBackend`, so owned execution takes the
/// non-streaming branch when a sink is supplied.
private actor ImmediateZeroExitBackend: ShellProcessBackend {
    let output: String

    init(output: String) {
        self.output = output
    }

    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        ShellCommandResult(
            combinedOutput: output,
            exitCode: 0,
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2)
        )
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        ShellBackgroundHandle(taskID: "bg-1")
    }

    func getTask(_ taskID: String) async -> ShellTaskSnapshot? { nil }
    func killTask(_ taskID: String) async -> ShellKillOutcome { .notFound }
    func killForegroundCommands() async {}
    func killForegroundCommands(ownerSessionID: String) async {}
    func killAllBackgroundTasks() async {}
    func killAllBackgroundTasks(ownerSessionID: String) async {}
    func warmShell(at cwd: URL) async {}
    func backgroundForegroundCommand(toolCallID: String) async -> Bool { false }
    func waitForCompletion(_ taskID: String, timeout: ShellDuration?) async -> ShellTaskSnapshot? {
        nil
    }
    func listTasks() async -> [ShellTaskSnapshot] { [] }
    func shellCWD() async -> URL? { nil }
}
