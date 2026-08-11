import Foundation
import OpenGrokLSP

/// Run `body` against a live `LSPSession` and shut the session down on every
/// exit path.
///
/// `defer { await session.shutdown() }` is what this replaces: an async call in
/// a defer body is rejected outright by some toolchains (it failed the macOS CI
/// build-tests step while compiling clean locally), and the obvious rewrite —
/// shutting down after the last assertion — silently skips cleanup whenever a
/// `try #require` throws first. These sessions own spawned language-server
/// child processes, so a skipped shutdown strands one per failed test.
func withLSPSession<T>(
    workspaceRoot: String,
    servers: [String: LspServerConfig],
    _ body: (LSPSession) async throws -> T
) async throws -> T {
    let session = LSPSession(workspaceRoot: workspaceRoot, servers: servers)
    do {
        let value = try await body(session)
        await session.shutdown()
        return value
    } catch {
        await session.shutdown()
        throw error
    }
}
