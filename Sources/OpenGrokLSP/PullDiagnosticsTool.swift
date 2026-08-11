import Foundation
import OpenGrokShared

public enum PullDiagnosticsTool {
    public static let toolName = "pull_diagnostics"

    public static var spec: PullDiagnosticsToolSpec {
        PullDiagnosticsToolSpec(
            name: toolName,
            description: """
            Pull language-server diagnostics for one file via `textDocument/diagnostic`. \
            Requires a configured LSP server whose extension map covers the file.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("File path to inspect, relative to the workspace or absolute."),
                    ]),
                ]),
                "required": .array([.string("path")]),
                "additionalProperties": .bool(false),
            ])
        )
    }
}

public struct PullDiagnosticsToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    public var parameters: JSONValue
}

/// How long drain waits for push/pull answers after an edit.
///
/// Rust reference: `mod.rs` `DIAGNOSTICS_DRAIN_TIMEOUT` (500ms).
public enum LSPDiagnostics {
    public static let drainTimeout: TimeInterval = 0.5
}

private struct PendingDiagnosticWait: Sendable, Equatable {
    var serverName: String
    var uri: String
    var version: Int
    var absolutePath: String
}

/// Live LSP session: multi-server by extension, document sync, push/pull
/// diagnostics, and drain for after-edit reminders.
///
/// Rust reference: `manager.rs` + `client.rs` notify/drain path.
public actor LSPSession {
    public let workspaceRoot: String
    private var servers: [String: LspServerConfig]
    private var clients: [String: LSPStdioClient] = [:]
    private var supportFlags: [String: PullSupportFlag] = [:]
    private var documentsByServer: [String: Documents] = [:]
    private var diagnosticsByServer: [String: DiagnosticsStore] = [:]
    private var initializedRoots: [String: String] = [:]
    private var pending: [PendingDiagnosticWait] = []

    public init(workspaceRoot: String, servers: [String: LspServerConfig]) {
        self.workspaceRoot = workspaceRoot
        self.servers = servers
    }

    public func pullDiagnostics(path: String) async -> String {
        guard let resolved = LSPConfigLoader.resolveServer(for: path, servers: servers) else {
            return "No configured LSP server handles '\(path)'."
        }
        let support = supportFlag(for: resolved.name)
        guard support.get() == .asking else {
            return "LSP server '\(resolved.name)' does not support pull diagnostics."
        }

        let absolutePath = LSPDocumentURI.resolvePath(path, workspaceRoot: workspaceRoot)
        let uri = LSPDocumentURI.fileURI(for: absolutePath, workspaceRoot: workspaceRoot)

        do {
            let client = try await client(for: resolved.name, config: resolved.config)
            let outcome = await PullDiagnostics.request(
                client: client,
                uri: uri,
                previousResultID: nil,
                support: support
            )
            switch outcome {
            case .reported(let items, _):
                return DiagnosticFormatting.format(path: absolutePath, diagnostics: items)
            case .clean:
                return DiagnosticFormatting.format(path: absolutePath, diagnostics: [])
            case .unsupported:
                return "LSP server '\(resolved.name)' does not support pull diagnostics."
            case .failed(let detail):
                return "Diagnostic pull failed for '\(absolutePath)': \(detail)"
            }
        } catch {
            return "Diagnostic pull failed for '\(absolutePath)': \(error)"
        }
    }

    /// Tell the matching server about the current contents of `path`.
    ///
    /// Sends `didOpen` or ranged full-text `didChange`, then marks the URI
    /// pending for drain. Pull-model servers that never publish get a
    /// background `textDocument/diagnostic` ask.
    ///
    /// Rust reference: `client.rs` `notify_file_change` / `manager.rs` `notify_file_changed`.
    public func notifyFileChanged(path: String, content: String) async {
        guard let resolved = LSPConfigLoader.resolveServer(for: path, servers: servers) else {
            return
        }
        let absolutePath = LSPDocumentURI.resolvePath(path, workspaceRoot: workspaceRoot)
        let uri = LSPDocumentURI.fileURI(for: absolutePath, workspaceRoot: workspaceRoot)
        let documents = documents(for: resolved.name)
        let store = diagnosticsStore(for: resolved.name)
        let update = documents.plan(uri: uri)
        let version = update.version
        let newEnd = Documents.endPosition(content)

        do {
            let client = try await client(for: resolved.name, config: resolved.config)
            switch update {
            case .open(let openVersion):
                try await client.notify(LSPJSONRPCNotification(
                    method: "textDocument/didOpen",
                    params: .object([
                        "textDocument": .object([
                            "uri": .string(uri),
                            "languageId": .string(resolved.languageID),
                            "version": .number(.int64(Int64(openVersion))),
                            "text": .string(content),
                        ]),
                    ])
                ))
            case .change(let changeVersion, let previousEnd):
                try await client.notify(LSPJSONRPCNotification(
                    method: "textDocument/didChange",
                    params: .object([
                        "textDocument": .object([
                            "uri": .string(uri),
                            "version": .number(.int64(Int64(changeVersion))),
                        ]),
                        "contentChanges": .array([
                            .object([
                                "range": .object([
                                    "start": .object([
                                        "line": .number(.int64(0)),
                                        "character": .number(.int64(0)),
                                    ]),
                                    "end": .object([
                                        "line": .number(.int64(Int64(previousEnd.line))),
                                        "character": .number(.int64(Int64(previousEnd.character))),
                                    ]),
                                ]),
                                "text": .string(content),
                            ]),
                        ]),
                    ])
                ))
            }
            documents.commit(
                uri: uri,
                version: version,
                languageID: resolved.languageID,
                end: newEnd
            )
            // A push can land between the write and commit; re-credit it now
            // that `latestSent` is known so drain is not stuck on NO_VERSION.
            if store.covers(uri: uri) == DiagnosticsStore.noVersion {
                let items = store.items(uri: uri)
                _ = store.recordPush(
                    uri: uri,
                    diagnostics: items,
                    reported: version,
                    latestSent: version
                )
            }
            pending.append(PendingDiagnosticWait(
                serverName: resolved.name,
                uri: uri,
                version: version,
                absolutePath: absolutePath
            ))
            if !store.serverPublishes() {
                schedulePull(
                    serverName: resolved.name,
                    client: client,
                    uri: uri,
                    version: version,
                    store: store
                )
            }
        } catch {
            // Failed notify must not advance documents — plan/commit already
            // kept them separate; nothing to wait for.
        }
    }

    /// Wait up to `timeout` for pending files to be answered; return a wrapped
    /// summary, or `nil` if nothing reportable arrived.
    ///
    /// Rust reference: `manager.rs` `drain_lsp_diagnostics` / `take_answered_diagnostics`.
    public func drainDiagnostics(
        timeout: TimeInterval = LSPDiagnostics.drainTimeout
    ) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let summary = takeAnsweredDiagnostics() {
                return summary
            }
            if !hasPendingDiagnostics {
                return nil
            }
            if Date() >= deadline {
                return takeAnsweredDiagnostics()
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    public func support(for serverName: String) -> PullSupport {
        supportFlag(for: serverName).get()
    }

    public func shutdown() async {
        for client in clients.values {
            await client.close()
        }
        clients.removeAll()
        pending.removeAll()
    }

    // MARK: - Private

    private var hasPendingDiagnostics: Bool {
        !pending.isEmpty
    }

    private func takeAnsweredDiagnostics() -> String? {
        var remaining: [PendingDiagnosticWait] = []
        var lines: [String] = []

        for wait in pending {
            guard let store = diagnosticsByServer[wait.serverName] else {
                remaining.append(wait)
                continue
            }
            guard store.answered(for: wait.uri, version: wait.version) else {
                remaining.append(wait)
                continue
            }
            let reportable = DiagnosticFormatting.reportable(store.items(uri: wait.uri))
            for diagnostic in reportable {
                lines.append(DiagnosticFormatting.drainLine(
                    path: wait.absolutePath,
                    diagnostic: diagnostic
                ))
            }
        }
        pending = remaining
        guard !lines.isEmpty else { return nil }
        return DiagnosticFormatting.wrapDrainSummary(lines)
    }

    private func schedulePull(
        serverName: String,
        client: LSPStdioClient,
        uri: String,
        version: Int,
        store: DiagnosticsStore
    ) {
        let support = supportFlag(for: serverName)
        guard support.get() == .asking else { return }
        Task {
            let outcome = await PullDiagnostics.request(
                client: client,
                uri: uri,
                previousResultID: nil,
                support: support
            )
            // A server that publishes must not have its pull answer taken as
            // the whole picture (rust-analyzer cargo check case).
            if store.serverPublishes() { return }
            switch outcome {
            case .reported(let items, let resultID):
                _ = store.install(
                    uri: uri,
                    answer: DiagnosticAnswer(items: items, covers: version, resultID: resultID)
                )
            case .clean(let resultID):
                _ = store.install(
                    uri: uri,
                    answer: DiagnosticAnswer(items: [], covers: version, resultID: resultID)
                )
            case .unsupported, .failed:
                break
            }
        }
    }

    private func supportFlag(for serverName: String) -> PullSupportFlag {
        if let existing = supportFlags[serverName] {
            return existing
        }
        let created = PullSupportFlag()
        supportFlags[serverName] = created
        return created
    }

    private func documents(for serverName: String) -> Documents {
        if let existing = documentsByServer[serverName] {
            return existing
        }
        let created = Documents()
        documentsByServer[serverName] = created
        return created
    }

    private func diagnosticsStore(for serverName: String) -> DiagnosticsStore {
        if let existing = diagnosticsByServer[serverName] {
            return existing
        }
        let created = DiagnosticsStore()
        diagnosticsByServer[serverName] = created
        return created
    }

    private func client(for serverName: String, config: LspServerConfig) async throws -> LSPStdioClient {
        if let existing = clients[serverName] {
            return existing
        }
        let root = config.effectiveRoot(workspaceRoot: workspaceRoot)
        let rootURI = LSPDocumentURI.fileURI(for: root, workspaceRoot: workspaceRoot)
        let documents = documents(for: serverName)
        let store = diagnosticsStore(for: serverName)
        let client = LSPStdioClient(
            configuration: LSPStdioClientConfiguration(
                command: config.command,
                arguments: config.args,
                environment: config.env.isEmpty ? nil : config.env,
                currentDirectoryPath: root,
                requestTimeout: PullDiagnostics.requestTimeout
            )
        )
        await client.setNotificationHandler { method, params in
            Self.handleNotification(
                method: method,
                params: params,
                documents: documents,
                store: store
            )
        }
        try await client.start()
        if initializedRoots[serverName] != rootURI {
            try await client.initialize(rootURI: rootURI)
            initializedRoots[serverName] = rootURI
        }
        clients[serverName] = client
        return client
    }

    private static func handleNotification(
        method: String,
        params: JSONValue?,
        documents: Documents,
        store: DiagnosticsStore
    ) {
        guard method == "textDocument/publishDiagnostics" else { return }
        guard case .object(let object)? = params else { return }
        guard case .string(let uri)? = object["uri"] else { return }
        let reported: Int?
        if let value = object["version"]?.int64Value {
            reported = Int(value)
        } else if let value = object["version"]?.doubleValue {
            reported = Int(value)
        } else {
            reported = nil
        }
        let items = PullDiagnostics.parseDiagnostics(object["diagnostics"])
        _ = store.recordPush(
            uri: uri,
            diagnostics: items,
            reported: reported,
            latestSent: documents.version(uri: uri)
        )
    }
}

/// Compatibility alias — LiveComposition still stores `lspPullSession`.
public typealias LSPPullSession = LSPSession
