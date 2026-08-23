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

struct LiveFolderTrustScope: Hashable, Sendable {
    let ownerHome: String
    let workspace: String

    init(identity: URL, environment: [String: String]) {
        let home = OpenGrokHomeResolver.resolve(environment: environment)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let root = identity.standardizedFileURL.resolvingSymlinksInPath().path
        #if os(Windows)
        ownerHome = home.replacingOccurrences(of: "\\", with: "/").lowercased()
        workspace = root.replacingOccurrences(of: "\\", with: "/").lowercased()
        #else
        ownerHome = home
        workspace = root
        #endif
    }
}

final class LiveFolderTrustExecutorBinding: @unchecked Sendable {
    let id = UUID()
    let scope: LiveFolderTrustScope
    private let lock = NSLock()
    private var closed = false
    private let sessionID: String
    private let workingDirectory: URL
    private let environment: [String: String]
    private let launchPermissionOptions: CLIPermissionOptions
    private let runtime: LiveFolderTrustRuntimeState
    private let permissionPipeline: PermissionPipeline?
    private let hookPresentationStore: LiveHookPresentationStore
    private let connections: MCPSessionConnections
    private let toolset: FinalizedToolset

    init(
        sessionID: String,
        workingDirectory: URL,
        environment: [String: String],
        launchPermissionOptions: CLIPermissionOptions,
        runtime: LiveFolderTrustRuntimeState,
        permissionPipeline: PermissionPipeline?,
        hookPresentationStore: LiveHookPresentationStore,
        connections: MCPSessionConnections,
        toolset: FinalizedToolset
    ) {
        let identity = LiveWorkspaceTrustIdentity.resolve(
            workingDirectory: workingDirectory,
            environment: environment
        )
        scope = LiveFolderTrustScope(identity: identity, environment: environment)
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.launchPermissionOptions = launchPermissionOptions
        self.runtime = runtime
        self.permissionPipeline = permissionPipeline
        self.hookPresentationStore = hookPresentationStore
        self.connections = connections
        self.toolset = toolset
    }

    var isActive: Bool {
        lock.withLock { !closed }
    }

    func close() {
        lock.withLock { closed = true }
    }

    func failClosed() {
        guard isActive else { return }
        runtime.failClosed()
    }

    func prepare(trusted: Bool) {
        guard isActive else { return }
        _ = runtime.begin(trusted: trusted)
    }

    func matches(sessionID: String, workspaceRoot: URL, environment: [String: String]) -> Bool {
        self.sessionID == sessionID
            && LiveToolExecutor.workspaceRootsMatch(workingDirectory, workspaceRoot)
            && scope == LiveFolderTrustScope(
                identity: LiveWorkspaceTrustIdentity.resolve(
                    workingDirectory: workspaceRoot,
                    environment: environment
                ),
                environment: environment
            )
    }

    func reload(trusted: Bool) async -> Int {
        guard isActive else { return 0 }
        let previousDeclarations = runtime.begin(trusted: trusted)
        var options = launchPermissionOptions
        options.trustFolder = false
        let security = LiveSecurityContext.resolve(
            workspaceRoot: workingDirectory,
            environment: environment,
            isInteractive: false,
            cli: options
        )
        guard security.projectTrusted == trusted, isActive else {
            runtime.failClosed()
            return 0
        }

        let loadedHooks = LiveHooksComposition.load(
            sessionId: sessionID,
            workspaceRoot: workingDirectory,
            environment: environment,
            projectTrusted: trusted
        )
        let presentationStore = hookPresentationStore
        loadedHooks.gate?.setRunObserver { [presentationStore] event, id, records in
            Task {
                await presentationStore.record(event: event, id: id, records: records)
            }
        }
        if let permissionPipeline {
            let runner: any PreToolUseHookRunner = loadedHooks.gate
                .map { $0 as any PreToolUseHookRunner }
                ?? FailOpenPreToolUseHookRunner()
            await permissionPipeline.replaceLiveFolderTrustHooks(runner)
            await permissionPipeline.permissions.replaceConfig(security.permissions.config)
        }

        let disabledServers = disabledMCPServers(in: security.document)
        let declarations = MCPConfigLoader.load(from: security.document).enabledServers
            .filter { !disabledServers.contains($0.name) }
        let declarationsByName = Dictionary(uniqueKeysWithValues: declarations.map { ($0.name, $0) })
        for name in await connections.names() {
            if let previous = previousDeclarations[name],
               let current = declarationsByName[name],
               previous == current {
                continue
            }
            await connections.markServerShuttingDown(name)
            MCPToolBridge.unregister(server: name, from: toolset)
            if let client = await connections.release(named: name) {
                try? await client.shutdown()
                await client.close()
            }
        }

        if let previousLanguageSession = runtime.replaceLanguageSession(nil) {
            await previousLanguageSession.shutdown()
        }
        toolset.unregister(prefix: LiveLspComposition.toolName)
        guard isActive else {
            runtime.failClosed()
            return 0
        }
        let languageSession = LiveLspComposition.registerTools(
            toolset: toolset,
            workingDirectory: workingDirectory,
            document: security.document,
            environment: environment,
            projectTrusted: trusted
        )
        _ = runtime.replaceLanguageSession(languageSession)

        let disabledTools = allDisabledMCPTools(in: security.document)
        for declaration in declarations {
            guard isActive else {
                runtime.failClosed()
                return 0
            }
            guard await connections.client(named: declaration.name) == nil else { continue }
            await connections.markServerAvailable(declaration.name)
            let outcome = await LiveMCPComposition.connect(
                declaration: declaration,
                toolset: toolset,
                connections: connections,
                environment: environment,
                disabledToolNames: disabledTools[declaration.name] ?? [],
                managedMCPPolicy: security.managedMCPPolicy
            )
            if outcome.failure != nil {
                MCPToolBridge.unregister(server: declaration.name, from: toolset)
            }
        }
        guard isActive else {
            runtime.failClosed()
            return 0
        }
        LiveMCPToolSearchIndex.refreshIfPresent(in: toolset)
        runtime.finish(trusted: trusted, declarations: declarations)
        return loadedHooks.result.registry.count
    }
}

actor LiveFolderTrustExecutorRegistry {
    static let shared = LiveFolderTrustExecutorRegistry()

    private struct WeakBinding {
        weak var value: LiveFolderTrustExecutorBinding?
    }

    private var registrations: [LiveFolderTrustScope: [WeakBinding]] = [:]
    private var blocked: Set<LiveFolderTrustScope> = []

    func register(_ binding: LiveFolderTrustExecutorBinding) {
        var current = registrations[binding.scope, default: []].filter { $0.value?.isActive == true }
        current.append(WeakBinding(value: binding))
        registrations[binding.scope] = current
        if blocked.contains(binding.scope) {
            binding.failClosed()
        }
    }

    func unregister(_ binding: LiveFolderTrustExecutorBinding) {
        binding.close()
        let survivors = registrations[binding.scope, default: []].filter {
            guard let value = $0.value else { return false }
            return value.id != binding.id && value.isActive
        }
        if survivors.isEmpty {
            registrations.removeValue(forKey: binding.scope)
            blocked.remove(binding.scope)
        } else {
            registrations[binding.scope] = survivors
        }
    }

    func block(_ scope: LiveFolderTrustScope) {
        blocked.insert(scope)
        for binding in liveBindings(for: scope) {
            binding.failClosed()
        }
    }

    func failClosed(_ scope: LiveFolderTrustScope) {
        block(scope)
    }

    @discardableResult
    func broadcast(
        scope: LiveFolderTrustScope,
        trusted: Bool,
        initiatingID: UUID
    ) async -> Int {
        var processed: Set<UUID> = []
        var initiatingHookCount = 0

        while true {
            let pending = liveBindings(for: scope).filter { !processed.contains($0.id) }
            guard !pending.isEmpty else {
                blocked.remove(scope)
                return initiatingHookCount
            }

            // No actor suspension precedes this full pass: every sibling loses
            // stale project authority before the first hook/MCP/LSP reload.
            for binding in pending {
                binding.prepare(trusted: trusted)
            }
            for binding in pending {
                processed.insert(binding.id)
                let hookCount = await binding.reload(trusted: trusted)
                if binding.id == initiatingID {
                    initiatingHookCount = hookCount
                }
            }
        }
    }

    private func liveBindings(for scope: LiveFolderTrustScope) -> [LiveFolderTrustExecutorBinding] {
        let live = registrations[scope, default: []].compactMap { entry in
            entry.value.flatMap { $0.isActive ? $0 : nil }
        }
        registrations[scope] = live.map { WeakBinding(value: $0) }
        return live
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
        let checkoutRoot: URL
        do {
            let result = try runGit(["rev-parse", "--show-toplevel"], cwd: workingDirectory)
            guard result.exitCode == 0,
                  !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return trusted
                    ? "Not in a git repository. Project hooks require a git worktree root."
                    : "Not in a git repository."
            }
            checkoutRoot = URL(fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                .standardizedFileURL.resolvingSymlinksInPath()
        } catch {
            return trusted
                ? "Not in a git repository. Project hooks require a git worktree root."
                : "Not in a git repository."
        }

        let trustIdentity = LiveWorkspaceTrustIdentity.resolve(
            workingDirectory: checkoutRoot,
            environment: environment
        )
        guard !isUnsafeTrustRoot(trustIdentity.path, home: environment["HOME"]) else {
            return "Refusing folder trust for an unsafe workspace root: \(trustIdentity.path)"
        }
        let scope = LiveFolderTrustScope(identity: trustIdentity, environment: environment)
        guard executor.belongsToFolderTrustScope(scope) else {
            executor.failClosedAfterFolderTrustPersistenceFailure()
            return "Refusing folder trust outside the current session's workspace: \(checkoutRoot.path)"
        }

        var store = PersistentFolderTrustStore(environment: environment)
        let wasTrusted = store.isTrusted(trustIdentity)
        if !trusted, !wasTrusted {
            await LiveFolderTrustExecutorRegistry.shared.block(scope)
            await LiveFolderTrustExecutorRegistry.shared.broadcast(
                scope: scope,
                trusted: false,
                initiatingID: executor.folderTrustRegistrationID
            )
            return "Not currently trusted: \(trustIdentity.path)"
        }

        await LiveFolderTrustExecutorRegistry.shared.block(scope)
        do {
            try store.record(trustIdentity, trusted: trusted)
            let persisted = PersistentFolderTrustStore(environment: environment)
            guard persisted.isTrusted(trustIdentity) == trusted else {
                executor.failClosedAfterFolderTrustPersistenceFailure()
                await LiveFolderTrustExecutorRegistry.shared.failClosed(scope)
                return "Failed to persist folder trust for \(trustIdentity.path). Project access is blocked."
            }
        } catch {
            executor.failClosedAfterFolderTrustPersistenceFailure()
            await LiveFolderTrustExecutorRegistry.shared.failClosed(scope)
            return "Failed to persist folder trust for \(trustIdentity.path): \(error). Project access is blocked."
        }

        let hookCount = await LiveFolderTrustExecutorRegistry.shared.broadcast(
            scope: scope,
            trusted: trusted,
            initiatingID: executor.folderTrustRegistrationID
        )
        let prefix = trusted ? "Trusted" : "Untrusted"
        return "\(prefix): \(trustIdentity.path).\nHooks reloaded: \(hookCount) hook(s) loaded."
    }
}
