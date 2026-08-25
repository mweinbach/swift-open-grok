import Foundation
import OpenGrokSamplingTypes
import OpenGrokShell
import OpenGrokShellBase
import Testing

@testable import OpenGrokCLI

@Suite("File-tool image output reaches the live model")
struct LiveToolImageOutputParityTests {
    @Test("image-only file tools retain image bytes and user-visible output", arguments: [
        "read_file", "view_image",
    ])
    func imageToolsPreserveModelOutput(_ toolName: String) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-image-output-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x42])
        let path = workspace.appendingPathComponent("diagram.png")
        try bytes.write(to: path)
        let environment = [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
            "GROK_SANDBOX": "off",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
        let executor = try await LiveToolExecutor(
            processBackend: LocalShellProcessBackend(inheritedEnvironment: environment),
            sessionID: "image-output-session",
            workingDirectory: workspace,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: environment
        )
        let outcome = await executor.invoke(
            sessionID: "image-output-session",
            workingDirectory: workspace,
            call: ToolCall(
                id: "image-output-call",
                name: toolName,
                arguments: #"{"path":"diagram.png","target_file":"diagram.png"}"#
            )
        )
        guard case .success(let result) = outcome else {
            Issue.record("image tool failed unexpectedly: \(outcome)")
            await executor.shutdown()
            return
        }

        #expect(result.images.count == 1)
        #expect(result.images.first?.mimeType == "image/png")
        #expect(result.images.first?.base64Data == bytes.base64EncodedString())
        #expect(result.images.first?.path == path.path)
        #expect(result.promptText == "Read image file: \(path.path)")
        await executor.shutdown()
    }

    @Test("tool result image payload survives the actual sampling conversation shape")
    func imagePayloadSurvivesConversationEncoding() throws {
        let item = ToolResultItem(
            toolCallId: "inspect-image",
            content: "Read image file: diagram.png",
            images: [.image(url: "data:image/png;base64,aW1hZ2U=")]
        )

        let encoded = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ToolResultItem.self, from: encoded)

        #expect(decoded.images == [.image(url: "data:image/png;base64,aW1hZ2U=")])
        #expect(decoded.content == "Read image file: diagram.png")
    }

    @Test("text-only GLM models never become image-output eligible", arguments: [
        "glm-5", "glm-5.1", "glm-5.2", "zai:glm-5.2",
    ])
    func textOnlyModelsFailClosed(_ model: String) {
        #expect(!LivePromptImageCapability.supports(modelID: model))
    }

    @Test("ordinary tool results remain compatible without image payloads")
    func legacyToolResultRemainsCompatible() {
        let result = OpenGrokShellToolCallResult(
            value: .string("ordinary text"),
            promptText: "ordinary text"
        )

        #expect(result.images.isEmpty)
        #expect(result.promptText == "ordinary text")
    }
}
