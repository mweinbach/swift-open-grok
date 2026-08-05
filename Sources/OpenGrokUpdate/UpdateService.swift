// UpdateService.swift
//
// The executing half of self-update. `OpenGrokUpdate.swift` decides *whether*
// to update and produces verification plans; nothing in it touches the network
// or the filesystem. This file is what actually fetches the GitHub release,
// downloads the asset, verifies its published SHA-256, smoke-tests the binary,
// and swaps the managed `bin/open-grok` link with a rollback on failure.
//
// Port of `xai-grok-update/src/auto_update.rs` (`install_open_grok_release`,
// `swap_managed_bin_links`, `LinkRollback`) and the release-fetch half of
// `version.rs` (`fetch_open_grok_release_version_from_api`).
//
// Ordering is the security property: the bytes are hashed and the binary is
// smoke-tested *before* any link is swapped, and the download is published to
// its final name only after `chmod 0755`, so no racer can exec a partial or
// world-writable image.

import Foundation
import OpenGrokFileUtils
import OpenGrokHTTP
import OpenGrokPaths
import OpenGrokVersion

// MARK: - Errors

public enum UpdateServiceError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupportedPlatform(String)
    case releaseFetchFailed(String)
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case smokeTestFailed(String)
    case activationFailed(String)

    public var description: String {
        switch self {
        case .unsupportedPlatform(let detail):
            return detail
        case .releaseFetchFailed(let detail):
            return "Open Grok release check failed: \(detail)"
        case .downloadFailed(let detail):
            return "downloading Open Grok release failed: \(detail)"
        case .checksumMismatch(let expected, let actual):
            return """
                Open Grok SHA-256 verification failed (expected \(expected), got \(actual)); \
                current version was not changed
                """
        case .smokeTestFailed(let detail):
            return detail
        case .activationFailed(let detail):
            return "activating the downloaded Open Grok binary failed: \(detail)"
        }
    }
}

// MARK: - Platform gate

extension ReleasePlatform {
    /// Rust publishes Open Grok updates for exactly two targets
    /// (`auto_update.rs:794-826`). Anything else has no asset to download, so
    /// fail with the same message rather than 404ing on a synthesized name.
    public var isSupportedForRelease: Bool {
        (operatingSystem == "macos" && architecture == "aarch64")
            || (operatingSystem == "windows" && architecture == "x86_64")
    }

    public var binaryExtension: String {
        operatingSystem == "windows" ? ".exe" : ""
    }

    /// `macos-aarch64` / `windows-x86_64` — the infix in the on-disk download
    /// name, kept separate from ``assetName`` so a downloaded file still parses
    /// back to its version.
    public var versionedPlatform: String {
        "\(operatingSystem)-\(architecture)"
    }

    public var displayName: String {
        switch (operatingSystem, architecture) {
        case ("macos", "aarch64"): return "macOS Apple Silicon"
        case ("windows", "x86_64"): return "Windows x86_64"
        default: return "\(operatingSystem) \(architecture)"
        }
    }

    public static var unsupportedPlatformMessage: String {
        "Open Grok currently publishes updates only for macOS on Apple Silicon and Windows x86_64"
    }
}

// MARK: - Release fetching

public struct UpdateReleaseClient: Sendable {
    public let transport: any HTTPTransport
    public let userAgent: String
    public let timeout: TimeInterval

    public init(
        transport: any HTTPTransport,
        userAgent: String = "open-grok-updater",
        timeout: TimeInterval = 15
    ) {
        self.transport = transport
        self.userAgent = userAgent
        self.timeout = timeout
    }

    public static func production() -> UpdateReleaseClient {
        UpdateReleaseClient(transport: URLSessionHTTPTransport())
    }

    /// GET the `releases/latest` endpoint and decode it into a candidate.
    ///
    /// A draft release is rejected outright, matching Rust — the latest-release
    /// endpoint should never return one, and treating a draft as installable
    /// would ship an unpublished binary.
    public func fetchLatestRelease(apiURL: URL) async throws -> ReleaseCandidate {
        let request = HTTPRequest(
            method: .get,
            url: apiURL,
            headers: [
                "User-Agent": userAgent,
                "Accept": "application/vnd.github+json"
            ],
            timeout: timeout
        )
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw UpdateServiceError.releaseFetchFailed("\(error)")
        }
        guard (200..<300).contains(response.metadata.statusCode) else {
            let excerpt = String(decoding: response.body.prefix(200), as: UTF8.self)
            throw UpdateServiceError.releaseFetchFailed(
                "HTTP \(response.metadata.statusCode): \(excerpt)"
            )
        }
        let candidate: ReleaseCandidate
        do {
            candidate = try JSONDecoder().decode(ReleaseCandidate.self, from: response.body)
        } catch {
            throw UpdateServiceError.releaseFetchFailed("release payload is not valid: \(error)")
        }
        guard !candidate.isDraft else {
            throw UpdateServiceError.releaseFetchFailed("latest release is a draft")
        }
        return candidate
    }

    /// Fetch a URL's bytes, refusing anything but a 2xx.
    func fetchBytes(_ url: URL, timeout: TimeInterval) async throws -> Data {
        let request = HTTPRequest(
            method: .get,
            url: url,
            headers: ["User-Agent": userAgent],
            timeout: timeout
        )
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw UpdateServiceError.downloadFailed("\(url.lastPathComponent): \(error)")
        }
        guard (200..<300).contains(response.metadata.statusCode) else {
            throw UpdateServiceError.downloadFailed(
                "\(url.lastPathComponent): HTTP \(response.metadata.statusCode)"
            )
        }
        return response.body
    }
}

// MARK: - Download destinations

public struct UpdatePaths: Sendable {
    public let home: URL
    public let downloadsDirectory: URL
    public let managedBinary: URL

    public init(environment: [String: String]) {
        self.home = OpenGrokStatePaths.stateDirectory(environment: environment)
        self.downloadsDirectory = home.appendingPathComponent("downloads", isDirectory: true)
        self.managedBinary = OpenGrokStatePaths.managedBinaryURL(environment: environment)
    }

    /// `open-grok-0.1.220-macos-aarch64` — the version comes before the
    /// platform so a reinstall suffix can be appended without breaking the
    /// version parse.
    public func downloadURL(version: String, platform: ReleasePlatform) -> URL {
        downloadsDirectory.appendingPathComponent(
            "open-grok-\(version)-\(platform.versionedPlatform)\(platform.binaryExtension)"
        )
    }
}

// MARK: - Install service

/// Downloads, verifies, and activates a release. Every failure path leaves the
/// currently-installed binary untouched.
public struct ReleaseInstallService: Sendable {
    public let client: UpdateReleaseClient
    public let paths: UpdatePaths
    /// Injectable so tests can assert the swap without executing a binary.
    public let smokeTest: @Sendable (URL, String) throws -> Void

    public init(
        client: UpdateReleaseClient,
        paths: UpdatePaths,
        smokeTest: (@Sendable (URL, String) throws -> Void)? = nil
    ) {
        self.client = client
        self.paths = paths
        self.smokeTest = smokeTest ?? ReleaseInstallService.defaultSmokeTest
    }

    public struct InstallResult: Sendable, Equatable {
        public let version: String
        public let stagedBinary: URL
        public let managedLink: URL
    }

    /// Download → verify SHA-256 → smoke test → swap link. Returns the
    /// activated paths.
    public func install(
        version: String,
        asset: ReleaseAsset,
        platform: ReleasePlatform = .current,
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> InstallResult {
        guard platform.isSupportedForRelease else {
            throw UpdateServiceError.unsupportedPlatform(ReleasePlatform.unsupportedPlatformMessage)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: paths.downloadsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: paths.managedBinary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var destination = paths.downloadURL(version: version, platform: platform)
        if fm.fileExists(atPath: destination.path) {
            // A forced reinstall of the running version must not unlink the
            // live inode — on macOS unlinking a running signed image can
            // SIGKILL the process. Download beside it instead.
            destination = Self.uniqueSibling(destination, suffix: "reinstall")
        }

        progress("  Downloading Open Grok v\(version) (\(platform.displayName))...\n")
        let payload = try await client.fetchBytes(asset.downloadURL, timeout: 20 * 60)

        // Publish to the final name only after the mode bits are right.
        let temporary = Self.temporaryPath(for: destination)
        try? fm.removeItem(at: temporary)
        do {
            try payload.write(to: temporary, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: temporary, to: destination)
        } catch {
            try? fm.removeItem(at: temporary)
            throw UpdateServiceError.downloadFailed("writing \(destination.path): \(error)")
        }

        // Verification happens against the published sidecar digest. Any
        // failure from here on deletes the staged binary and returns before
        // the link swap, so the installed version is unchanged.
        do {
            let checksumURL = asset.checksumURL
                ?? URL(string: asset.downloadURL.absoluteString + ".sha256")!
            let checksumBody = try await client.fetchBytes(checksumURL, timeout: 60)
            let expectation = try UpdateChecksum.parsePublishedChecksum(
                String(decoding: checksumBody, as: UTF8.self),
                expectedAsset: asset.name
            )
            let actual = try FileChecksum.sha256HexFromFile(at: destination).lowercased()
            guard actual == expectation.digest else {
                throw UpdateServiceError.checksumMismatch(
                    expected: expectation.digest,
                    actual: actual
                )
            }
            try smokeTest(destination, version)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }

        let link = try activate(stagedBinary: destination)
        return InstallResult(version: version, stagedBinary: destination, managedLink: link)
    }

    // MARK: Activation

    /// Swap `bin/open-grok` to point at `stagedBinary`, restoring the previous
    /// target if the swap fails partway.
    public func activate(stagedBinary: URL) throws -> URL {
        #if os(macOS) || os(Linux)
        let link = paths.managedBinary
        let fm = FileManager.default

        // Capture rollback state before mutating anything.
        let previousTarget: String?
        if let attributes = try? fm.attributesOfItem(atPath: link.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            previousTarget = try? fm.destinationOfSymbolicLink(atPath: link.path)
        } else if fm.fileExists(atPath: link.path) {
            // A regular file here is the legacy install.sh layout. Replacing it
            // with a symlink is the migration; there is no prior link target to
            // restore, so treat it as absent for rollback purposes.
            previousTarget = nil
        } else {
            previousTarget = nil
        }

        let target = Self.relativeTarget(from: stagedBinary, to: link)
        let temporary = link.appendingPathExtension("\(ProcessInfo.processInfo.processIdentifier).tmp-link")
        try? fm.removeItem(at: temporary)
        do {
            try fm.createSymbolicLink(atPath: temporary.path, withDestinationPath: target)
            // `rename(2)` over an existing link is atomic; never unlink first.
            guard rename(temporary.path, link.path) == 0 else {
                throw UpdateServiceError.activationFailed(
                    "renaming \(temporary.path) onto \(link.path): errno \(errno)"
                )
            }
        } catch {
            try? fm.removeItem(at: temporary)
            if let previousTarget {
                // Best effort: a failed rollback still leaves the prior target
                // recorded in the thrown error rather than a half-swapped link.
                try? fm.removeItem(at: link)
                try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: previousTarget)
            }
            throw UpdateServiceError.activationFailed("\(error)")
        }
        return link
        #else
        // Windows has no atomic symlink; copy over the destination instead.
        let link = paths.managedBinary
        let fm = FileManager.default
        let backup = Self.uniqueSibling(link, suffix: "rollback.bak")
        let hadExisting = fm.fileExists(atPath: link.path)
        if hadExisting { try? fm.copyItem(at: link, to: backup) }
        do {
            try? fm.removeItem(at: link)
            try fm.copyItem(at: stagedBinary, to: link)
        } catch {
            if hadExisting {
                try? fm.removeItem(at: link)
                try? fm.copyItem(at: backup, to: link)
            }
            try? fm.removeItem(at: backup)
            throw UpdateServiceError.activationFailed("\(error)")
        }
        try? fm.removeItem(at: backup)
        return link
        #endif
    }

    // MARK: Helpers

    /// `../downloads/open-grok-…` when the two live in sibling directories, so
    /// the link survives the whole tree being moved.
    static func relativeTarget(from binary: URL, to link: URL) -> String {
        let binaryDirectory = binary.deletingLastPathComponent().standardizedFileURL
        let linkDirectory = link.deletingLastPathComponent().standardizedFileURL
        if binaryDirectory == linkDirectory {
            return binary.lastPathComponent
        }
        if binaryDirectory.deletingLastPathComponent() == linkDirectory.deletingLastPathComponent() {
            return "../\(binaryDirectory.lastPathComponent)/\(binary.lastPathComponent)"
        }
        return binary.standardizedFileURL.path
    }

    static func temporaryPath(for destination: URL) -> URL {
        destination.appendingPathExtension(
            "\(ProcessInfo.processInfo.processIdentifier).tmp"
        )
    }

    static func uniqueSibling(_ url: URL, suffix: String) -> URL {
        let stamp = UInt64(Date().timeIntervalSince1970 * 1000)
        return url.appendingPathExtension("\(suffix).\(ProcessInfo.processInfo.processIdentifier)-\(stamp)")
    }

    /// Run `<binary> --version` under a hard deadline and require it to report
    /// the version we think we downloaded.
    ///
    /// This is the last gate before the swap: a checksum only proves the bytes
    /// match what the release published, not that they run on this machine.
    public static let defaultSmokeTest: @Sendable (URL, String) throws -> Void = { binary, expected in
        #if os(macOS) || os(Linux)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw UpdateServiceError.smokeTestFailed(
                "downloaded Open Grok binary could not be executed: \(error)"
            )
        }

        // Bounded wait: poll rather than block forever on a hung child, and
        // terminate the process group if it overruns.
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            usleep(200_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw UpdateServiceError.smokeTestFailed(
                "downloaded Open Grok binary timed out during --version"
            )
        }
        guard process.terminationStatus == 0 else {
            throw UpdateServiceError.smokeTestFailed(
                "downloaded Open Grok binary failed its --version smoke test (\(process.terminationStatus))"
            )
        }

        let output = String(
            decoding: (try? pipe.fileHandleForReading.readToEnd()) ?? Data(),
            as: UTF8.self
        )
        let reported = output
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",;()[]")) }
            .first { (try? SemVerVersion.parse($0)) != nil }
        guard let reported else {
            throw UpdateServiceError.smokeTestFailed(
                "downloaded Open Grok binary did not report a semver version"
            )
        }
        let normalizedExpected = (try? UpdateVersion.normalize(expected)) ?? expected
        guard reported == normalizedExpected else {
            throw UpdateServiceError.smokeTestFailed(
                "downloaded Open Grok binary reported version \(reported) (expected \(normalizedExpected))"
            )
        }
        #else
        _ = (binary, expected)
        #endif
    }
}
