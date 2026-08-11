import Foundation
import OpenGrokConfigTypes
import Testing
@testable import OpenGrokCLI
import OpenGrokMemory

private func makeDreamTestWorkspace() throws -> (root: URL, storage: MemoryStorage, backend: LiveMemoryBackend) {
    let repoBuild = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(".build/dream-cli-tests", isDirectory: true)
    let root = repoBuild.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cwd = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    let grokHome = root.appendingPathComponent("state", isDirectory: true)
    let environment = [
        "OPENGROK_HOME": grokHome.path,
        "OPENGROK_MEMORY": "1",
    ]
    var config = LiveMemoryConfiguration.disabled
    config.enabled = true
    config.dream = MemoryDreamConfig(enabled: true)
    guard let backend = LiveMemoryBackend(
        configuration: config,
        workingDirectory: cwd,
        environment: environment
    ) else {
        throw NSError(domain: "DreamTest", code: 1)
    }
    let storage = MemoryStorage(cwd: cwd, environment: environment)
    return (root, storage, backend)
}

@Suite("Live /dream command")
struct LiveMemoryDreamTests {
    @Test("/dream with fake sampler writes MEMORY.md")
    func dreamWritesMemory() async throws {
        let fixture = try makeDreamTestWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.storage.ensureInitialized()
        let sessions = fixture.storage.sessionsDir
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let sessionFile = sessions.appendingPathComponent("2026-08-10-proj-sess9999.md")
        try "Decision: ship dream runtime.".write(to: sessionFile, atomically: true, encoding: .utf8)
        let oldDate = Date(timeIntervalSinceNow: -600)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: sessionFile.path
        )

        let response = "## Consolidated\n\nShipped dream runtime."
        let message = await LiveMemoryCommands.dream(
            backend: fixture.backend,
            dreamConfig: MemoryDreamConfig(enabled: true),
            sessionID: "current1",
            sampler: LiveMemoryDreamSampler { _, _ in response }
        )
        #expect(message.contains("complete"))
        let memory = try String(contentsOf: fixture.storage.workspaceMemoryFile, encoding: .utf8)
        #expect(memory.contains("Shipped dream runtime."))
    }

    @Test("disabled dream config refuses /dream")
    func disabledRefuses() async throws {
        let fixture = try makeDreamTestWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let message = await LiveMemoryCommands.dream(
            backend: fixture.backend,
            dreamConfig: MemoryDreamConfig(enabled: false),
            sessionID: "test0001",
            sampler: LiveMemoryDreamSampler { _, _ in "## Topic\n\nNever called." }
        )
        #expect(message.contains("disabled"))
    }
}
