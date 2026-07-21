// Leader.swift
//
// Port of `xai-grok-test-support/src/leader.rs`. Leader-mode
// (`open-grok agent --leader stdio`) test harness, Unix-only (the leader
// transport is a unix socket). Spawns the real binary as a stdio client
// whose bridge elects a leader subprocess hosting the actual sessions,
// speaks ACP over pipes, and exposes lock-file helpers for leader-lifecycle
// assertions.
//
// The Rust source uses `agent_client_protocol::ClientSideConnection` for the
// ACP plumbing. The Swift port reuses the minimal JSON-RPC client from
// `AcpClient.swift` (since `OpenGrokACP` is Wave 1), and provides the
// lock-file helpers (`leaderLockPath`, `readLeaderPID`, `pidAlive`,
// `waitForLiveLeader`, `waitForNewLeader`, `leaderLog`).

import Foundation
import OpenGrokTestUtilities

#if os(macOS) || os(Linux)

/// Env var naming the binary that elects/hosts the leader in a two-binary
/// (version-skew) test. Falls back to `grokBinary()`'s resolution.
public let leaderBinaryEnv = "GROK_BINARY_LEADER"

/// Env var naming the binary for the second (usually newer) client in a
/// two-binary test. Falls back to `grokBinary()`'s resolution.
public let clientBinaryEnv = "GROK_BINARY_CLIENT"

/// Leader-mode helpers.
public enum Leader {
    /// Binary for the leader-electing side of a version-skew test
    /// (`GROK_BINARY_LEADER`, else the shared `grokBinary()` resolution).
    public static func leaderBinary(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        try TestEnv.roleBinary(role: "leader", envVar: leaderBinaryEnv, environment: environment)
    }

    /// Binary for the client side of a version-skew test
    /// (`GROK_BINARY_CLIENT`, else the shared `grokBinary()` resolution).
    public static func clientBinary(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        try TestEnv.roleBinary(role: "client", envVar: clientBinaryEnv, environment: environment)
    }

    /// The leader lock file path under `home`.
    public static func leaderLockPath(home: URL) -> URL {
        home.appendingPathComponent(".opengrok").appendingPathComponent("leader.lock")
    }

    /// Read the leader PID from the lock file at `home/.opengrok/leader.lock`.
    public static func readLeaderPID(home: URL) -> Int32? {
        let path = leaderLockPath(home: home)
        guard let content = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        return Int32(content.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Returns `true` if `pid` is alive (sends signal 0 via `kill(2)`).
    public static func pidAlive(_ pid: Int32) -> Bool {
        return kill(pid, 0) == 0
    }

    /// Wait until the leader lock file contains a live PID, return it.
    /// Returns `nil` on timeout.
    public static func waitForLiveLeader(home: URL, timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = readLeaderPID(home: home), pidAlive(pid) {
                return pid
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    /// Wait until the leader lock file contains a live PID different from
    /// `oldPID`. Returns `nil` on timeout.
    public static func waitForNewLeader(home: URL, oldPID: Int32, timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = readLeaderPID(home: home), pid != oldPID, pidAlive(pid) {
                return pid
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    /// Read the leader log at `home/.opengrok/leader.log`, returning "" if
    /// missing.
    public static func leaderLog(home: URL) -> String {
        let url = home.appendingPathComponent(".opengrok").appendingPathComponent("leader.log")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

/// A `open-grok agent --leader stdio` client subprocess speaking ACP over
/// pipes. The leader subprocess it elects hosts the actual sessions.
///
/// The Rust source uses `env_clear` + an explicit allowlist to guarantee the
/// test can never touch a leader outside its sandbox home. The Swift port
/// does the same: the environment is built from scratch (only `PATH`,
/// `HOME`, `OPENGROK_HOME`, `GROK_LEADER_SOCKET`, mock URLs, API key, and
/// telemetry kill-switches are passed).
public final class LeaderStdioClient: @unchecked Sendable {
    private let child: PipedChild
    private let home: HermeticEnv
    private var nextID: Int64 = 0
    private let idLock = NSLock()
    /// Capture for `session/notification` chunks + `x.ai/leader_reconnected`
    /// ext notifications + the notification count (mirrors Rust `Capture`).
    private let capture: LeaderCapture

    public init(
        server: MockInferenceServer,
        cwd: URL,
        home: HermeticEnv,
        binary: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        self.home = home
        self.capture = LeaderCapture()
        let resolvedBinary = try binary ?? TestEnv.grokBinary(environment: environment)
        let process = Process()
        process.executableURL = resolvedBinary
        process.arguments = ["agent", "--leader", "stdio"]
        process.currentDirectoryURL = cwd
        // env_clear equivalent: build from scratch.
        var env: [String: String] = [
            "PATH": environment["PATH"] ?? "",
            "HOME": home.root.path,
            "OPENGROK_HOME": home.opengrokHome.path,
            // Pin the socket inside the sandbox.
            "GROK_LEADER_SOCKET": home.opengrokHome.appendingPathComponent("leader.sock").path,
            "GROK_CLI_CHAT_PROXY_BASE_URL": server.url,
            "GROK_XAI_API_BASE_URL": server.url,
            "XAI_API_KEY": "test-key-for-ci",
            "GROK_TELEMETRY_ENABLED": "false",
            "GROK_FEEDBACK_ENABLED": "false",
            "GROK_TRACE_UPLOAD": "false",
            "GROK_INSTRUMENTATION": "disabled",
            "RUST_LOG": "xai_grok_shell=debug",
        ]
        // Windows resolves `~` via USERPROFILE; mirror the hermeticity guard.
        #if os(Windows)
        env["USERPROFILE"] = home.root.path
        #endif
        _ = env // silence unused
        process.environment = env
        self.child = try spawnPipedWithStderrCapture(process)
    }

    deinit { child.kill() }

    public func stderrText() -> String { child.stderrString() }

    /// Send a JSON-RPC request and wait for the matching response.
    public func send(
        method: String,
        params: JSONValue = .object([]),
        timeout: TimeInterval = 30
    ) throws -> JsonRpcResponse {
        idLock.lock()
        let id = nextID
        nextID &+= 1
        idLock.unlock()
        let request = JsonRpcRequest(id: .integer(id), method: method, params: params)
        let line = try request.encodeLine() + "\n"
        guard let stdin = child.stdin else {
            throw AcpClientError.ioClosed(what: method, skipped: 0, stderrTail: Headless.stderrTail(stderrText(), maxChars: 1200))
        }
        try stdin.write(contentsOf: Data(line.utf8))
        return try waitForResponse(id: .integer(id), what: method, timeout: timeout)
    }

    public func waitForResponse(id: JsonRpcID, what: String, timeout: TimeInterval) throws -> JsonRpcResponse {
        guard let stdout = child.takeStdout() else {
            throw AcpClientError.ioClosed(what: what, skipped: 0, stderrTail: Headless.stderrTail(stderrText(), maxChars: 1200))
        }
        let deadline = Date().addingTimeInterval(timeout)
        var skipped = 0
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
                    continue
                }
                // Capture notifications and ext notifications before any
                // response-match check (so a notification preceding the
                // response is still counted). Mirrors `LeaderAcpClient`.
                capture.recordIfNotification(value)
                capture.recordIfReconnect(value)
                if value["method"].isNull {
                    let respID: JsonRpcID
                    switch value["id"] {
                    case .integer(let i): respID = .integer(i)
                    case .string(let s): respID = .string(s)
                    default: respID = .null
                    }
                    if respID == id {
                        return JsonRpcResponse(id: respID, result: value["result"].isNull ? nil : value["result"], error: value["error"].isNull ? nil : value["error"])
                    }
                }
                skipped &+= 1
            }
        }
        throw AcpClientError.responseTimeout(what: what, skipped: skipped, stderrTail: Headless.stderrTail(stderrText(), maxChars: 1200))
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
        let initResp = try send(method: "initialize", params: initParams, timeout: 60)
        if initResp.error != nil {
            throw AcpClientError.initializeFailed(stderr: stderrText())
        }
        guard let result = initResp.result,
              let authMethods = result["authMethods"].arrayValue else {
            throw AcpClientError.initializeFailed(stderr: stderrText())
        }
        let apiKeyMethod = authMethods.first(where: { $0["id"].stringValue == "xai.api_key" }) ?? authMethods.first
        guard let methodID = apiKeyMethod?["id"].stringValue else {
            throw AcpClientError.initializeFailed(stderr: stderrText())
        }
        let authParams = JSONValue.object([
            ("authMethodId", .string(methodID)),
            ("meta", .object([("headless", .bool(true))])),
        ])
        let authResp = try send(method: "authenticate", params: authParams, timeout: 30)
        if authResp.error != nil {
            throw AcpClientError.authenticateFailed(stderr: stderrText())
        }
        return initResp
    }

    /// Create a new session with `cwd` as the working directory.
    public func createSession(cwd: URL, modelID: String? = nil) throws -> JsonRpcResponse {
        var meta: [(String, JSONValue)] = []
        if let modelID {
            meta.append(("modelId", .string(modelID)))
        }
        let params = JSONValue.object([
            ("cwd", .string(cwd.path)),
            ("mcpServers", .array([])),
            ("meta", .object(meta)),
        ])
        let resp = try send(method: "session/new", params: params, timeout: 30)
        if resp.error != nil {
            throw AcpClientError.sessionNewFailed(stderr: stderrText())
        }
        return resp
    }

    /// Send a prompt to `sessionID`.
    public func prompt(sessionID: String, text: String) throws -> JsonRpcResponse {
        let params = JSONValue.object([
            ("sessionId", .string(sessionID)),
            ("prompt", .array([
                .object([("type", .string("text")), ("text", .string(text))]),
            ])),
        ])
        let resp = try send(method: "session/prompt", params: params, timeout: 30)
        if resp.error != nil {
            throw AcpClientError.promptFailed(stderr: stderrText())
        }
        return resp
    }

    /// Load an existing session by id, replaying history. Mirrors the typed
    /// ACP `session/load` (the leader subprocess replays via the leader
    /// transport; the 60s timeout matches the Rust lifecycle CI budget).
    public func loadSession(sessionID: String, cwd: URL) throws -> JsonRpcResponse {
        let params = JSONValue.object([
            ("sessionId", .string(sessionID)),
            ("cwd", .string(cwd.path)),
            ("mcpServers", .array([])),
        ])
        let resp = try send(method: "session/load", params: params, timeout: 60)
        if resp.error != nil {
            throw AcpClientError.sessionNewFailed(stderr: stderrText())
        }
        return resp
    }

    /// The captured text chunks joined into one string. Mirrors
    /// `leader::LeaderStdioClient::captured_text`.
    public func capturedText() -> String {
        capture.chunks()
    }

    /// The number of `session/notification` messages received so far.
    public func notificationCount() -> UInt32 {
        capture.notificationCount()
    }

    /// The number of `x.ai/leader_reconnected` ext notifications observed.
    /// Mirrors `leader::LeaderStdioClient::reconnected_count`. The typed ACP
    /// `ClientSideConnection` drops bare `x.ai/*` methods (the Rust source
    /// documents this), so the count is driven by the raw line scan in
    /// `waitForResponse` instead.
    public func reconnectedCount() -> UInt32 {
        capture.reconnectedCount()
    }
}

/// Lock-protected capture for the leader client: text chunks, notification
/// count, reconnect count. Mirrors `leader::Capture`. `@unchecked Sendable`
/// via internal `NSLock`.
private final class LeaderCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var chunkStore: [String] = []
    private var notifications: UInt32 = 0
    private var reconnected: UInt32 = 0

    func chunks() -> String {
        lock.lock(); defer { lock.unlock() }
        return chunkStore.joined()
    }

    func notificationCount() -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        return notifications
    }

    func reconnectedCount() -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        return reconnected
    }

    /// If `value` is a `session/notification` with an `AgentMessageChunk`
    /// update carrying text, append the text to the chunk buffer and bump
    /// the notification count.
    func recordIfNotification(_ value: JSONValue) {
        guard value["method"].stringValue == "session/notification" else { return }
        lock.lock(); defer { lock.unlock() }
        notifications &+= 1
        let update = value["params"]["update"]
        if let text = update["content"]["text"].stringValue, !text.isEmpty {
            chunkStore.append(text)
        }
    }

    /// If `value` is an `ext/notification` with method
    /// `x.ai/leader_reconnected`, bump the reconnect counter. Mirrors
    /// `leader::LeaderAcpClient::ext_notification`.
    func recordIfReconnect(_ value: JSONValue) {
        guard value["method"].stringValue == "ext/notification" else { return }
        if value["params"]["method"].stringValue == "x.ai/leader_reconnected" {
            lock.lock(); defer { lock.unlock() }
            reconnected &+= 1
        }
    }
}

/// Wait for evidence that the bridge finished its reconnect replay. Mirrors
/// `leader::wait_for_replay_notifications`. The `x.ai/leader_reconnected` ext
/// notification is dropped by the typed `ClientSideConnection` (bare `x.ai/*`
/// methods are rejected by the ACP decoder), so this waits for the replayed
/// `session/load` to emit session notifications instead: the notification
/// count rises above `baseline`, or the reconnect counter is non-zero.
public func waitForReplayNotifications(
    client: LeaderStdioClient,
    baseline: UInt32,
    timeout: TimeInterval
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if client.reconnectedCount() > 0 || client.notificationCount() > baseline {
            return true
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return false
}

#endif // os(macOS) || os(Linux)
