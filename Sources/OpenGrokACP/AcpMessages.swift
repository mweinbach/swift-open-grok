// AcpMessages.swift
//
// Typed ACP message enums and method dispatch. Replaces type-erased
// JSONValue envelopes for core methods while preserving extension
// routing, aliases, and unknown-field retention on schemas.

import Foundation
import OpenGrokShared

// MARK: - Typed agent messages

/// A message meant FOR the agent (client → agent direction).
///
/// Swift port of `xai_acp_lib::message::AcpAgentMessage`. Each case holds
/// a typed `AcpArgs` so responses are delivered through a single-shot
/// channel with exactly-once completion.
public enum AcpAgentMessage: Sendable {
    case initialize(AcpArgs<InitializeRequest>)
    case authenticate(AcpArgs<AuthenticateRequest>)
    case newSession(AcpArgs<NewSessionRequest>)
    case loadSession(AcpArgs<LoadSessionRequest>)
    case resumeSession(AcpArgs<ResumeSessionRequest>)
    case forkSession(AcpArgs<ForkSessionRequest>)
    case listSessions(AcpArgs<ListSessionsRequest>)
    case closeSession(AcpArgs<CloseSessionRequest>)
    case prompt(AcpArgs<PromptRequest>)
    case cancel(AcpArgs<CancelNotification>)
    case setSessionMode(AcpArgs<SetSessionModeRequest>)
    case setSessionModel(AcpArgs<SetSessionModelRequest>)
    case setSessionConfigOption(AcpArgs<SetSessionConfigOptionRequest>)
    case logout(AcpArgs<LogoutRequest>)
    case extMethod(AcpArgs<ExtRequest>)
    case extNotification(AcpArgs<ExtNotification>)
    case askUserQuestion(AcpArgs<AskUserQuestionExtRequest>)
}

extension AcpAgentMessage: AcpMethod {
    public var methodName: String {
        switch self {
        case .initialize(let args): return args.methodName
        case .authenticate(let args): return args.methodName
        case .newSession(let args): return args.methodName
        case .loadSession(let args): return args.methodName
        case .resumeSession(let args): return args.methodName
        case .forkSession(let args): return args.methodName
        case .listSessions(let args): return args.methodName
        case .closeSession(let args): return args.methodName
        case .prompt(let args): return args.methodName
        case .cancel(let args): return args.methodName
        case .setSessionMode(let args): return args.methodName
        case .setSessionModel(let args): return args.methodName
        case .setSessionConfigOption(let args): return args.methodName
        case .logout(let args): return args.methodName
        case .extMethod(let args): return args.methodName
        case .extNotification(let args): return args.methodName
        case .askUserQuestion(let args): return args.methodName
        }
    }
}

extension AcpAgentMessage: Equatable {
    public static func == (lhs: AcpAgentMessage, rhs: AcpAgentMessage) -> Bool {
        lhs.methodName == rhs.methodName
    }
}

extension AcpAgentMessage: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(methodName)
    }
}

// MARK: - Typed client messages

/// A message meant FOR the client (agent → client direction).
///
/// Swift port of `xai_acp_lib::message::AcpClientMessage`.
public enum AcpClientMessage: Sendable {
    case requestPermission(AcpArgs<RequestPermissionRequest>)
    case readTextFile(AcpArgs<ReadTextFileRequest>)
    case writeTextFile(AcpArgs<WriteTextFileRequest>)
    case sessionNotification(AcpArgs<SessionNotification>)
    case createTerminal(AcpArgs<CreateTerminalRequest>)
    case terminalOutput(AcpArgs<TerminalOutputRequest>)
    case releaseTerminal(AcpArgs<ReleaseTerminalRequest>)
    case waitForTerminalExit(AcpArgs<WaitForTerminalExitRequest>)
    case killTerminal(AcpArgs<KillTerminalRequest>)
    case extMethod(AcpArgs<ExtRequest>)
    case extNotification(AcpArgs<ExtNotification>)
    case askUserQuestion(AcpArgs<AskUserQuestionExtRequest>)
}

extension AcpClientMessage: AcpMethod {
    public var methodName: String {
        switch self {
        case .requestPermission(let args): return args.methodName
        case .readTextFile(let args): return args.methodName
        case .writeTextFile(let args): return args.methodName
        case .sessionNotification(let args): return args.methodName
        case .createTerminal(let args): return args.methodName
        case .terminalOutput(let args): return args.methodName
        case .releaseTerminal(let args): return args.methodName
        case .waitForTerminalExit(let args): return args.methodName
        case .killTerminal(let args): return args.methodName
        case .extMethod(let args): return args.methodName
        case .extNotification(let args): return args.methodName
        case .askUserQuestion(let args): return args.methodName
        }
    }
}

extension AcpClientMessage: Equatable {
    public static func == (lhs: AcpClientMessage, rhs: AcpClientMessage) -> Bool {
        lhs.methodName == rhs.methodName
    }
}

extension AcpClientMessage: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(methodName)
    }
}

// MARK: - Dispatch

/// Errors raised while decoding a method payload into a typed request.
public enum AcpDispatchError: Error, Hashable, Sendable {
    case methodNotFound(String)
    case invalidParams(method: String, detail: String)
}

/// Decode a typed agent-side message from a method name and JSON params.
///
/// Accepts both snake_case canonical and camelCase alias spellings for
/// set-mode / set-model. Unknown methods are routed to `extMethod` or
/// `extNotification` according to the JSON-RPC request/notification
/// classification carried by `isNotification`, preserving the original
/// extension method name on the wire.
///
/// The supplied `responseChannel` is bridged exactly once from the typed
/// `AcpArgs` response channel (via `bridgeTypedResponseChannel` /
/// `onFirstDelivery`) so transport/JSON-RPC callers observe success,
/// error, encode failure, and cancellation without stealing the typed
/// waiter slot.
public func decodeAcpAgentMessage(
    method: String,
    params: JSONValue,
    responseChannel: ResponseChannel<JSONValue> = ResponseChannel(),
    isNotification: Bool = false
) -> Result<AcpAgentMessage, AcpDispatchError> {
    func decodeTyped<T: AcpRequest & Decodable>(
        _ type: T.Type,
        wrap: (AcpArgs<T>) -> AcpAgentMessage
    ) -> Result<AcpAgentMessage, AcpDispatchError> {
        do {
            let request = try params.decode(T.self)
            let channel = ResponseChannel<T.Response>()
            bridgeTypedResponseChannel(from: channel, into: responseChannel)
            let args = AcpArgs(request: request, responseChannel: channel)
            return .success(wrap(args))
        } catch {
            return .failure(.invalidParams(method: method, detail: "\(error)"))
        }
    }

    func decodeExtension(methodName: String) -> AcpAgentMessage {
        if isNotification || methodName == "ext_notification" {
            let channel = ResponseChannel<EmptyAcpResponse>()
            bridgeTypedResponseChannel(from: channel, into: responseChannel)
            let request = ExtNotification(method: methodName, params: params)
            return .extNotification(AcpArgs(request: request, responseChannel: channel))
        } else {
            let channel = ResponseChannel<ExtResponse>()
            bridgeTypedResponseChannel(from: channel, into: responseChannel)
            let request = ExtRequest(method: methodName, params: params)
            return .extMethod(AcpArgs(request: request, responseChannel: channel))
        }
    }

    switch method {
    case AgentMethodNames.initialize:
        return decodeTyped(InitializeRequest.self, wrap: AcpAgentMessage.initialize)
    case AgentMethodNames.authenticate:
        return decodeTyped(AuthenticateRequest.self, wrap: AcpAgentMessage.authenticate)
    case AgentMethodNames.sessionNew:
        return decodeTyped(NewSessionRequest.self, wrap: AcpAgentMessage.newSession)
    case AgentMethodNames.sessionLoad:
        return decodeTyped(LoadSessionRequest.self, wrap: AcpAgentMessage.loadSession)
    case AgentMethodNames.sessionResume:
        return decodeTyped(ResumeSessionRequest.self, wrap: AcpAgentMessage.resumeSession)
    case AgentMethodNames.sessionFork:
        return decodeTyped(ForkSessionRequest.self, wrap: AcpAgentMessage.forkSession)
    case AgentMethodNames.sessionList:
        return decodeTyped(ListSessionsRequest.self, wrap: AcpAgentMessage.listSessions)
    case AgentMethodNames.sessionClose:
        return decodeTyped(CloseSessionRequest.self, wrap: AcpAgentMessage.closeSession)
    case AgentMethodNames.sessionPrompt:
        return decodeTyped(PromptRequest.self, wrap: AcpAgentMessage.prompt)
    case AgentMethodNames.sessionCancel:
        return decodeTyped(CancelNotification.self, wrap: AcpAgentMessage.cancel)
    case AgentMethodNames.sessionSetMode, AgentMethodNames.sessionSetModeCamel:
        return decodeTyped(SetSessionModeRequest.self, wrap: AcpAgentMessage.setSessionMode)
    case AgentMethodNames.sessionSetModel, AgentMethodNames.sessionSetModelCamel:
        return decodeTyped(SetSessionModelRequest.self, wrap: AcpAgentMessage.setSessionModel)
    case AgentMethodNames.sessionSetConfigOption:
        return decodeTyped(SetSessionConfigOptionRequest.self, wrap: AcpAgentMessage.setSessionConfigOption)
    case AgentMethodNames.logout:
        return decodeTyped(LogoutRequest.self, wrap: AcpAgentMessage.logout)
    case OpenGrokACPExtMethods.askUserQuestion:
        return decodeTyped(AskUserQuestionExtRequest.self, wrap: AcpAgentMessage.askUserQuestion)
    case "ext_method":
        return .success(decodeExtension(methodName: method))
    case "ext_notification":
        return .success(decodeExtension(methodName: method))
    default:
        // Unknown methods become extension methods/notifications so Open
        // Grok can extend the surface without breaking dispatch. The
        // original method name is preserved for routing.
        return .success(decodeExtension(methodName: method))
    }
}

/// Decode a typed client-side message from a method name and JSON params.
///
/// When `isNotification` is true (JSON-RPC notification / no id), unknown
/// methods are routed to `extNotification` with the original method name.
/// Otherwise they become `extMethod` requests.
public func decodeAcpClientMessage(
    method: String,
    params: JSONValue,
    responseChannel: ResponseChannel<JSONValue> = ResponseChannel(),
    isNotification: Bool = false
) -> Result<AcpClientMessage, AcpDispatchError> {
    func decodeTyped<T: AcpRequest & Decodable>(
        _ type: T.Type,
        wrap: (AcpArgs<T>) -> AcpClientMessage
    ) -> Result<AcpClientMessage, AcpDispatchError> {
        do {
            let request = try params.decode(T.self)
            let channel = ResponseChannel<T.Response>()
            bridgeTypedResponseChannel(from: channel, into: responseChannel)
            return .success(wrap(AcpArgs(request: request, responseChannel: channel)))
        } catch {
            return .failure(.invalidParams(method: method, detail: "\(error)"))
        }
    }

    func decodeExtension(methodName: String) -> AcpClientMessage {
        if isNotification || methodName == "ext_notification" {
            let channel = ResponseChannel<EmptyAcpResponse>()
            bridgeTypedResponseChannel(from: channel, into: responseChannel)
            let request = ExtNotification(method: methodName, params: params)
            return .extNotification(AcpArgs(request: request, responseChannel: channel))
        } else {
            let channel = ResponseChannel<ExtResponse>()
            bridgeTypedResponseChannel(from: channel, into: responseChannel)
            let request = ExtRequest(method: methodName, params: params)
            return .extMethod(AcpArgs(request: request, responseChannel: channel))
        }
    }

    switch method {
    case ClientMethodNames.sessionRequestPermission:
        return decodeTyped(RequestPermissionRequest.self, wrap: AcpClientMessage.requestPermission)
    case ClientMethodNames.fsReadTextFile:
        return decodeTyped(ReadTextFileRequest.self, wrap: AcpClientMessage.readTextFile)
    case ClientMethodNames.fsWriteTextFile:
        return decodeTyped(WriteTextFileRequest.self, wrap: AcpClientMessage.writeTextFile)
    case ClientMethodNames.sessionUpdate:
        return decodeTyped(SessionNotification.self, wrap: AcpClientMessage.sessionNotification)
    case ClientMethodNames.terminalCreate:
        return decodeTyped(CreateTerminalRequest.self, wrap: AcpClientMessage.createTerminal)
    case ClientMethodNames.terminalOutput:
        return decodeTyped(TerminalOutputRequest.self, wrap: AcpClientMessage.terminalOutput)
    case ClientMethodNames.terminalRelease:
        return decodeTyped(ReleaseTerminalRequest.self, wrap: AcpClientMessage.releaseTerminal)
    case ClientMethodNames.terminalWaitForExit:
        return decodeTyped(WaitForTerminalExitRequest.self, wrap: AcpClientMessage.waitForTerminalExit)
    case ClientMethodNames.terminalKill:
        return decodeTyped(KillTerminalRequest.self, wrap: AcpClientMessage.killTerminal)
    case OpenGrokACPExtMethods.askUserQuestion:
        return decodeTyped(AskUserQuestionExtRequest.self, wrap: AcpClientMessage.askUserQuestion)
    case "ext_method", "ext_notification":
        return .success(decodeExtension(methodName: method))
    default:
        return .success(decodeExtension(methodName: method))
    }
}

/// Encode a typed request's params as a JSON-RPC request envelope that
/// preserves the caller's request id.
public func encodeJsonRpcRequest<T: AcpRequest>(
    id: AcpRequestId,
    request: T
) throws -> JSONValue {
    let params = try JSONValue.encode(request)
    return .object([
        "jsonrpc": .string("2.0"),
        "id": encodeRequestId(id),
        "method": .string(request.methodName),
        "params": params,
    ])
}

/// Encode a typed response as a JSON-RPC result that preserves the id.
public func encodeJsonRpcResult<T: Encodable>(
    id: AcpRequestId,
    result: T
) throws -> JSONValue {
    .object([
        "jsonrpc": .string("2.0"),
        "id": encodeRequestId(id),
        "result": try JSONValue.encode(result),
    ])
}

/// Encode a typed error response that preserves the id and error data.
public func encodeJsonRpcError(
    id: AcpRequestId,
    error: AcpError
) throws -> JSONValue {
    .object([
        "jsonrpc": .string("2.0"),
        "id": encodeRequestId(id),
        "error": try JSONValue.encode(error),
    ])
}

private func encodeRequestId(_ id: AcpRequestId) -> JSONValue {
    switch id {
    case .null: return .null
    case .number(let n): return .number(.int64(n))
    case .string(let s): return .string(s)
    }
}
