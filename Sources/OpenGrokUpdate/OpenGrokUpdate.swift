// OpenGrokUpdate.swift
//
// Open Grok update metadata, release selection, cache state, and safe update
// planning. This target deliberately stops before downloading, replacing, or
// re-executing the current process; those operations belong to a later
// distribution integration and must use a verified external installer.

import Foundation
import OpenGrokShared
import OpenGrokPaths
import OpenGrokVersion

// MARK: - Constants

public enum OpenGrokUpdateConstants {
    public static let releaseRepository = "mweinbach/open-grok"
    public static let releaseAPIURL = "https://api.github.com/repos/mweinbach/open-grok/releases/latest"
    public static let releaseDownloadBaseURL = "https://github.com/mweinbach/open-grok/releases"
    public static let releaseSource = "github"
    public static let npmPackage = "@xai-official/grok"
    public static let defaultCacheTTL: TimeInterval = 30 * 60
    public static let versionCacheFileName = "version.json"
}

public let RELEASE_SOURCE = OpenGrokUpdateConstants.releaseSource

// MARK: - Errors

public enum OpenGrokUpdateError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidVersion(String)
    case unsupportedChannel(String)
    case invalidCache(String)
    case cacheIO(String)
    case missingRelease(String)
    case invalidChecksum(String)
    case checksumAssetMismatch(expected: String, actual: String)
    case missingSignature(String)
    case invalidPlanningRequest(String)

    public var description: String {
        switch self {
        case .invalidVersion(let value):
            return "Invalid Open Grok version: \(value)"
        case .unsupportedChannel(let channel):
            return "Unsupported Open Grok update channel: \(channel)"
        case .invalidCache(let reason):
            return "Invalid Open Grok update cache: \(reason)"
        case .cacheIO(let reason):
            return "Open Grok update cache I/O failed: \(reason)"
        case .missingRelease(let reason):
            return "No eligible Open Grok release: \(reason)"
        case .invalidChecksum(let reason):
            return "Invalid published SHA-256 checksum: \(reason)"
        case .checksumAssetMismatch(let expected, let actual):
            return "Published checksum names \(actual), expected \(expected)"
        case .missingSignature(let asset):
            return "Required signature metadata is missing for \(asset)"
        case .invalidPlanningRequest(let reason):
            return "Invalid Open Grok update planning request: \(reason)"
        }
    }
}

// MARK: - Channels and installers

public enum UpdateChannel: Sendable, Equatable, Hashable, CustomStringConvertible {
    case stable
    case alpha
    case enterprise
    case unsupported(String)

    public init(rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "stable": self = .stable
        case "alpha": self = .alpha
        case "enterprise": self = .enterprise
        default: self = .unsupported(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .stable: return "stable"
        case .alpha: return "alpha"
        case .enterprise: return "enterprise"
        case .unsupported(let value): return value
        }
    }

    public var description: String { rawValue }

    public var rejectsUnrecognizedPrereleases: Bool {
        switch self {
        case .stable, .enterprise: return true
        case .alpha, .unsupported: return false
        }
    }
}

public enum UpdateInstaller: Sendable, Equatable, Hashable, CustomStringConvertible {
    case openGrok
    case internalInstaller
    case npm
    case githubRelease
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "open-grok": self = .openGrok
        case "internal": self = .internalInstaller
        case "npm": self = .npm
        case "gh-release", "github", "github-release": self = .githubRelease
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .openGrok: return "open-grok"
        case .internalInstaller: return "internal"
        case .npm: return "npm"
        case .githubRelease: return "gh-release"
        case .unknown(let value): return value
        }
    }

    public var description: String { rawValue }

    /// Only authoritative Open Grok-managed sources may intentionally follow
    /// a channel pointer rollback. npm registries are explicitly never allowed
    /// to turn a stale result into a downgrade.
    public var allowsDowngrade: Bool {
        switch self {
        case .openGrok, .internalInstaller, .githubRelease: return true
        case .npm, .unknown: return false
        }
    }
}

public struct UpdateConfig: Sendable, Equatable {
    public var proxyBaseURL: String
    public var authScope: String
    public var deploymentKey: String?
    public var alphaTestKey: String?
    public var channel: UpdateChannel
    public var installer: UpdateInstaller
    public var releaseAPIURL: URL
    public var releaseDownloadBaseURL: URL
    public var npmRegistry: URL?
    public var autoUpdate: Bool?
    public var cacheTTL: TimeInterval

    public init(
        proxyBaseURL: String = "https://cli-chat-proxy.grok.com/v1",
        authScope: String = "open-grok",
        deploymentKey: String? = nil,
        alphaTestKey: String? = nil,
        channel: UpdateChannel = .stable,
        installer: UpdateInstaller = .openGrok,
        releaseAPIURL: URL = URL(string: OpenGrokUpdateConstants.releaseAPIURL)!,
        releaseDownloadBaseURL: URL = URL(string: OpenGrokUpdateConstants.releaseDownloadBaseURL)!,
        npmRegistry: URL? = nil,
        autoUpdate: Bool? = nil,
        cacheTTL: TimeInterval = OpenGrokUpdateConstants.defaultCacheTTL
    ) {
        self.proxyBaseURL = proxyBaseURL
        self.authScope = authScope
        self.deploymentKey = deploymentKey
        self.alphaTestKey = alphaTestKey
        self.channel = channel
        self.installer = installer
        self.releaseAPIURL = releaseAPIURL
        self.releaseDownloadBaseURL = releaseDownloadBaseURL
        self.npmRegistry = npmRegistry
        self.autoUpdate = autoUpdate
        self.cacheTTL = cacheTTL
    }
}

// MARK: - Version normalization and release pointers

public enum UpdateVersion {
    public static func normalize(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutTag = trimmed.first == "v" ? String(trimmed.dropFirst()) : trimmed
        guard !withoutTag.isEmpty else { throw OpenGrokUpdateError.invalidVersion(value) }
        do {
            return try SemVerVersion.parse(withoutTag).description
        } catch {
            throw OpenGrokUpdateError.invalidVersion(value)
        }
    }

    public static func maximum(_ lhs: String, _ rhs: String) throws -> String {
        let left = try SemVerVersion.parse(try normalize(lhs))
        let right = try SemVerVersion.parse(try normalize(rhs))
        return max(left, right).description
    }

    public static func isOpenGrokPrerelease(_ version: SemVerVersion) -> Bool {
        version.prerelease.first?.lowercased() == "open-grok"
    }

    public static func satisfiesFloor(_ version: SemVerVersion, _ floor: SemVerVersion) -> Bool {
        if isOpenGrokPrerelease(version) && floor.prerelease.isEmpty {
            if version.major != floor.major { return version.major > floor.major }
            if version.minor != floor.minor { return version.minor > floor.minor }
            return version.patch >= floor.patch
        }
        return version >= floor
    }
}

/// A channel pointer pair. Alpha intentionally considers both alpha and stable
/// pointers, matching npm/GitHub/internal updater behavior in the Rust crate.
public struct ReleasePointers: Sendable, Equatable {
    public let stable: String
    public let alpha: String?

    public init(stable: String, alpha: String? = nil) throws {
        self.stable = try UpdateVersion.normalize(stable)
        self.alpha = try alpha.map(UpdateVersion.normalize)
    }

    public func resolvedVersion(for channel: UpdateChannel) throws -> String {
        switch channel {
        case .stable, .enterprise:
            return stable
        case .alpha:
            guard let alpha else {
                throw OpenGrokUpdateError.missingRelease("alpha pointer is unavailable")
            }
            return try UpdateVersion.maximum(alpha, stable)
        case .unsupported(let value):
            throw OpenGrokUpdateError.unsupportedChannel(value)
        }
    }
}

// MARK: - Release metadata and deterministic selection

public struct ReleaseAsset: Sendable, Equatable, Hashable, Codable {
    public let name: String
    public let downloadURL: URL
    public let checksumURL: URL?
    public let signatureURL: URL?
    public let byteCount: Int64?

    public init(
        name: String,
        downloadURL: URL,
        checksumURL: URL? = nil,
        signatureURL: URL? = nil,
        byteCount: Int64? = nil
    ) {
        self.name = name
        self.downloadURL = downloadURL
        self.checksumURL = checksumURL
        self.signatureURL = signatureURL
        self.byteCount = byteCount
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
        case checksumURL = "checksum_url"
        case signatureURL = "signature_url"
        case byteCount = "size"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        let downloadString = try container.decode(String.self, forKey: .downloadURL)
        guard let downloadURL = URL(string: downloadString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .downloadURL,
                in: container,
                debugDescription: "release asset URL is invalid"
            )
        }
        self.downloadURL = downloadURL
        self.checksumURL = try container.decodeIfPresent(URL.self, forKey: .checksumURL)
        self.signatureURL = try container.decodeIfPresent(URL.self, forKey: .signatureURL)
        self.byteCount = try container.decodeIfPresent(Int64.self, forKey: .byteCount)
    }
}

public struct ReleaseCandidate: Sendable, Equatable, Codable {
    public let tagName: String
    public let version: String
    public let isDraft: Bool
    public let isPrerelease: Bool
    public let assets: [ReleaseAsset]

    public init(
        tagName: String,
        version: String,
        isDraft: Bool = false,
        isPrerelease: Bool = false,
        assets: [ReleaseAsset] = []
    ) throws {
        self.tagName = tagName
        self.version = try UpdateVersion.normalize(version)
        self.isDraft = isDraft
        self.isPrerelease = isPrerelease
        self.assets = assets
    }

    public init(
        tagName: String,
        isDraft: Bool = false,
        isPrerelease: Bool = false,
        assets: [ReleaseAsset] = []
    ) throws {
        try self.init(
            tagName: tagName,
            version: tagName,
            isDraft: isDraft,
            isPrerelease: isPrerelease,
            assets: assets
        )
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case version
        case isDraft = "draft"
        case isPrerelease = "prerelease"
        case assets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tagName = try container.decode(String.self, forKey: .tagName)
        let version = try container.decodeIfPresent(String.self, forKey: .version) ?? tagName
        do {
            self.tagName = tagName
            self.version = try UpdateVersion.normalize(version)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .tagName,
                in: container,
                debugDescription: "release tag is not valid semver"
            )
        }
        self.isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        self.isPrerelease = try container.decodeIfPresent(Bool.self, forKey: .isPrerelease) ?? false
        self.assets = try container.decodeIfPresent([ReleaseAsset].self, forKey: .assets) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tagName, forKey: .tagName)
        try container.encode(version, forKey: .version)
        try container.encode(isDraft, forKey: .isDraft)
        try container.encode(isPrerelease, forKey: .isPrerelease)
        try container.encode(assets, forKey: .assets)
    }
}

public enum ReleaseSelector {
    public static func latest(
        channel: UpdateChannel,
        releases: [ReleaseCandidate]
    ) throws -> ReleaseCandidate {
        if case .unsupported(let value) = channel {
            throw OpenGrokUpdateError.unsupportedChannel(value)
        }
        let candidates = releases.filter { release in
            guard !release.isDraft else { return false }
            let hasPrerelease = release.isPrerelease
                || ((try? SemVerVersion.parse(release.version))?.hasPrerelease == true)
            switch channel {
            case .stable, .enterprise:
                return !hasPrerelease
            case .alpha:
                return true
            case .unsupported:
                return false
            }
        }
        let sorted = candidates.sorted {
            guard
                let lhs = try? SemVerVersion.parse($0.version),
                let rhs = try? SemVerVersion.parse($1.version)
            else { return $0.version < $1.version }
            if lhs != rhs { return lhs > rhs }
            return $0.tagName < $1.tagName
        }
        if let result = sorted.first { return result }
        throw OpenGrokUpdateError.missingRelease("no non-draft release matches \(channel)")
    }

    public static func asset(
        named assetName: String,
        in release: ReleaseCandidate
    ) throws -> ReleaseAsset {
        guard let asset = release.assets.first(where: { $0.name == assetName }) else {
            throw OpenGrokUpdateError.missingRelease(
                "release \(release.tagName) does not contain asset \(assetName)"
            )
        }
        return asset
    }

    public static func resolvedVersion(
        channel: UpdateChannel,
        stable: String,
        alpha: String? = nil
    ) throws -> String {
        try ReleasePointers(stable: stable, alpha: alpha).resolvedVersion(for: channel)
    }
}

// MARK: - Version policy and eligibility

public struct VersionPolicy: Sendable, Equatable {
    public var minimum: SemVerVersion?
    public var maximum: SemVerVersion?
    public var requiredMinimum: SemVerVersion?
    public var requiredMaximum: SemVerVersion?

    public init(
        minimum: SemVerVersion? = nil,
        maximum: SemVerVersion? = nil,
        requiredMinimum: SemVerVersion? = nil,
        requiredMaximum: SemVerVersion? = nil
    ) {
        self.minimum = minimum
        self.maximum = maximum
        self.requiredMinimum = requiredMinimum
        self.requiredMaximum = requiredMaximum
    }

    public static func fromStrings(
        minimum: String? = nil,
        maximum: String? = nil,
        requiredMinimum: String? = nil,
        requiredMaximum: String? = nil
    ) throws -> VersionPolicy {
        VersionPolicy(
            minimum: try minimum.map { try SemVerVersion.parse(UpdateVersion.normalize($0)) },
            maximum: try maximum.map { try SemVerVersion.parse(UpdateVersion.normalize($0)) },
            requiredMinimum: try requiredMinimum.map { try SemVerVersion.parse(UpdateVersion.normalize($0)) },
            requiredMaximum: try requiredMaximum.map { try SemVerVersion.parse(UpdateVersion.normalize($0)) }
        )
    }

    public var hasContradictoryRequiredRange: Bool {
        if let requiredMinimum, let requiredMaximum { return requiredMinimum > requiredMaximum }
        return false
    }

    public func resolvedTarget(_ target: SemVerVersion) -> SemVerVersion? {
        var resolved = target
        if let maximum, resolved > maximum {
            resolved = maximum
        }
        if !hasContradictoryRequiredRange, let requiredMaximum, resolved > requiredMaximum {
            resolved = requiredMaximum
        }
        if !hasContradictoryRequiredRange,
           let requiredMinimum,
           !UpdateVersion.satisfiesFloor(resolved, requiredMinimum) {
            resolved = requiredMinimum
        }
        if let minimum, !UpdateVersion.satisfiesFloor(resolved, minimum) {
            return nil
        }
        return resolved
    }
}

public enum UpdateEligibility: Sendable, Equatable {
    case current
    case upgrade
    case prereleaseRecovery
    case rollback
    case rollbackRejected
    case invalidCurrentVersion
    case invalidTargetVersion
    case unsupportedChannel
    case stablePrereleaseRejected
    case belowMinimum
    case aboveMaximum
    case targetUnavailable

    public var shouldUpdate: Bool {
        switch self {
        case .upgrade, .prereleaseRecovery, .rollback: return true
        default: return false
        }
    }
}

public struct UpdateDecision: Sendable, Equatable {
    public let currentVersion: String
    public let targetVersion: String
    public let channel: UpdateChannel
    public let installer: UpdateInstaller
    public let eligibility: UpdateEligibility

    public init(
        currentVersion: String,
        targetVersion: String,
        channel: UpdateChannel,
        installer: UpdateInstaller,
        eligibility: UpdateEligibility
    ) {
        self.currentVersion = currentVersion
        self.targetVersion = targetVersion
        self.channel = channel
        self.installer = installer
        self.eligibility = eligibility
    }

    public var shouldUpdate: Bool { eligibility.shouldUpdate }
    public var isDowngrade: Bool { eligibility == .rollback }
}

public enum UpdatePlanner {
    public static func decide(
        current: String,
        target: String,
        channel: UpdateChannel,
        installer: UpdateInstaller,
        policy: VersionPolicy = VersionPolicy()
    ) -> UpdateDecision {
        let normalizedCurrent = (try? UpdateVersion.normalize(current)) ?? current
        let normalizedTarget = (try? UpdateVersion.normalize(target)) ?? target

        if case .unsupported = channel {
            return UpdateDecision(
                currentVersion: normalizedCurrent,
                targetVersion: normalizedTarget,
                channel: channel,
                installer: installer,
                eligibility: .unsupportedChannel
            )
        }

        guard let currentVersion = try? SemVerVersion.parse(normalizedCurrent) else {
            return UpdateDecision(
                currentVersion: normalizedCurrent,
                targetVersion: normalizedTarget,
                channel: channel,
                installer: installer,
                eligibility: .invalidCurrentVersion
            )
        }
        var targetVersion: SemVerVersion
        if let parsedTarget = try? SemVerVersion.parse(normalizedTarget) {
            targetVersion = parsedTarget
        } else {
            guard !policy.hasContradictoryRequiredRange,
                  let requiredMinimum = policy.requiredMinimum else {
                return UpdateDecision(
                    currentVersion: normalizedCurrent,
                    targetVersion: normalizedTarget,
                    channel: channel,
                    installer: installer,
                    eligibility: .invalidTargetVersion
                )
            }
            targetVersion = requiredMinimum
        }

        guard let resolvedTarget = policy.resolvedTarget(targetVersion) else {
            return UpdateDecision(
                currentVersion: normalizedCurrent,
                targetVersion: targetVersion.description,
                channel: channel,
                installer: installer,
                eligibility: .belowMinimum
            )
        }
        targetVersion = resolvedTarget

        if channel.rejectsUnrecognizedPrereleases,
           targetVersion.hasPrerelease,
           !UpdateVersion.isOpenGrokPrerelease(targetVersion) {
            return UpdateDecision(
                currentVersion: normalizedCurrent,
                targetVersion: normalizedTarget,
                channel: channel,
                installer: installer,
                eligibility: .stablePrereleaseRejected
            )
        }

        if channel.rejectsUnrecognizedPrereleases,
           currentVersion.hasPrerelease,
           !UpdateVersion.isOpenGrokPrerelease(currentVersion) {
            return UpdateDecision(
                currentVersion: normalizedCurrent,
                targetVersion: targetVersion.description,
                channel: channel,
                installer: installer,
                eligibility: .prereleaseRecovery
            )
        }

        if targetVersion == currentVersion {
            return UpdateDecision(
                currentVersion: normalizedCurrent,
                targetVersion: targetVersion.description,
                channel: channel,
                installer: installer,
                eligibility: .current
            )
        }
        if targetVersion > currentVersion {
            return UpdateDecision(
                currentVersion: normalizedCurrent,
                targetVersion: targetVersion.description,
                channel: channel,
                installer: installer,
                eligibility: .upgrade
            )
        }

        if installer.allowsDowngrade {
            return UpdateDecision(
                currentVersion: normalizedCurrent,
                targetVersion: targetVersion.description,
                channel: channel,
                installer: installer,
                eligibility: .rollback
            )
        }
        return UpdateDecision(
            currentVersion: normalizedCurrent,
            targetVersion: targetVersion.description,
            channel: channel,
            installer: installer,
            eligibility: .rollbackRejected
        )
    }
}

// MARK: - Machine-readable status

public struct UpdateStatus: Sendable, Equatable, Codable {
    public let currentVersion: String
    public let latestVersion: String?
    public let updateAvailable: Bool
    public let installer: String?
    public let channel: String
    public let autoUpdate: Bool?
    public let error: String?

    public init(
        currentVersion: String,
        latestVersion: String?,
        updateAvailable: Bool,
        installer: String?,
        channel: String,
        autoUpdate: Bool?,
        error: String?
    ) {
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.updateAvailable = updateAvailable
        self.installer = installer
        self.channel = channel
        self.autoUpdate = autoUpdate
        self.error = error
    }

    public init(decision: UpdateDecision, autoUpdate: Bool? = nil, error: String? = nil) {
        self.init(
            currentVersion: decision.currentVersion,
            latestVersion: decision.targetVersion,
            updateAvailable: decision.shouldUpdate,
            installer: decision.installer.rawValue,
            channel: decision.channel.rawValue,
            autoUpdate: autoUpdate,
            error: error
        )
    }

    private enum CodingKeys: String, CodingKey {
        case currentVersion, latestVersion, updateAvailable, installer, channel, autoUpdate, error
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currentVersion, forKey: .currentVersion)
        try container.encode(latestVersion, forKey: .latestVersion)
        try container.encode(updateAvailable, forKey: .updateAvailable)
        try container.encode(installer, forKey: .installer)
        try container.encode(channel, forKey: .channel)
        try container.encode(autoUpdate, forKey: .autoUpdate)
        try container.encode(error, forKey: .error)
    }
}

// MARK: - Cached check state

public struct VersionCacheEntry: Sendable, Equatable, Codable {
    public let version: String
    public let stableVersion: String?
    public let checkedAt: String

    public init(version: String, stableVersion: String? = nil, checkedAt: String) {
        self.version = version
        self.stableVersion = stableVersion
        self.checkedAt = checkedAt
    }

    public init(version: String, stableVersion: String? = nil, checkedAt: Date) {
        self.init(
            version: version,
            stableVersion: stableVersion,
            checkedAt: UpdateDateCoding.string(from: checkedAt)
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawVersion = try container.decode(String.self, forKey: .version)
        let rawStableVersion = try container.decodeIfPresent(String.self, forKey: .stableVersion)
        do {
            self.version = try UpdateVersion.normalize(rawVersion)
            self.stableVersion = try rawStableVersion.map(UpdateVersion.normalize)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "cached Open Grok version is not valid semver"
            )
        }
        self.checkedAt = try container.decode(String.self, forKey: .checkedAt)
    }

    public func isFresh(at now: Date, ttl: TimeInterval = OpenGrokUpdateConstants.defaultCacheTTL) -> Bool {
        guard ttl > 0, let checkedDate = UpdateDateCoding.date(from: checkedAt) else { return false }
        guard checkedDate <= now else { return false }
        return now.timeIntervalSince(checkedDate) < ttl
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case stableVersion = "stable_version"
        case checkedAt = "checked_at"
    }
}

private enum UpdateDateCoding {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

public actor VersionCacheStore {
    public let cacheURL: URL
    private let fileManager: FileManager

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.cacheURL = OpenGrokStatePaths.stateDirectory(environment: environment)
            .appendingPathComponent(OpenGrokUpdateConstants.versionCacheFileName)
        self.fileManager = FileManager.default
    }

    public func load() throws -> VersionCacheEntry? {
        guard fileManager.fileExists(atPath: cacheURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: cacheURL)
            return try JSONDecoder().decode(VersionCacheEntry.self, from: data)
        } catch {
            throw OpenGrokUpdateError.invalidCache(error.localizedDescription)
        }
    }

    public func isFresh(
        at now: Date = Date(),
        ttl: TimeInterval = OpenGrokUpdateConstants.defaultCacheTTL
    ) -> Bool {
        do {
            return try load()?.isFresh(at: now, ttl: ttl) == true
        } catch {
            return false
        }
    }

    public func save(_ entry: VersionCacheEntry) throws {
        do {
            try fileManager.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entry)
            let temporaryURL = cacheURL.appendingPathExtension("tmp")
            defer { try? fileManager.removeItem(at: temporaryURL) }
            try data.write(to: temporaryURL, options: .atomic)
            try atomicallyReplaceItem(at: cacheURL, with: temporaryURL)
        } catch let error as OpenGrokUpdateError {
            throw error
        } catch {
            throw OpenGrokUpdateError.cacheIO(error.localizedDescription)
        }
    }

    public func record(
        version: String,
        stableVersion: String? = nil,
        checkedAt: Date = Date()
    ) throws {
        let normalized = try UpdateVersion.normalize(version)
        let stable = try stableVersion.map(UpdateVersion.normalize)
        try save(VersionCacheEntry(version: normalized, stableVersion: stable, checkedAt: checkedAt))
    }
}

public func writeVersionCache(
    version: String,
    stableVersion: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    checkedAt: Date = Date()
) async throws {
    let store = VersionCacheStore(environment: environment)
    try await store.record(version: version, stableVersion: stableVersion, checkedAt: checkedAt)
}

public func isVersionCacheFresh(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    now: Date = Date(),
    ttl: TimeInterval = OpenGrokUpdateConstants.defaultCacheTTL
) async -> Bool {
    let store = VersionCacheStore(environment: environment)
    return await store.isFresh(at: now, ttl: ttl)
}

// MARK: - Artifact integrity and release assets

public enum ChecksumAlgorithm: String, Sendable, Equatable, Hashable {
    case sha256 = "SHA-256"
}

public struct ChecksumExpectation: Sendable, Equatable, Hashable {
    public let algorithm: ChecksumAlgorithm
    public let digest: String
    public let assetName: String

    public init(digest: String, assetName: String, algorithm: ChecksumAlgorithm = .sha256) throws {
        let normalized = digest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 64, normalized.unicodeScalars.allSatisfy(UpdateChecksum.isHexScalar) else {
            throw OpenGrokUpdateError.invalidChecksum("digest must contain exactly 64 hexadecimal characters")
        }
        self.algorithm = algorithm
        self.digest = normalized
        self.assetName = assetName
    }
}

public enum UpdateChecksum {
    public static func parsePublishedChecksum(
        _ contents: String,
        expectedAsset: String
    ) throws -> ChecksumExpectation {
        guard let line = contents.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else {
            throw OpenGrokUpdateError.invalidChecksum("checksum file is empty")
        }

        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let digest = parts.first else {
            throw OpenGrokUpdateError.invalidChecksum("checksum file has no digest")
        }
        let digestString = String(digest)
        guard digestString.count == 64, digestString.unicodeScalars.allSatisfy(isHexScalar) else {
            throw OpenGrokUpdateError.invalidChecksum("digest is malformed")
        }
        if parts.count > 1 {
            let actualAsset = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            guard actualAsset == expectedAsset else {
                throw OpenGrokUpdateError.checksumAssetMismatch(expected: expectedAsset, actual: actualAsset)
            }
        }
        return try ChecksumExpectation(digest: digestString, assetName: expectedAsset)
    }

    fileprivate static func isHexScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...70, 97...102: return true
        default: return false
        }
    }
}

public enum SignatureRequirement: Sendable, Equatable, Hashable {
    case notRequired
    case required(keyID: String)
}

public struct SignatureVerificationPlan: Sendable, Equatable, Hashable {
    public let requirement: SignatureRequirement
    public let signatureURL: URL?

    public init(requirement: SignatureRequirement, signatureURL: URL?) throws {
        if case .required(let keyID) = requirement,
           (keyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || signatureURL == nil) {
            throw OpenGrokUpdateError.missingSignature("release asset")
        }
        self.requirement = requirement
        self.signatureURL = signatureURL
    }
}

public struct ArtifactVerificationPlan: Sendable, Equatable, Hashable {
    public let asset: ReleaseAsset
    public let checksum: ChecksumExpectation
    public let signature: SignatureVerificationPlan

    /// This target only produces a verification plan. A later installer must
    /// verify the checksum/signature before activation; no bytes are written by
    /// this initializer.
    public init(
        asset: ReleaseAsset,
        publishedChecksum: String,
        signature: SignatureRequirement = .notRequired
    ) throws {
        guard Self.isSecureRemoteURL(asset.downloadURL),
              asset.checksumURL.map(Self.isSecureRemoteURL) ?? true,
              asset.signatureURL.map(Self.isSecureRemoteURL) ?? true else {
            throw OpenGrokUpdateError.invalidPlanningRequest(
                "release artifact metadata must use HTTPS URLs"
            )
        }
        self.asset = asset
        self.checksum = try UpdateChecksum.parsePublishedChecksum(
            publishedChecksum,
            expectedAsset: asset.name
        )
        self.signature = try SignatureVerificationPlan(
            requirement: signature,
            signatureURL: asset.signatureURL
        )
    }

    private static func isSecureRemoteURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil
    }
}

public struct UpdateInstallPlan: Sendable, Equatable {
    public let targetVersion: String
    public let installer: UpdateInstaller
    public let artifact: ArtifactVerificationPlan
    public let destinationURL: URL?
    public let requiresExternalActivation: Bool

    public init(
        decision: UpdateDecision,
        artifact: ArtifactVerificationPlan,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard decision.shouldUpdate else {
            throw OpenGrokUpdateError.invalidPlanningRequest("decision does not authorize an update")
        }
        self.targetVersion = decision.targetVersion
        self.installer = decision.installer
        self.artifact = artifact
        self.destinationURL = decision.installer == .npm
            ? nil
            : OpenGrokStatePaths.managedBinaryURL(environment: environment)
        self.requiresExternalActivation = true
    }
}

// MARK: - Platform asset naming

public struct ReleasePlatform: Sendable, Equatable, Hashable {
    public let operatingSystem: String
    public let architecture: String

    public init(operatingSystem: String, architecture: String) {
        self.operatingSystem = operatingSystem
        self.architecture = architecture
    }

    public static var current: ReleasePlatform {
        #if os(macOS)
        let os = "macos"
        #elseif os(Linux)
        let os = "linux"
        #elseif os(Windows)
        let os = "windows"
        #else
        let os = "unknown"
        #endif

        #if arch(arm64)
        let architecture = "aarch64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return ReleasePlatform(operatingSystem: os, architecture: architecture)
    }

    public var assetName: String {
        let suffix = operatingSystem == "windows" ? ".exe" : ""
        return "open-grok-\(operatingSystem)-\(architecture)\(suffix)"
    }
}
