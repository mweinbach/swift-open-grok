// AcpClient.swift
//
// Port of `xai-grok-test-support/src/acp_client.rs`. Two ACP stdio clients
// for testing grok sessions end-to-end:
//
//   * `GrokStdioClient` — the typed ACP client that drives `open-grok agent
//     stdio` via JSON-RPC over pipes. Handles the full lifecycle: spawn →
//     initialize → authenticate → session → prompt. Auto-approves
//     permissions, captures text chunks.
//   * `RawStdioClient` — raw-wire sibling for bytes the typed client can't
//     produce (escaped-slash methods `"session\/prompt"`, string UUID ids —
//     the Xcode/Foundation shape).
//
// The Rust source uses `agent_client_protocol::ClientSideConnection` for the
// typed client. `OpenGrokACP` is Wave 1; this target cannot depend on it.
// The Swift port implements a minimal JSON-RPC client inline (the ACP
// protocol is newline-delimited JSON-RPC 2.0 over stdio), sufficient for
// the typed lifecycle methods the test harness needs. When `OpenGrokACP`
// lands, the typed path can be replaced without breaking the raw client or
// the spawn plumbing.

import Foundation
import OpenGrokTestUtilities

/// A minimal JSON-RPC 2.0 request envelope.
public struct JsonRpcRequest: Sendable {
    public let jsonrpc: String
    public let id: JsonRpcID
    public let method: String
    public let params: JSONValue

    public init(id: JsonRpcID, method: String, params: JSONValue = .object([])) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }

    /// Encode to a single JSON line (no trailing newline).
    public func encodeLine() throws -> String {
        let pairs: [(String, JSONValue)] = [
            ("jsonrpc", .string(jsonrpc)),
            ("id", id.toJSONValue()),
            ("method", .string(method)),
            ("params", params),
        ]
        return try JSONValue.object(pairs).encodeString()
    }
}

/// A JSON-RPC 2.0 ID (integer, string, or null).
public enum JsonRpcID: Sendable, Equatable {
    case integer(Int64)
    case string(String)
    case null

    public func toJSONValue() -> JSONValue {
        switch self {
        case .integer(let i): return .integer(i)
        case .string(let s): return .string(s)
        case .null: return .null
        }
    }
}

/// A JSON-RPC 2.0 response (result or error).
public struct JsonRpcResponse: Sendable {
    public let id: JsonRpcID
    public let result: JSONValue?
    public let error: JSONValue?

    public init(id: JsonRpcID, result: JSONValue?, error: JSONValue?) {
        self.id = id
        self.result = result
        self.error = error
    }

    /// Parse a JSON line as a response. Returns nil if the line is not a
    /// response (e.g. a notification with no `id`).
    public static func parse(_ line: String) -> JsonRpcResponse? {
        guard let value = try? JSONValue.decode(line) else { return nil }
        // A response has no `method` key (per JSON-RPC 2.0).
        if value["method"].isNull == false { return nil }
        let id: JsonRpcID
        switch value["id"] {
        case .integer(let i): id = .integer(i)
        case .string(let s): id = .string(s)
        default: id = .null
        }
        let result = value["result"].isNull ? nil : value["result"]
        let error = value["error"].isNull ? nil : value["error"]
        return JsonRpcResponse(id: id, result: result, error: error)
    }
}

/// Errors thrown by the ACP clients.
public enum AcpClientError: Error, Equatable, CustomStringConvertible {
    case spawnFailed(program: String, underlying: String)
    case initializeFailed(stderr: String)
    case authenticateFailed(stderr: String)
    case sessionNewFailed(stderr: String)
    case promptFailed(stderr: String)
    case responseTimeout(what: String, skipped: Int, stderrTail: String)
    case ioClosed(what: String, skipped: Int, stderrTail: String)

    public var description: String {
        switch self {
        case let .spawnFailed(program, underlying):
            return "Failed to spawn \(program): \(underlying)"
        case let .initializeFailed(stderr):
            return "initialize failed\nstderr:\n\(stderr)"
        case let .authenticateFailed(stderr):
            return "authenticate failed\nstderr:\n\(stderr)"
        case let .sessionNewFailed(stderr):
            return "session/new failed\nstderr:\n\(stderr)"
        case let .promptFailed(stderr):
            return "prompt failed\nstderr:\n\(stderr)"
        case let .responseTimeout(what, skipped, tail):
            return "\(what): no matching response within timeout (\(skipped) other messages seen)\nstderr:\n\(tail)"
        case let .ioClosed(what, skipped, tail):
            return "\(what): agent closed stdout before responding (\(skipped) other messages seen)\nstderr:\n\(tail)"
        }
    }
}

/// Drives `open-grok agent stdio` via JSON-RPC over pipes. Handles the full
/// lifecycle: spawn → initialize → authenticate → session → prompt.
/// Auto-approves permissions, captures text chunks. Child process is killed
/// on `dispose`.
public final class GrokStdioClient: @unchecked Sendable {
    private let child: PipedChild
    private var nextID: Int64 = 0
    private let idLock = NSLock()
    private let home: HermeticEnv
    private let capture: TextCapture

    /// Spawn `open-grok agent stdio` with the canonical hermetic test env.
    /// `leadingArgs` go before the `agent stdio` subcommand (global flags);
    /// `extraEnv` is applied after the kill-list so a test can still set
    /// e.g. `GROK_DEBUG_LOG=1` explicitly.
    public init(
        server: MockInferenceServer,
        cwd: URL,
        home: HermeticEnv,
        extraEnv: [String: String] = [:],
        leadingArgs: [String] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        self.home = home
        let binary = try TestEnv.grokBinary(environment: environment)
        let process = Process()
        process.executableURL = binary
        process.arguments = leadingArgs + ["agent", "stdio"]
        process.currentDirectoryURL = cwd
        var env = home.environment
        // Hermetic firehose env: clear inherited debug-logging knobs.
        for k in ["GROK_DEBUG_LOG", "GROK_LOG_FILE", "GROK_LOG_SAMPLING", "GROK_HOOKS_LOG"] {
            env.removeValue(forKey: k)
        }
        for (k, v) in extraEnv { env[k] = v }
        // Apply the canonical test env (mock URL, telemetry kill-switches).
        env["GROK_CLI_CHAT_PROXY_BASE_URL"] = server.url
        env["GROK_XAI_API_BASE_URL"] = server.url
        env["XAI_API_KEY"] = "test-key-for-ci"
        process.environment = env
        self.capture = TextCapture()
        self.child = try spawnPipedWithStderrCapture(process)
    }

    deinit {
        child.kill()
    }

    /// The captured text chunks joined into one string.
    public func capturedText() -> String {
        capture.chunks()
    }

    /// The number of session notifications received so far.
    public func notificationCount() -> UInt32 {
        capture.notificationCount()
    }

    /// The captured stderr as a UTF-8 string.
    public func stderr() -> String {
        child.stderrString()
    }

    /// The hermetic home directory (for cache invalidation between phases).
    public var homeURL: URL { home.opengrokHome }

    /// Send a JSON-RPC request and wait for the matching response (matched
    /// by integer id). Notifications (server → client) are skipped; any
    /// agent → client request is refused with a JSON-RPC error so a turn
    /// can never hang on this client.
    public func send(
        method: String,
        params: JSONValue = .object([]),
        timeout: TimeInterval = 20
    ) throws -> JsonRpcResponse {
        idLock.lock()
        let id = nextID
        nextID &+= 1
        idLock.unlock()
        let request = JsonRpcRequest(id: .integer(id), method: method, params: params)
        let line = try request.encodeLine() + "\n"
        guard let stdin = child.stdin else {
            throw AcpClientError.ioClosed(what: method, skipped: 0, stderrTail: Headless.stderrTail(stderr(), maxChars: 1200))
        }
        try stdin.write(contentsOf: Data(line.utf8))
        return try waitForResponse(id: .integer(id), what: method, timeout: timeout)
    }

    /// Wait for the response matching `id`, skipping notifications and
    /// refusing agent → client requests.
    public func waitForResponse(id: JsonRpcID, what: String, timeout: TimeInterval) throws -> JsonRpcResponse {
        guard let stdout = child.takeStdout() else {
            throw AcpClientError.ioClosed(what: what, skipped: 0, stderrTail: Headless.stderrTail(stderr(), maxChars: 1200))
        }
        let deadline = Date().addingTimeInterval(timeout)
        var skipped = 0
        var skippedTail: [String] = []
        // Line-buffered read: read until newline.
        var lineBuffer = Data()
        while Date() < deadline {
            let chunk = stdout.availableData
            if chunk.isEmpty {
                // No data available; sleep briefly and retry.
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }
            lineBuffer.append(chunk)
            // Process complete lines.
            while let nlRange = lineBuffer.range(of: Data([0x0A])) {
                let lineData = lineBuffer.prefix(upTo: nlRange.lowerBound)
                lineBuffer.removeSubrange(lineBuffer.startIndex...nlRange.upperBound.advanced(by: -1))
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                guard let value = try? JSONValue.decode(line) else {
                    skipped &+= 1
                    appendSkippedTail(&skippedTail, line)
                    continue
                }
                let isResponse = value["method"].isNull
                if isResponse {
                    let respID: JsonRpcID
                    switch value["id"] {
                    case .integer(let i): respID = .integer(i)
                    case .string(let s): respID = .string(s)
                    default: respID = .null
                    }
                    if respID == id {
                        // Capture notifications before returning (in case
                        // the response is preceded by an
                        // `session/notification`).
                        capture.recordIfNotification(value)
                        return JsonRpcResponse(id: respID, result: value["result"].isNull ? nil : value["result"], error: value["error"].isNull ? nil : value["error"])
                    }
                } else {
                    // It's a notification or a server → client request.
                    capture.recordIfNotification(value)
                    if value["id"].isNull == false {
                        // Refuse agent → client requests.
                        let refusal = "{\"jsonrpc\":\"2.0\",\"id\":\(try! value["id"].encodeString()),\"error\":{\"code\":-32601,\"message\":\"unsupported by raw test client\"}}\n"
                        try? child.stdin?.write(contentsOf: Data(refusal.utf8))
                    }
                }
                skipped &+= 1
                appendSkippedTail(&skippedTail, line)
            }
        }
        throw AcpClientError.responseTimeout(what: what, skipped: skipped, stderrTail: Headless.stderrTail(stderr(), maxChars: 1200))
    }

    /// Initialize and authenticate (picks the `xai.api_key` auth method).
    public func initialize() throws -> JsonRpcResponse {
        let initParams = JSONValue.object([
            ("protocolVersion", .string("1")),
            ("clientCapabilities", .object([
                ("fs", .object([("readText", .bool(true)), ("writeText", .bool(true))])),
                ("terminal", .bool(false)),
            ])),
            ("meta", .object([
                ("startupHints", .object([
                    ("nonInteractive", .bool(true)),
                    ("skipGitStatus", .bool(true)),
                    ("skipProjectLayout", .bool(true)),
                ])),
                ("clientType", .string("test-client")),
                ("clientVersion", .string("0.0.0-test")),
            ])),
        ])
        let initResp = try send(method: "initialize", params: initParams, timeout: 20)
        if initResp.error != nil {
            throw AcpClientError.initializeFailed(stderr: stderr())
        }
        // Authenticate with the `xai.api_key` method.
        guard let result = initResp.result,
              let authMethods = result["authMethods"].arrayValue else {
            throw AcpClientError.initializeFailed(stderr: stderr())
        }
        let apiKeyMethod = authMethods.first(where: { $0["id"].stringValue == "xai.api_key" }
        ) ?? authMethods.first
        guard let methodID = apiKeyMethod?["id"].stringValue else {
            throw AcpClientError.initializeFailed(stderr: stderr())
        }
        let authParams = JSONValue.object([
            ("authMethodId", .string(methodID)),
            ("meta", .object([("headless", .bool(true))])),
        ])
        let authResp = try send(method: "authenticate", params: authParams, timeout: 20)
        if authResp.error != nil {
            throw AcpClientError.authenticateFailed(stderr: stderr())
        }
        return initResp
    }

    /// Create a new session with `cwd` as the working directory.
    public func createSession(cwd: URL) throws -> JsonRpcResponse {
        let params = JSONValue.object([
            ("cwd", .string(cwd.path)),
            ("mcpServers", .array([])),
        ])
        let resp = try send(method: "session/new", params: params, timeout: 20)
        if resp.error != nil {
            throw AcpClientError.sessionNewFailed(stderr: stderr())
        }
        return resp
    }

    /// Create a new session with a specific model pre-selected. Mirrors
    /// `acp_client::GrokStdioClient::create_session_with_model`.
    public func createSessionWithModel(cwd: URL, modelID: String) throws -> JsonRpcResponse {
        let params = JSONValue.object([
            ("cwd", .string(cwd.path)),
            ("mcpServers", .array([])),
            ("meta", .object([("modelId", .string(modelID))])),
        ])
        let resp = try send(method: "session/new", params: params, timeout: 20)
        if resp.error != nil {
            throw AcpClientError.sessionNewFailed(stderr: stderr())
        }
        return resp
    }

    /// Switch model on an existing session via the typed ACP
    /// `session/set_model`. Mirrors `acp_client::GrokStdioClient::set_model`.
    public func setModel(sessionID: String, modelID: String) throws -> JsonRpcResponse {
        let params = JSONValue.object([
            ("sessionId", .string(sessionID)),
            ("model", .string(modelID)),
        ])
        return try send(method: "session/set_model", params: params, timeout: 20)
    }

    /// Load an existing session by id, replaying history. Mirrors
    /// `acp_client::GrokStdioClient::load_session_with_timeout` (60s timeout
    /// — session/load replays history and is slower under Rosetta on
    /// macos-x86_64 lifecycle CI).
    public func loadSession(sessionID: String, cwd: URL) throws -> JsonRpcResponse {
        let params = JSONValue.object([
            ("sessionId", .string(sessionID)),
            ("cwd", .string(cwd.path)),
            ("mcpServers", .array([])),
        ])
        let resp = try send(method: "session/load", params: params, timeout: 60)
        if resp.error != nil {
            throw AcpClientError.sessionNewFailed(stderr: stderr())
        }
        return resp
    }

    /// Invoke a custom (vendor-extension) method on the agent. Mirrors
    /// `acp_client::GrokStdioClient::ext_method`. The caller owns the
    /// `params` payload — it is sent verbatim as the JSON-RPC `params`.
    public func extMethod(_ method: String, params: JSONValue) throws -> JsonRpcResponse {
        return try send(method: method, params: params, timeout: 20)
    }

    /// Send a prompt to `sessionID` with `text` as the user message.
    public func prompt(sessionID: String, text: String) throws -> JsonRpcResponse {
        let params = JSONValue.object([
            ("sessionId", .string(sessionID)),
            ("prompt", .array([
                .object([("type", .string("text")), ("text", .string(text))]),
            ])),
        ])
        let resp = try send(method: "session/prompt", params: params, timeout: 30)
        if resp.error != nil {
            throw AcpClientError.promptFailed(stderr: stderr())
        }
        return resp
    }
}

/// Drives `open-grok agent stdio` with verbatim newline-delimited JSON-RPC
/// lines. Exists for wire shapes the typed `GrokStdioClient` (integer ids)
/// can never produce — e.g. Xcode's Swift/Foundation `JSONEncoder` output:
/// escaped-slash methods (`"session\/prompt"`) and string UUID request ids.
public final class RawStdioClient: @unchecked Sendable {
    private let child: PipedChild
    private let home: HermeticEnv

    public init(
        server: MockInferenceServer,
        cwd: URL,
        home: HermeticEnv,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        self.home = home
        let binary = try TestEnv.grokBinary(environment: environment)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["agent", "stdio"]
        process.currentDirectoryURL = cwd
        var env = home.environment
        for k in ["GROK_DEBUG_LOG", "GROK_LOG_FILE", "GROK_LOG_SAMPLING", "GROK_HOOKS_LOG"] {
            env.removeValue(forKey: k)
        }
        env["GROK_CLI_CHAT_PROXY_BASE_URL"] = server.url
        env["GROK_XAI_API_BASE_URL"] = server.url
        env["XAI_API_KEY"] = "test-key-for-ci"
        process.environment = env
        self.child = try spawnPipedWithStderrCapture(process)
    }

    deinit { child.kill() }

    /// The captured stderr as a UTF-8 string.
    public func stderr() -> String { child.stderrString() }

    /// Write `line` verbatim followed by `\n`, and flush.
    public func sendLine(_ line: String) throws {
        guard let stdin = child.stdin else { return }
        try stdin.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Read stdout lines until the response to `id` arrives (no `method` key
    /// + exact string-id match) — the match IS the id-echo assertion.
    /// Notifications are skipped; any agent → client request is refused with
    /// a JSON-RPC error. Throws on timeout.
    public func responseForID(id: String, what: String, timeout: TimeInterval) throws -> JSONValue {
        guard let stdout = child.takeStdout() else {
            throw AcpClientError.ioClosed(what: what, skipped: 0, stderrTail: Headless.stderrTail(stderr(), maxChars: 1200))
        }
        let deadline = Date().addingTimeInterval(timeout)
        var skipped = 0
        var skippedTail: [String] = []
        var lineBuffer = Data()
        while Date() < deadline {
            let chunk = stdout.availableData
            if chunk.isEmpty {
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }
            lineBuffer.append(chunk)
            while let nlRange = lineBuffer.range(of: Data([0x0A])) {
                let lineData = lineBuffer.prefix(upTo: nlRange.lowerBound)
                lineBuffer.removeSubrange(lineBuffer.startIndex...nlRange.upperBound.advanced(by: -1))
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                guard let value = try? JSONValue.decode(line) else {
                    skipped &+= 1
                    appendSkippedTail(&skippedTail, line)
                    continue
                }
                let isResponse = value["method"].isNull
                if isResponse && value["id"].stringValue == id {
                    return value
                }
                skipped &+= 1
                appendSkippedTail(&skippedTail, line)
                if !isResponse && value["id"].isNull == false {
                    let refusal = "{\"jsonrpc\":\"2.0\",\"id\":\(try! value["id"].encodeString()),\"error\":{\"code\":-32601,\"message\":\"unsupported by raw test client\"}}\n"
                    try? child.stdin?.write(contentsOf: Data(refusal.utf8))
                }
            }
        }
        throw AcpClientError.responseTimeout(what: what, skipped: skipped, stderrTail: Headless.stderrTail(stderr(), maxChars: 1200))
    }
}

/// Lock-protected text chunk + notification counter, shared between the
/// client and the notification-capture path.
private final class TextCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var chunkStore: [String] = []
    private var notifications: UInt32 = 0

    func chunks() -> String {
        lock.lock(); defer { lock.unlock() }
        return chunkStore.joined()
    }

    func notificationCount() -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        return notifications
    }

    /// If `value` is a `session/notification` with an `AgentMessageChunk`
    /// update carrying text, append the text to the chunk buffer.
    func recordIfNotification(_ value: JSONValue) {
        guard value["method"].stringValue == "session/notification" else { return }
        lock.lock(); defer { lock.unlock() }
        notifications &+= 1
        // The update payload shape varies across ACP versions; capture the
        // text if present in the common locations.
        let update = value["params"]["update"]
        if let text = update["content"]["text"].stringValue {
            if !text.isEmpty { chunkStore.append(text) }
        }
    }
}

/// Record a non-matching line for the timeout diagnostics: bump the count,
/// keep the last 3 lines (truncated).
private func appendSkippedTail(_ tail: inout [String], _ line: String) {
    if tail.count == 3 { tail.removeFirst() }
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = trimmed.count > 200 ? String(trimmed.prefix(200)) : trimmed
    tail.append(prefix)
}
