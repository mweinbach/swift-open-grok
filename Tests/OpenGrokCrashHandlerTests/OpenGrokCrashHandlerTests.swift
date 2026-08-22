// OpenGrokCrashHandlerTests.swift
import Foundation
import Testing
@testable import OpenGrokCrashHandler
import OpenGrokSecrets

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
        #expect(signalName(6).contains("SIGABRT"))
    }

    @Test("signalName SIGABRT pin parity")
    func signalNameSigabrt() {
        // Mirrors symbolicate.rs:signal_name at pin 650c1db7: 6 => SIGABRT (Abort)
        #expect(signalName(6) == "SIGABRT (Abort)")
        #expect(signalName(6).contains("SIGABRT"))
    }

    @Test("siCodeName for SIGABRT")
    func siCodeNameSigabrt() {
        // SIGABRT carries no fault si_code (symbolicate.rs:94-99 at pin 650c1db7)
        #expect(siCodeName(signal: 6, code: 0).contains("abort()"))
        #expect(siCodeName(signal: 6, code: 1).contains("abort()"))
        #expect(siCodeName(signal: 6, code: -1).contains("abort()"))
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

    @Test("formatReport for SIGABRT identifies abort")
    func formatReportSigabrt() {
        let blob = CrashBlob(
            signal: 6,
            siCode: 0,
            siAddr: 0x0,
            pid: 99,
            timestamp: 1_700_000_001,
            frames: [0x1000],
            appVersion: "0.0.0-test"
        )
        let frames = [ResolvedFrame(ip: 0x1000, symbolName: "abort", filename: nil, lineNumber: nil)]
        let report = formatReport(blob: blob, frames: frames)
        #expect(report.contains("SIGABRT"))
        #expect(report.contains("abort()"))
        #expect(report.contains("Open Grok Crash Report"))
    }

    @Test("redactSecrets strips API keys and bearer tokens via canonical sanitizer")
    func redactSecretsTest() {
        // Canonical marker is [REDACTED_SECRET] (SecretRedaction.secret)
        let marker = SecretRedaction.secret
        // API key prefix (sk-/xai-) requires 20+ chars after prefix
        #expect(redactSecrets("token sk-abcdefghijklmnopqrstuvwx").contains(marker))
        #expect(redactSecrets("Authorization: Bearer abcdefghijklmnop1234").contains(marker))
        #expect(redactSecrets("key: xai-abc123XYZdef456GHIjkl789").contains(marker))
        #expect(redactSecrets("api_key=supersecretvalue").contains(marker))
        #expect(redactSecrets("normal frame name") == "normal frame name")
    }

    @Test("redactSecrets covers canonical 10-pattern sanitizer")
    func redactSecretsCanonicalTenPatterns() {
        let marker = SecretRedaction.secret
        // 1. API key prefix sk-/xai- (20+)
        #expect(redactSecrets("key: xai-abc123XYZdef456GHIjkl789").contains(marker), "xai prefix not redacted")
        #expect(redactSecrets("stripe sk_live_0123456789abcdefghijABCD").contains(marker), "sk_ vendor not redacted")
        // 2. AWS AKIA/ASIA (16)
        #expect(redactSecrets("aws AKIAABCDEFGHIJKLMNOP key").contains(marker), "AWS AKIA not redacted")
        #expect(redactSecrets("aws ASIAABCDEFGHIJKLMNOP creds").contains(marker), "AWS ASIA not redacted")
        // 3. GitHub PAT
        #expect(redactSecrets("token ghp_0123456789abcdefghijABCDEFGHIJ012345").contains(marker), "GitHub classic PAT not redacted")
        #expect(redactSecrets("github_pat_11ABCDE0123456789_abcdefghijklmnopqrstuvwxyz0123456789").contains(marker), "GitHub fine-grained not redacted")
        // 4. Vendor tokens glpat-/xoxb-/xapp-
        #expect(redactSecrets("glpat-0123456789abcdefABCD here").contains(marker), "GitLab PAT not redacted")
        #expect(redactSecrets("xoxb-2420837490-2420837490-AbCdEfGhIjKlMnOpQr").contains(marker), "Slack token not redacted")
        // 5. Google API key
        #expect(redactSecrets("AIzaSyD0123456789abcdefghijklmnopqrstuvw").contains(marker), "Google API key not redacted")
        // 6. PEM private key block
        let pem = "key:\n-----BEGIN PRIVATE KEY-----\nMIIabc123def456\nMIIxyz789\n-----END PRIVATE KEY-----\ndone"
        let pemOut = redactSecrets(pem)
        #expect(pemOut.contains(marker), "PEM not redacted")
        #expect(!pemOut.contains("MIIabc123"), "PEM body leaked")
        #expect(!pemOut.contains("BEGIN PRIVATE KEY"), "PEM header leaked")
        // 7. Bearer token (16+)
        #expect(redactSecrets("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.foobar1234567890").contains("Bearer \(marker)"), "Bearer not redacted with canonical prefix")
        // 8. Bare JWT (eyJ.<8>.<8>.<8>)
        let jwt = "deployment key eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4f"
        let jwtOut = redactSecrets(jwt)
        #expect(jwtOut.contains(marker), "bare JWT not redacted")
        #expect(!jwtOut.contains("eyJ"), "bare JWT survived")
        // 9. URL with sensitive query params -> redacted query value
        let urlOut = redactSecrets("callback https://x.ai/cb?code=ABC123XYZ&state=xyz789 failed")
        #expect(!urlOut.contains("ABC123XYZ"), "OAuth code leaked via URL")
        #expect(!urlOut.contains("xyz789"), "state leaked via URL")
        #expect(urlOut.contains("code=redacted") || urlOut.contains("code=\(SecretRedaction.urlValue)"), "URL sensitive param not canonical redacted")
        // 10. Secret assignment (api_key, token, secret, password with 8+ value)
        #expect(redactSecrets("api_key=supersecretvalue").contains(marker), "secret assignment not redacted")
        #expect(redactSecrets("password: supersecret123").contains(marker), "password assignment not redacted")
        // Negative: unrelated string unchanged (cheap borrowed path)
        #expect(redactSecrets("model=grok-3") == "model=grok-3")
        #expect(redactSecrets("just a normal log line") == "just a normal log line")
        // Over-redaction guard: sk- mid-word should not fold
        for input in ["task-deadbeefdeadbeefdeadbeef0123", "disk-0123456789abcdefghijklmno"] {
            #expect(redactSecrets(input) == input, "over-redacted: \(input)")
        }
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

    @Test("checkPreviousCrash handles SIGABRT blob")
    func checkPreviousCrashSigabrt() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-crash-prev-abrt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let blob = CrashBlob(
            signal: 6,
            siCode: 0,
            siAddr: 0x0,
            pid: 99,
            timestamp: 1_700_000_001,
            frames: [0x1000],
            appVersion: "0.0.0-test"
        )
        let crashFile = dir.appendingPathComponent("last-crash.bin")
        try blob.serialize().write(to: crashFile)

        let report = checkPreviousCrash(crashDir: dir)
        #expect(report?.signalName.contains("SIGABRT") == true)
        #expect(report?.appVersion == "0.0.0-test")
        #expect(FileManager.default.fileExists(atPath: report!.reportPath.path))
        let body = try String(contentsOf: report!.reportPath, encoding: .utf8)
        #expect(body.contains("SIGABRT"))
        #expect(body.contains("abort()"))
        #expect(!FileManager.default.fileExists(atPath: crashFile.path))
    }

    @Test("record writes only under OPENGROK_HOME and redacts secrets")
    func recordUnderHome() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let handler = PlatformCrashHandler(appVersion: "1.2.3")
        // Use 20+ chars after sk- to meet canonical 20-char floor
        let dest = try await handler.record(
            CrashReport(
                summary: "panic with sk-abcdefghijklmnopqrstuvwx",
                redactedBacktrace: ["frame sk-shouldredact12345abcdefghij", "/Users/me/secret/path.swift"],
                openGrokHomeRelativePath: "crash/manual-report.txt",
                signalName: "SIGSEGV",
                appVersion: "1.2.3",
                timestamp: 123
            ),
            openGrokHome: home
        )
        #expect(dest.path.hasPrefix(home.path) || dest.path.contains(home.lastPathComponent))
        let body = try String(contentsOf: dest, encoding: .utf8)
        #expect(body.contains(SecretRedaction.secret))
        #expect(body.contains("Open Grok Crash Report"))
        #expect(!body.contains("sk-abcdefghijklmnopqrstuvwx"))
    }

    @Test("record redacts canonical 10-pattern secrets")
    func recordRedactsCanonical() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-home-canonical-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let handler = PlatformCrashHandler(appVersion: "1.2.3")
        let marker = SecretRedaction.secret
        let dest = try await handler.record(
            CrashReport(
                summary: "keys ghp_0123456789abcdefghijABCDEFGHIJ012345 and AKIAABCDEFGHIJKLMNOP and https://x.ai/cb?code=ABC123XYZ",
                redactedBacktrace: [
                    "frame with xai-abc123XYZdef456GHIjkl789",
                    "bearer Bearer eyJhbGciOiJIUzI1NiJ9.foobar1234567890 and PEM -----BEGIN PRIVATE KEY-----\nMIIabc\n-----END PRIVATE KEY-----",
                    "api_key=supersecretvalue",
                ],
                openGrokHomeRelativePath: "crash/canonical-report.txt",
                signalName: "SIGABRT (Abort)",
                appVersion: "1.2.3",
                timestamp: 999
            ),
            openGrokHome: home
        )
        let body = try String(contentsOf: dest, encoding: .utf8)
        #expect(body.contains(marker))
        #expect(!body.contains("ghp_0123456789abcdefghijABCDEFGHIJ012345"))
        #expect(!body.contains("AKIAABCDEFGHIJKLMNOP"))
        #expect(!body.contains("xai-abc123XYZdef456GHIjkl789"))
        #expect(!body.contains("MIIabc"))
        #expect(!body.contains("supersecretvalue"))
        #expect(!body.contains("ABC123XYZ") || body.contains("code=redacted"))
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

    @Test("install registers SIGABRT in addition to SIGSEGV/SIGBUS")
    func installRegistersSigabrt() throws {
        #if os(macOS) || os(Linux)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-home-sigabrt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let crashDir = home.appendingPathComponent("crash", isDirectory: true)
        _ = installCrashHandler(
            CrashHandlerConfig(appVersion: "test-sigabrt", crashDir: crashDir),
            openGrokHome: home
        )
        // All three fatal signals must be on alternate stack (SA_ONSTACK) after install.
        // SA_ONSTACK is the portable proof the shim ran; SIGABRT capture is the delta at pin 650c1db7
        // (handler.rs:306-308). Handler pointer comparison is Darwin-specific (__sigaction_u vs
        // __sigaction_handler) so we rely on the flag alone here — the C shim's sigaction(SIGABRT)
        // line is the authoritative install proof.
        for sig in [SIGSEGV, SIGBUS, SIGABRT] {
            var sa = sigaction()
            let rc = sigaction(sig, nil, &sa)
            #expect(rc == 0, "sigaction query should succeed for signal \(sig)")
            #expect((sa.sa_flags & Int32(SA_ONSTACK)) != 0, "signal \(sig) must use SA_ONSTACK")
        }
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
