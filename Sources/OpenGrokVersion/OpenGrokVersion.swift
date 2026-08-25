import Foundation

public enum OpenGrokVersionError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidSemVer(input: String, reason: String)
    case conflictingBuildIdentity(OpenGrokBuildInfo)

    public var description: String {
        switch self {
        case .invalidSemVer(let input, let reason):
            return "invalid semver '\(input)': \(reason)"
        case .conflictingBuildIdentity(let identity):
            return "conflicting Open Grok build identity: \(identity)"
        }
    }
}

public enum OpenGrokBuildKind: String, Equatable, Sendable {
    case local
    case release
}

public struct OpenGrokBuildInfo: Equatable, Sendable, CustomStringConvertible {
    public let version: String
    public let versionWithCommit: String
    public let kind: OpenGrokBuildKind

    public init(version: String, versionWithCommit: String, kind: OpenGrokBuildKind) {
        self.version = version
        self.versionWithCommit = versionWithCommit
        self.kind = kind
    }

    public static func local(versionWithCommit: String) -> Self {
        Self(version: OpenGrokVersion.fallbackVersion, versionWithCommit: versionWithCommit, kind: .local)
    }

    public static func release(version: String, versionWithCommit: String) -> Self {
        Self(version: version, versionWithCommit: versionWithCommit, kind: .release)
    }

    public static func fromCompileStamp(releaseVersion: String?, versionWithCommit: String) -> Self {
        if let releaseVersion {
            return .release(version: releaseVersion, versionWithCommit: versionWithCommit)
        }
        return .local(versionWithCommit: versionWithCommit)
    }

    public static func fromVersionStamp(releaseVersion: String?) -> Self {
        if let releaseVersion {
            return .release(version: releaseVersion, versionWithCommit: releaseVersion)
        }
        return .local(versionWithCommit: OpenGrokVersion.fallbackVersionWithCommit)
    }

    public var description: String {
        "OpenGrokBuildInfo(version: \(version), versionWithCommit: \(versionWithCommit), kind: \(kind.rawValue))"
    }
}

/// Separately constructible so the once-only invariant is testable without
/// resetting process-global identity between concurrent tests.
final class OpenGrokBuildIdentityCell: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: OpenGrokBuildInfo?

    /// Returns nil after a successful first or identical registration, and
    /// the rejected identity after a conflict.
    func initialize(_ identity: OpenGrokBuildInfo) -> OpenGrokBuildInfo? {
        lock.lock()
        defer { lock.unlock() }
        if let stored {
            return stored == identity ? nil : identity
        }
        stored = identity
        return nil
    }

    var registered: OpenGrokBuildInfo? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

public enum OpenGrokVersion {
    public static let testVersionEnvironmentVariable = "GROK_TEST_VERSION"
    public static let compileTimeVersionEnvironmentVariable = "GROK_VERSION"

    /// Mirrors the shared Rust crate package version. The shipping release
    /// stamp belongs only to the final executable.
    public static let fallbackVersion = "1.0.0"
    public static let fallbackVersionWithCommit = "1.0.0 (unknown)"

    private static let buildIdentity = OpenGrokBuildIdentityCell()

    /// Re-registering an identical value is harmless. A conflict is rejected so
    /// embedded callers cannot mutate security or updater behavior after startup.
    public static func initialize(_ identity: OpenGrokBuildInfo) throws {
        if let conflict = buildIdentity.initialize(identity) {
            throw OpenGrokVersionError.conflictingBuildIdentity(conflict)
        }
    }

    public static var registeredBuildInfo: OpenGrokBuildInfo? { buildIdentity.registered }
    public static var version: String { registeredBuildInfo?.version ?? fallbackVersion }
    public static var versionWithCommit: String {
        registeredBuildInfo?.versionWithCommit ?? fallbackVersionWithCommit
    }

    /// Missing initialization cannot make an optimized production-shaped
    /// process look local and silently disable a security gate.
    public static var isReleaseBuild: Bool {
        classifyBuildKind(
            registered: registeredBuildInfo?.kind,
            debugAssertions: _isDebugAssertConfiguration()
        ) == .release
    }

    static func classifyBuildKind(
        registered: OpenGrokBuildKind?,
        debugAssertions: Bool
    ) -> OpenGrokBuildKind {
        registered ?? (debugAssertions ? .local : .release)
    }

    // Compatibility names while shared consumers migrate to runtime identity.
    public static var compiledVersion: String { version }
    public static var compiledShortCommit: String? {
        guard let registeredBuildInfo else { return nil }
        let prefix = registeredBuildInfo.version + " ("
        guard registeredBuildInfo.versionWithCommit.hasPrefix(prefix),
              registeredBuildInfo.versionWithCommit.hasSuffix(")") else { return nil }
        return String(registeredBuildInfo.versionWithCommit.dropFirst(prefix.count).dropLast())
    }
    public static var compiledVersionWithCommit: String { versionWithCommit }

    public static func installed(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = environment[testVersionEnvironmentVariable] {
            return override.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return version
    }

    public static func installedWithCommit(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if environment[testVersionEnvironmentVariable] != nil {
            return installed(environment: environment)
        }
        return versionWithCommit
    }

    public static func installedSemVer(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> SemVerVersion {
        try SemVerVersion.parse(installed(environment: environment))
    }

    public static func displayVersion(channelLabel: String) -> String {
        "\(version)\(channelLabel)"
    }

    public static func displayVersionWithCommit(
        _ versionWithCommit: String,
        channelLabel: String
    ) -> String {
        "\(versionWithCommit)\(channelLabel)"
    }
}
