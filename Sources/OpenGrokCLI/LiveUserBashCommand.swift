import Foundation
import OpenGrokPager
import OpenGrokPagerMinimal
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell

enum LiveUserBashCommand {
    static func start(
        command: String,
        sessionID: String,
        workingDirectory: URL,
        toolExecutor: LiveToolExecutor,
        renderer: LiveInteractiveControllerRenderer
    ) async throws {
        let callID = "user-bash-\(UUID().uuidString)"
        let arguments: JSONValue = .object(["command": .string(command)])
        let rawInput = encoded(arguments) ?? command
        let running = OpenGrokPagerToolUpdate(
            callID: callID,
            name: "run_terminal_cmd",
            input: rawInput,
            isBashMode: true,
            state: .running
        )
        try await renderer.render(.session(.tool(running)))

        Task {
            let call = ToolCall(
                id: callID,
                name: "run_terminal_cmd",
                arguments: rawInput
            )
            let result = await toolExecutor.invoke(
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                call: call,
                onOutput: { delta in
                    let update = OpenGrokPagerToolUpdate(
                        callID: callID,
                        name: "run_terminal_cmd",
                        input: rawInput,
                        output: delta.text,
                        isBashMode: true,
                        state: .running,
                        outputOp: delta.op == .replace ? .replace : .append
                    )
                    try? await renderer.render(.session(.tool(update)))
                }
            )
            await finish(
                result,
                callID: callID,
                rawInput: rawInput,
                renderer: renderer
            )
        }
    }

    private static func finish(
        _ result: Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError>,
        callID: String,
        rawInput: String,
        renderer: LiveInteractiveControllerRenderer
    ) async {
        let update: OpenGrokPagerToolUpdate
        switch result {
        case .success(let result):
            update = OpenGrokPagerToolUpdate(
                callID: callID,
                name: "run_terminal_cmd",
                input: rawInput,
                output: result.promptText,
                structuredOutput: LiveToolResultText.structuredOutput(for: result),
                isBashMode: true,
                state: result.displayState == .failed ? .failed : .succeeded
            )
        case .failure(let error):
            update = OpenGrokPagerToolUpdate(
                callID: callID,
                name: "run_terminal_cmd",
                input: rawInput,
                output: error.description,
                isBashMode: true,
                state: error == .cancelled ? .cancelled : .failed
            )
        }
        try? await renderer.render(.session(.tool(update)))
    }

    private static func encoded(_ value: JSONValue) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
