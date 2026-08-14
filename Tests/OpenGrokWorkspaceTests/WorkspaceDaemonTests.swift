// WorkspaceDaemonTests.swift
//
// Tests for self-daemonization, stdio redirection, OOM protection,
// and PidFile single-instance locking / takeover.
// Ported from `xai-grok-workspace-daemon/src/daemonize.rs`.

import Foundation
import Testing
@testable import OpenGrokWorkspace

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("WorkspaceDaemon & PidFile tests")
struct WorkspaceDaemonTests {
    private func temporaryDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-daemon-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanUp(dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("pidfile acquire is exclusive")
    func pidfileAcquireIsExclusive() throws {
        let dir = temporaryDirectory()
        defer { cleanUp(dir: dir) }
        let path = dir.appendingPathComponent("ws.pid").path

        let first = try PidFile.acquire(path: path)
        #expect(first != nil, "first acquire should win the lock")

        let second = try PidFile.acquire(path: path)
        #expect(second == nil, "contended acquire must report nil")

        first?.close()

        // After releasing, acquire should succeed again.
        var third: PidFile? = nil
        let deadline = Date().addingTimeInterval(2.0)
        while third == nil && Date() < deadline {
            third = try PidFile.acquire(path: path)
            if third == nil {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        #expect(third != nil, "acquire should succeed after release")
        third?.close()
    }

    @Test("pidfile records current PID")
    func pidfileRecordsCurrentPID() throws {
        let dir = temporaryDirectory()
        defer { cleanUp(dir: dir) }
        let path = dir.appendingPathComponent("ws.pid").path

        let guardFile = try PidFile.acquire(path: path)
        #expect(guardFile != nil)
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        let pid = Int(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(pid == Int(getpid()))
        guardFile?.close()
    }

    @Test("pidfile persists on disk after close")
    func pidfilePersistsOnDiskAfterClose() throws {
        let dir = temporaryDirectory()
        defer { cleanUp(dir: dir) }
        let path = dir.appendingPathComponent("ws.pid").path

        let guardFile = try PidFile.acquire(path: path)
        #expect(FileManager.default.fileExists(atPath: path))
        guardFile?.close()
        #expect(FileManager.default.fileExists(atPath: path), "pidfile should remain on disk after close")
    }

    @Test("pidfile acquire creates parent dir")
    func pidfileAcquireCreatesParentDir() throws {
        let dir = temporaryDirectory()
        defer { cleanUp(dir: dir) }
        let path = dir.appendingPathComponent("nested/sub/ws.pid").path

        let guardFile = try PidFile.acquire(path: path)
        #expect(guardFile != nil)
        #expect(FileManager.default.fileExists(atPath: path))
        guardFile?.close()
    }

    @Test("pidfile acquire truncates stale longer content")
    func pidfileAcquireTruncatesStaleLongerContent() throws {
        let dir = temporaryDirectory()
        defer { cleanUp(dir: dir) }
        let path = dir.appendingPathComponent("ws.pid").path
        try "999999999999 stale junk\n".write(toFile: path, atomically: false, encoding: .utf8)

        let guardFile = try PidFile.acquire(path: path)
        #expect(guardFile != nil)
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(contents == "\(getpid())\n", "stale content must be fully truncated")
        guardFile?.close()
    }

    @Test("contended acquire does not modify pidfile")
    func contendedAcquireDoesNotModifyPidfile() throws {
        let dir = temporaryDirectory()
        defer { cleanUp(dir: dir) }
        let path = dir.appendingPathComponent("ws.pid").path

        let holder = try PidFile.acquire(path: path)
        #expect(holder != nil)
        let before = try String(contentsOfFile: path, encoding: .utf8)

        let contended = try PidFile.acquire(path: path)
        #expect(contended == nil)

        let after = try String(contentsOfFile: path, encoding: .utf8)
        #expect(before == after, "contended acquire must not rewrite the file")
        holder?.close()
    }

    @Test("pidfile acquire errors on directory")
    func pidfileAcquireErrorsOnDirectory() throws {
        let dir = temporaryDirectory()
        defer { cleanUp(dir: dir) }
        let asDir = dir.appendingPathComponent("a_dir").path
        try FileManager.default.createDirectory(atPath: asDir, withIntermediateDirectories: true)

        #expect(throws: Error.self) {
            _ = try PidFile.acquire(path: asDir)
        }
    }

    #if !os(Windows)
    @Test("open stdio targets opens /dev/null and log")
    func openStdioTargetsOpensDevNullAndLog() throws {
        let dir = temporaryDirectory()
        defer { cleanUp(dir: dir) }
        let logPath = dir.appendingPathComponent("logs/ws.log").path

        let targets = try openStdioTargets(logPath: logPath)
        defer {
            Darwin.close(targets.stdinFd)
            Darwin.close(targets.logFd)
        }

        #expect(FileManager.default.fileExists(atPath: logPath))
        let msg = "hello"
        _ = msg.withCString { ptr in
            write(targets.logFd, ptr, msg.utf8.count)
        }
        let readBack = try String(contentsOfFile: logPath, encoding: .utf8)
        #expect(readBack == "hello")

        var buf = [UInt8](repeating: 0, count: 4)
        let bytesRead = read(targets.stdinFd, &buf, buf.count)
        #expect(bytesRead == 0, "/dev/null read yields EOF")
    }

    @Test("open stdio targets appends to existing log")
    func openStdioTargetsAppendsToExistingLog() throws {
        let dir = temporaryDirectory()
        defer { cleanUp(dir: dir) }
        let logPath = dir.appendingPathComponent("ws.log").path
        try "prior\n".write(toFile: logPath, atomically: false, encoding: .utf8)

        let targets = try openStdioTargets(logPath: logPath)
        defer {
            Darwin.close(targets.stdinFd)
            Darwin.close(targets.logFd)
        }

        let more = "more\n"
        _ = more.withCString { ptr in
            write(targets.logFd, ptr, more.utf8.count)
        }
        let readBack = try String(contentsOfFile: logPath, encoding: .utf8)
        #expect(readBack == "prior\nmore\n")
    }

    @Test("open stdio targets errors when parent is a file")
    func openStdioTargetsErrorsWhenParentIsAFile() throws {
        let dir = temporaryDirectory()
        defer { cleanUp(dir: dir) }
        let parentFile = dir.appendingPathComponent("not_a_dir").path
        try "x".write(toFile: parentFile, atomically: false, encoding: .utf8)
        let logPath = dir.appendingPathComponent("not_a_dir/ws.log").path

        #expect(throws: Error.self) {
            _ = try openStdioTargets(logPath: logPath)
        }
    }

    @Test("open stdio targets rejects symlinked log")
    func openStdioTargetsRejectsSymlinkedLog() throws {
        let dir = temporaryDirectory()
        defer { cleanUp(dir: dir) }
        let realLog = dir.appendingPathComponent("real.log").path
        try "".write(toFile: realLog, atomically: false, encoding: .utf8)
        let linkLog = dir.appendingPathComponent("link.log").path
        try FileManager.default.createSymbolicLink(atPath: linkLog, withDestinationPath: realLog)

        #expect(throws: Error.self) {
            _ = try openStdioTargets(logPath: linkLog)
        }
    }

    @Test("pidfile acquire rejects symlinked path")
    func pidfileAcquireRejectsSymlinkedPath() throws {
        let dir = temporaryDirectory()
        defer { cleanUp(dir: dir) }
        let realPid = dir.appendingPathComponent("real.pid").path
        let linkPid = dir.appendingPathComponent("link.pid").path
        try FileManager.default.createSymbolicLink(atPath: linkPid, withDestinationPath: realPid)

        #expect(throws: Error.self) {
            _ = try PidFile.acquire(path: linkPid)
        }
        #expect(!FileManager.default.fileExists(atPath: realPid))
    }

    @Test("pidfile created mode is owner only")
    func pidfileCreatedModeIsOwnerOnly() throws {
        let dir = temporaryDirectory()
        defer { cleanUp(dir: dir) }
        let path = dir.appendingPathComponent("ws.pid").path

        let guardFile = try PidFile.acquire(path: path)
        #expect(guardFile != nil)

        var statBuf = stat()
        #if canImport(Darwin)
        stat(path, &statBuf)
        #elseif canImport(Glibc)
        Glibc.stat(path, &statBuf)
        #endif
        let mode = statBuf.st_mode
        #expect(mode & 0o077 == 0, "pidfile must not be group/other-accessible")
        guardFile?.close()
    }
    #endif

    @Test("take over uncontended acquires normally")
    func takeOverUncontendedAcquiresNormally() throws {
        let dir = temporaryDirectory()
        defer { cleanUp(dir: dir) }
        let path = dir.appendingPathComponent("ws.pid").path

        let guardFile = try PidFile.acquireOrTakeOver(path: path, grace: 0.1)
        #expect(guardFile != nil)
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(contents == "\(getpid())\n")
        guardFile?.close()
    }

    @Test("take over declines unreadable pidfile")
    func takeOverDeclinesUnreadablePidfile() throws {
        let dir = temporaryDirectory()
        defer { cleanUp(dir: dir) }
        let path = dir.appendingPathComponent("ws.pid").path

        let holder = try PidFile.acquire(path: path)
        #expect(holder != nil)
        try "not a pid".write(toFile: path, atomically: false, encoding: .utf8)

        let taken = try PidFile.acquireOrTakeOverMatching(path: path, grace: 0.1, nameFragment: "sleep")
        #expect(taken == nil, "an unidentifiable holder must be declined")
        holder?.close()
    }

    @Test("take over declines own pid")
    func takeOverDeclinesOwnPid() throws {
        let dir = temporaryDirectory()
        defer { cleanUp(dir: dir) }
        let path = dir.appendingPathComponent("ws.pid").path

        let holder = try PidFile.acquire(path: path)
        #expect(holder != nil)

        let taken = try PidFile.acquireOrTakeOverMatching(path: path, grace: 0.1, nameFragment: "")
        #expect(taken == nil)
        holder?.close()
    }

    @Test("basename contains ignores directory components")
    func basenameContainsIgnoresDirectoryComponents() {
        #expect(basenameContains(name: "/usr/local/bin/xai-workspace-server", fragment: "workspace-server"))
        #expect(basenameContains(name: "C:\\Program Files\\XAI-Workspace-Server.exe", fragment: "workspace-server"))
        #expect(!basenameContains(name: "/var/lib/workspace-server-data/unrelated", fragment: "workspace-server"))
    }

    @Test("read pidfile pid parses and rejects")
    func readPidfilePidParsesAndRejects() throws {
        let dir = temporaryDirectory()
        defer { cleanUp(dir: dir) }
        let path = dir.appendingPathComponent("ws.pid").path

        try "1234\n".write(toFile: path, atomically: false, encoding: .utf8)
        #expect(readPidfilePid(path) == 1234)

        try "0".write(toFile: path, atomically: false, encoding: .utf8)
        #expect(readPidfilePid(path) == nil, "pid 0 is not valid")

        try "garbage".write(toFile: path, atomically: false, encoding: .utf8)
        #expect(readPidfilePid(path) == nil)

        #expect(readPidfilePid(dir.appendingPathComponent("missing").path) == nil)
    }

    @Test("oom score constants preserve ordering")
    func oomScoreConstantsPreserveOrdering() {
        #expect(PREVIEW_PROXY_OOM_SCORE_ADJ < 0)
        #expect(WORKSPACE_SERVER_OOM_SCORE_ADJ < PREVIEW_PROXY_OOM_SCORE_ADJ)
        #expect(WORKSPACE_SERVER_OOM_SCORE_ADJ > -1000)
    }

    @Test("record oom protect records outcome")
    func recordOOMProtectRecordsOutcome() {
        let before = oomProtectCounts()
        recordOOMProtect(outcome: "applied")
        recordOOMProtect(outcome: "failed")
        let after = oomProtectCounts()
        #expect(after.applied > before.applied)
        #expect(after.failed > before.failed)
    }
}
