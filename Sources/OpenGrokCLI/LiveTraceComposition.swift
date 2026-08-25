import Foundation
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokShellSessionSupport

private struct LiveTraceResult: Encodable {
    let sessionID: String
    let status: String
    let url: String?
    let localPath: String?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case status
        case url
        case localPath = "local_path"
        case error
    }
}

private struct LiveTraceExportMetadata: Encodable {
    let sessionID: String
    let grokVersion: String
    let operatingSystem: String
    let architecture: String
    let exportedAt: String
    let memoryTraceFiles: Int

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case grokVersion = "grok_version"
        case operatingSystem = "os"
        case architecture = "arch"
        case exportedAt = "exported_at"
        case memoryTraceFiles = "memtrace_files"
    }
}

/// Endpoint values never enter the archive: Rust exports only booleans and
/// source labels because deployment keys, bucket names, and URLs are secrets.
private struct LiveTraceConfigSnapshot: Encodable {
    let traceUploadEnabled: Bool
    let telemetryTraceUpload: Bool?
    let customUploadURL: Bool
    let bucketURLSource: String
    let directUploadConfigured: Bool
    let hasBucketConfigured: Bool
    let hasRegionConfigured: Bool
    let hasCustomEndpoint: Bool
    let hasCredentialsFile: Bool
    let hasInlineCredentials: Bool
    let hasDeploymentKey: Bool

    private enum CodingKeys: String, CodingKey {
        case traceUploadEnabled = "trace_upload_enabled"
        case telemetryTraceUpload = "telemetry_trace_upload"
        case customUploadURL = "custom_upload_url"
        case bucketURLSource = "bucket_url_source"
        case directUploadConfigured = "direct_upload_configured"
        case hasBucketConfigured = "has_bucket_configured"
        case hasRegionConfigured = "has_region_configured"
        case hasCustomEndpoint = "has_custom_endpoint"
        case hasCredentialsFile = "has_credentials_file"
        case hasInlineCredentials = "has_inline_credentials"
        case hasDeploymentKey = "has_deployment_key"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(traceUploadEnabled, forKey: .traceUploadEnabled)
        try container.encode(telemetryTraceUpload, forKey: .telemetryTraceUpload)
        try container.encode(customUploadURL, forKey: .customUploadURL)
        try container.encode(bucketURLSource, forKey: .bucketURLSource)
        try container.encode(directUploadConfigured, forKey: .directUploadConfigured)
        try container.encode(hasBucketConfigured, forKey: .hasBucketConfigured)
        try container.encode(hasRegionConfigured, forKey: .hasRegionConfigured)
        try container.encode(hasCustomEndpoint, forKey: .hasCustomEndpoint)
        try container.encode(hasCredentialsFile, forKey: .hasCredentialsFile)
        try container.encode(hasInlineCredentials, forKey: .hasInlineCredentials)
        try container.encode(hasDeploymentKey, forKey: .hasDeploymentKey)
    }
}

private struct LiveMemoryTraceCandidate {
    let stem: String
    let name: String
    let url: URL
    let byteCount: Int
    let modifiedAt: Date
    let isAllocatorDump: Bool
    let dumpSequence: UInt64
}

/// Rust: `xai-grok-pager/src/trace_cmd.rs:35-73,80-153,351-534`.
/// Every remote path authorizes before constructing an archive; disabled
/// uploads retain Rust's local-export path.
public enum LiveTraceComposition {
    private static let maximumSessionFiles = 2_048
    private static let maximumSessionFileBytes = 16 * 1_024 * 1_024
    private static let maximumSessionBytes = 64 * 1_024 * 1_024
    private static let maximumMemoryTraceFiles = 32
    private static let maximumMemoryTraceBytes = 16 * 1_024 * 1_024
    private static let maximumDirectoryDepth = 32

    public static func handles(_ command: CLICommand) -> Bool {
        guard case .utility(let options) = command else { return false }
        return options.name == "trace"
    }

    public static func session(
        for command: CLICommand,
        context: CLIApplicationContext,
        services: LiveTraceUploadServices = .production
    ) throws -> CLIApplicationSession {
        guard case .utility(let options) = command, options.name == "trace" else {
            throw CLIApplicationError.unsupported(route: command.routeName)
        }
        return CLIApplicationSession(
            waitForExit: {
                try await run(
                    options: options,
                    environment: context.environment,
                    streams: context.streams,
                    services: services
                )
            },
            shutdown: {}
        )
    }

    public static func run(
        options: CLIUtilityOptions,
        environment: [String: String],
        streams: CLIStreams,
        services: LiveTraceUploadServices = .production
    ) async throws {
        guard options.values.count == 1, let sessionID = options.values.first else {
            throw CLIApplicationError.failed(
                "trace requires exactly one session id: "
                    + "open-grok trace <SESSION_ID> [--local] [-o PATH] [--json]"
            )
        }
        do {
            try LiveConversationStore.validateSessionID(sessionID)
        } catch {
            throw CLIApplicationError.failed("Invalid session ID '\(sessionID)'.")
        }

        let home = OpenGrokHomeResolver.resolve(environment: environment).standardizedFileURL
        let document = LiveManagedSetupComposition.trustedConfigDocument(environment: environment)
        let uploadEnabled = EffectiveFeatures.resolve(FeatureResolutionInputs(
            effectiveConfig: document,
            environment: environment
        )).traceUpload.value

        let uploadsRemotely = !options.isSet("--local") && uploadEnabled
        let authorization: LiveTraceUpload.Authorization?
        if uploadsRemotely {
            authorization = try await LiveTraceUpload.authorize(
                sessionID: sessionID,
                home: home,
                document: document,
                environment: environment,
                uploadEnabled: uploadEnabled
            )
        } else {
            authorization = nil
            if !options.isSet("--local"), !options.json {
                streams.err(
                    "Trace uploads disabled. Set [telemetry] trace_upload = true in "
                        + "\(home.appendingPathComponent("config.toml").path)\n"
                )
                streams.err("Falling back to local export.\n")
            }
        }

        let sessionDirectory = try findSessionDirectory(id: sessionID, home: home)
        if !options.json {
            streams.err("Found session at: \(sessionDirectory.path)\n")
            streams.err("Building session trace archive...\n")
        }

        var entries: [LiveTraceArchive.Entry] = []
        var totalSessionBytes = 0
        try appendSessionFiles(
            from: sessionDirectory,
            root: sessionDirectory,
            archivePrefix: sessionID,
            depth: 0,
            entries: &entries,
            totalBytes: &totalSessionBytes
        )

        let memoryTraces = collectMemoryTraces(home: home)
        entries.append(contentsOf: memoryTraces.map {
            LiveTraceArchive.Entry(
                path: "\(sessionID)/memtrace/\($0.name)",
                contents: $0.contents
            )
        })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        entries.append(LiveTraceArchive.Entry(
            path: "\(sessionID)/trace_config.json",
            contents: try encoder.encode(configSnapshot(
                document: document,
                environment: environment,
                uploadEnabled: uploadEnabled
            ))
        ))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let metadata = LiveTraceExportMetadata(
            sessionID: sessionID,
            grokVersion: OpenGrokCLIVersion.installedWithCommit(environment: environment),
            operatingSystem: operatingSystem,
            architecture: architecture,
            exportedAt: formatter.string(from: Date()),
            memoryTraceFiles: memoryTraces.count
        )
        entries.append(LiveTraceArchive.Entry(
            path: "\(sessionID)/export_metadata.json",
            contents: try encoder.encode(metadata)
        ))

        let archive = try LiveTraceArchive.make(entries: entries)
        let destination = outputPath(
            options.options["--output"],
            sessionID: sessionID,
            home: home,
            environment: environment
        )

        if let authorization {
            if !options.json {
                streams.err("Uploading session trace (\(archive.count / 1_024) KB)...\n")
            }

            let uploadedURL: String
            let retryNotice: (@Sendable (TimeInterval) -> Void)?
            if options.json {
                retryNotice = nil
            } else {
                retryNotice = { seconds in
                    streams.err("  Upload failed, retrying in \(Int(seconds))s...\n")
                }
            }
            do {
                uploadedURL = try await LiveTraceUpload.upload(
                    sessionID: sessionID,
                    archive: archive,
                    initialAuthorization: authorization,
                    home: home,
                    document: document,
                    environment: environment,
                    uploadEnabled: uploadEnabled,
                    services: services,
                    retryNotice: retryNotice
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let failure = LiveTraceUpload.failureMessage(error)
                try writeArchive(archive, to: destination)
                let logPath = try writeUploadFailureLog(
                    sessionID: sessionID,
                    archiveSize: archive.count,
                    failure: failure,
                    home: home,
                    environment: environment
                )

                if options.json {
                    try emitResult(
                        LiveTraceResult(
                            sessionID: sessionID,
                            status: "failed",
                            url: nil,
                            localPath: destination.path,
                            error: failure
                        ),
                        streams: streams
                    )
                } else {
                    streams.err("\nTrace upload failed: \(failure)\n")
                    streams.err("  Bundle: \(destination.path)\n")
                    streams.err("  Log:    \(logPath.path)\n")
                    streams.err("  Retry:  open-grok trace \(sessionID)\n")
                    streams.out(destination.path + "\n")
                }
                throw CLIApplicationError.failed("Trace upload failed for session \(sessionID)")
            }

            if options.json {
                try emitResult(
                    LiveTraceResult(
                        sessionID: sessionID,
                        status: "uploaded",
                        url: uploadedURL,
                        localPath: nil,
                        error: nil
                    ),
                    streams: streams
                )
            } else {
                streams.err("\nSession trace uploaded successfully.\n")
                streams.err("  \(uploadedURL)\n")
                streams.out(uploadedURL + "\n")
            }
            return
        }

        try writeArchive(archive, to: destination)

        if options.json {
            try emitResult(
                LiveTraceResult(
                    sessionID: sessionID,
                    status: "exported",
                    url: nil,
                    localPath: destination.path,
                    error: nil
                ),
                streams: streams
            )
        } else {
            streams.err("Session trace exported (\(archive.count / 1_024) KB):\n")
            streams.err("  \(destination.path)\n")
            streams.out(destination.path + "\n")
        }
    }

    private static func writeArchive(_ archive: Data, to destination: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try rejectSymbolicLinkDestination(destination)
            try SecureFile.write(at: destination, contents: archive)
        } catch {
            throw CLIApplicationError.failed(
                "Failed to securely write trace archive \(destination.path): \(error)"
            )
        }
    }

    private static func emitResult(_ result: LiveTraceResult, streams: CLIStreams) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(result)
        streams.out(String(decoding: encoded, as: UTF8.self) + "\n")
    }

    private static func writeUploadFailureLog(
        sessionID: String,
        archiveSize: Int,
        failure: String,
        home: URL,
        environment: [String: String]
    ) throws -> URL {
        let directory = home.appendingPathComponent("trace-exports", isDirectory: true)
        let destination = directory.appendingPathComponent("\(sessionID).upload.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let contents = """
        Trace upload debug log
        ======================
        Timestamp:         \(timestamp)
        Open Grok version: \(OpenGrokCLIVersion.installedWithCommit(environment: environment))
        OS:                \(operatingSystem) \(architecture)
        Session ID:        \(sessionID)
        Archive size:      \(archiveSize) bytes
        Object path:       \(sessionID)/trace_export.tar.gz
        Upload method:     authenticated storage proxy

        Error:
          \(failure)

        """
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try rejectSymbolicLinkDestination(destination)
            try SecureFile.write(at: destination, contents: Data(contents.utf8))
        } catch {
            throw CLIApplicationError.failed(
                "Trace upload failed and its private diagnostic log could not be saved."
            )
        }
        return destination
    }

    private static func findSessionDirectory(id: String, home: URL) throws -> URL {
        let store = SessionDocumentStore(grokHome: home)
        let state: PersistedSessionState
        do {
            guard let saved = try store.load(sessionID: id) else {
                throw CLIApplicationError.failed(
                    "Session '\(id)' not found under "
                        + "\(home.appendingPathComponent("sessions").path)"
                )
            }
            state = saved
        } catch let error as CLIApplicationError {
            throw error
        } catch {
            throw CLIApplicationError.failed("Session '\(id)' could not be read safely: \(error)")
        }

        let directory = try store.sessionDirectory(sessionID: id, cwd: state.summary.cwd)
        guard try isRealDirectory(directory) else {
            throw CLIApplicationError.failed("Session '\(id)' is not a real private directory.")
        }
        return directory
    }

    private static func appendSessionFiles(
        from directory: URL,
        root: URL,
        archivePrefix: String,
        depth: Int,
        entries: inout [LiveTraceArchive.Entry],
        totalBytes: inout Int
    ) throws {
        guard depth <= maximumDirectoryDepth else {
            throw CLIApplicationError.failed("Session trace exceeds the maximum directory depth.")
        }
        let children = try directoryContents(directory).sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }

        for child in children {
            let relative = "\(archivePrefix)/\(child.lastPathComponent)"
            #if os(Windows)
            guard let values = try WindowsSecurePath.metadata(at: child),
                  !values.isReparsePoint
            else {
                throw CLIApplicationError.failed(
                    "Session trace contains an unsafe symbolic link or reparse point."
                )
            }
            let isDirectory = values.isDirectory
            #else
            let values = try child.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true,
                  isStrictDescendant(child.resolvingSymlinksInPath(), of: root)
            else {
                throw CLIApplicationError.failed("Session trace contains an unsafe symbolic link.")
            }
            let isDirectory = values.isDirectory == true
            guard isDirectory || values.isRegularFile == true else { continue }
            #endif

            if isDirectory {
                try appendSessionFiles(
                    from: child,
                    root: root,
                    archivePrefix: relative,
                    depth: depth + 1,
                    entries: &entries,
                    totalBytes: &totalBytes
                )
                continue
            }

            guard entries.count < maximumSessionFiles else {
                throw CLIApplicationError.failed("Session trace exceeds the maximum file count.")
            }
            let contents: Data
            do {
                contents = try PathSecurity.readNoFollow(
                    child,
                    maximumBytes: maximumSessionFileBytes,
                    requireOwnerOnly: true
                )
            } catch {
                throw CLIApplicationError.failed(
                    "Session trace contains an unsafe or oversized private file: \(error)"
                )
            }
            let (updated, overflow) = totalBytes.addingReportingOverflow(contents.count)
            guard !overflow, updated <= maximumSessionBytes else {
                throw CLIApplicationError.failed("Session trace exceeds the maximum archive size.")
            }
            totalBytes = updated
            entries.append(LiveTraceArchive.Entry(path: relative, contents: contents))
        }
    }

    private static func directoryContents(_ directory: URL) throws -> [URL] {
        #if os(Windows)
        return try WindowsSecurePath.contentsOfDirectory(
            at: directory,
            maximumEntries: maximumSessionFiles,
            skipsHiddenFiles: false
        )
        #else
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ],
            options: []
        )
        #endif
    }

    private static func isRealDirectory(_ directory: URL) throws -> Bool {
        #if os(Windows)
        guard let values = try WindowsSecurePath.metadata(at: directory) else { return false }
        return values.isDirectory && !values.isReparsePoint
        #else
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values.isDirectory == true && values.isSymbolicLink != true
        #endif
    }

    private static func outputPath(
        _ requested: String?,
        sessionID: String,
        home: URL,
        environment: [String: String]
    ) -> URL {
        guard let requested else {
            return home.appendingPathComponent("trace-exports", isDirectory: true)
                .appendingPathComponent("\(sessionID).tar.gz")
                .standardizedFileURL
        }
        if (requested as NSString).isAbsolutePath {
            return URL(fileURLWithPath: requested).standardizedFileURL
        }
        let directory = environment["PWD"] ?? FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(requested)
            .standardizedFileURL
    }

    private static func configSnapshot(
        document: TOMLValue,
        environment: [String: String],
        uploadEnabled: Bool
    ) -> LiveTraceConfigSnapshot {
        func configured(_ key: String, environmentVariable: String? = nil) -> Bool {
            if let environmentVariable,
               let value = environment[environmentVariable],
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return true
            }
            guard let value = document[path: ["endpoints", key]]?.stringValue else {
                return false
            }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        let telemetryBucket = environment["GROK_TELEMETRY_GCS_BUCKET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let environmentBucket = environment["GROK_TRACE_UPLOAD_BUCKET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredBucket = document[path: ["endpoints", "trace_upload_bucket"]]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointBucket: String?
        if let environmentBucket, !environmentBucket.isEmpty {
            endpointBucket = environmentBucket
        } else if let configuredBucket, !configuredBucket.isEmpty {
            endpointBucket = configuredBucket
        } else {
            endpointBucket = nil
        }
        let bucket = endpointBucket != nil
        let directUploadConfigured = endpointBucket.map {
            $0.hasPrefix("gs://") || $0.hasPrefix("s3://")
        } ?? false
        let source: String
        if telemetryBucket?.isEmpty == false {
            source = "env"
        } else if bucket {
            source = "config"
        } else {
            source = "unconfigured"
        }
        let credentialsFile = configured(
            "trace_upload_credentials_file",
            environmentVariable: "GROK_TRACE_UPLOAD_CREDENTIALS_FILE"
        )
        let inlineCredentials = configured("trace_upload_credentials")
        return LiveTraceConfigSnapshot(
            traceUploadEnabled: uploadEnabled,
            telemetryTraceUpload: document[path: ["telemetry", "trace_upload"]]?.boolValue,
            customUploadURL: configured("trace_upload_url", environmentVariable: "GROK_TRACE_UPLOAD_URL"),
            bucketURLSource: source,
            directUploadConfigured: directUploadConfigured,
            hasBucketConfigured: bucket,
            hasRegionConfigured: configured(
                "trace_upload_region",
                environmentVariable: "GROK_TRACE_UPLOAD_REGION"
            ),
            hasCustomEndpoint: configured(
                "trace_upload_endpoint_url",
                environmentVariable: "GROK_TRACE_UPLOAD_ENDPOINT_URL"
            ),
            hasCredentialsFile: credentialsFile,
            hasInlineCredentials: inlineCredentials,
            hasDeploymentKey: configured("deployment_key", environmentVariable: "GROK_DEPLOYMENT_KEY")
        )
    }

    private static var operatingSystem: String {
        #if os(macOS)
        "macos"
        #elseif os(Linux)
        "linux"
        #elseif os(Windows)
        "windows"
        #else
        "unknown"
        #endif
    }

    private static var architecture: String {
        #if arch(arm64)
        "aarch64"
        #elseif arch(x86_64)
        "x86_64"
        #elseif arch(arm)
        "arm"
        #else
        "unknown"
        #endif
    }

    /// Rust: `xai-grok-pager/src/memory_trace.rs:573-659`; process timelines
    /// stay grouped, newest process first, with allocator dumps newest first.
    private static func collectMemoryTraces(home: URL) -> [(name: String, contents: Data)] {
        let directory = home.appendingPathComponent("memtrace", isDirectory: true)
        guard let paths = try? directoryContents(directory),
              (try? isRealDirectory(directory)) == true
        else { return [] }

        var candidates: [LiveMemoryTraceCandidate] = []
        for url in paths {
            let name = url.lastPathComponent
            guard let parsed = parseMemoryTraceName(name) else { continue }
            #if os(Windows)
            guard let metadata = try? WindowsSecurePath.metadata(at: url),
                  !metadata.isDirectory, !metadata.isReparsePoint
            else { continue }
            #else
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ]), values.isRegularFile == true, values.isSymbolicLink != true
            else { continue }
            #endif
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  size >= 0
            else { continue }
            candidates.append(LiveMemoryTraceCandidate(
                stem: parsed.stem,
                name: name,
                url: url,
                byteCount: size,
                modifiedAt: attributes[.modificationDate] as? Date ?? .distantPast,
                isAllocatorDump: parsed.isAllocatorDump,
                dumpSequence: parsed.dumpSequence
            ))
        }

        var processActivity: [String: Date] = [:]
        for candidate in candidates {
            processActivity[candidate.stem] = max(
                processActivity[candidate.stem] ?? .distantPast,
                candidate.modifiedAt
            )
        }
        candidates.sort { left, right in
            let leftActivity = processActivity[left.stem] ?? left.modifiedAt
            let rightActivity = processActivity[right.stem] ?? right.modifiedAt
            if leftActivity != rightActivity { return leftActivity > rightActivity }
            if left.stem != right.stem { return left.stem < right.stem }
            if left.isAllocatorDump != right.isAllocatorDump { return !left.isAllocatorDump }
            if left.dumpSequence != right.dumpSequence { return left.dumpSequence > right.dumpSequence }
            return left.name < right.name
        }

        var exported: [(name: String, contents: Data)] = []
        var total = 0
        for candidate in candidates {
            if exported.count >= maximumMemoryTraceFiles { break }
            let (updated, overflow) = total.addingReportingOverflow(candidate.byteCount)
            guard !overflow, updated <= maximumMemoryTraceBytes,
                  let contents = try? PathSecurity.readNoFollow(
                    candidate.url,
                    maximumBytes: maximumMemoryTraceBytes,
                    requireOwnerOnly: false
                  ),
                  contents.count == candidate.byteCount
            else { continue }
            total = updated
            exported.append((name: candidate.name, contents: contents))
        }
        return exported
    }

    private static func rejectSymbolicLinkDestination(_ destination: URL) throws {
        #if os(Windows)
        guard let metadata = try WindowsSecurePath.metadata(at: destination) else { return }
        guard !metadata.isReparsePoint else {
            throw CLIApplicationError.failed("refusing a symbolic-link or reparse-point destination")
        }
        #else
        do {
            guard !(try PathSecurity.isSymlink(destination)) else {
                throw CLIApplicationError.failed("refusing a symbolic-link destination")
            }
        } catch let error as FileUtilsError {
            guard case .notFound = error else { throw error }
        }
        #endif
    }

    private static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count > rootComponents.count
            && candidateComponents.starts(with: rootComponents)
    }

    private static func parseMemoryTraceName(
        _ name: String
    ) -> (stem: String, isAllocatorDump: Bool, dumpSequence: UInt64)? {
        let stem: String
        let isDump: Bool
        let sequence: UInt64
        if let range = name.range(of: "-jemalloc-", options: .backwards) {
            guard name.hasSuffix(".txt"),
                  let parsed = UInt64(name[range.upperBound...].dropLast(4))
            else { return nil }
            stem = String(name[..<range.lowerBound])
            isDump = true
            sequence = parsed
        } else if name.hasSuffix(".jsonl.1") {
            stem = String(name.dropLast(8))
            isDump = false
            sequence = 0
        } else if name.hasSuffix(".jsonl") {
            stem = String(name.dropLast(6))
            isDump = false
            sequence = 0
        } else {
            return nil
        }

        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              UInt64(parts[0]) != nil,
              UInt32(parts[1]) != nil
        else { return nil }
        return (stem, isDump, sequence)
    }
}
