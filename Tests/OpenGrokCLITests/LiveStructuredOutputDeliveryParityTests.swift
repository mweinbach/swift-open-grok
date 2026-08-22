import Foundation
@testable import OpenGrokCLI
import OpenGrokPagerMinimal
import Testing

@Suite("Validated structured-output terminal delivery parity", .serialized)
struct LiveStructuredOutputDeliveryParityTests {
    private func deliveredLines(
        format: CLIOutputFormat,
        requested: Bool,
        assistantText: String,
        completion: OpenGrokPagerMinimalCompletion
    ) async throws -> [[String: Any]] {
        let captured = CLIStreams.buffered()
        let output = LivePagerOutput(
            streams: captured.streams,
            format: format,
            structuredOutputRequested: requested,
            sessionID: "schema-session",
            model: "schema-model"
        )
        try await output.forward(.output(assistantText))
        try await output.forward(.completed(completion))
        return try captured.out.contents.split(whereSeparator: \.isNewline).map { line in
            try #require(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            )
        }
    }

    private func launch(
        output: String,
        schema: String?
    ) async throws -> [String: Any] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-schema-delivery-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, _ in
                    OpenGrokLiveSamplingResponse(output: output, stopReason: "stop")
                }
            }
        )
        var arguments = [
            "headless",
            "--prompt", "extract the answer",
            "--cwd", workspace.path,
            "--model", "grok-4.5",
        ]
        if let schema {
            arguments.append(contentsOf: ["--json-schema", schema])
        } else {
            arguments.append(contentsOf: ["--output-format", "json"])
        }
        let captured = CLIStreams.buffered()
        let code = await CLIRunner.run(
            arguments,
            environment: [
                "HOME": home.path,
                "OPENGROK_HOME": home.path,
                "XAI_API_KEY": "schema-delivery-private-credential",
            ],
            streams: captured.streams,
            application: OpenGrokApplication.live(
                dependencies: dependencies,
                control: .never
            )
        )
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        return try #require(
            JSONSerialization.jsonObject(with: Data(captured.out.contents.utf8))
                as? [String: Any]
        )
    }

    @Test("JSON completion attaches only the validated shell value under exact camelCase")
    func jsonSuccessUsesValidatedValue() async throws {
        let completion = OpenGrokPagerMinimalCompletion(
            sessionID: "schema-session",
            summary: "stop",
            structuredOutput: Data(#"{"answer":"validated","count":2}"#.utf8)
        )
        let result = try #require(try await deliveredLines(
            format: .json,
            requested: true,
            assistantText: "untrusted assistant text",
            completion: completion
        ).first)
        let structured = try #require(result["structuredOutput"] as? [String: Any])

        #expect(structured["answer"] as? String == "validated")
        #expect(structured["count"] as? Int == 2)
        #expect(result["structuredOutputError"] == nil)
        #expect(result["structured_output"] == nil)
        #expect(result["output"] as? String == "untrusted assistant text")
    }

    @Test("JSON completion stamps null and the validator error without trusting raw JSON")
    func jsonFailureNeverPromotesRawAssistantText() async throws {
        let completion = OpenGrokPagerMinimalCompletion(
            sessionID: "schema-session",
            summary: "stop",
            structuredOutputError: "output does not match the required schema"
        )
        let result = try #require(try await deliveredLines(
            format: .json,
            requested: true,
            assistantText: #"{"answer":"unvalidated"}"#,
            completion: completion
        ).first)

        #expect(result["structuredOutput"] is NSNull)
        #expect(result["structuredOutputError"] as? String
            == "output does not match the required schema")
        #expect(result["output"] as? String == #"{"answer":"unvalidated"}"#)
    }

    @Test("A requested schema with no validated result reports upstream's explicit error")
    func missingValidatedValueDoesNotParseRawAssistantJSON() async throws {
        let result = try #require(try await deliveredLines(
            format: .json,
            requested: true,
            assistantText: #"{"answer":"do-not-trust-raw-text"}"#,
            completion: OpenGrokPagerMinimalCompletion(sessionID: "schema-session")
        ).first)

        #expect(result["structuredOutput"] is NSNull)
        #expect(result["structuredOutputError"] as? String
            == "model did not produce structured output")
    }

    @Test("No schema keeps the preexisting JSON result shape exactly unchanged")
    func noSchemaDoesNotExposeStructuredFields() async throws {
        let completion = OpenGrokPagerMinimalCompletion(
            sessionID: "schema-session",
            summary: "stop",
            structuredOutput: Data(#"{"answer":"must-stay-private"}"#.utf8),
            structuredOutputError: "must stay private"
        )
        let result = try #require(try await deliveredLines(
            format: .json,
            requested: false,
            assistantText: "ordinary answer",
            completion: completion
        ).first)

        #expect(result["structuredOutput"] == nil)
        #expect(result["structuredOutputError"] == nil)
        #expect(result["structured_output"] == nil)
        #expect(result["output"] as? String == "ordinary answer")
    }

    @Test("Generic streaming JSON attaches structured fields only to its terminal frame")
    func streamingJSONUsesCamelCaseTerminalFields() async throws {
        let lines = try await deliveredLines(
            format: .streamingJSON,
            requested: true,
            assistantText: "visible text",
            completion: OpenGrokPagerMinimalCompletion(
                sessionID: "schema-session",
                structuredOutput: Data(#"{"answer":"stream-validated"}"#.utf8)
            )
        )
        let first = try #require(lines.first)
        let last = try #require(lines.last)
        let structured = try #require(last["structuredOutput"] as? [String: Any])

        #expect(first["type"] as? String == "output")
        #expect(first["structuredOutput"] == nil)
        #expect(last["type"] as? String == "completed")
        #expect(structured["answer"] as? String == "stream-validated")
        #expect(last["structured_output"] == nil)
    }

    @Test("Native Messages terminal success uses exact snake_case structured_output")
    func nativeMessagesSuccessUsesSDKDialect() async throws {
        let lines = try await deliveredLines(
            format: .streamingMessagesJSON,
            requested: true,
            assistantText: "native answer",
            completion: OpenGrokPagerMinimalCompletion(
                sessionID: "schema-session",
                summary: "end_turn",
                structuredOutput: Data(#"{"answer":"native-validated"}"#.utf8)
            )
        )
        let result = try #require(lines.last)
        let structured = try #require(result["structured_output"] as? [String: Any])

        #expect(result["type"] as? String == "result")
        #expect(result["subtype"] as? String == "success")
        #expect(result["is_error"] as? Bool == false)
        #expect(structured["answer"] as? String == "native-validated")
        #expect(result["structuredOutput"] == nil)
        #expect(result["structuredOutputError"] == nil)
    }

    @Test("Native Messages validation failure uses the exact SDK error subtype")
    func nativeMessagesFailureUsesStructuredRetrySubtype() async throws {
        let lines = try await deliveredLines(
            format: .streamingMessagesJSON,
            requested: true,
            assistantText: #"{"answer":"unvalidated-native"}"#,
            completion: OpenGrokPagerMinimalCompletion(
                sessionID: "schema-session",
                summary: "end_turn",
                structuredOutputError: "output does not match the required schema"
            )
        )
        let result = try #require(lines.last)

        #expect(result["type"] as? String == "result")
        #expect(result["subtype"] as? String == "error_max_structured_output_retries")
        #expect(result["is_error"] as? Bool == true)
        #expect(result["errors"] as? [String]
            == ["output does not match the required schema"])
        #expect(result["structured_output"] == nil)
        #expect(result["result"] == nil)
    }

    @Test("The actual headless --json-schema launch delivers the validated result object")
    func actualHeadlessLaunchDeliversValidatedOutput() async throws {
        let schema = #"{"type":"object","required":["answer"],"properties":{"answer":{"type":"string"}}}"#
        let result = try await launch(
            output: #"{"answer":"real-live-validation"}"#,
            schema: schema
        )
        let structured = try #require(result["structuredOutput"] as? [String: Any])

        #expect(structured["answer"] as? String == "real-live-validation")
        #expect(result["structuredOutputError"] == nil)
    }

    @Test("The actual headless launch never upgrades schema-invalid raw JSON")
    func actualHeadlessLaunchDeliversValidationFailure() async throws {
        let schema = #"{"type":"object","required":["answer"],"properties":{"answer":{"type":"string"}}}"#
        let result = try await launch(
            output: #"{"wrong":"raw-json-is-not-trusted"}"#,
            schema: schema
        )

        #expect(result["structuredOutput"] is NSNull)
        let error = try #require(result["structuredOutputError"] as? String)
        #expect(error.contains("required schema"))
        #expect(error.contains("answer"))
        #expect(result["output"] as? String == #"{"wrong":"raw-json-is-not-trusted"}"#)
    }

    @Test("A real headless JSON launch without --json-schema emits no schema fields")
    func actualHeadlessLaunchWithoutSchemaKeepsExistingShape() async throws {
        let result = try await launch(
            output: #"{"answer":"ordinary-json-looking-text"}"#,
            schema: nil
        )

        #expect(result["structuredOutput"] == nil)
        #expect(result["structuredOutputError"] == nil)
        #expect(result["structured_output"] == nil)
        #expect(result["output"] as? String == #"{"answer":"ordinary-json-looking-text"}"#)
    }
}
