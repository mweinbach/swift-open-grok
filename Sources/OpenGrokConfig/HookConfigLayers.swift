import Foundation

/// Origin of a configuration-declared hook. Unknown wire values degrade to the
/// least-trusted provenance instead of preventing newer peer records decoding.
public enum HookProvenance: String, Codable, CaseIterable, Sendable {
    case systemManaged = "system_managed"
    case managed
    case requirements
    case user
    case file
    case plugin
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = HookProvenance(rawValue: rawValue) ?? .unknown
    }
}

/// One config tier's raw hook table. Keeping tiers separate prevents a
/// lower-authority array from replacing an administrator's executable hooks.
public struct HookConfigLayer: Equatable, Sendable {
    public let provenance: HookProvenance
    public let sourceName: String
    public let path: URL
    public let hooks: TOMLValue

    public init(
        provenance: HookProvenance,
        sourceName: String,
        hooks: TOMLValue,
        path: URL? = nil
    ) {
        self.provenance = provenance
        self.sourceName = sourceName
        self.path = path ?? URL(fileURLWithPath: sourceName)
        self.hooks = hooks
    }
}

/// Return independent config hook declarations in highest-authority-first
/// order. Hook commands remain unexpanded so their runner expands them once.
public func hookConfigLayers(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> [HookConfigLayer] {
    hookConfigLayersAt(
        systemDir: systemConfigDir(),
        userHome: userGrokHome(environment: environment),
        environment: environment
    )
}

/// Explicit-directory variant for isolated configuration loading and tests.
public func hookConfigLayersAt(
    systemDir: URL?,
    userHome: URL?,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> [HookConfigLayer] {
    let candidates: [(directory: URL?, filename: String, provenance: HookProvenance, source: String)] = [
        (systemDir, REQUIREMENTS_FILENAME, .requirements, "requirements/system"),
        (userHome, REQUIREMENTS_FILENAME, .requirements, "requirements/user"),
        (userHome, "config.toml", .user, "user"),
        (userHome, MANAGED_CONFIG_FILENAME, .managed, "managed"),
        (systemDir, MANAGED_CONFIG_FILENAME, .systemManaged, "system_managed"),
    ]

    var layers: [HookConfigLayer] = []
    for candidate in candidates {
        guard let directory = candidate.directory else { continue }
        let path = directory.appendingPathComponent(candidate.filename)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { continue }

        do {
            let contents = try String(contentsOf: path, encoding: .utf8)
            var document = try parseTOML(contents)
            try applyVersionOverridesWithRegistered(&document, environment: environment)
            guard let hooks = document["hooks"], hooks.isTable else { continue }
            layers.append(
                HookConfigLayer(
                    provenance: candidate.provenance,
                    sourceName: candidate.source,
                    hooks: hooks,
                    path: path
                )
            )
        } catch {
            continue
        }
    }

    return layers
}
