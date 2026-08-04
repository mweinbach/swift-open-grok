import Foundation
import OpenGrokHooksPluginTypes

public enum HookSource: Sendable, Equatable {
    case settingsFile(URL)
    case directory(URL)
}

public struct HookRegistry: Sendable {
    private var storage: [HookEvent: [HookSpec]]

    public init(specs: [HookSpec] = []) {
        var grouped: [HookEvent: [HookSpec]] = [:]
        for spec in specs { grouped[spec.event, default: []].append(spec) }
        storage = grouped
    }

    public func hooks(for event: HookEvent) -> [HookSpec] {
        storage[event] ?? []
    }

    public func hooksForCanonical(_ event: HookEvent) -> [HookSpec] {
        storage[event] ?? []
    }

    public func hasEnabledHooks(for event: HookEvent, disabledNames: Set<String> = []) -> Bool {
        hooksForCanonical(event).contains { $0.enabled && !disabledNames.contains($0.name) }
    }

    public var isEmpty: Bool { storage.values.allSatisfy(\.isEmpty) }
    public var count: Int { storage.values.reduce(0) { $0 + $1.count } }

    public func allHooks() -> [HookSpec] {
        HookEvent.runtimeOrder.flatMap { storage[$0] ?? [] }
    }

    public func hookInfos(disabledNames: Set<String> = []) -> [HookInfo] {
        allHooks().map { $0.info(disabled: disabledNames.contains($0.name)) }
    }

    public func recompileMatchers() -> HookRegistry {
        HookRegistry(specs: allHooks().map { spec in
            var copy = spec
            guard let pattern = copy.configuredMatcher else { return copy }
            copy.matcher = (try? HookMatcher(pattern: pattern)) ?? .never
            return copy
        })
    }
}

public struct HookLoadResult: Sendable {
    public var registry: HookRegistry
    public var errors: [HookError]
    public var skippedEvents: [String]

    public init(registry: HookRegistry = HookRegistry(), errors: [HookError] = [], skippedEvents: [String] = []) {
        self.registry = registry
        self.errors = errors
        self.skippedEvents = skippedEvents
    }
}

public enum HookDiscovery {
    public static func load(
        globalSources: [HookSource] = [],
        projectSources: [HookSource] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> HookLoadResult {
        var specs: [HookSpec] = []
        var errors: [HookError] = []
        var skippedEvents: [String] = []

        for source in globalSources {
            let result = load(source: source, environment: environment)
            specs.append(contentsOf: result.specs.map { prefix($0, with: "global/") })
            errors.append(contentsOf: result.errors)
            skippedEvents.append(contentsOf: result.skippedEvents)
        }
        for source in projectSources {
            let result = load(source: source, environment: environment)
            specs.append(contentsOf: result.specs.map { prefix($0, with: "project/") })
            errors.append(contentsOf: result.errors)
            skippedEvents.append(contentsOf: result.skippedEvents)
        }
        return HookLoadResult(registry: registryFromSpecsDeduped(specs), errors: errors, skippedEvents: skippedEvents)
    }

    public static func load(
        globalDirectory: URL?,
        projectDirectory: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> HookLoadResult {
        let global = globalDirectory.map { [HookSource.directory($0)] } ?? []
        let project = projectDirectory.map { [HookSource.directory($0)] } ?? []
        return load(globalSources: global, projectSources: project, environment: environment)
    }

    public static func defaultDirectories(workspaceRoot: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> (global: URL, project: URL) {
        (openGrokHome(environment: environment).appendingPathComponent("hooks"), workspaceRoot.appendingPathComponent(".opengrok/hooks"))
    }

    public static func loadDefaults(workspaceRoot: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> HookLoadResult {
        let directories = defaultDirectories(workspaceRoot: workspaceRoot, environment: environment)
        return load(globalDirectory: directories.global, projectDirectory: directories.project, environment: environment)
    }

    public static func registryFromSpecsDeduped(_ specs: [HookSpec]) -> HookRegistry {
        makeRegistryFromSpecsDeduped(specs)
    }

    private static func load(source: HookSource, environment: [String: String]) -> HookParseResult {
        switch source {
        case .settingsFile(let path):
            guard FileManager.default.fileExists(atPath: path.path) else { return HookParseResult() }
            do {
                return parseHookFile(try String(contentsOf: path, encoding: .utf8), path: path, environment: environment)
            } catch {
                return HookParseResult(errors: [.readFile(path: path, detail: String(describing: error))])
            }
        case .directory(let directory):
            guard FileManager.default.fileExists(atPath: directory.path) else { return HookParseResult() }
            do {
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                    .filter { isDirectHookJSONName($0.lastPathComponent) }
                    .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                    .sorted { $0.path < $1.path }
                var result = HookParseResult()
                for file in files {
                    do {
                        let parsed = parseHookFile(try String(contentsOf: file, encoding: .utf8), path: file, environment: environment)
                        result.specs.append(contentsOf: parsed.specs)
                        result.errors.append(contentsOf: parsed.errors)
                        result.skippedEvents.append(contentsOf: parsed.skippedEvents)
                    } catch {
                        result.errors.append(.readFile(path: file, detail: String(describing: error)))
                    }
                }
                return result
            } catch {
                return HookParseResult(errors: [.readFile(path: directory, detail: String(describing: error))])
            }
        }
    }
}

private func prefix(_ spec: HookSpec, with prefix: String) -> HookSpec {
    var copy = spec
    copy.name = prefix + spec.name
    return copy
}

private func makeRegistryFromSpecsDeduped(_ specs: [HookSpec]) -> HookRegistry {
    var seen: Set<String> = []
    var retained: [HookSpec] = []
    for spec in specs {
        let key = [spec.event.runtimeWireName, spec.commandRaw ?? "", spec.urlRaw ?? "", spec.configuredMatcher ?? ""].joined(separator: "\u{1f}")
        if seen.insert(key).inserted { retained.append(spec) }
    }
    return HookRegistry(specs: retained)
}

public func isDirectHookJSONName(_ name: String) -> Bool {
    guard name.hasSuffix(".json"), name.count > 5, !name.hasPrefix(".") else { return false }
    return !name.hasSuffix("~") && !name.hasSuffix(".swp") && !name.hasSuffix(".swo")
}

public func openGrokHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    if let override = environment["OPENGROK_HOME"], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }
    let home = environment["HOME"] ?? environment["USERPROFILE"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    return URL(fileURLWithPath: home).appendingPathComponent(".opengrok")
}

public func disabledHooksFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    openGrokHome(environment: environment).appendingPathComponent("disabled-hooks")
}

public func disabledHookNames(environment: [String: String] = ProcessInfo.processInfo.environment) -> Set<String> {
    guard let content = try? String(contentsOf: disabledHooksFile(environment: environment), encoding: .utf8) else { return [] }
    return Set(content.split(whereSeparator: \.isNewline).map(String.init).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.hasPrefix("#") })
}

@discardableResult
public func disableHook(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Bool {
    let file = disabledHooksFile(environment: environment)
    var names = disabledHookNames(environment: environment)
    let inserted = names.insert(name).inserted
    guard inserted else { return false }
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let contents = names.sorted().joined(separator: "\n") + "\n"
    try contents.write(to: file, atomically: true, encoding: .utf8)
    return true
}

@discardableResult
public func enableHook(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Bool {
    let file = disabledHooksFile(environment: environment)
    guard let content = try? String(contentsOf: file, encoding: .utf8) else { return false }
    let lines = content.split(whereSeparator: \.isNewline).map(String.init)
    let filtered = lines.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines) != name }
    guard filtered.count != lines.count else { return false }
    try filtered.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
    return true
}
