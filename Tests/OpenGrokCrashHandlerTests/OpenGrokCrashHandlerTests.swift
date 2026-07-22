// OpenGrokCrashHandlerTests.swift
import Foundation
import Testing
@testable import OpenGrokCrashHandler

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("OpenGrokCrashHandler")
struct OpenGrokCrashHandlerTests {
    @Test("CrashReport value type")
    func reportValueType() {
        let report = CrashReport(
            summary: "trap",
            redactedBacktrace: ["frame0", "frame1"],
            openGrokHomeRelativePath: "crashes/abc.json"
        )
        #expect(report.summary == "trap")
        #expect(report.redactedBacktrace.count == 2)
        #expect(report.openGrokHomeRelativePath.hasPrefix("crashes/"))
    }

    @Test("GCRX blob round-trip")
    func crashBlobRoundTrip() {
        let blob = CrashBlob(
            signal: 10,
            siCode: 2,
            siAddr: 0x7f8a_1234_0000,
            pid: 42,
            timestamp: 1_712_678_587,
            frames: [0xdead_beef, 0xcafe_babe, 0x1234_5678],
            appVersion: "0.1.169-alpha.2"
        )
        let data = blob.serialize()
        let parsed = CrashBlob.parse(data)
        #expect(parsed != nil)
        #expect(parsed?.signal == 10)
        #expect(parsed?.siCode == 2)
        #expect(parsed?.siAddr == 0x7f8a_1234_0000)
        #expect(parsed?.pid == 42)
        #expect(parsed?.timestamp == 1_712_678_587)
        #expect(parsed?.frames == [0xdead_beef, 0xcafe_babe, 0x1234_5678])
        #expect(parsed?.appVersion == "0.1.169-alpha.2")
    }

    @Test("GCRX rejects bad magic and truncated data")
    func crashBlobRejectsInvalid() {
        var bad = [UInt8](repeating: 0, count: CrashBlobFormat.headerSize)
        bad[0..<4] = [0x4e, 0x4f, 0x50, 0x45] // NOPE
        #expect(CrashBlob.parse(Data(bad)) == nil)
        #expect(CrashBlob.parse(Data()) == nil)
        #expect(CrashBlob.parse(Data(CrashBlobFormat.magic)) == nil)
    }

    @Test("signal names")
    func signalNames() {
        #expect(signalName(10).contains("SIGBUS"))
        #expect(signalName(7).contains("SIGBUS"))
        #expect(signalName(11).contains("SIGSEGV"))
        #expect(signalName(4).contains("SIGILL"))
    }

    @Test("formatReport smoke with redaction")
    func formatReportSmoke() {
        let blob = CrashBlob(
            signal: 10,
            siCode: 2,
            siAddr: 0x7f8a_1234_0000,
            pid: 42,
            timestamp: 1_712_678_587,
            frames: [0xdead_beef],
            appVersion: "0.1.169"
        )
        let frames = [
            ResolvedFrame(
                ip: 0xdead_beef,
                symbolName: "OpenGrokPager.main",
                filename: "/Users/test/src/main.swift",
                lineNumber: 42
            ),
        ]
        let report = formatReport(blob: blob, frames: frames)
        #expect(report.contains("SIGBUS"))
        #expect(report.contains("BUS_ADRERR"))
        #expect(report.contains("OpenGrokPager.main"))
        #expect(report.contains("Open Grok Crash Report"))
    }

    @Test("redactSecrets strips API keys and bearer tokens")
    func redactSecretsTest() {
        #expect(redactSecrets("token sk-abcdefghijklmnop").contains("<redacted>"))
        #expect(redactSecrets("Authorization: Bearer abcdefghijklmnop").contains("<redacted>"))
        #expect(redactSecrets("xai-secretkey1234567890").contains("<redacted>"))
        #expect(redactSecrets("api_key=supersecretvalue").contains("<redacted>"))
        #expect(redactSecrets("normal frame name") == "normal frame name")
    }

    @Test("writeOwnerOnly creates 0600 file")
    func writeOwnerOnlyPermissions() throws {
        #if os(macOS) || os(Linux)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-crash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("report.txt")
        try writeOwnerOnly(path: path, contents: Data("secret".utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600)
        #expect(try String(contentsOf: path, encoding: .utf8) == "secret")
        #endif
    }

    @Test("writeOwnerOnly tightens preexisting 0644")
    func writeOwnerOnlyTightens() throws {
        #if os(macOS) || os(Linux)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-crash-tighten-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("report.txt")
        try Data("old".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        try writeOwnerOnly(path: path, contents: Data("new-secret".utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600)
        #expect(try String(contentsOf: path, encoding: .utf8) == "new-secret")
        #endif
    }

    @Test("checkPreviousCrash returns nil when no file")
    func checkPreviousNone() {
        let dir = URL(fileURLWithPath: "/tmp/ogrok-crash-nonexistent-\(UUID().uuidString)")
        #expect(checkPreviousCrash(crashDir: dir) == nil)
    }

    @Test("checkPreviousCrash parses blob, writes report, archives, deletes blob")
    func checkPreviousCrashFlow() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-crash-prev-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let blob = CrashBlob(
            signal: 11,
            siCode: 1,
            siAddr: 0x0,
            pid: 99,
            timestamp: 1_700_000_000,
            frames: [0x1000],
            appVersion: "0.0.0-test"
        )
        let crashFile = dir.appendingPathComponent("last-crash.bin")
        try blob.serialize().write(to: crashFile)

        let report = checkPreviousCrash(crashDir: dir)
        #expect(report != nil)
        #expect(report?.signalName.contains("SIGSEGV") == true)
        #expect(report?.appVersion == "0.0.0-test")
        #expect(report?.reportPath.pathExtension == "txt")
        #expect(FileManager.default.fileExists(atPath: report!.reportPath.path))
        #expect(!FileManager.default.fileExists(atPath: crashFile.path))

        let history = dir.appendingPathComponent("history")
        let entries = try FileManager.default.contentsOfDirectory(atPath: history.path)
        #expect(entries.contains { $0.hasPrefix("crash-") })
    }

    @Test("record writes only under OPENGROK_HOME and redacts secrets")
    func recordUnderHome() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let handler = PlatformCrashHandler(appVersion: "1.2.3")
        let dest = try await handler.record(
            CrashReport(
                summary: "panic with sk-abcdefghijklmnopqrst",
                redactedBacktrace: ["frame sk-shouldredact12345", "/Users/me/secret/path.swift"],
                openGrokHomeRelativePath: "crash/manual-report.txt",
                signalName: "SIGSEGV",
                appVersion: "1.2.3",
                timestamp: 123
            ),
            openGrokHome: home
        )
        #expect(dest.path.hasPrefix(home.path) || dest.path.contains(home.lastPathComponent))
        let body = try String(contentsOf: dest, encoding: .utf8)
        #expect(body.contains("<redacted>"))
        #expect(body.contains("Open Grok Crash Report"))
        #expect(!body.contains("sk-abcdefghijklmnopqrst"))
    }

    @Test("record rejects path escape")
    func recordRejectsEscape() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-home-esc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let handler = PlatformCrashHandler()
        do {
            _ = try await handler.record(
                CrashReport(
                    summary: "x",
                    redactedBacktrace: [],
                    openGrokHomeRelativePath: "../outside.txt"
                ),
                openGrokHome: home
            )
            Issue.record("expected writeFailed")
        } catch CrashHandlerError.writeFailed {
            // expected
        }
    }

    @Test("record rejects absolute paths")
    func recordRejectsAbsolute() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-home-abs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let handler = PlatformCrashHandler()
        do {
            _ = try await handler.record(
                CrashReport(
                    summary: "x",
                    redactedBacktrace: [],
                    openGrokHomeRelativePath: "/tmp/evil.txt"
                ),
                openGrokHome: home
            )
            Issue.record("expected writeFailed")
        } catch CrashHandlerError.writeFailed {
            // expected
        }
    }

    @Test("record rejects symlinked intermediate directory")
    func recordRejectsSymlinkedDir() async throws {
        #if os(macOS) || os(Linux)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-home-sym-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let link = home.appendingPathComponent("crash")
        // symlink home/crash -> outside
        let rc = symlink(outside.path, link.path)
        #expect(rc == 0)

        let handler = PlatformCrashHandler()
        do {
            _ = try await handler.record(
                CrashReport(
                    summary: "x",
                    redactedBacktrace: [],
                    openGrokHomeRelativePath: "crash/escaped.txt"
                ),
                openGrokHome: home
            )
            Issue.record("expected writeFailed for symlinked dir")
        } catch CrashHandlerError.writeFailed {
            // expected — O_NOFOLLOW rejects the crash component
        }
        // Outside must remain empty of escaped reports.
        let outsideEntries = (try? FileManager.default.contentsOfDirectory(atPath: outside.path)) ?? []
        #expect(!outsideEntries.contains("escaped.txt"))
        #endif
    }

    @Test("install creates owner-only last-crash.bin under home")
    func installCreatesBlob() throws {
        #if os(macOS) || os(Linux)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-home-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let crashDir = home.appendingPathComponent("crash", isDirectory: true)
        let ok = installCrashHandler(
            CrashHandlerConfig(appVersion: "test-version", crashDir: crashDir),
            openGrokHome: home
        )
        #expect(ok)
        #expect(isCrashHandlerInstalled())
        let path = crashDir.appendingPathComponent("last-crash.bin")
        #expect(FileManager.default.fileExists(atPath: path.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600)
        #endif
    }

    @Test("install rejects symlinked crash directory")
    func installRejectsSymlinkedCrashDir() throws {
        #if os(macOS) || os(Linux)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-home-inst-sym-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-crash-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let link = home.appendingPathComponent("crash")
        #expect(symlink(outside.path, link.path) == 0)

        let ok = installCrashHandler(
            CrashHandlerConfig(appVersion: "v", crashDir: link),
            openGrokHome: home
        )
        #expect(!ok)
        // Outside must not receive last-crash.bin
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: outside.path)) ?? []
        #expect(!entries.contains("last-crash.bin"))
        #endif
    }

    @Test("relativeComponents rejects hostile forms")
    func relativeComponentsHostile() {
        func expectFail(_ relative: String) {
            do {
                _ = try CrashPathIsolation.relativeComponents(relative)
                Issue.record("expected rejection for \(relative)")
            } catch CrashHandlerError.writeFailed {
                // expected
            } catch {
                Issue.record("unexpected error for \(relative): \(error)")
            }
        }
        expectFail("../x")
        expectFail("/abs")
        expectFail("")
        expectFail("a/./b")
        expectFail("a/../b")
        let ok = try? CrashPathIsolation.relativeComponents("crash/report.txt")
        #expect(ok == ["crash", "report.txt"])
    }

    @Test("Terminal restore sequence invariants")
    func restoreSeqInvariants() {
        let seq = CrashTerminalRestore.restoreSeq
        let start = Array("\u{1b}[?2026l".utf8)
        #expect(Array(seq.prefix(start.count)) == start)
        let kitty = Array("\u{1b}[<u".utf8)
        let alt = Array("\u{1b}[?1049l".utf8)
        let kittyIdx = indexOf(seq, kitty)
        let altIdx = indexOf(seq, alt)
        #expect(kittyIdx != nil && altIdx != nil)
        #expect(kittyIdx! < altIdx!)
    }

    @Test("BootstrapCrashHandler install/record work")
    func bootstrapHandler() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-home-boot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let handler = BootstrapCrashHandler(appVersion: "boot")
        #if os(macOS) || os(Linux)
        try await handler.install(openGrokHome: home)
        #endif
        let url = try await handler.record(
            CrashReport(
                summary: "x",
                redactedBacktrace: ["f0"],
                openGrokHomeRelativePath: "crash/a.txt"
            ),
            openGrokHome: home
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    private func indexOf(_ haystack: [UInt8], _ needle: [UInt8]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for i in 0...(haystack.count - needle.count) {
            if Array(haystack[i..<(i + needle.count)]) == needle {
                return i
            }
        }
        return nil
    }
}
