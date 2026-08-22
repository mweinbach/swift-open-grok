import Foundation

#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

enum LiveSessionBusStatus: String, Codable, Sendable, Equatable {
    case idle
    case busy
}

struct LiveSessionBusPresence: Codable, Sendable, Equatable {
    var sessionID: String
    var cwd: String
    var projectName: String
    var modelID: String?
    var title: String?
    var status: LiveSessionBusStatus
    var updatedAtMS: UInt64

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case projectName = "project_name"
        case modelID = "model_id"
        case title
        case status
        case updatedAtMS = "updated_at_ms"
    }
}

struct LiveSessionBusPresenceFile: Codable, Sendable, Equatable {
    var instanceID: String
    var pid: Int32
    var socketPath: String
    var protocolVersion: UInt32
    var heartbeatAtMS: UInt64
    var startedAtMS: UInt64
    var sessions: [LiveSessionBusPresence]

    private enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case pid
        case socketPath = "socket_path"
        case protocolVersion = "protocol_version"
        case heartbeatAtMS = "heartbeat_at_ms"
        case startedAtMS = "started_at_ms"
        case sessions
    }
}

struct LiveSessionBusDiscoveredSession: Sendable, Equatable {
    var presence: LiveSessionBusPresence
    var socketURL: URL
    var processID: Int32
    var instanceID: String
    var conflict: Bool
}

#if os(macOS) || os(Linux)
enum LiveSessionBusPresenceStore {
    static let protocolVersion: UInt32 = 1
    static let staleTTLMS: UInt64 = 20_000
    static let heartbeatIntervalNanoseconds: UInt64 = 5_000_000_000

    static func directory(openGrokHome: URL) -> URL {
        openGrokHome.standardizedFileURL
            .appendingPathComponent("session-bus", isDirectory: true)
    }

    static func nowMilliseconds() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
    }

    static func makeInstanceID(processID: Int32) -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return "p\(processID)-\(hex.suffix(8).lowercased())"
    }

    static func ensureSecureDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let information = fileInformation(directory),
              fileType(information) == mode_t(S_IFDIR),
              information.st_uid == getuid()
        else {
            throw LiveSessionBusError.insecurePresence(
                "session-bus directory is not an owned real directory"
            )
        }
        if information.st_mode & 0o077 != 0,
           chmod(directory.path, 0o700) != 0
        {
            throw LiveSessionBusError.insecurePresence(
                "could not restrict session-bus directory permissions"
            )
        }
    }

    static func write(_ presence: LiveSessionBusPresenceFile, directory: URL) throws {
        try ensureSecureDirectory(directory)
        let finalURL = directory.appendingPathComponent("\(presence.instanceID).json")
        let temporaryURL = directory.appendingPathComponent("\(presence.instanceID).json.tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(presence)
        if FileManager.default.fileExists(atPath: temporaryURL.path) {
            guard let information = fileInformation(temporaryURL),
                  fileType(information) == mode_t(S_IFREG),
                  information.st_uid == getuid()
            else {
                throw LiveSessionBusError.insecurePresence("unsafe session-bus temporary file")
            }
            try FileManager.default.removeItem(at: temporaryURL)
        }
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw LiveSessionBusError.insecurePresence("could not write session-bus presence")
        }
        guard rename(temporaryURL.path, finalURL.path) == 0 else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw LiveSessionBusError.insecurePresence("could not publish session-bus presence")
        }
    }

    static func remove(instanceID: String, directory: URL) {
        let presenceURL = directory.appendingPathComponent("\(instanceID).json")
        guard let information = fileInformation(presenceURL),
              fileType(information) == mode_t(S_IFREG),
              information.st_uid == getuid()
        else { return }
        _ = unlink(presenceURL.path)
    }

    static func liveSessions(
        directory: URL,
        now: UInt64 = nowMilliseconds()
    ) -> [LiveSessionBusDiscoveredSession] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var best: [String: LiveSessionBusDiscoveredSession] = [:]
        for entry in entries where isPresenceFileName(entry.lastPathComponent) {
            guard let file = validatedPresence(at: entry, directory: directory),
                  now >= file.heartbeatAtMS
                    ? now - file.heartbeatAtMS <= staleTTLMS
                    : true,
                  processIsAlive(file.pid)
            else { continue }

            for presence in file.sessions {
                let discovered = LiveSessionBusDiscoveredSession(
                    presence: presence,
                    socketURL: URL(fileURLWithPath: file.socketPath),
                    processID: file.pid,
                    instanceID: file.instanceID,
                    conflict: false
                )
                guard var previous = best[presence.sessionID] else {
                    best[presence.sessionID] = discovered
                    continue
                }
                if discovered.presence.updatedAtMS > previous.presence.updatedAtMS {
                    var replacement = discovered
                    replacement.conflict = true
                    best[presence.sessionID] = replacement
                } else {
                    previous.conflict = true
                    best[presence.sessionID] = previous
                }
            }
        }

        return best.values.sorted { lhs, rhs in
            if lhs.presence.updatedAtMS == rhs.presence.updatedAtMS {
                return lhs.presence.sessionID < rhs.presence.sessionID
            }
            return lhs.presence.updatedAtMS > rhs.presence.updatedAtMS
        }
    }

    static func collectStale(
        directory: URL,
        now: UInt64 = nowMilliseconds()
    ) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var removed: [String] = []
        for entry in entries where isPresenceFileName(entry.lastPathComponent) {
            guard let information = fileInformation(entry),
                  fileType(information) == mode_t(S_IFREG),
                  information.st_uid == getuid()
            else { continue }
            let modifiedAt = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate.map {
                    UInt64(max(0, $0.timeIntervalSince1970 * 1_000))
                } ?? 0
            let ageExpired = now >= modifiedAt && now - modifiedAt > staleTTLMS
            guard let file = decodedPresence(at: entry) else {
                if ageExpired {
                    _ = unlink(entry.path)
                }
                continue
            }
            guard entry.deletingPathExtension().lastPathComponent == file.instanceID,
                  file.instanceID.hasPrefix("p\(file.pid)-")
            else {
                if ageExpired {
                    _ = unlink(entry.path)
                }
                continue
            }
            let beatExpired = now >= file.heartbeatAtMS
                && now - file.heartbeatAtMS > staleTTLMS
            guard beatExpired || ageExpired || !processIsAlive(file.pid) else { continue }
            _ = unlink(entry.path)
            let socketURL = directory.appendingPathComponent("\(file.instanceID).sock")
            if let socketInformation = fileInformation(socketURL),
               fileType(socketInformation) == mode_t(S_IFSOCK),
               socketInformation.st_uid == getuid()
            {
                _ = unlink(socketURL.path)
            }
            removed.append(file.instanceID)
        }
        return removed.sorted()
    }

    static func isPresenceFileName(_ name: String) -> Bool {
        name.range(
            of: #"^p[0-9]+-[0-9a-fA-F]{8}\.json$"#,
            options: .regularExpression
        ) != nil
    }

    private static func validatedPresence(
        at url: URL,
        directory: URL
    ) -> LiveSessionBusPresenceFile? {
        guard let information = fileInformation(url),
              fileType(information) == mode_t(S_IFREG),
              information.st_uid == getuid(),
              information.st_mode & 0o022 == 0,
              let file = decodedPresence(at: url),
              file.protocolVersion == protocolVersion,
              url.deletingPathExtension().lastPathComponent == file.instanceID,
              file.instanceID.hasPrefix("p\(file.pid)-"),
              file.pid > 0
        else { return nil }

        let expectedSocket = directory
            .appendingPathComponent("\(file.instanceID).sock")
            .standardizedFileURL
        let announcedSocket = URL(fileURLWithPath: file.socketPath).standardizedFileURL
        guard announcedSocket == expectedSocket,
              let socketInformation = fileInformation(announcedSocket),
              fileType(socketInformation) == mode_t(S_IFSOCK),
              socketInformation.st_uid == getuid(),
              socketInformation.st_mode & 0o077 == 0
        else { return nil }

        return file
    }

    private static func decodedPresence(at url: URL) -> LiveSessionBusPresenceFile? {
        guard let data = try? Data(contentsOf: url),
              data.count <= 128 * 1_024
        else { return nil }
        return try? JSONDecoder().decode(LiveSessionBusPresenceFile.self, from: data)
    }

    private static func processIsAlive(_ processID: Int32) -> Bool {
        guard processID > 0 else { return false }
        if processID == getpid() { return true }
        if kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func fileInformation(_ url: URL) -> stat? {
        var result = stat()
        guard lstat(url.path, &result) == 0 else { return nil }
        return result
    }

    private static func fileType(_ information: stat) -> mode_t {
        information.st_mode & mode_t(S_IFMT)
    }
}
#else
enum LiveSessionBusPresenceStore {
    static let protocolVersion: UInt32 = 1
    static let staleTTLMS: UInt64 = 20_000
    static let heartbeatIntervalNanoseconds: UInt64 = 5_000_000_000

    static func directory(openGrokHome: URL) -> URL {
        openGrokHome.standardizedFileURL
            .appendingPathComponent("session-bus", isDirectory: true)
    }

    static func nowMilliseconds() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
    }

    static func makeInstanceID(processID: Int32) -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return "p\(processID)-\(hex.suffix(8).lowercased())"
    }

    static func ensureSecureDirectory(_ directory: URL) throws {
        _ = directory
        throw LiveSessionBusTransportError.unsupportedPlatform
    }

    static func write(_ presence: LiveSessionBusPresenceFile, directory: URL) throws {
        _ = presence
        _ = directory
        throw LiveSessionBusTransportError.unsupportedPlatform
    }

    static func remove(instanceID: String, directory: URL) {
        _ = instanceID
        _ = directory
    }

    static func liveSessions(
        directory: URL,
        now: UInt64 = nowMilliseconds()
    ) -> [LiveSessionBusDiscoveredSession] {
        _ = directory
        _ = now
        return []
    }

    static func collectStale(
        directory: URL,
        now: UInt64 = nowMilliseconds()
    ) -> [String] {
        _ = directory
        _ = now
        return []
    }

    static func isPresenceFileName(_ name: String) -> Bool {
        name.range(
            of: #"^p[0-9]+-[0-9a-fA-F]{8}\.json$"#,
            options: .regularExpression
        ) != nil
    }
}
#endif
