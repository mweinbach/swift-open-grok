import Foundation
import OpenGrokConfig
import OpenGrokFastWorktree
import OpenGrokHooks
import OpenGrokLSP
import OpenGrokMCP
import OpenGrokToolRegistry
import OpenGrokWorkspace

final class LiveFolderTrustRuntimeState: @unchecked Sendable {
    private let lock = NSLock()
    private var trusted: Bool
    private var changing = false
    private var declarations: [String: MCPServerDeclaration]
    private var languageSession: LSPSession?

    init(
        trusted: Bool,
        declarations: [MCPServerDeclaration],
        languageSession: LSPSession?
    ) {
        self.trusted = trusted
        self.declarations = Dictionary(uniqueKeysWithValues: declarations.map { ($0.name, $0) })
        self.languageSession = languageSession
    }

    var isTrusted: Bool {
        lock.withLock { trusted }
    }

    var isChanging: Bool {
        lock.withLock { changing }
    }

    var currentLanguageSession: LSPSession? {
        lock.withLock { languageSession }
    }

    func begin(trusted: Bool) -> [String: MCPServerDeclaration] {
        lock.withLock {
            self.trusted = trusted
            changing = true
            return declarations
        }
    }

    func replaceLanguageSession(_ replacement: LSPSession?) -> LSPSession? {
        lock.withLock {
            let previous = languageSession
            languageSession = replacement
            return previous
        }
    }

    func finish(trusted: Bool, declarations: [MCPServerDeclaration]) {
        lock.withLock {
            self.trusted = trusted
            self.declarations = Dictionary(uniqueKeysWithValues: declarations.map { ($0.name, $0) })
            changing = false
        }
    }

    func failClosed() {
        lock.withLock {
            trusted = false
            changing = true
        }
    }
}

extension PermissionPipeline {
    func replaceLiveFolderTrustHooks(_ runner: any PreToolUseHookRunner) {
        hooks = runner
    }

    func liveFolderTrustHookGate() -> HookPermissionGate? {
        hooks as? HookPermissionGate
    }
}

enum LiveFolderTrustControls {
    static func change(
        trusted: Bool,
        workingDirectory: URL,
        sessionID: String,
        environment: [String: String],
        executor: LiveToolExecutor
    ) async -> String {
        let root: URL
        do {
            let result = try runGit(["rev-parse", "--show-toplevel"], cwd: workingDirectory)
            guard result.exitCode == 0,
                  !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return trusted
                    ? "Not in a git repository. Project hooks require a git worktree root."
                    : "Not in a git repository."
            }
            root = URL(fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                .standardizedFileURL.resolvingSymlinksInPath()
        } catch {
            return trusted
                ? "Not in a git repository. Project hooks require a git worktree root."
                : "Not in a git repository."
        }

        guard !isUnsafeTrustRoot(root.path, home: environment["HOME"]) else {
            return "Refusing folder trust for an unsafe workspace root: \(root.path)"
        }

        var store = PersistentFolderTrustStore(environment: environment)
        let wasTrusted = store.isTrusted(root)
        if !trusted, !wasTrusted {
            _ = await executor.reloadFolderTrust(
                trusted: false,
                sessionID: sessionID,
                workspaceRoot: root,
                environment: environment
            )
            return "Not currently trusted: \(root.path)"
        }

        do {
            try store.record(root, trusted: trusted)
            let persisted = PersistentFolderTrustStore(environment: environment)
            guard persisted.isTrusted(root) == trusted else {
                executor.failClosedAfterFolderTrustPersistenceFailure()
                return "Failed to persist folder trust for \(root.path). Project access is blocked."
            }
        } catch {
            executor.failClosedAfterFolderTrustPersistenceFailure()
            return "Failed to persist folder trust for \(root.path): \(error). Project access is blocked."
        }

        let hookCount = await executor.reloadFolderTrust(
            trusted: trusted,
            sessionID: sessionID,
            workspaceRoot: root,
            environment: environment
        )
        let prefix = trusted ? "Trusted" : "Untrusted"
        return "\(prefix): \(root.path).\nHooks reloaded: \(hookCount) hook(s) loaded."
    }
}
