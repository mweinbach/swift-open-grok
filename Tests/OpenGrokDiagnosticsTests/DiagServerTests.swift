import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenGrokDiagnostics

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if !os(Windows)
private var diagnosticSocketStreamType: Int32 {
    #if canImport(Darwin)
    SOCK_STREAM
    #else
    Int32(SOCK_STREAM.rawValue)
    #endif
}
#endif

struct DiagServerTests {

    private func getJSON(port: UInt16, path: String) async throws -> (Int, [String: Any]) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            fatalError("invalid url")
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            fatalError("not http response")
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (httpResponse.statusCode, json)
    }

    private func getText(port: UInt16, path: String) async throws -> (Int, String?, String) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            fatalError("invalid url")
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            fatalError("not http response")
        }
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")
        let text = String(decoding: data, as: UTF8.self)
        return (httpResponse.statusCode, contentType, text)
    }

    private func serveWithLog(logFile: String?) async throws -> (BoundDiag, UInt16) {
        let handle = DiagHandle()
        let bound = try await serve(listener: .tcp(0), handle: handle, logFile: logFile)
        guard let port = bound.port else {
            fatalError("missing tcp port")
        }
        return (bound, port)
    }

    @Test
    func readyResponseContractIsFrozen() async throws {
        let handle = DiagHandle(launchId: "nonce-1")
        let bound = try await serve(listener: .tcp(0), handle: handle, logFile: nil)
        defer { bound.stop() }
        let port = try #require(bound.port)

        let (status, body) = try await getJSON(port: port, path: "/ready")
        #expect(status == 503, "not yet connected must not probe as ready")

        let frozenKeys = [
            "launch_id",
            "state",
            "pid",
            "connected_at",
            "state_changed_at",
            "version"
        ]
        for key in frozenKeys {
            #expect(body.keys.contains(key), "missing frozen key \(key)")
        }
        #expect(body["launch_id"] as? String == "nonce-1")
        #expect(body["state"] as? String == "starting")
        #expect(body["connected_at"] is NSNull)
        #expect(body["last_close_code"] == nil, "last_close_code must be omitted unless a terminal close was recorded")
    }

    @Test
    func statuszCarriesImageCapabilitiesPublishedByTheOwner() async throws {
        let handle = DiagHandle()
        let bound = try await serve(listener: .tcp(0), handle: handle, logFile: nil)
        defer { bound.stop() }
        let port = try #require(bound.port)

        let (status1, body1) = try await getJSON(port: port, path: "/statusz")
        #expect(status1 == 200)
        #expect(body1["state"] as? String == "starting", "/ready fields stay flattened in")
        #expect((body1["image_capabilities"] as? [String]) == [], "an unpublished snapshot is empty, not absent")
        #expect(body1["image_capabilities_declared"] as? Bool == false)

        handle.setImageCapabilities(["capabilities.v1", "playwright.v1"], declared: true)
        let (status2, body2) = try await getJSON(port: port, path: "/statusz")
        #expect(status2 == 200)
        #expect((body2["image_capabilities"] as? [String]) == ["capabilities.v1", "playwright.v1"])
        #expect(body2["image_capabilities_declared"] as? Bool == true)
    }

    @Test
    func stateFollowsHubLifecycleAndFreezesConnectedAt() async throws {
        let handle = DiagHandle()
        let bound = try await serve(listener: .tcp(0), handle: handle, logFile: nil)
        defer { bound.stop() }
        let port = try #require(bound.port)

        handle.setConnected()
        let (statusConnected, connected) = try await getJSON(port: port, path: "/ready")
        #expect(statusConnected == 200)
        #expect(connected["state"] as? String == "connected")
        let connectedAt = try #require(connected["connected_at"] as? UInt64 ?? (connected["connected_at"] as? NSNumber)?.uint64Value)
        #expect(connected["launch_id"] is NSNull)

        handle.setDisconnected()
        let (statusDisconnected, disconnected) = try await getJSON(port: port, path: "/ready")
        #expect(statusDisconnected == 503)
        #expect(disconnected["state"] as? String == "disconnected")
        #expect(disconnected["last_close_code"] == nil, "plain disconnect must omit last_close_code")
        let disconnectedConnectedAt = disconnected["connected_at"] as? UInt64 ?? (disconnected["connected_at"] as? NSNumber)?.uint64Value
        #expect(disconnectedConnectedAt == connectedAt, "connected_at is frozen at first connect and echoed on disconnect")

        handle.setConnected()
        let (statusReconnected, reconnected) = try await getJSON(port: port, path: "/ready")
        #expect(statusReconnected == 200)
        #expect(reconnected["state"] as? String == "connected")
        let reconnectedConnectedAt = reconnected["connected_at"] as? UInt64 ?? (reconnected["connected_at"] as? NSNumber)?.uint64Value
        #expect(reconnectedConnectedAt == connectedAt, "reconnect must not re-mint connected_at")
    }

    @Test
    func shuttingDownLatchesDisconnectedAcrossReconnects() async throws {
        let handle = DiagHandle()
        let bound = try await serve(listener: .tcp(0), handle: handle, logFile: nil)
        defer { bound.stop() }
        let port = try #require(bound.port)

        handle.setConnected()
        handle.setShuttingDown()
        handle.setConnected()

        let (status, body) = try await getJSON(port: port, path: "/ready")
        #expect(status == 503)
        #expect(body["state"] as? String == "disconnected")
    }

    @Test
    func readyReportsLastCloseCodeOnlyWhenSet() async throws {
        let handle = DiagHandle()
        let bound = try await serve(listener: .tcp(0), handle: handle, logFile: nil)
        defer { bound.stop() }
        let port = try #require(bound.port)

        handle.setConnected()
        handle.setTerminalClose(4103)
        handle.setDisconnected()

        let (status, body) = try await getJSON(port: port, path: "/ready")
        #expect(status == 503)
        #expect(body["state"] as? String == "disconnected")
        let closeCode = body["last_close_code"] as? UInt16 ?? (body["last_close_code"] as? NSNumber)?.uint16Value
        #expect(closeCode == 4103)
    }

    @Test
    func staleSettleAfterTerminalCloseKeepsReadyDisconnectedWith4103() async throws {
        let handle = DiagHandle()
        let bound = try await serve(listener: .tcp(0), handle: handle, logFile: nil)
        defer { bound.stop() }
        let port = try #require(bound.port)

        handle.setConnected()
        handle.setTerminalClose(4103)
        handle.setConnected()
        handle.setDisconnected()

        let (status, body) = try await getJSON(port: port, path: "/ready")
        #expect(status == 503)
        #expect(body["state"] as? String == "disconnected")
        let closeCode = body["last_close_code"] as? UInt16 ?? (body["last_close_code"] as? NSNumber)?.uint16Value
        #expect(closeCode == 4103)
    }

    @Test
    func readyBodyOmitsLastCloseCodeUntilTerminalClose() {
        let handle = DiagHandle()
        #expect(handle.readyBody().lastCloseCode == nil)
        handle.setDisconnected()
        #expect(handle.readyBody().lastCloseCode == nil)
        handle.setTerminalClose(4103)
        #expect(handle.readyBody().lastCloseCode == 4103)
        handle.setDisconnected()
        #expect(handle.readyBody().lastCloseCode == 4103, "set_disconnected must not wipe a recorded terminal close")
        handle.setConnected()
        #expect(handle.readyBody().lastCloseCode == 4103, "stale set_connected must not clear a latched terminal close")
        #expect(handle.readyBody().state == .disconnected)

        handle.setTerminalClose(4103)
        handle.setShuttingDown()
        #expect(handle.readyBody().lastCloseCode == 4103, "shutdown drain after CLEANUP still reports the close code")

        handle.setFailed(errorClass: .unknown, errorDetail: "late fail")
        #expect(handle.readyBody().state == .failed)
        #expect(handle.readyBody().lastCloseCode == nil, "failed must not advertise last_close_code")
    }

    @Test
    func readyReportsFailedWithErrorFields() async throws {
        let handle = DiagHandle(launchId: "nonce-fail")
        let bound = try await serve(listener: .tcp(0), handle: handle, logFile: nil)
        defer { bound.stop() }
        let port = try #require(bound.port)

        handle.setFailed(errorClass: .hubAuth, errorDetail: "handshake auth failed: HTTP 401")
        let (status, body) = try await getJSON(port: port, path: "/ready")

        #expect(status == 503, "failed is not ready")
        #expect(body["launch_id"] as? String == "nonce-fail")
        #expect(body["state"] as? String == "failed")
        #expect(body["error_class"] as? String == "hub_auth")
        #expect(body["error_detail"] as? String == "handshake auth failed: HTTP 401")
        #expect(body["state_changed_at"] != nil)
        #expect(body["pid"] != nil)
        #expect(body["version"] != nil)

        let starting = DiagHandle()
        let bound2 = try await serve(listener: .tcp(0), handle: starting, logFile: nil)
        defer { bound2.stop() }
        let port2 = try #require(bound2.port)
        let (_, startBody) = try await getJSON(port: port2, path: "/ready")
        #expect(startBody["state"] as? String == "starting")
        #expect(startBody["error_class"] == nil, "error_class must be omitted unless failed")
        #expect(startBody["error_detail"] == nil, "error_detail must be omitted unless failed")
    }

    @Test
    func readyFailedHubConnectAndUnknownClasses() async throws {
        let handle = DiagHandle()
        let bound = try await serve(listener: .tcp(0), handle: handle, logFile: nil)
        defer { bound.stop() }
        let port = try #require(bound.port)

        handle.setFailed(errorClass: .hubConnect, errorDetail: "network error: connection refused")
        let (status1, body1) = try await getJSON(port: port, path: "/ready")
        #expect(status1 == 503)
        #expect(body1["state"] as? String == "failed")
        #expect(body1["error_class"] as? String == "hub_connect")
        #expect(body1["error_detail"] as? String == "network error: connection refused")

        handle.setFailed(errorClass: .unknown, errorDetail: "something else")
        let (status2, body2) = try await getJSON(port: port, path: "/ready")
        #expect(status2 == 503)
        #expect(body2["state"] as? String == "failed")
        #expect(body2["error_class"] as? String == "unknown")
        #expect(body2["error_detail"] as? String == "something else")
    }

    @Test
    func failedIsStickyAgainstLaterLifecycleTransitions() async throws {
        let handle = DiagHandle()
        let bound = try await serve(listener: .tcp(0), handle: handle, logFile: nil)
        defer { bound.stop() }
        let port = try #require(bound.port)

        handle.setFailed(errorClass: .hubAuth, errorDetail: "handshake auth failed: HTTP 401")
        handle.setConnected()
        handle.setDisconnected()
        handle.setShuttingDown()
        handle.setTerminalClose(4103)

        let (status, body) = try await getJSON(port: port, path: "/ready")
        #expect(status == 503)
        #expect(body["state"] as? String == "failed")
        #expect(body["error_class"] as? String == "hub_auth")
        #expect(body["error_detail"] as? String == "handshake auth failed: HTTP 401")
        #expect(body["last_close_code"] == nil, "failed must not advertise last_close_code after set_terminal_close")
    }

    @Test
    func errorDetailIsTruncatedToCap() {
        let handle = DiagHandle()
        let long = String(repeating: "x", count: MAX_ERROR_DETAIL_BYTES + 64)
        handle.setFailed(errorClass: .unknown, errorDetail: long)
        let body = handle.readyBody()
        let detail = body.errorDetail
        #expect(detail?.utf8.count == MAX_ERROR_DETAIL_BYTES)
    }

    @Test
    func errorDetailTruncationRespectsUtf8CharBoundary() {
        var long = String(repeating: "a", count: MAX_ERROR_DETAIL_BYTES - 1)
        long.append("é")
        #expect(long.utf8.count == MAX_ERROR_DETAIL_BYTES + 1)

        let handle = DiagHandle()
        handle.setFailed(errorClass: .unknown, errorDetail: long)
        let detail = handle.readyBody().errorDetail ?? ""
        #expect(detail.utf8.count <= MAX_ERROR_DETAIL_BYTES)
        #expect(detail.hasSuffix("a") || detail.hasSuffix("é"))
    }

    #if !os(Windows)
    @Test
    func unixSocketServesReadyAndRebindsOverStaleSocket() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sockPath = tempDir.appendingPathComponent("ws.sock").path

        // Create stale socket file
        let staleFd = socket(AF_UNIX, diagnosticSocketStreamType, 0)
        #expect(staleFd >= 0)
        var staleAddr = sockaddr_un()
        staleAddr.sun_family = sa_family_t(AF_UNIX)
        _ = sockPath.withCString {
            strncpy(&staleAddr.sun_path.0, $0, MemoryLayout.size(ofValue: staleAddr.sun_path))
        }
        let staleBindRes = withUnsafePointer(to: &staleAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(staleFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(staleBindRes == 0)
        close(staleFd)

        let handle = DiagHandle(launchId: "nonce-uds")
        let bound = try await serve(listener: .unix(sockPath), handle: handle, logFile: nil)
        defer { bound.stop() }
        handle.setConnected()

        // Verify file permissions are 0600
        let attrs = try FileManager.default.attributesOfItem(atPath: sockPath)
        let posixPerms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect((posixPerms & 0o777) == 0o600, "socket must be owner-only permissions")

        // Connect over Unix socket
        let clientFd = socket(AF_UNIX, diagnosticSocketStreamType, 0)
        #expect(clientFd >= 0)
        defer { close(clientFd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = sockPath.withCString {
            strncpy(&addr.sun_path.0, $0, MemoryLayout.size(ofValue: addr.sun_path))
        }
        let connectRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(clientFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(connectRes == 0, "connect to Unix socket must succeed")

        let req = Array("GET /ready HTTP/1.1\r\nHost: ws\r\nConnection: close\r\n\r\n".utf8)
        let written = req.withUnsafeBytes { raw in
            write(clientFd, raw.baseAddress, raw.count)
        }
        #expect(written == req.count)

        var respBuffer = [UInt8](repeating: 0, count: 4096)
        let readCount = read(clientFd, &respBuffer, respBuffer.count)
        #expect(readCount > 0)
        let respString = String(decoding: respBuffer.prefix(Int(readCount)), as: UTF8.self)
        #expect(respString.starts(with: "HTTP/1.1 200"), "got: \(respString)")
        #expect(respString.contains("\"launch_id\":\"nonce-uds\"") || respString.contains("\"launch_id\": \"nonce-uds\""))
        #expect(respString.contains("\"state\":\"connected\"") || respString.contains("\"state\": \"connected\""))
    }
    #endif

    @Test
    func tcpBindConflictSurfacesAsError() async throws {
        let first = try await serve(listener: .tcp(0), handle: DiagHandle(), logFile: nil)
        defer { first.stop() }
        let port = try #require(first.port)

        var failed = false
        do {
            let second = try await serve(listener: .tcp(port), handle: DiagHandle(), logFile: nil)
            second.stop()
        } catch {
            failed = true
        }
        #expect(failed, "second bind on the same port must fail")
    }

    @Test
    func logsTailsRequestedBytesAsPlainText() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logPath = tempDir.appendingPathComponent("ws.log").path
        try "0123456789".write(toFile: logPath, atomically: true, encoding: .utf8)

        let (bound, port) = try await serveWithLog(logFile: logPath)
        defer { bound.stop() }

        let (status1, contentType1, body1) = try await getText(port: port, path: "/logs?tail_bytes=4")
        #expect(status1 == 200)
        #expect(contentType1 == "text/plain; charset=utf-8")
        #expect(body1 == "6789")

        let (status2, _, body2) = try await getText(port: port, path: "/logs?tail_bytes=1000")
        #expect(status2 == 200)
        #expect(body2 == "0123456789")
    }

    @Test
    func logsDefaultAndHardCapBoundTheResponse() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logPath = tempDir.appendingPathComponent("ws.log").path
        var data = Data(repeating: UInt8(ascii: "a"), count: Int(MAX_LOG_TAIL_BYTES) + 4096)
        data.append(contentsOf: "END-MARKER".utf8)
        try data.write(to: URL(fileURLWithPath: logPath))

        let (bound, port) = try await serveWithLog(logFile: logPath)
        defer { bound.stop() }

        let (status1, _, body1) = try await getText(port: port, path: "/logs")
        #expect(status1 == 200)
        #expect(body1.utf8.count == Int(DEFAULT_LOG_TAIL_BYTES))
        #expect(body1.hasSuffix("END-MARKER"))

        let (status2, _, body2) = try await getText(port: port, path: "/logs?tail_bytes=999999999")
        #expect(status2 == 200)
        #expect(body2.utf8.count == Int(MAX_LOG_TAIL_BYTES), "hard cap applies")
        #expect(body2.hasSuffix("END-MARKER"))
    }

    @Test
    func logsTailIsLossyUtf8() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logPath = tempDir.appendingPathComponent("ws.log").path
        try "aé".write(toFile: logPath, atomically: true, encoding: .utf8)

        let (bound, port) = try await serveWithLog(logFile: logPath)
        defer { bound.stop() }

        let (status, _, body) = try await getText(port: port, path: "/logs?tail_bytes=1")
        #expect(status == 200)
        #expect(body == "\u{FFFD}", "a torn UTF-8 boundary must be lossy")
    }

    @Test
    func logsWithoutLogFileIs404() async throws {
        let (bound, port) = try await serveWithLog(logFile: nil)
        defer { bound.stop() }

        let (status, _, _) = try await getText(port: port, path: "/logs")
        #expect(status == 404)
    }

    @Test
    func logsMissingLogFileIs404() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let logPath = tempDir.appendingPathComponent("never-created.log").path
        let (bound, port) = try await serveWithLog(logFile: logPath)
        defer { bound.stop() }

        let (status, _, _) = try await getText(port: port, path: "/logs")
        #expect(status == 404)
    }
}
