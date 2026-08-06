// ACPLeaderProtocolTests.swift
//
// The leader IPC envelope: framing, message goldens, id namespacing, and
// capability injection. All byte-level and platform-free.

import Foundation
import OpenGrokACP
import OpenGrokShared
import Testing

@testable import OpenGrokACPRuntime

private func json(_ bytes: [UInt8]) throws -> [String: JSONValue] {
    // The frame's own length prefix is stripped first; what remains is the body.
    let body = Array(bytes.dropFirst(4))
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(body))
    guard case .object(let object) = value else {
        Issue.record("frame body was not a JSON object")
        return [:]
    }
    return object
}

@Suite("Leader IPC framing")
struct ACPLeaderFramingTests {
    @Test("the length prefix is 4 bytes big-endian")
    func lengthPrefixIsBigEndian() throws {
        let body: [UInt8] = Array("hello".utf8)
        let frame = try ACPLeaderFrameEncoder.encode(body)
        #expect(Array(frame.prefix(4)) == [0, 0, 0, 5])
        #expect(Array(frame.dropFirst(4)) == body)
    }

    @Test("an empty body still carries a prefix")
    func emptyBody() throws {
        #expect(try ACPLeaderFrameEncoder.encode([]) == [0, 0, 0, 0])
    }

    /// A read can end anywhere. Every strict prefix of a frame must decode to
    /// "need more bytes" rather than to a frame or an error — the alternative
    /// is a decoder that invents a short message out of a partial read.
    @Test("every strict prefix needs more bytes")
    func partialFramesNeedMore() throws {
        let frame = try ACPLeaderFrameEncoder.encode(Array(#"{"type":"ping"}"#.utf8))
        for cut in 0..<frame.count {
            var decoder = ACPLeaderFrameDecoder()
            decoder.append(Array(frame.prefix(cut)))
            #expect(try decoder.nextFrame() == nil, "prefix of \(cut) bytes decoded early")
        }
        var decoder = ACPLeaderFrameDecoder()
        decoder.append(frame)
        #expect(try decoder.nextFrame() != nil)
    }

    @Test("a stream splits at every possible boundary")
    func everyTwoChunkSplit() throws {
        var stream: [UInt8] = []
        for body in ["a", "bb", "ccc"] {
            stream.append(contentsOf: try ACPLeaderFrameEncoder.encode(Array(body.utf8)))
        }
        for split in 0...stream.count {
            var decoder = ACPLeaderFrameDecoder()
            decoder.append(Array(stream.prefix(split)))
            var bodies: [String] = []
            while let body = try decoder.nextFrame() {
                bodies.append(String(decoding: body, as: UTF8.self))
            }
            decoder.append(Array(stream.dropFirst(split)))
            while let body = try decoder.nextFrame() {
                bodies.append(String(decoding: body, as: UTF8.self))
            }
            #expect(bodies == ["a", "bb", "ccc"], "split at \(split) lost frames")
        }
    }

    @Test("one byte at a time still reassembles")
    func byteAtATime() throws {
        let frame = try ACPLeaderFrameEncoder.encode(Array("payload".utf8))
        var decoder = ACPLeaderFrameDecoder()
        for (index, byte) in frame.enumerated() {
            decoder.append([byte])
            let result = try decoder.nextFrame()
            if index == frame.count - 1 {
                #expect(result.map { String(decoding: $0, as: UTF8.self) } == "payload")
            } else {
                #expect(result == nil)
            }
        }
    }

    /// `protocol.rs:8` — 64 MiB. Enforced on both sides: a declared length over
    /// the cap means the stream is already desynchronised, and scanning ahead
    /// for the next plausible header turns that into silent corruption.
    @Test("the cap is 64 MiB and is enforced both ways")
    func messageSizeCap() throws {
        #expect(ACPLeaderProtocolLimits.maximumMessageSize == 64 * 1024 * 1024)

        #expect(throws: ACPLeaderProtocolError.self) {
            try ACPLeaderFrameEncoder.encode(Array(repeating: 0, count: 11), maximumMessageSize: 10)
        }

        var decoder = ACPLeaderFrameDecoder(maximumMessageSize: 10)
        decoder.append([0, 0, 0, 200])
        #expect(throws: ACPLeaderProtocolError.self) { try decoder.nextFrame() }
    }
}

@Suite("Leader IPC messages")
struct ACPLeaderMessageTests {
    @Test("register serialises with snake_case keys")
    func registerWireShape() throws {
        let frame = try ACPLeaderCodec.encode(
            ACPLeaderClientMessage.register(
                clientType: "grok-tui",
                mode: .stdio,
                capabilities: ACPLeaderClientCapabilities(
                    yoloMode: true,
                    defaultModel: "grok-4",
                    fsRead: true
                )
            )
        )
        let object = try json(frame)
        #expect(object["type"] == .string("register"))
        #expect(object["client_type"] == .string("grok-tui"))
        #expect(object["mode"] == .string("stdio"))
        guard case .object(let capabilities) = object["capabilities"] ?? .null else {
            Issue.record("capabilities missing")
            return
        }
        #expect(capabilities["yolo_mode"] == .bool(true))
        #expect(capabilities["default_model"] == .string("grok-4"))
        #expect(capabilities["fs_read"] == .bool(true))
        #expect(capabilities["auto_mode"] == .bool(false))
    }

    @Test("every client message round-trips")
    func clientRoundTrip() throws {
        let messages: [ACPLeaderClientMessage] = [
            .register(clientType: "ide", mode: .headless, capabilities: ACPLeaderClientCapabilities()),
            .acp(payload: #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#),
            .control(requestID: "7", command: ["type": "get_leader_info"]),
            .ping,
            .disconnect,
        ]
        for message in messages {
            let frame = try ACPLeaderCodec.encode(message)
            var decoder = ACPLeaderFrameDecoder()
            decoder.append(frame)
            let body = try #require(try decoder.nextFrame())
            #expect(try ACPLeaderCodec.decode(ACPLeaderClientMessage.self, from: body) == message)
        }
    }

    @Test("every server message round-trips")
    func serverRoundTrip() throws {
        let messages: [ACPLeaderServerMessage] = [
            .registered(
                clientID: 3,
                ready: false,
                protocolVersion: 1,
                binaryVersion: "1.2.3",
                capabilities: ACPLeaderCapabilities(controlV1: true, profileFormats: ["svg"])
            ),
            .acp(payload: #"{"jsonrpc":"2.0","id":1,"result":{}}"#),
            .controlResult(
                requestID: "6",
                payload: .workspaceStatus(
                    ACPLeaderWorkspaceStatus(state: "none", pid: 7)
                )
            ),
            .controlError(requestID: "7", code: 1, message: "nope"),
            .pong,
            .error(code: 3, message: "Registration timeout"),
            .shuttingDown(reason: .autoUpdate, delayMilliseconds: 0),
            .shutdown,
            .leaderReady,
        ]
        for message in messages {
            let frame = try ACPLeaderCodec.encode(message)
            var decoder = ACPLeaderFrameDecoder()
            decoder.append(frame)
            let body = try #require(try decoder.nextFrame())
            #expect(try ACPLeaderCodec.decode(ACPLeaderServerMessage.self, from: body) == message)
        }
    }

    /// `protocol.rs:335-337` — `default_ready() -> true`, so a leader predating
    /// the field decodes as already initialised rather than parking a client on
    /// a `LeaderReady` that will never arrive.
    @Test("an absent ready flag defaults to true")
    func readyDefaultsTrue() throws {
        let body = Array(#"{"type":"registered","client_id":9}"#.utf8)
        let decoded = try ACPLeaderCodec.decode(ACPLeaderServerMessage.self, from: body)
        guard case .registered(let clientID, let ready, let version, _, _) = decoded else {
            Issue.record("expected registered, got \(decoded)")
            return
        }
        #expect(clientID == 9)
        #expect(ready)
        #expect(version == nil)
    }

    @Test("absent capability fields default to false")
    func capabilityDefaults() throws {
        let decoded = try ACPLeaderCodec.decode(
            ACPLeaderClientCapabilities.self,
            from: Array("{}".utf8)
        )
        #expect(decoded == ACPLeaderClientCapabilities())
    }

    @Test("an unknown message type is refused, not ignored")
    func unknownType() {
        #expect(throws: (any Error).self) {
            try ACPLeaderCodec.decode(
                ACPLeaderClientMessage.self,
                from: Array(#"{"type":"teleport"}"#.utf8)
            )
        }
    }

    /// Upstream's typed client encodes `frequency_hz` as a JSON *number*
    /// (`protocol.rs:198-202`), which a strict `[String: String]` decode
    /// would reject whole-frame — wedging the connection over one command.
    @Test("a control frame with a numeric field still decodes")
    func controlFrameNumericField() throws {
        let body = Array(
            #"{"type":"control","request_id":"1","command":{"type":"start_cpu_profile","frequency_hz":250,"output":"/tmp/p"}}"#.utf8
        )
        let decoded = try ACPLeaderCodec.decode(ACPLeaderClientMessage.self, from: body)
        #expect(
            decoded == .control(
                requestID: "1",
                command: ["type": "start_cpu_profile", "frequency_hz": "250", "output": "/tmp/p"]
            )
        )
    }

    @Test("the protocol version is 1")
    func protocolVersion() {
        #expect(ACPLeaderProtocolLimits.protocolVersion == 1)
    }

    /// The advertisement is pinned field-by-field: `control_v1` and
    /// `workspace_exposure` are claimed because `ACPLeaderControlPlane`
    /// implements them (upstream advertises both unconditionally for the same
    /// reason — `server.rs:153-160`); the profiler and relaunch stay
    /// unclaimed because this build has neither.
    @Test("advertised capabilities claim exactly the implemented control plane")
    func advertisedCapabilities() {
        let supported = ACPLeaderCapabilities.supported
        #expect(supported.controlV1)
        #expect(supported.workspaceExposure)
        #expect(!supported.runtimeCPUProfile)
        #expect(!supported.relaunchV1)
        #expect(supported.profileFormats.isEmpty)
    }
}

@Suite("Leader control payloads")
struct ACPLeaderControlPayloadTests {
    /// The whole success frame, byte-pinned. `protocol.rs:364-367` wraps the
    /// payload in serde's `{"Ok": ...}`; `protocol.rs:719-731` pins the
    /// `workspace_status` tag and field spellings.
    @Test("a workspace_status control result encodes to upstream's exact JSON")
    func workspaceStatusResultWireShape() throws {
        let frame = try ACPLeaderCodec.encode(
            ACPLeaderServerMessage.controlResult(
                requestID: "ws-1",
                payload: .workspaceStatus(
                    ACPLeaderWorkspaceStatus(
                        state: "running",
                        hubURL: "wss://hub.example/v1/tools",
                        cwd: "/home/u/proj",
                        uptimeMs: 4200,
                        activeToolCalls: 2,
                        sessions: ["grok-a", "grok-b"],
                        pid: 4242
                    )
                )
            )
        )
        #expect(
            String(decoding: frame.dropFirst(4), as: UTF8.self)
                == #"{"request_id":"ws-1","result":{"Ok":{"active_tool_calls":2,"cwd":"/home/u/proj","hub_url":"wss://hub.example/v1/tools","pid":4242,"sessions":["grok-a","grok-b"],"state":"running","type":"workspace_status","uptime_ms":4200}},"type":"control_result"}"#
        )
    }

    /// serde has no `skip_serializing_if` on the optional fields, so a
    /// not-running status carries explicit nulls (`protocol.rs:266-274`).
    @Test("a not-running status encodes explicit nulls, not omitted keys")
    func notRunningStatusEncodesNulls() throws {
        let frame = try ACPLeaderCodec.encode(
            ACPLeaderWorkspaceStatus(state: "none", pid: 4242)
        )
        #expect(
            String(decoding: frame.dropFirst(4), as: UTF8.self)
                == #"{"active_tool_calls":0,"cwd":null,"hub_url":null,"pid":4242,"sessions":[],"state":"none","type":"workspace_status","uptime_ms":0}"#
        )
    }

    /// `protocol.rs:735-747` — the optional fields may be absent entirely;
    /// both spellings must decode to the same payload.
    @Test("a status with absent optional fields still decodes")
    func statusDecodeDefaults() throws {
        let body = Array(
            #"{"type":"workspace_status","state":"none","uptime_ms":0,"active_tool_calls":0,"pid":1}"#.utf8
        )
        let decoded = try ACPLeaderCodec.decode(ACPLeaderControlPayload.self, from: body)
        guard case .workspaceStatus(let status) = decoded else {
            Issue.record("expected workspace_status, got \(decoded)")
            return
        }
        #expect(status == ACPLeaderWorkspaceStatus(state: "none", pid: 1))
    }

    /// `protocol.rs:647-679` — an upstream `leader_info` payload decodes, with
    /// `cpu_profile_stopping` defaulting to false for older leaders.
    @Test("upstream's leader_info golden decodes")
    func leaderInfoDecode() throws {
        let body = Array(
            #"{"type":"leader_info","pid":123,"socket_path":"/tmp/leader.sock","lock_path":"/tmp/leader.lock","ws_url_suffix":"suffix","leader_protocol_version":1,"leader_binary_version":"1.2.3","profiling_supported":true,"profiling_compiled_in":true,"cpu_profile_active":false,"profile_started_at":null,"profile_formats":["svg"]}"#.utf8
        )
        let decoded = try ACPLeaderCodec.decode(ACPLeaderControlPayload.self, from: body)
        #expect(
            decoded == .leaderInfo(
                ACPLeaderInfo(
                    pid: 123,
                    socketPath: "/tmp/leader.sock",
                    lockPath: "/tmp/leader.lock",
                    wsURLSuffix: "suffix",
                    leaderProtocolVersion: 1,
                    leaderBinaryVersion: "1.2.3",
                    profilingSupported: true,
                    profilingCompiledIn: true,
                    profileFormats: ["svg"]
                )
            )
        )
    }

    /// `protocol.rs:663-666` — upstream's inactive `cpu_profile_status`
    /// golden, the only payload a profiler-less build ever produces.
    @Test("upstream's inactive cpu_profile_status golden decodes")
    func cpuProfileStatusDecode() throws {
        let body = Array(
            #"{"type":"cpu_profile_status","active":false,"started_at":null,"svg_path":null,"frequency_hz":null}"#.utf8
        )
        let decoded = try ACPLeaderCodec.decode(ACPLeaderControlPayload.self, from: body)
        #expect(decoded == .cpuProfileStatus(ACPLeaderCpuProfileStatus()))
    }

    @Test("every payload variant round-trips")
    func payloadRoundTrips() throws {
        let payloads: [ACPLeaderControlPayload] = [
            .leaderInfo(
                ACPLeaderInfo(
                    pid: 1,
                    socketPath: "/s",
                    lockPath: "/l",
                    wsURLSuffix: "",
                    leaderProtocolVersion: 1,
                    leaderBinaryVersion: "0.0.0"
                )
            ),
            .cpuProfileStatus(ACPLeaderCpuProfileStatus(active: true, stopping: true, startedAt: "t", svgPath: "/p", frequencyHz: 250)),
            .workspaceStatus(ACPLeaderWorkspaceStatus(state: "paused", hubURL: "wss://h", cwd: "/c", uptimeMs: 1, activeToolCalls: 3, sessions: ["a"], pid: 9)),
        ]
        for payload in payloads {
            let frame = try ACPLeaderCodec.encode(payload)
            var decoder = ACPLeaderFrameDecoder()
            decoder.append(frame)
            let body = try #require(try decoder.nextFrame())
            #expect(try ACPLeaderCodec.decode(ACPLeaderControlPayload.self, from: body) == payload)
        }
    }

    /// A payload variant this port does not model fails to decode rather
    /// than being approximated into one it does.
    @Test("an unknown payload type is refused")
    func unknownPayloadType() {
        #expect(throws: ACPLeaderProtocolError.self) {
            try ACPLeaderCodec.decode(
                ACPLeaderControlPayload.self,
                from: Array(#"{"type":"relaunching","from_version":"1","to_version":"2","grace_ms":0}"#.utf8)
            )
        }
    }

    /// The Err half shares the `control_result` type with Ok; both must be
    /// reachable through the same decode entry point.
    @Test("the Err half of a control result still decodes")
    func controlErrorStillDecodes() throws {
        let body = Array(
            #"{"type":"control_result","request_id":"7","result":{"Err":{"code":102,"message":"no workspace exposure is running"}}}"#.utf8
        )
        let decoded = try ACPLeaderCodec.decode(ACPLeaderServerMessage.self, from: body)
        #expect(decoded == .controlError(requestID: "7", code: 102, message: "no workspace exposure is running"))
    }
}

@Suite("Request id namespacing")
struct ACPLeaderRequestNamespaceTests {
    /// `server.rs:293-303`. Without this, two clients both sending `{"id":1}`
    /// each receive the other's response.
    @Test("ids round-trip through the namespace for every id kind")
    func roundTrip() {
        let ids: [AcpRequestId] = [
            .number(1),
            .number(-7),
            .string("abc"),
            .string("has|separator"),
            .string(#"quote"and\slash"#),
            .null,
        ]
        for id in ids {
            let namespaced = ACPLeaderRequestNamespace.namespaced(id, clientID: 42)
            let split = ACPLeaderRequestNamespace.split(namespaced)
            #expect(split?.clientID == 42)
            #expect(split?.original == id, "\(id) did not survive the round trip")
        }
    }

    /// A numeric `1` and a string `"1"` are different JSON-RPC ids, so the
    /// original must be embedded as JSON rather than as a bare string.
    @Test("a numeric id and a string id stay distinguishable")
    func numberAndStringDiffer() {
        let number = ACPLeaderRequestNamespace.namespaced(.number(1), clientID: 5)
        let string = ACPLeaderRequestNamespace.namespaced(.string("1"), clientID: 5)
        #expect(number != string)
        #expect(ACPLeaderRequestNamespace.split(number)?.original == .number(1))
        #expect(ACPLeaderRequestNamespace.split(string)?.original == .string("1"))
    }

    @Test("the wire form is clientID|json")
    func wireForm() {
        #expect(
            ACPLeaderRequestNamespace.namespaced(.number(12), clientID: 3) == .string("3|12")
        )
        #expect(
            ACPLeaderRequestNamespace.namespaced(.string("x"), clientID: 3) == .string(#"3|"x""#)
        )
    }

    @Test("an id that was never namespaced does not split")
    func plainIdsDoNotSplit() {
        #expect(ACPLeaderRequestNamespace.split(.number(4)) == nil)
        #expect(ACPLeaderRequestNamespace.split(.string("no-separator")) == nil)
        #expect(ACPLeaderRequestNamespace.split(.string("notanumber|1")) == nil)
    }
}

@Suite("Capability injection")
struct ACPLeaderCapabilityInjectionTests {
    private func meta(_ message: ACPMessage) -> [String: JSONValue] {
        guard case .request(_, _, let params) = message,
            case .object(let object) = params ?? .null,
            case .object(let meta) = object["_meta"] ?? .null
        else { return [:] }
        return meta
    }

    private func inject(
        method: String,
        params: JSONValue = .object([:]),
        capabilities: ACPLeaderClientCapabilities
    ) -> ACPMessage {
        ACPLeaderCapabilityInjection.inject(
            into: .request(id: .number(1), method: method, params: params),
            clientID: 7,
            clientType: "grok-tui",
            capabilities: capabilities
        )
    }

    @Test("session/new receives yoloMode, modelId and the client tag")
    func sessionNewInjection() {
        let injected = inject(
            method: "session/new",
            capabilities: ACPLeaderClientCapabilities(
                yoloMode: true,
                defaultModel: "grok-4",
                codeNavEnabled: true,
                fsRead: true
            )
        )
        let meta = meta(injected)
        #expect(meta["yoloMode"] == .bool(true))
        #expect(meta["modelId"] == .string("grok-4"))
        #expect(meta["clientIdentifier"] == .string("grok-tui"))
        #expect(meta[ACPLeaderCapabilityInjection.clientIDKey] == .number(.uint64(7)))
        #expect(meta["codeNavEnabled"] == .bool(true))
        #expect(meta["clientFsRead"] == .bool(true))
        #expect(meta["clientFsWrite"] == .bool(false))
    }

    /// `server.rs:670-767` — autoMode is suppressed when yoloMode is set,
    /// because yolo already implies unattended approval and setting both would
    /// let the weaker mode win a later precedence check.
    @Test("autoMode is suppressed under yoloMode")
    func autoModeYieldsToYolo() {
        let both = meta(
            inject(
                method: "session/new",
                capabilities: ACPLeaderClientCapabilities(yoloMode: true, autoMode: true)
            )
        )
        #expect(both["autoMode"] == nil)

        let autoOnly = meta(
            inject(method: "session/new", capabilities: ACPLeaderClientCapabilities(autoMode: true))
        )
        #expect(autoOnly["autoMode"] == .bool(true))
    }

    /// A preference the request stated explicitly outranks the client's
    /// registered default; an ability the client does not have cannot be
    /// claimed by the request. That is why one is "if absent" and the other is
    /// an overwrite.
    @Test("preferences yield to the request, abilities overwrite it")
    func precedence() {
        let injected = inject(
            method: "session/new",
            params: .object([
                "_meta": .object([
                    "modelId": .string("explicit-model"),
                    "clientFsWrite": .bool(true),
                ])
            ]),
            capabilities: ACPLeaderClientCapabilities(defaultModel: "grok-4", fsWrite: false)
        )
        let meta = meta(injected)
        #expect(meta["modelId"] == .string("explicit-model"))
        #expect(meta["clientFsWrite"] == .bool(false))
    }

    /// `server.rs:670-767` short-circuits yoloMode and modelId for
    /// `session/load`: a loaded session already has both, and re-stamping them
    /// would silently rewrite a resumed session's model.
    @Test("session/load gets identity but not yoloMode or modelId")
    func sessionLoadInjection() {
        let meta = meta(
            inject(
                method: "session/load",
                capabilities: ACPLeaderClientCapabilities(yoloMode: true, defaultModel: "grok-4")
            )
        )
        #expect(meta["yoloMode"] == nil)
        #expect(meta["modelId"] == nil)
        #expect(meta["clientIdentifier"] == .string("grok-tui"))
        #expect(meta[ACPLeaderCapabilityInjection.clientIDKey] == .number(.uint64(7)))
    }

    @Test("initialize gets only the client identifier")
    func initializeInjection() {
        let meta = meta(
            inject(
                method: "initialize",
                capabilities: ACPLeaderClientCapabilities(yoloMode: true, fsWrite: true)
            )
        )
        #expect(meta["clientIdentifier"] == .string("grok-tui"))
        #expect(meta["yoloMode"] == nil)
        #expect(meta["clientFsWrite"] == nil)
    }

    @Test("unrelated methods and notifications are untouched")
    func passthrough() {
        let prompt = inject(method: "session/prompt", capabilities: ACPLeaderClientCapabilities(fsWrite: true))
        #expect(meta(prompt).isEmpty)

        let notification = ACPMessage.notification(method: "session/update", params: .object([:]))
        let injected = ACPLeaderCapabilityInjection.inject(
            into: notification,
            clientID: 1,
            clientType: "x",
            capabilities: ACPLeaderClientCapabilities(fsWrite: true)
        )
        #expect(injected == notification)
    }
}

@Suite("Leader socket paths")
struct ACPLeaderSocketPathTests {
    /// `lock.rs:13-33` — the production relay and the empty string both mean
    /// "the default leader", so they must share a socket.
    @Test("the production relay URL and an empty URL share the default socket")
    func productionHasNoSuffix() {
        #expect(ACPLeaderSocketPaths.suffix(forRelayURL: nil) == "")
        #expect(ACPLeaderSocketPaths.suffix(forRelayURL: "") == "")
        #expect(ACPLeaderSocketPaths.suffix(forRelayURL: ACPRelayConfiguration.productionURL) == "")
    }

    /// A leader pointed at staging must not adopt the production leader's
    /// socket, so a non-production URL gets its own stable suffix.
    @Test("a non-production relay gets a stable distinct suffix")
    func nonProductionSuffix() {
        let staging = ACPLeaderSocketPaths.suffix(forRelayURL: "wss://staging.example/ws")
        let other = ACPLeaderSocketPaths.suffix(forRelayURL: "wss://other.example/ws")
        #expect(staging.hasPrefix("-"))
        #expect(staging.count == 9)
        #expect(staging != other)
        #expect(staging == ACPLeaderSocketPaths.suffix(forRelayURL: "wss://staging.example/ws"))
    }

    @Test("the default paths sit in the grok home and share a stem")
    func defaultPaths() {
        let home = URL(fileURLWithPath: "/tmp/grok-home")
        let paths = ACPLeaderSocketPaths.resolve(
            openGrokHome: home,
            relayURL: ACPRelayConfiguration.productionURL,
            environment: [:]
        )
        #expect(paths.socket.path == "/tmp/grok-home/leader.sock")
        #expect(paths.lock.path == "/tmp/grok-home/leader.lock")
    }

    /// `lock.rs:36-44` — the env override names an exact socket, so it must
    /// bypass the suffix entirely rather than decorating it.
    @Test("the environment override bypasses the suffix")
    func environmentOverride() {
        let paths = ACPLeaderSocketPaths.resolve(
            openGrokHome: URL(fileURLWithPath: "/tmp/grok-home"),
            relayURL: "wss://staging.example/ws",
            environment: [ACPLeaderSocketPaths.socketEnvironmentVariable: "/tmp/custom.sock"]
        )
        #expect(paths.socket.path == "/tmp/custom.sock")
        #expect(paths.lock.path == "/tmp/custom.sock.lock")
    }
}

@Suite("Leader advisory lock")
struct ACPLeaderLockTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("leader-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

#if !os(Windows)
    @Test("acquiring records this process's pid")
    func recordsPID() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = ACPLeaderLock(
            lockPath: directory.appendingPathComponent("leader.lock"),
            socketPath: directory.appendingPathComponent("leader.sock")
        )
        try lock.acquire()
        defer { lock.release() }
        #expect(
            ACPLeaderLock.readPID(at: lock.lockPath)
                == ProcessInfo.processInfo.processIdentifier
        )
    }

    /// The whole point: a second leader for the same endpoint must be refused
    /// atomically, not after a PID-file read that another process can race.
    @Test("a second acquisition is refused while the first is held")
    func secondAcquisitionRefused() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockPath = directory.appendingPathComponent("leader.lock")
        let socketPath = directory.appendingPathComponent("leader.sock")

        let first = ACPLeaderLock(lockPath: lockPath, socketPath: socketPath)
        try first.acquire()

        // Same process, so `flock` would normally succeed on a second fd; it
        // does not, because each `open` produces an independent open-file
        // description and `flock` is per-description.
        let second = ACPLeaderLock(lockPath: lockPath, socketPath: socketPath)
        #expect(throws: ACPLeaderLockError.self) { try second.acquire() }

        first.release()
        let third = ACPLeaderLock(lockPath: lockPath, socketPath: socketPath)
        try third.acquire()
        third.release()
    }

    /// `lock.rs:275-316` — cleanup is for the owner only. A non-owner deleting
    /// the socket would unhook a live leader from every client.
    @Test("releasing removes both files, and a non-owner removes neither")
    func cleanupIsOwnerOnly() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockPath = directory.appendingPathComponent("leader.lock")
        let socketPath = directory.appendingPathComponent("leader.sock")
        FileManager.default.createFile(atPath: socketPath.path, contents: Data())

        let owner = ACPLeaderLock(lockPath: lockPath, socketPath: socketPath)
        try owner.acquire()

        let bystander = ACPLeaderLock(lockPath: lockPath, socketPath: socketPath)
        bystander.release()
        #expect(FileManager.default.fileExists(atPath: socketPath.path))
        #expect(FileManager.default.fileExists(atPath: lockPath.path))

        owner.release()
        #expect(!FileManager.default.fileExists(atPath: socketPath.path))
        #expect(!FileManager.default.fileExists(atPath: lockPath.path))
    }
#else
    @Test("Windows refuses leader locking before creating endpoint artifacts")
    func windowsRefusesWithoutArtifacts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("leader-lock-\(UUID().uuidString)")
        let lockPath = directory.appendingPathComponent("leader.lock")
        let socketPath = directory.appendingPathComponent("leader.sock")
        let lock = ACPLeaderLock(lockPath: lockPath, socketPath: socketPath)

        do {
            try lock.acquire()
            Issue.record("Windows leader locking unexpectedly succeeded")
        } catch let error as ACPLeaderLockError {
            guard case .unsupportedPlatform(let path) = error else {
                Issue.record("expected unsupportedPlatform, got \(error)")
                return
            }
            #expect(path == lockPath.path)
        }

        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(!FileManager.default.fileExists(atPath: lockPath.path))
        #expect(!FileManager.default.fileExists(atPath: socketPath.path))
    }
#endif
}
