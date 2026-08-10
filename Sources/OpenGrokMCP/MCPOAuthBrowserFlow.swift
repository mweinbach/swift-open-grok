// MCPOAuthBrowserFlow.swift
//
// Port of `xai-grok-mcp/src/oauth.rs` (reference 650c1db7): the interactive
// browser-based OAuth consent flow for MCP servers, with the two dedup layers
// that prevent duplicate consent tabs — an in-process single-flight keyed by
// server name (oauth.rs:56-133) and a cross-process
// `$OPENGROK_HOME/mcp_auth_{safe_name}.lock` flock (oauth.rs:162-276).
//
// The loopback callback listener reuses the socket-serve pattern E6 landed in
// `Sources/OpenGrokAuth/XAIBrowserLogin.swift` (bind/poll/accept loop on a
// blocking thread bridged through a continuation, CRLF-aware request
// parsing). It is a separate implementation because (a) the package graph
// has no OpenGrokMCP → OpenGrokAuth edge and Package.swift is bootstrap-owned,
// and (b) the HTTP contract differs: upstream's MCP callback server routes
// GET **and** POST on `/callback` (oauth.rs:584), forwards the RFC 9207 `iss`
// parameter, serves upstream's own HTML pages, and has no CORS layer.

import Foundation
import OpenGrokConfigTypes
import OpenGrokFileUtils
import OpenGrokHTTP

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Flow errors

/// Flow-level failure whose `description` carries upstream's exact string
/// copy — oauth.rs models the whole flow as `Result<(), String>`.
public struct MCPOAuthFlowError: Error, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Overall budget for one interactive consent flow (oauth.rs:30-37). Without
/// a bound, an abandoned browser tab parks the leader forever — holding both
/// dedup layers, so every other session blocks on the same server's auth.
public let mcpBrowserAuthTimeoutSeconds: TimeInterval = 600

/// Credential-store polling cadence while the browser callback is pending
/// (oauth.rs:27-29, 420-435).
public let mcpCredentialPollIntervalSeconds: TimeInterval = 2

/// How long a follower waits for the cross-process auth lock before giving
/// up on dedup and proceeding with its own flow (oauth.rs:39-45).
let mcpAuthLockWaitSeconds: TimeInterval = mcpBrowserAuthTimeoutSeconds + 60

// MARK: - Callback payload (oauth.rs:496-530)

struct MCPOAuthCallbackPayload: Sendable, Equatable {
    var code: String
    var state: String
    /// RFC 9207 `iss` (optional; required when the AS advertises it).
    var issuer: String?
}

func mcpParseOAuthCallbackParams(
    _ params: [String: String]
) -> Result<MCPOAuthCallbackPayload, MCPOAuthFlowError> {
    if let error = params["error"] {
        let desc = params["error_description"] ?? "Unknown error"
        return .failure(MCPOAuthFlowError("OAuth error: \(error) - \(desc)"))
    }
    guard let code = params["code"], !code.isEmpty else {
        return .failure(MCPOAuthFlowError("Missing authorization code"))
    }
    guard let state = params["state"], !state.isEmpty else {
        return .failure(MCPOAuthFlowError("Missing state parameter"))
    }
    return .success(MCPOAuthCallbackPayload(code: code, state: state, issuer: params["iss"]))
}

/// oauth.rs:488-494.
func mcpHTMLEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

/// The consent-complete page (oauth.rs:555-560), byte-identical.
let mcpCallbackSuccessHTML = """
<!DOCTYPE html><html><head><title>Authorization Complete</title></head>
                    <body style="font-family: sans-serif; text-align: center; padding: 50px;">
                    <h1>Authorization Complete</h1>
                    <p>You can close this window and return to the terminal.</p>
                    <script>window.close();</script></body></html>
"""

/// The consent-failed page (oauth.rs:564-571) with the escaped message.
func mcpCallbackFailureHTML(_ message: String) -> String {
    let msg = mcpHTMLEscape(message)
    return """
    <!DOCTYPE html><html><head><title>Authorization Failed</title></head>
                            <body style="font-family: sans-serif; text-align: center; padding: 50px;">
                            <h1>Authorization Failed</h1>
                            <p>\(msg)</p>
                            <p>You can close this window and return to the terminal.</p>
                            </body></html>
    """
}

// MARK: - Loopback listener

/// Cross-platform `SOCK_STREAM` (Darwin: bare Int32; glibc: enum).
private var mcpSockStreamType: Int32 {
    #if canImport(Darwin)
    return SOCK_STREAM
    #else
    return Int32(SOCK_STREAM.rawValue)
    #endif
}

/// Loopback OAuth callback server for MCP consent redirects.
///
/// Serves an accept loop until a decisive `/callback` (GET or POST, matching
/// upstream's axum route, oauth.rs:584) arrives or the deadline passes.
/// Unknown paths get 404 and do not consume the wait.
final class MCPOAuthLoopbackListener: @unchecked Sendable {
    private var serverFd: Int32 = -1
    let port: UInt16

    /// Bind 127.0.0.1 on `port` (0 = OS-assigned; a BYO `callback_port`
    /// passes the fixed port, oauth.rs:311-316).
    init(port: UInt16) throws {
        guard let bound = Self.bindListener(port: port) else {
            throw MCPOAuthFlowError(
                "Failed to bind loopback port \(port): could not bind 127.0.0.1:\(port)")
        }
        self.serverFd = bound.fd
        self.port = bound.port
    }

    private static func bindListener(port: UInt16) -> (fd: Int32, port: UInt16)? {
        let fd = socket(AF_INET, mcpSockStreamType, 0)
        guard fd >= 0 else { return nil }
        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard res == 0, listen(fd, 4) == 0 else {
            close(fd)
            return nil
        }
        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        // An ephemeral bind whose port cannot be read back would advertise
        // ":0" in the redirect_uri; fail the bind instead.
        guard nameResult == 0 else {
            close(fd)
            return nil
        }
        return (fd, UInt16(bigEndian: boundAddr.sin_port))
    }

    func closeListener() {
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }
    }

    /// Serve until the decisive `/callback` request arrives or the deadline
    /// passes. Blocking-thread + continuation shape; the thread is reclaimed
    /// at the timeout ceiling.
    func awaitCallback(timeoutSeconds: TimeInterval) async throws -> MCPOAuthCallbackPayload {
        let sFd = serverFd
        guard sFd >= 0 else {
            throw MCPOAuthFlowError("Failed to bind loopback port 0: listener is closed")
        }
        let timeout = timeoutSeconds
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try Self.serveUntilCallback(fd: sFd, timeoutSeconds: timeout)
                })
            }
        }
    }

    /// Wait for either the loopback callback or a changed token in the real
    /// credential store. One blocking poll loop owns both signals, so disk
    /// recovery returns immediately instead of leaving a structured child
    /// parked until the callback timeout.
    fileprivate func awaitCallbackOrCredential(
        timeoutSeconds: TimeInterval,
        credentialPollIntervalSeconds: TimeInterval,
        credentialsChanged: @escaping @Sendable () -> Bool
    ) async throws -> MCPOAuthBrowserCompletion {
        let sFd = serverFd
        guard sFd >= 0 else {
            throw MCPOAuthFlowError("Failed to bind loopback port 0: listener is closed")
        }
        let timeout = timeoutSeconds
        let interval = max(0.001, credentialPollIntervalSeconds)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try Self.serveUntilCallbackOrCredential(
                        fd: sFd,
                        timeoutSeconds: timeout,
                        credentialPollIntervalSeconds: interval,
                        credentialsChanged: credentialsChanged
                    )
                })
            }
        }
    }

    private static func serveUntilCallback(
        fd: Int32,
        timeoutSeconds: TimeInterval
    ) throws -> MCPOAuthCallbackPayload {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            let remainingMs = Int32((deadline.timeIntervalSinceNow * 1000).rounded(.down))
            guard remainingMs > 0 else {
                throw MCPOAuthFlowError(
                    "OAuth consent timed out after \(UInt64(timeoutSeconds))s; "
                        + "re-run authentication to try again")
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollRes = poll(&pfd, 1, remainingMs)
            if pollRes == 0 {
                throw MCPOAuthFlowError(
                    "OAuth consent timed out after \(UInt64(timeoutSeconds))s; "
                        + "re-run authentication to try again")
            }
            guard pollRes > 0 else {
                if errno == EINTR { continue }
                throw MCPOAuthFlowError("OAuth callback failed: poll failed: errno \(errno)")
            }

            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &clientLen)
                }
            }
            guard clientFd >= 0 else { continue }
            defer { close(clientFd) }

            var buffer = [UInt8](repeating: 0, count: 8192)
            let bytesRead = recv(clientFd, &buffer, buffer.count - 1, 0)
            guard bytesRead > 0,
                  let request = String(bytes: buffer[..<bytesRead], encoding: .utf8)
            else { continue }

            if let outcome = handle(request: request, clientFd: clientFd) {
                switch outcome {
                case .success(let payload): return payload
                case .failure(let error):
                    throw MCPOAuthFlowError("OAuth callback failed: \(error.message)")
                }
            }
            // Non-callback path answered (404); keep waiting.
        }
    }

    private static func serveUntilCallbackOrCredential(
        fd: Int32,
        timeoutSeconds: TimeInterval,
        credentialPollIntervalSeconds: TimeInterval,
        credentialsChanged: @escaping @Sendable () -> Bool
    ) throws -> MCPOAuthBrowserCompletion {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var nextCredentialPoll = Date().addingTimeInterval(credentialPollIntervalSeconds)
        while true {
            let now = Date()
            guard now < deadline else {
                throw MCPOAuthFlowError(
                    "OAuth consent timed out after \(UInt64(timeoutSeconds))s; "
                        + "re-run authentication to try again")
            }
            if now >= nextCredentialPoll {
                if credentialsChanged() { return .credentialsStored }
                nextCredentialPoll = now.addingTimeInterval(credentialPollIntervalSeconds)
                continue
            }

            let untilDeadline = deadline.timeIntervalSince(now)
            let untilCredentialPoll = nextCredentialPoll.timeIntervalSince(now)
            let waitSeconds = min(untilDeadline, untilCredentialPoll)
            let waitMs = Int32(max(1, (waitSeconds * 1000).rounded(.up)))
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollRes = poll(&pfd, 1, waitMs)
            if pollRes == 0 { continue }
            guard pollRes > 0 else {
                if errno == EINTR { continue }
                throw MCPOAuthFlowError("OAuth callback failed: poll failed: errno \(errno)")
            }

            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &clientLen)
                }
            }
            guard clientFd >= 0 else { continue }
            defer { close(clientFd) }

            var buffer = [UInt8](repeating: 0, count: 8192)
            let bytesRead = recv(clientFd, &buffer, buffer.count - 1, 0)
            guard bytesRead > 0,
                  let request = String(bytes: buffer[..<bytesRead], encoding: .utf8)
            else { continue }

            if let outcome = handle(request: request, clientFd: clientFd) {
                switch outcome {
                case .success(let payload): return .callback(payload)
                case .failure(let error):
                    throw MCPOAuthFlowError("OAuth callback failed: \(error.message)")
                }
            }
        }
    }

    /// `nil` means "answered, not decisive" (unknown path).
    private static func handle(
        request: String,
        clientFd: Int32
    ) -> Result<MCPOAuthCallbackPayload, MCPOAuthFlowError>? {
        // AGENTS.md §2: `\r\n` is ONE Character — split on `isNewline`, never
        // on the "\n" Character.
        let lines = request.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        )
        guard let rawFirst = lines.first else { return nil }
        let parts = String(rawFirst).split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])
        let path = target.split(separator: "?", maxSplits: 1)[0]

        // Upstream routes GET and POST on `/callback` (oauth.rs:584); any
        // other path is axum's 404.
        guard (method == "GET" || method == "POST"), path == "/callback" else {
            respond(clientFd, status: "404 Not Found", body: "")
            return nil
        }

        var params: [String: String] = [:]
        if let components = URLComponents(string: target), let items = components.queryItems {
            for item in items where params[item.name] == nil {
                params[item.name] = item.value ?? ""
            }
        }

        let result = mcpParseOAuthCallbackParams(params)
        // 200 for BOTH arms; only the page differs (oauth.rs:553-580).
        switch result {
        case .success:
            respond(clientFd, status: "200 OK", body: mcpCallbackSuccessHTML)
        case .failure(let error):
            respond(clientFd, status: "200 OK", body: mcpCallbackFailureHTML(error.message))
        }
        return result
    }

    private static func respond(_ clientFd: Int32, status: String, body: String) {
        var response = "HTTP/1.1 \(status)\r\n"
        response += "Content-Type: text/html; charset=utf-8\r\n"
        response += "Content-Length: \(body.utf8.count)\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"
        response += body
        let bytes = Array(response.utf8)
        _ = bytes.withUnsafeBufferPointer { ptr in
            send(clientFd, ptr.baseAddress, ptr.count, 0)
        }
    }
}

// MARK: - Cross-process lock (oauth.rs:162-276)

/// `$OPENGROK_HOME/mcp_auth_{safe}.lock`, with the server name sanitized to
/// alphanumerics plus `-`/`_` (oauth.rs:264-276).
func mcpAuthLockPath(home: URL, serverName: String) -> URL {
    let safe = String(serverName.map { ch in
        (ch.isLetter || ch.isNumber || ch == "-" || ch == "_") ? ch : "_"
    })
    return home.appendingPathComponent("mcp_auth_\(safe).lock")
}

// MARK: - In-process single flight (oauth.rs:56-133)

/// In-process in-flight auth tracker keyed by server name: only one task per
/// server runs the browser flow; followers await the leader's outcome. A
/// forced override evicts the stale leader; the old leader's cleanup is
/// generation-safe and cannot clobber the new entry.
public actor MCPOAuthSingleFlight {
    public static let shared = MCPOAuthSingleFlight()

    private struct Entry {
        var generation: UInt64
        var task: Task<Void, Error>
    }

    private var inFlight: [String: Entry] = [:]
    private var nextGeneration: UInt64 = 0

    public init() {}

    public func run(
        serverName: String,
        force: Bool,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        if let existing = inFlight[serverName] {
            if force {
                inFlight.removeValue(forKey: serverName)
            } else {
                return try await existing.task.value
            }
        }
        nextGeneration += 1
        let generation = nextGeneration
        let task = Task { try await operation() }
        inFlight[serverName] = Entry(generation: generation, task: task)
        defer {
            if inFlight[serverName]?.generation == generation {
                inFlight.removeValue(forKey: serverName)
            }
        }
        try await task.value
    }
}

// MARK: - The interactive flow (oauth.rs:81-160, 284-486)

/// Run the browser-based OAuth flow for one MCP server, persisting the
/// resulting tokens to `$OPENGROK_HOME/mcp_credentials.json`.
///
/// Order of operations mirrors `run_browser_auth_flow`:
///   1. token refresh first — no browser when a refresh succeeds;
///   2. bind the loopback callback port (fixed BYO port or ephemeral);
///   3. BYO client credentials when configured, else dynamic registration;
///   4. authorization URL → browser → callback (bounded wait);
///   5. code exchange (state + RFC 9207 `iss` validated) → persisted tokens.
///
public func mcpRunBrowserAuthFlow(
    serverName: String,
    serverURL: URL,
    home: URL,
    transport: any HTTPTransport,
    byoConfig: McpOAuthConfig?,
    openBrowser: @escaping @Sendable (URL) -> Void,
    timeoutSeconds: TimeInterval = mcpBrowserAuthTimeoutSeconds,
    credentialPollIntervalSeconds: TimeInterval = mcpCredentialPollIntervalSeconds
) async throws {
    let storage = MCPFileCredentialStorage(
        home: home, serverName: serverName, serverURL: serverURL)
    let manager = MCPAuthorizationManager(
        baseURL: serverURL, transport: transport, storage: storage)

    // 1. Refresh first (oauth.rs:290-309) — needs stored credentials and
    //    discovery, both of which initializeFromStore performs.
    if (try? await manager.initializeFromStore()) == true,
       (try? await manager.refreshToken()) != nil {
        return
    }
    if await manager.currentMetadata() == nil {
        let metadata: MCPAuthorizationMetadata
        do {
            metadata = try await manager.discoverMetadata()
        } catch {
            throw MCPOAuthFlowError("OAuth discovery failed: \(error)")
        }
        await manager.setMetadata(metadata)
    }

    // 2. Loopback callback port (oauth.rs:311-321).
    let requestedPort = byoConfig?.callbackPort ?? 0
    let listener = try MCPOAuthLoopbackListener(port: requestedPort)
    defer { listener.closeListener() }
    let redirectURI = "http://127.0.0.1:\(listener.port)/callback"

    // 3. BYO client or DCR (oauth.rs:323-362).
    let byoScopes = byoConfig?.scopes ?? []
    let scopes: [String]
    if let byo = byoConfig, let clientID = byo.clientId {
        scopes = byoScopes
        do {
            try await manager.configureClient(
                clientID: clientID,
                clientSecret: byo.clientSecret,
                redirectURI: redirectURI
            )
        } catch {
            throw MCPOAuthFlowError("Failed to configure BYO client: \(error)")
        }
    } else {
        scopes = byoScopes.isEmpty ? await manager.selectScopes() : byoScopes
        do {
            try await manager.registerClient(
                name: mcpOAuthClientName,
                redirectURI: redirectURI,
                scopes: scopes
            )
        } catch {
            throw MCPOAuthFlowError("Dynamic client registration failed: \(error)")
        }
    }

    let authURL: URL
    do {
        authURL = try await manager.authorizationURL(scopes: scopes)
    } catch {
        throw MCPOAuthFlowError("Failed to get authorization URL: \(error)")
    }

    // Snapshot after DCR/authorization URL generation, before opening the
    // browser. A different non-nil token means another flow completed.
    let tokenBeforeBrowser = (try? storage.load())?.tokenResponse?.accessToken

    // 4. Browser consent. Open failure is non-fatal upstream
    //    (oauth.rs:381-385); the caller has already surfaced the URL.
    openBrowser(authURL)

    // 5. Race the bounded callback wait against the REAL on-disk store
    //    (oauth.rs:387-485). The callback's timeout bounds both arms.
    let completion = try await listener.awaitCallbackOrCredential(
        timeoutSeconds: timeoutSeconds,
        credentialPollIntervalSeconds: credentialPollIntervalSeconds,
        credentialsChanged: {
            guard let tokenNow = (try? storage.load())?.tokenResponse?.accessToken else {
                return false
            }
            return tokenNow != tokenBeforeBrowser
        }
    )

    if case .callback(let callback) = completion {
        do {
            _ = try await manager.exchangeCode(
                code: callback.code,
                state: callback.state,
                issuer: callback.issuer
            )
        } catch {
            throw MCPOAuthFlowError("Token exchange failed: \(error)")
        }
    }
}

private enum MCPOAuthBrowserCompletion: Sendable {
    case callback(MCPOAuthCallbackPayload)
    case credentialsStored
}

/// The dedup wrapper (`authenticate_mcp_server_dedup`, oauth.rs:81-160): the
/// in-process single flight, then the cross-process flock with a post-wait
/// token-changed recheck. `force` (a user-initiated trigger) skips both, so
/// a stale leader cannot block a fresh consent.
public func mcpAuthenticateServer(
    serverName: String,
    serverURL: URL,
    home: URL,
    transport: any HTTPTransport,
    byoConfig: McpOAuthConfig?,
    force: Bool,
    openBrowser: @escaping @Sendable (URL) -> Void,
    timeoutSeconds: TimeInterval = mcpBrowserAuthTimeoutSeconds,
    credentialPollIntervalSeconds: TimeInterval = mcpCredentialPollIntervalSeconds,
    singleFlight: MCPOAuthSingleFlight = .shared
) async throws {
    try await singleFlight.run(serverName: serverName, force: force) {
        if force {
            // Skip the fs lock — the old leader may still hold it and a
            // user-initiated flow must not queue behind a stale tab
            // (oauth.rs:135-143).
            try await mcpRunBrowserAuthFlow(
                serverName: serverName,
                serverURL: serverURL,
                home: home,
                transport: transport,
                byoConfig: byoConfig,
                openBrowser: openBrowser,
                timeoutSeconds: timeoutSeconds,
                credentialPollIntervalSeconds: credentialPollIntervalSeconds
            )
            return
        }

        let storage = MCPFileCredentialStorage(
            home: home, serverName: serverName, serverURL: serverURL)
        let tokenBefore = (try? storage.load())?.tokenResponse?.accessToken

        // Cross-process dedup: wait for the flock, bounded (oauth.rs:204-234).
        let lockPath = mcpAuthLockPath(home: home, serverName: serverName)
        let deadline = Date().addingTimeInterval(mcpAuthLockWaitSeconds)
        var lock: AdvisoryLock?
        while lock == nil, Date() < deadline {
            lock = try? AdvisoryFileLock.tryAcquire(at: lockPath)
            if lock == nil {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { lock?.release() }

        // Re-check the store after the wait: another process may have
        // written a DIFFERENT token while we queued (oauth.rs:236-258).
        // Runs on the timeout path too — an unlocked best-effort read beats
        // a second consent browser.
        if let tokenAfter = (try? storage.load())?.tokenResponse?.accessToken,
           tokenAfter != tokenBefore {
            return
        }

        try await mcpRunBrowserAuthFlow(
            serverName: serverName,
            serverURL: serverURL,
            home: home,
            transport: transport,
            byoConfig: byoConfig,
            openBrowser: openBrowser,
            timeoutSeconds: timeoutSeconds,
            credentialPollIntervalSeconds: credentialPollIntervalSeconds
        )
    }
}
