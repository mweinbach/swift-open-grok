import Foundation
import OpenGrokConfig
import OpenGrokHooksPluginTypes

public let defaultHookTimeoutMs: UInt64 = 5_000
public let defaultStopHookTimeoutMs: UInt64 = 600_000
public let hookOutputLimitBytes: Int = 64 * 1024

public struct HookConfigurationLayer: Sendable {
    public var sourceName: String
    public var path: URL
    public var hooks: TOMLValue
    public var sourceKind: HookSourceKind

    public init(sourceName: String, path: URL, hooks: TOMLValue, sourceKind: HookSourceKind = .user) {
        self.sourceName = sourceName
        self.path = path
        self.hooks = hooks
        self.sourceKind = sourceKind
    }
}

private struct RawHookDocument: Decodable {
    var hooks: [String: [RawMatcherGroup]]?
}

private struct RawMatcherGroup: Decodable {
    var matcher: String?
    var hooks: [RawHandler]

    private enum CodingKeys: String, CodingKey { case matcher, hooks }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        matcher = try container.decodeIfPresent(String.self, forKey: .matcher)
        hooks = try container.decode([RawHandler].self, forKey: .hooks)
    }
}

private struct RawHandler: Decodable {
    var type: String
    var command: String?
    var url: String?
    var timeout: UInt64?
    var env: [String: String]

    private enum CodingKeys: String, CodingKey { case type, command, url, timeout, env }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        timeout = try container.decodeIfPresent(UInt64.self, forKey: .timeout)
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
    }
}

public struct HookParseResult: Sendable {
    public var specs: [HookSpec]
    public var errors: [HookError]
    public var skippedEvents: [String]

    public init(specs: [HookSpec] = [], errors: [HookError] = [], skippedEvents: [String] = []) {
        self.specs = specs
        self.errors = errors
        self.skippedEvents = skippedEvents
    }
}

public func parseHookFile(
    _ content: String,
    path: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> HookParseResult {
    guard let data = content.data(using: .utf8) else {
        return HookParseResult(errors: [.parseFile(path: path, detail: "content is not valid UTF-8")])
    }
    do {
        let document = try JSONDecoder().decode(RawHookDocument.self, from: data)
        guard let hooks = document.hooks else { return HookParseResult() }
        return buildSpecs(
            hooks: hooks,
            sourceName: path.deletingPathExtension().lastPathComponent,
            sourceDirectory: path.deletingLastPathComponent(),
            sourcePath: path,
            sourceKind: .file,
            environment: environment,
            unknownEvents: hooks.keys.filter { HookEvent(hookKey: $0) == nil }
        )
    } catch {
        return HookParseResult(errors: [.parseFile(path: path, detail: String(describing: error))])
    }
}

public func parseHooksFromValue(
    _ hooksValue: HookJSONValue,
    sourceName: String,
    sourceDirectory: URL = URL(fileURLWithPath: "."),
    sourcePath: URL = URL(fileURLWithPath: "hooks.json"),
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> HookParseResult {
    guard case .object(let object) = hooksValue else {
        return HookParseResult(errors: [.parseFile(path: sourcePath, detail: "hooks must be an object")])
    }
    do {
        let data = try JSONEncoder().encode(object)
        let hooks = try JSONDecoder().decode([String: [RawMatcherGroup]].self, from: data)
        return buildSpecs(
            hooks: hooks,
            sourceName: sourceName,
            sourceDirectory: sourceDirectory,
            sourcePath: sourcePath,
            sourceKind: .file,
            environment: environment,
            unknownEvents: hooks.keys.filter { HookEvent(hookKey: $0) == nil }
        )
    } catch {
        return HookParseResult(errors: [.parseFile(path: sourcePath, detail: String(describing: error))])
    }
}

public func parseHooksFromTOML(
    _ value: TOMLValue,
    sourceName: String,
    sourcePath: URL,
    sourceKind: HookSourceKind = .user,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> HookParseResult {
    guard let table = value.table else {
        return HookParseResult(errors: [.parseFile(path: sourcePath, detail: "hooks must be a TOML table")])
    }
    var specs: [HookSpec] = []
    var errors: [HookError] = []
    var skipped: [String] = []
    let sourceDirectory = sourcePath.deletingLastPathComponent()

    for (eventKey, eventValue) in table.pairs {
        guard HookEvent(hookKey: eventKey) != nil else {
            skipped.append(eventKey)
            continue
        }
        guard let groups = eventValue.arrayValue else {
            skipped.append(eventKey)
            continue
        }
        var parsedGroups: [RawMatcherGroup] = []
        var eventMalformed = false
        for groupValue in groups {
            guard let groupTable = groupValue.table,
                  let hooksValue = groupTable["hooks"],
                  let hookValues = hooksValue.arrayValue else {
                eventMalformed = true
                break
            }
            let matcher = groupTable["matcher"]?.stringValue
            var handlers: [RawHandler] = []
            for hookValue in hookValues {
                guard let handlerTable = hookValue.table,
                      let type = handlerTable["type"]?.stringValue else {
                    eventMalformed = true
                    break
                }
                let command = handlerTable["command"]?.stringValue
                let url = handlerTable["url"]?.stringValue
                let timeout: UInt64?
                if let timeoutValue = handlerTable["timeout"]?.int64Value, timeoutValue >= 0 {
                    timeout = UInt64(timeoutValue)
                } else {
                    timeout = nil
                }
                var env: [String: String] = [:]
                if let envTable = handlerTable["env"]?.table {
                    for (key, envValue) in envTable.pairs where envValue.stringValue != nil {
                        env[key] = envValue.stringValue
                    }
                }
                handlers.append(RawHandler(type: type, command: command, url: url, timeout: timeout, env: env))
            }
            if eventMalformed { break }
            parsedGroups.append(RawMatcherGroup(matcher: matcher, hooks: handlers))
        }
        if eventMalformed {
            skipped.append(eventKey)
            continue
        }
        let result = buildSpecs(
            hooks: [eventKey: parsedGroups],
            sourceName: sourceName,
            sourceDirectory: sourceDirectory,
            sourcePath: sourcePath,
            sourceKind: sourceKind,
            environment: environment,
            unknownEvents: []
        )
        specs.append(contentsOf: result.specs)
        errors.append(contentsOf: result.errors)
    }
    return HookParseResult(specs: specs, errors: errors, skippedEvents: skipped)
}

private func buildSpecs(
    hooks: [String: [RawMatcherGroup]],
    sourceName: String,
    sourceDirectory: URL,
    sourcePath: URL,
    sourceKind: HookSourceKind,
    environment: [String: String],
    unknownEvents: [String]
) -> HookParseResult {
    var specs: [HookSpec] = []
    var errors: [HookError] = []
    let knownEvents = HookEvent.runtimeOrder.filter { event in hooks.keys.contains { HookEvent(hookKey: $0) == event } }

    for event in knownEvents {
        guard let originalKey = hooks.keys.first(where: { HookEvent(hookKey: $0) == event }),
              let groups = hooks[originalKey] else { continue }
        for (groupIndex, group) in groups.enumerated() {
            let configuredMatcher = group.matcher?.isEmpty == false ? group.matcher : nil
            var compiledMatcher: HookMatcher?
            if let configuredMatcher, event.matcherPolicy == .tested {
                do {
                    compiledMatcher = try HookMatcher(pattern: configuredMatcher)
                } catch {
                    let groupName = "\(sourceName):\(event.runtimeWireName)[\(groupIndex)]"
                    errors.append(.invalidMatcher(name: groupName, path: sourcePath, detail: String(describing: error)))
                    continue
                }
            }
            for (handlerIndex, rawHandler) in group.hooks.enumerated() {
                let name = "\(sourceName):\(event.runtimeWireName)[\(groupIndex)].hooks[\(handlerIndex)]"
                let timeoutMs = rawHandler.timeout.map { $0 > UInt64.max / 1000 ? UInt64.max : $0 * 1000 }
                    ?? (event.gateKind == .stop ? defaultStopHookTimeoutMs : defaultHookTimeoutMs)
                let extra = rawHandler.env.filter { !runnerReservedEnvironmentKeys.contains($0.key) }
                let handlerType: HookHandlerType
                switch rawHandler.type {
                case "command": handlerType = .command
                case "http": handlerType = .http
                default:
                    errors.append(.unsupportedHandler(name: name, path: sourcePath, handler: rawHandler.type))
                    continue
                }
                switch handlerType {
                case .command:
                    guard let command = rawHandler.command else {
                        errors.append(.invalidConfiguration(name: name, path: sourcePath, detail: "command handler requires a 'command' field"))
                        continue
                    }
                    let expanded = expandHookEnvironment(command, extra: extra, environment: environment)
                    specs.append(HookSpec(name: name, event: event, handlerType: handlerType, configuredMatcher: configuredMatcher, matcher: compiledMatcher, command: expanded, commandRaw: command, timeoutMs: timeoutMs, sourceDirectory: sourceDirectory, extraEnvironment: extra, sourceKind: sourceKind))
                case .http:
                    guard let url = rawHandler.url else {
                        errors.append(.invalidConfiguration(name: name, path: sourcePath, detail: "http handler requires a 'url' field"))
                        continue
                    }
                    let expanded = expandHookEnvironment(url, extra: extra, environment: environment)
                    specs.append(HookSpec(name: name, event: event, handlerType: handlerType, configuredMatcher: configuredMatcher, matcher: compiledMatcher, url: expanded, urlRaw: url, timeoutMs: timeoutMs, sourceDirectory: sourceDirectory, extraEnvironment: extra, sourceKind: sourceKind))
                }
            }
        }
    }
    return HookParseResult(specs: specs, errors: errors, skippedEvents: unknownEvents)
}

private extension RawHandler {
    init(type: String, command: String?, url: String?, timeout: UInt64?, env: [String: String]) {
        self.type = type
        self.command = command
        self.url = url
        self.timeout = timeout
        self.env = env
    }
}

private extension RawMatcherGroup {
    init(matcher: String?, hooks: [RawHandler]) {
        self.matcher = matcher
        self.hooks = hooks
    }
}

public let runnerReservedEnvironmentKeys: Set<String> = [
    "GROK_HOOK_EVENT",
    "GROK_HOOK_NAME",
    "GROK_SESSION_ID",
    "GROK_WORKSPACE_ROOT",
    "CLAUDE_PROJECT_DIR"
]

public func expandHookEnvironment(
    _ input: String,
    extra: [String: String] = [:],
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    var output = ""
    var index = input.startIndex
    while index < input.endIndex {
        guard input[index] == "$" else {
            output.append(input[index])
            index = input.index(after: index)
            continue
        }
        let dollar = index
        index = input.index(after: index)
        if index == input.endIndex {
            output.append("$")
            break
        }
        if input[index] == "{" {
            let bodyStart = input.index(after: index)
            guard let close = input[bodyStart...].firstIndex(of: "}") else {
                output.append(contentsOf: input[dollar...])
                break
            }
            let body = String(input[bodyStart..<close])
            let name = body.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            if !name.isEmpty && name.count == body.count {
                let replacement = extra[String(name)] ?? environment[String(name)]
                output.append(contentsOf: replacement ?? String(input[dollar...close]))
            } else {
                output.append(contentsOf: input[dollar...close])
            }
            index = input.index(after: close)
            continue
        }
        guard input[index].isASCII && (input[index].isLetter || input[index].isNumber || input[index] == "_") else {
            output.append("$")
            continue
        }
        let nameStart = index
        while index < input.endIndex && input[index].isASCII && (input[index].isLetter || input[index].isNumber || input[index] == "_") {
            index = input.index(after: index)
        }
        let name = String(input[nameStart..<index])
        output.append(contentsOf: extra[name] ?? environment[name] ?? String(input[dollar..<index]))
    }
    return output
}
