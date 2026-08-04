import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HookRunContext: Sendable, Equatable {
    public var sessionId: String
    public var workspaceRoot: URL
    public var environment: [String: String]

    public init(
        sessionId: String,
        workspaceRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.sessionId = sessionId
        self.workspaceRoot = workspaceRoot
        self.environment = environment
    }
}

public enum HookDecision: Sendable, Equatable {
    case allow
    case deny(reason: String, hookName: String)
}

public struct StopOverride: Sendable, Equatable {
    public var reason: String?
    public init(reason: String? = nil) { self.reason = reason }
}

public struct StopHookOutcome: Sendable, Equatable {
    public var blockReason: String?
    public var additionalContext: String?
    public var forceStop: StopOverride?

    public init(blockReason: String? = nil, additionalContext: String? = nil, forceStop: StopOverride? = nil) {
        self.blockReason = blockReason
        self.additionalContext = additionalContext
        self.forceStop = forceStop
    }

    public var isEmpty: Bool { blockReason == nil && additionalContext == nil && forceStop == nil }
}

public struct HookHTTPInfo: Sendable, Equatable {
    public var url: String
    public var rawURL: String?
    public var statusCode: Int?
    public var responsePreview: String?

    public init(url: String, rawURL: String? = nil, statusCode: Int? = nil, responsePreview: String? = nil) {
        self.url = url
        self.rawURL = rawURL
        self.statusCode = statusCode
        self.responsePreview = responsePreview
    }
}

public enum HookRunnerResult: Sendable, Equatable {
    case success
    case decision(HookDecision)
    case stop(StopHookOutcome)
    case failed(String)
}

public struct HookInvocation: Sendable, Equatable {
    public var result: HookRunnerResult
    public var elapsedMs: UInt64
    public var httpInfo: HookHTTPInfo?

    public init(result: HookRunnerResult, elapsedMs: UInt64, httpInfo: HookHTTPInfo? = nil) {
        self.result = result
        self.elapsedMs = elapsedMs
        self.httpInfo = httpInfo
    }
}

public enum HookRunner {
    public static func run(
        spec: HookSpec,
        envelope: HookEventEnvelope,
        context: HookRunContext,
        mode: HookGateKind
    ) async -> HookInvocation {
        let start = Date()
        let invocation: HookInvocation
        switch spec.handlerType {
        case .command:
            invocation = await runCommand(spec: spec, envelope: envelope, context: context, mode: mode)
        case .http:
            invocation = await runHTTP(spec: spec, envelope: envelope, context: context, mode: mode)
        }
        let elapsedMs = elapsedMilliseconds(since: start)
        return HookInvocation(result: invocation.result, elapsedMs: max(invocation.elapsedMs, elapsedMs), httpInfo: invocation.httpInfo)
    }
}

private struct ProcessOutput: Sendable {
    var statusCode: Int32
    var stdout: Data
    var stderr: Data
}

private final class HookProcessController: @unchecked Sendable {
    let process: Process
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    init(process: Process) { self.process = process }

    func launch(input: Data) throws {
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        Task.detached(priority: .userInitiated) { [self] in
            do { try stdinPipe.fileHandleForWriting.write(contentsOf: input) } catch { }
            try? stdinPipe.fileHandleForWriting.close()
        }
    }

    func wait() -> Int32 {
        process.waitUntilExit()
        return process.terminationStatus
    }

    func readStdout() -> Data { stdoutPipe.fileHandleForReading.readDataToEndOfFile() }
    func readStderr() -> Data { stderrPipe.fileHandleForReading.readDataToEndOfFile() }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

private enum ProcessWaitOutcome: Sendable {
    case completed(Int32)
    case timedOut
}

private func runCommand(
    spec: HookSpec,
    envelope: HookEventEnvelope,
    context: HookRunContext,
    mode: HookGateKind
) async -> HookInvocation {
    let started = Date()
    guard let command = spec.command, !command.isEmpty else {
        return HookInvocation(result: .failed("command hook has no 'command' field"), elapsedMs: elapsedMilliseconds(since: started))
    }

    guard let input = try? envelope.jsonData() else {
        return HookInvocation(result: .failed("failed to serialize envelope"), elapsedMs: elapsedMilliseconds(since: started))
    }

    let shell = command.contains(where: { " \t|&;><$()".contains($0) }) || command.hasPrefix("~")
    if shell {
        let unresolved = unresolvedEnvironmentVariables(in: command, extra: spec.extraEnvironment, environment: context.environment)
        if !unresolved.isEmpty {
            let names = unresolved.map { "${\($0)}" }.joined(separator: ", ")
            return HookInvocation(result: .failed("hook not executed: required env var(s) not set: \(names)"), elapsedMs: elapsedMilliseconds(since: started))
        }
    }

    let process: Process
    if shell {
        process = Process()
        #if os(Windows)
        process.executableURL = URL(fileURLWithPath: context.environment["COMSPEC"] ?? "cmd.exe")
        process.arguments = ["/C", command]
        #else
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        #endif
    } else {
        let path = URL(fileURLWithPath: command, relativeTo: spec.sourceDirectory).standardizedFileURL
        guard FileManager.default.fileExists(atPath: path.path) else {
            return HookInvocation(result: .failed("command not found: \(path.path)"), elapsedMs: elapsedMilliseconds(since: started))
        }
        process = Process()
        process.executableURL = path
        process.arguments = []
    }

    process.currentDirectoryURL = context.workspaceRoot
    var childEnvironment = context.environment
    for (key, value) in spec.extraEnvironment { childEnvironment[key] = value }
    childEnvironment["GROK_HOOK_EVENT"] = envelope.hookEventName.runtimeWireName
    childEnvironment["GROK_HOOK_NAME"] = spec.name
    childEnvironment["GROK_SESSION_ID"] = context.sessionId
    childEnvironment["GROK_WORKSPACE_ROOT"] = context.workspaceRoot.path
    childEnvironment["CLAUDE_PROJECT_DIR"] = context.workspaceRoot.path
    process.environment = childEnvironment

    let controller = HookProcessController(process: process)
    do {
        try controller.launch(input: input)
    } catch {
        return HookInvocation(result: .failed("failed to spawn command: \(error)"), elapsedMs: elapsedMilliseconds(since: started))
    }

    let waitTask = Task.detached(priority: .userInitiated) { controller.wait() }
    let stdoutTask = Task.detached(priority: .userInitiated) { controller.readStdout() }
    let stderrTask = Task.detached(priority: .userInitiated) { controller.readStderr() }
    let waitOutcome: ProcessWaitOutcome
    do {
        waitOutcome = try await withTaskCancellationHandler(operation: {
            try await withThrowingTaskGroup(of: ProcessWaitOutcome.self) { group in
                group.addTask { .completed(await waitTask.value) }
                group.addTask {
                    try await Task.sleep(nanoseconds: min(spec.timeoutMs, UInt64.max / 1_000_000) * 1_000_000)
                    return .timedOut
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        }, onCancel: {
            controller.terminate()
        })
    } catch is CancellationError {
        controller.terminate()
        _ = await waitTask.value
        _ = await stdoutTask.value
        _ = await stderrTask.value
        return HookInvocation(result: .failed("hook cancelled"), elapsedMs: elapsedMilliseconds(since: started))
    } catch {
        controller.terminate()
        _ = await waitTask.value
        _ = await stdoutTask.value
        _ = await stderrTask.value
        return HookInvocation(result: .failed("hook execution failed: \(error)"), elapsedMs: elapsedMilliseconds(since: started))
    }

    if case .timedOut = waitOutcome {
        controller.terminate()
        _ = await waitTask.value
        _ = await stdoutTask.value
        _ = await stderrTask.value
        return HookInvocation(result: .failed("timed out after \(spec.timeoutMs)ms"), elapsedMs: elapsedMilliseconds(since: started))
    }

    if Task.isCancelled {
        controller.terminate()
        _ = await waitTask.value
        _ = await stdoutTask.value
        _ = await stderrTask.value
        return HookInvocation(result: .failed("hook cancelled"), elapsedMs: elapsedMilliseconds(since: started))
    }

    let statusCode: Int32
    if case .completed(let status) = waitOutcome { statusCode = status } else { statusCode = -1 }
    let stdout = truncateHookOutput(await stdoutTask.value)
    let stderr = truncateHookOutput(await stderrTask.value)
    let output = ProcessOutput(statusCode: statusCode, stdout: stdout, stderr: stderr)

    switch mode {
    case .observe:
        return HookInvocation(result: output.statusCode == 0 ? .success : .failed("exit code \(output.statusCode)"), elapsedMs: elapsedMilliseconds(since: started))
    case .tool:
        return HookInvocation(result: parseToolOutput(output, hookName: spec.name), elapsedMs: elapsedMilliseconds(since: started))
    case .stop:
        return HookInvocation(result: parseStopOutput(output, hookName: spec.name), elapsedMs: elapsedMilliseconds(since: started))
    }
}

private struct GateHookResponse: Decodable {
    var decision: String?
    var reason: String?
    var `continue`: Bool?
    var stopReason: String?
    var hookSpecificOutput: HookSpecificOutput?
}

private struct HookSpecificOutput: Decodable {
    var additionalContext: String?
}

private func decodedResponse(_ data: Data) -> GateHookResponse? {
    try? JSONDecoder().decode(GateHookResponse.self, from: data)
}

private func parseToolOutput(_ output: ProcessOutput, hookName: String) -> HookRunnerResult {
    let trimmed = output.stdout.trimmingUTF8Whitespace
    if !trimmed.isEmpty, let response = decodedResponse(trimmed) {
        switch response.decision {
        case "deny":
            return .decision(.deny(reason: response.reason ?? "denied by hook", hookName: hookName))
        case "allow":
            if output.statusCode != 2 { return .decision(.allow) }
        case nil:
            break
        default:
            return .failed("invalid decision in hook output")
        }
    }
    switch output.statusCode {
    case 0: return .decision(.allow)
    case 2: return .decision(.deny(reason: "denied by hook '\(hookName)' (exit code 2)", hookName: hookName))
    default: return .failed("hook '\(hookName)' failed with exit code \(output.statusCode)")
    }
}

private func parseStopOutput(_ output: ProcessOutput, hookName: String) -> HookRunnerResult {
    let trimmed = output.stdout.trimmingUTF8Whitespace
    if !trimmed.isEmpty, let response = decodedResponse(trimmed) {
        if let decision = response.decision, decision != "block" && decision != "allow" {
            return .failed("invalid stop decision in hook output")
        }
        let block = response.decision == "block" ? (response.reason ?? "blocked by stop hook") : nil
        let force = response.continue == false ? StopOverride(reason: response.stopReason) : nil
        return .stop(StopHookOutcome(blockReason: block, additionalContext: response.hookSpecificOutput?.additionalContext, forceStop: force))
    }
    switch output.statusCode {
    case 0: return .stop(StopHookOutcome())
    case 2:
        let feedback = String(data: output.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .stop(StopHookOutcome(blockReason: feedback?.isEmpty == false ? feedback : "Blocked by stop hook '\(hookName)' (exit code 2)"))
    default: return .failed("hook '\(hookName)' failed with exit code \(output.statusCode)")
    }
}

private func truncateHookOutput(_ data: Data) -> Data {
    guard data.count > hookOutputLimitBytes else { return data }
    var clipped = Data(data.prefix(hookOutputLimitBytes))
    clipped.append(contentsOf: " [truncated]".data(using: .utf8) ?? Data())
    return clipped
}

private func unresolvedEnvironmentVariables(in command: String, extra: [String: String], environment: [String: String]) -> [String] {
    var names: Set<String> = []
    var index = command.startIndex
    while index < command.endIndex {
        guard command[index] == "$" else { index = command.index(after: index); continue }
        let dollar = index
        index = command.index(after: index)
        guard index < command.endIndex else { break }
        if command[index] == "{" {
            let start = command.index(after: index)
            guard let close = command[start...].firstIndex(of: "}") else { break }
            let body = String(command[start..<close])
            let name = body.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            if !name.isEmpty && name.count == body.count {
                let nameString = String(name)
                if !runnerReservedEnvironmentKeys.contains(nameString) && extra[nameString] == nil && environment[nameString] == nil { names.insert(nameString) }
            }
            index = command.index(after: close)
        } else if command[index].isASCII && (command[index].isLetter || command[index].isNumber || command[index] == "_") {
            let start = index
            while index < command.endIndex && command[index].isASCII && (command[index].isLetter || command[index].isNumber || command[index] == "_") { index = command.index(after: index) }
            let name = String(command[start..<index])
            if !runnerReservedEnvironmentKeys.contains(name) && extra[name] == nil && environment[name] == nil { names.insert(name) }
        } else {
            index = command.index(after: dollar)
        }
    }
    return names.sorted()
}

private func elapsedMilliseconds(since start: Date) -> UInt64 {
    UInt64(max(0, Date().timeIntervalSince(start)) * 1000)
}

private extension Data {
    var trimmingUTF8Whitespace: Data {
        guard let string = String(data: self, encoding: .utf8) else { return self }
        return Data(string.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }
}

private func runHTTP(
    spec: HookSpec,
    envelope: HookEventEnvelope,
    context: HookRunContext,
    mode: HookGateKind
) async -> HookInvocation {
    let started = Date()
    guard let rawURL = spec.url else {
        return HookInvocation(result: .failed("http hook has no 'url' field"), elapsedMs: elapsedMilliseconds(since: started))
    }
    let urlString = expandHookEnvironment(rawURL, extra: spec.extraEnvironment, environment: context.environment)
    guard let url = URL(string: urlString), validateHookURL(url) else {
        return HookInvocation(result: .failed("blocked by SSRF protection: only https URLs and public hosts are allowed"), elapsedMs: elapsedMilliseconds(since: started), httpInfo: HookHTTPInfo(url: urlString, rawURL: spec.urlRaw))
    }
    guard let body = try? envelope.jsonData() else {
        return HookInvocation(result: .failed("failed to serialize envelope"), elapsedMs: elapsedMilliseconds(since: started), httpInfo: HookHTTPInfo(url: urlString, rawURL: spec.urlRaw))
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body
    request.timeoutInterval = TimeInterval(spec.timeoutMs) / 1000
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let session = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }

    do {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        let info = HookHTTPInfo(url: urlString, rawURL: spec.urlRaw, statusCode: status, responsePreview: responsePreview(data))
        guard let status else {
            return HookInvocation(result: .failed("HTTP response had no status code"), elapsedMs: elapsedMilliseconds(since: started), httpInfo: info)
        }
        if mode == .tool, !data.isEmpty, let parsed = decodedResponse(data) {
            switch parsed.decision {
            case "deny":
                return HookInvocation(result: .decision(.deny(reason: parsed.reason ?? "denied by hook", hookName: spec.name)), elapsedMs: elapsedMilliseconds(since: started), httpInfo: info)
            case "allow":
                if !(200..<300).contains(status) {
                    return HookInvocation(result: .decision(.allow), elapsedMs: elapsedMilliseconds(since: started), httpInfo: info)
                }
            case nil:
                if !(200..<300).contains(status) {
                    return HookInvocation(result: .failed("HTTP status \(status) with invalid decision"), elapsedMs: elapsedMilliseconds(since: started), httpInfo: info)
                }
            default:
                return HookInvocation(result: .failed("invalid decision in HTTP hook output"), elapsedMs: elapsedMilliseconds(since: started), httpInfo: info)
            }
        }
        guard (200..<300).contains(status) else {
            return HookInvocation(result: .failed("HTTP status \(status)"), elapsedMs: elapsedMilliseconds(since: started), httpInfo: info)
        }
        switch mode {
        case .observe: return HookInvocation(result: .success, elapsedMs: elapsedMilliseconds(since: started), httpInfo: info)
        case .tool:
            if data.isEmpty { return HookInvocation(result: .decision(.allow), elapsedMs: elapsedMilliseconds(since: started), httpInfo: info) }
            guard let parsed = decodedResponse(data) else { return HookInvocation(result: .decision(.allow), elapsedMs: elapsedMilliseconds(since: started), httpInfo: info) }
            switch parsed.decision {
            case "deny": return HookInvocation(result: .decision(.deny(reason: parsed.reason ?? "denied by hook", hookName: spec.name)), elapsedMs: elapsedMilliseconds(since: started), httpInfo: info)
            case "allow", nil: return HookInvocation(result: .decision(.allow), elapsedMs: elapsedMilliseconds(since: started), httpInfo: info)
            default: return HookInvocation(result: .failed("invalid decision in HTTP hook output"), elapsedMs: elapsedMilliseconds(since: started), httpInfo: info)
            }
        case .stop:
            guard !data.isEmpty else { return HookInvocation(result: .stop(StopHookOutcome()), elapsedMs: elapsedMilliseconds(since: started), httpInfo: info) }
            guard let parsed = decodedResponse(data) else { return HookInvocation(result: .stop(StopHookOutcome()), elapsedMs: elapsedMilliseconds(since: started), httpInfo: info) }
            if let decision = parsed.decision, decision != "block" && decision != "allow" { return HookInvocation(result: .failed("invalid stop decision in HTTP hook output"), elapsedMs: elapsedMilliseconds(since: started), httpInfo: info) }
            let block = parsed.decision == "block" ? (parsed.reason ?? "blocked by stop hook") : nil
            let force = parsed.continue == false ? StopOverride(reason: parsed.stopReason) : nil
            return HookInvocation(result: .stop(StopHookOutcome(blockReason: block, additionalContext: parsed.hookSpecificOutput?.additionalContext, forceStop: force)), elapsedMs: elapsedMilliseconds(since: started), httpInfo: info)
        }
    } catch is CancellationError {
        return HookInvocation(result: .failed("hook cancelled"), elapsedMs: elapsedMilliseconds(since: started), httpInfo: HookHTTPInfo(url: urlString, rawURL: spec.urlRaw))
    } catch {
        return HookInvocation(result: .failed("HTTP request failed for \(spec.urlRaw ?? urlString): \(error)"), elapsedMs: elapsedMilliseconds(since: started), httpInfo: HookHTTPInfo(url: urlString, rawURL: spec.urlRaw))
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private func responsePreview(_ data: Data) -> String? {
    guard let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
    if string.count <= 200 { return string }
    return String(string.prefix(200)) + "..."
}

private func validateHookURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "https", let host = url.host, !host.isEmpty else { return false }
    let lowered = host.lowercased()
    if lowered == "localhost" || lowered == "::1" { return true }
    let octets = lowered.split(separator: ".").compactMap { Int($0) }
    if octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
        if octets[0] == 127 { return true }
        if octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 169 && octets[1] == 254) || (octets[0] == 100 && (64...127).contains(octets[1])) || octets.allSatisfy({ $0 == 0 }) { return false }
    }
    if lowered == "::" || lowered.hasPrefix("fe80:") || lowered.hasPrefix("fc") || lowered.hasPrefix("fd") { return false }
    return true
}
