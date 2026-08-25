import Foundation
import Testing

@testable import OpenGrokCLI

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(SQLite3)
import SQLite3
#endif

@Suite("Codex compressed foreign-session parity")
struct CodexCompressedSessionParityTests {
    @Test("zstd support decodes a genuine fixture or reports an explicit unsupported backend")
    func capabilityIsExplicit() throws {
        let compressed = try CodexCompressedFixture.data(CodexCompressedFixture.validFrame)
        if CodexZstdSessionReader.isAvailable {
            let decoded = try CodexZstdSessionReader.decodeHead(compressed)
            let text = try #require(String(data: decoded, encoding: .utf8))
            #expect(text.contains("Read genuine zstd Codex rollouts"))
        } else {
            #if canImport(Darwin) || canImport(Glibc)
            #expect(throws: CodexZstdSessionReaderError.unavailableTrustedLibrary) {
                try CodexZstdSessionReader.decodeHead(compressed)
            }
            #else
            #expect(throws: CodexZstdSessionReaderError.unsupportedPlatform) {
                try CodexZstdSessionReader.decodeHead(compressed)
            }
            #endif
        }
    }

    @Test(
        "live foreign-session scanner discovers a genuine single-frame zstd rollout",
        .enabled(if: CodexZstdSessionReader.isAvailable)
    )
    func liveScannerDiscoversCompressedRollout() throws {
        let fixture = try CodexCompressedFixture()
        defer { fixture.remove() }
        try fixture.writeCompressed(
            id: CodexCompressedFixture.validID,
            base64: CodexCompressedFixture.validFrame
        )

        let scanner = LiveForeignSessionScanner(environment: ["CODEX_HOME": fixture.home.path])
        let sessions = scanner.scan(
            cwd: fixture.cwd,
            enabled: EnabledForeignSources(codex: true)
        )
        let session = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(session.nativeID == CodexCompressedFixture.validID)
        #expect(session.source == .codexVsCode)
        #expect(session.title == "Read genuine zstd Codex rollouts")
        #expect(session.branch == "feature/zstd")
    }

    @Test(
        "compressed custom-source records preserve provider identity and response-item text",
        .enabled(if: CodexZstdSessionReader.isAvailable)
    )
    func compressedCustomSourceKeepsIdentity() throws {
        let fixture = try CodexCompressedFixture()
        defer { fixture.remove() }
        try fixture.writeCompressed(
            id: CodexCompressedFixture.atlasID,
            base64: CodexCompressedFixture.atlasFrame
        )

        let session = try #require(fixture.scan().first)
        #expect(session.source == .codexAtlas)
        #expect(session.title == "Atlas compressed request")
    }

    @Test(
        "compressed rollout filename UUID and requested workspace remain authoritative",
        .enabled(if: CodexZstdSessionReader.isAvailable)
    )
    func compressedIdentityAndWorkspaceFailClosed() throws {
        let fixture = try CodexCompressedFixture()
        defer { fixture.remove() }
        try fixture.writeCompressed(
            id: "00000000-0000-4000-8000-000000000099",
            base64: CodexCompressedFixture.validFrame
        )
        try fixture.writeCompressed(
            id: CodexCompressedFixture.unknownID,
            base64: CodexCompressedFixture.unknownSourceFrame
        )

        #expect(fixture.scan().isEmpty)
        #expect(fixture.scan(cwd: "/a/different/workspace").isEmpty)
    }

    @Test(
        "concatenated zstd frames never import metadata hidden in the second frame",
        .enabled(if: CodexZstdSessionReader.isAvailable)
    )
    func decoderStopsAfterFirstFrame() throws {
        let fixture = try CodexCompressedFixture()
        defer { fixture.remove() }
        var concatenated = try CodexCompressedFixture.data(CodexCompressedFixture.firstFrameOnly)
        concatenated.append(try CodexCompressedFixture.data(CodexCompressedFixture.validFrame))
        try fixture.writeCompressed(id: CodexCompressedFixture.validID, data: concatenated)

        let decoded = try CodexZstdSessionReader.decodeHead(concatenated)
        let first = try #require(String(data: decoded, encoding: .utf8))
        #expect(first.contains("frame one only"))
        #expect(!first.contains("session_meta"))
        #expect(fixture.scan().isEmpty)
    }

    @Test(
        "valid compression ratios above 256:1 are retained below the conservative bomb ceiling",
        .enabled(if: CodexZstdSessionReader.isAvailable)
    )
    func validHighCompressionRatioRemainsSupported() throws {
        let compressed = try CodexCompressedFixture.data(CodexCompressedFixture.highRatioFrame)
        let decoded = try CodexZstdSessionReader.decodeHead(compressed)

        #expect(decoded.count == 16 * 1024)
        #expect(decoded.count > compressed.count * 256)
        #expect(decoded.count < compressed.count * CodexZstdSessionReader.maxExpansionRatio)
    }

    @Test(
        "expansion bombs stop before exceeding the bounded decoded head",
        .enabled(if: CodexZstdSessionReader.isAvailable)
    )
    func compressionBombIsRejected() throws {
        let compressed = try CodexCompressedFixture.data(CodexCompressedFixture.expansionBomb)
        #expect(throws: CodexZstdSessionReaderError.expansionRatioExceeded) {
            try CodexZstdSessionReader.decodeHead(compressed)
        }

        let fixture = try CodexCompressedFixture()
        defer { fixture.remove() }
        try fixture.writeCompressed(id: CodexCompressedFixture.validID, data: compressed)
        #expect(fixture.scan().isEmpty)
    }

    @Test(
        "malformed zstd bytes never become a foreign session",
        .enabled(if: CodexZstdSessionReader.isAvailable)
    )
    func malformedCompressedFrameIsRejected() throws {
        let malformed = Data("not a genuine zstd frame".utf8)
        #expect(throws: CodexZstdSessionReaderError.invalidFrame) {
            try CodexZstdSessionReader.decodeHead(malformed)
        }

        let fixture = try CodexCompressedFixture()
        defer { fixture.remove() }
        try fixture.writeCompressed(id: CodexCompressedFixture.validID, data: malformed)
        #expect(fixture.scan().isEmpty)
    }

    @Test(
        "decoder refuses zstd windows larger than the upstream eight-megabyte ceiling",
        .enabled(if: CodexZstdSessionReader.isAvailable)
    )
    func oversizedDecoderWindowIsRejected() throws {
        let compressed = try CodexCompressedFixture.data(CodexCompressedFixture.oversizedWindow)
        #expect(throws: CodexZstdSessionReaderError.windowLimitExceeded) {
            try CodexZstdSessionReader.decodeHead(compressed)
        }

        let fixture = try CodexCompressedFixture()
        defer { fixture.remove() }
        try fixture.writeCompressed(id: CodexCompressedFixture.validID, data: compressed)
        #expect(fixture.scan().isEmpty)
    }

    @Test("compressed input, cancellation, and deadline limits fail before unsafe decoding")
    func inputCancellationAndDeadlineLimitsAreExplicit() throws {
        let overLimit = Data(repeating: 0x28, count: CodexZstdSessionReader.maxCompressedBytes + 1)
        #expect(throws: CodexZstdSessionReaderError.compressedInputLimitExceeded) {
            try CodexZstdSessionReader.decodeHead(overLimit)
        }

        let compressed = try CodexCompressedFixture.data(CodexCompressedFixture.validFrame)
        #expect(throws: CodexZstdSessionReaderError.cancelled) {
            try CodexZstdSessionReader.decodeHead(compressed, isCancelled: { true })
        }
        #expect(throws: CodexZstdSessionReaderError.deadlineExceeded) {
            try CodexZstdSessionReader.decodeHead(compressed, timeoutNanoseconds: 0)
        }
    }

    @Test(
        "skippable compressed prefixes cannot move session metadata beyond the input budget",
        .enabled(if: CodexZstdSessionReader.isAvailable)
    )
    func oversizedSkippableFrameCannotBypassCompressedLimit() throws {
        let fixture = try CodexCompressedFixture()
        defer { fixture.remove() }

        var skipped = Data([0x50, 0x2a, 0x4d, 0x18])
        var length = UInt32(CodexZstdSessionReader.maxCompressedBytes + 1024).littleEndian
        withUnsafeBytes(of: &length) { skipped.append(contentsOf: $0) }
        skipped.append(Data(repeating: 0, count: Int(length)))
        skipped.append(try CodexCompressedFixture.data(CodexCompressedFixture.validFrame))
        try fixture.writeCompressed(id: CodexCompressedFixture.validID, data: skipped)

        #expect(fixture.scan().isEmpty)
    }

    @Test(
        "compressed rollout symlinks never escape the owner-approved Codex root",
        .enabled(if: CodexZstdSessionReader.isAvailable)
    )
    func symlinkedCompressedRolloutIsRejected() throws {
        let fixture = try CodexCompressedFixture()
        defer { fixture.remove() }
        let outside = try fixture.writeCompressed(
            id: CodexCompressedFixture.validID,
            base64: CodexCompressedFixture.validFrame,
            base: fixture.outside
        )
        let destination = fixture.dateDirectory(base: fixture.home)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: destination.appendingPathComponent(outside.lastPathComponent),
            withDestinationURL: outside
        )

        #expect(fixture.scan().isEmpty)
    }

    #if canImport(Darwin) || canImport(Glibc)
    @Test(
        "group-writable compressed rollouts are rejected without changing foreign permissions",
        .enabled(if: CodexZstdSessionReader.isAvailable)
    )
    func groupWritableCompressedRolloutIsRejected() throws {
        let fixture = try CodexCompressedFixture()
        defer { fixture.remove() }
        let path = try fixture.writeCompressed(
            id: CodexCompressedFixture.validID,
            base64: CodexCompressedFixture.validFrame
        )
        #expect(chmod(path.path, mode_t(0o664)) == 0)

        #expect(fixture.scan().isEmpty)

        var information = stat()
        #expect(lstat(path.path, &information) == 0)
        #expect(information.st_mode & mode_t(0o777) == mode_t(0o664))
    }
    #endif

    #if canImport(SQLite3)
    @Test(
        "SQLite rollout references can resolve their existing compressed sibling",
        .enabled(if: CodexZstdSessionReader.isAvailable)
    )
    func databaseFindsCompressedRolloutSibling() throws {
        let fixture = try CodexCompressedFixture()
        defer { fixture.remove() }
        let compressed = try fixture.writeCompressed(
            id: CodexCompressedFixture.validID,
            base64: CodexCompressedFixture.validFrame
        )
        let uncompressedPath = String(compressed.path.dropLast(".zst".count))
        try fixture.createDatabase(
            id: CodexCompressedFixture.validID,
            rolloutPath: uncompressedPath,
            title: "Database-backed compressed rollout"
        )

        let session = try #require(fixture.scan().first)
        #expect(session.nativeID == CodexCompressedFixture.validID)
        #expect(session.source == .codexVsCode)
        #expect(session.title == "Database-backed compressed rollout")
    }
    #endif
}

private struct CodexCompressedFixture {
    static let validID = "00000000-0000-4000-8000-000000000001"
    static let atlasID = "00000000-0000-4000-8000-000000000002"
    static let unknownID = "00000000-0000-4000-8000-000000000003"

    // Genuine frames produced by zstd 1.5.7; no executable is needed at test time.
    static let validFrame = """
        KLUv/QRYlQUA4swmH2BnnAPQiIhICI3J9oVNGymEaDAEkLYMFcsHigHgUqxFjN4HlWHUGYenChj5NmG8LbBdMXJ9wMrIV9bum8R9obJN8toLL2KMzrcJ5A6+9QIrG7C2HIEf5bcoRn4q24KVzxzUNfLhqezI7945jTLkbDl74NSAWDkNzMiEgCOlBHCklNKRrJyLH+VcyiCWY+T13iRNl92vle8gnp8HAC1SR8uWyaTcUkYHyEEmSclAGWUfdDg=
        """
    static let atlasFrame = """
        KLUv/QRYnQUAwowlHnBJqgPm0GdEhKiyKVrkXMLQ6WdPJCj8xEta/7DuC4X3Cp5X7xDeDAY9yA4YXbyJr7GOrYMAveu7Erm4XZ3RR7K5+AZH9Up9D+O6kulb4b1nPcgeo1WuOuQEfdRcqosTT4mKdNU3phIdjg7Tg5aIg9EJgVwMIFAYYwIKY4wpjNHpcIJOJ5GEw1x89spYeahejT5LWCcBCQAjs5xK+3Kqv2YZQDH5xcToA9nKJCkZKANwoCWH
        """
    static let unknownSourceFrame = """
        KLUv/QRYBQUAwgohHXCn1QHIMew/IYPSJFpIucTP1f+qsRAw7Uqrow8mxLL4aTp2GH3yZt4izJgBIxc+Ie2eGfpFCMuM156cWBbr15GkutOUbIWGGPlKkVwXLvhKddZ3r46lGlwltwVNZWDkpSgXBhA4iBhwEBEPGnkdPiCvlASG5Fw4vTOj5bH7NfKd4fkQCQBoDHGFMbRIxSxbEJOymBgdIAeZJCUDZbHOwnc=
        """
    static let firstFrameOnly = """
        KLUv/QRYHQIAEgQOFKBXBzb+lordBHR/KqAaffqyb+4rQGtmR9G4ovFEJfhMfIO7z6K+wzlAdBgmE5vNsvTEfX5iy0UCAC2kGgqVBwq+7ik=
        """
    static let highRatioFrame = "KLUv/QRYTQAAEAAAAQD7nwdY7EUsMw=="
    static let expansionBomb = "KLUv/QRYVQAAEAAAAQD7/znAAnNQlXo="
    static let oversizedWindow = """
        KLUv/QRwrQQAYoofHXA31QGAAb32G44mRoKiFUv6/5+0PPF++eZVpy8mxXt2modyg/bU9BzkC9S2J+rj4hvQ7pfRvgfDLgM5nrx4z09Nm/j4qR10XUzw1GTyu29saSI8IbYCTR3Bx+mSiwsBBhEBDCKiQR+ncuI4kQ4gEHMxQr6MQ9Xu18dnCMSJBwAtUifLlsGk3ITRC/KSSWgyoAcAo0Sn
        """

    let root: URL
    let home: URL
    let outside: URL
    let now: Date
    let cwd = "/workspace/compressed-codex"

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-codex-zstd-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("codex", isDirectory: true)
        outside = root.appendingPathComponent("outside", isDirectory: true)
        now = Date()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    static func data(_ value: String) throws -> Data {
        try #require(Data(base64Encoded: value.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func scan(cwd: String? = nil) -> [ForeignSessionSummary] {
        CodexSessionScanner.scan(requestedCwd: cwd ?? self.cwd, now: now, codexHome: home)
    }

    func dateDirectory(base: URL) -> URL {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day],
            from: now
        )
        return base.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", parts.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.day!), isDirectory: true)
    }

    @discardableResult
    func writeCompressed(id: String, base64: String, base: URL? = nil) throws -> URL {
        try writeCompressed(id: id, data: Self.data(base64), base: base)
    }

    @discardableResult
    func writeCompressed(id: String, data: Data, base: URL? = nil) throws -> URL {
        let directory = dateDirectory(base: base ?? home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(
            "rollout-2027-01-15T12-00-00-\(id).jsonl.zst"
        )
        try data.write(to: path)
        return path
    }
}

#if canImport(SQLite3)
private struct CodexCompressedDatabaseError: Error {}

extension CodexCompressedFixture {
    func createDatabase(id: String, rolloutPath: String, title: String) throws {
        let path = home.appendingPathComponent("state_8.sqlite")
        var opened: OpaquePointer?
        let status = path.path.withCString {
            sqlite3_open_v2(
                $0,
                &opened,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
        }
        guard status == SQLITE_OK, let database = opened else {
            if let opened { sqlite3_close(opened) }
            throw CodexCompressedDatabaseError()
        }
        defer { sqlite3_close(database) }

        let timestamp = Int64(now.timeIntervalSince1970 * 1_000)
        let escapedPath = rolloutPath.replacingOccurrences(of: "'", with: "''")
        let escapedTitle = title.replacingOccurrences(of: "'", with: "''")
        let sql = """
            CREATE TABLE threads (
                id TEXT,
                rollout_path TEXT,
                updated_at_ms INTEGER,
                source TEXT,
                cwd TEXT,
                archived INTEGER,
                title TEXT,
                first_user_message TEXT,
                git_branch TEXT
            );
            INSERT INTO threads VALUES (
                '\(id)', '\(escapedPath)', \(timestamp), 'vscode', '\(cwd)', 0,
                '\(escapedTitle)', '', NULL
            );
            """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CodexCompressedDatabaseError()
        }
    }
}
#endif
