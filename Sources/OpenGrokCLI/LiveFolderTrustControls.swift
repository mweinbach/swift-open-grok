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

enum LiveFolderTrustStartupCheckpoint: Sendable {
    case beforeProjectMCP
}

final class LiveFolderTrustStartupReservation: @unchecked Sendable {
    let id = UUID()
    let scope: LiveFolderTrustScope
    private let lock = NSLock()
    private var pending = true
    private var invalidated = false

    init(scope: LiveFolderTrustScope) {
        self.scope = scope
    }

    var isPending: Bool {
        lock.withLock { pending }
    }

    var wasInvalidated: Bool {
        lock.withLock { invalidated }
    }

    func invalidate() {
        lock.withLock {
            if pending { invalidated = true }
        }
    }

    func consume() {
        lock.withLock { pending = false }
    }
}

enum LiveFolderTrustStartupAdmission: Sendable {
    case admitted
    case changed(LiveSecurityContext)
    case blocked
}

final class LiveFolderTrustStartupMCPConfiguration: @unchecked Sendable {
    private let lock = NSLock()
    private var currentDeclarations: MCPConfigLoadResult
    private var currentDisabledTools: [String: Set<String>]

    init(document: TOMLValue) {
        currentDeclarations = MCPConfigLoader.load(from: document)
        currentDisabledTools = allDisabledMCPTools(in: document)
    }

    var declarations: MCPConfigLoadResult {
        lock.withLock { currentDeclarations }
    }

    func disabledTools(for server: String) -> Set<String> {
        lock.withLock { currentDisabledTools[server] ?? [] }
    }

    func replace(document: TOMLValue) {
        let declarations = MCPConfigLoader.load(from: document)
        let disabledTools = allDisabledMCPTools(in: document)
        lock.withLock {
            currentDeclarations = declarations
            currentDisabledTools = disabledTools
        }
    }
}

final class LiveFolderTrustExecutorBinding: @unchecked Sendable {
    let id = UUID()
    let scope: LiveFolderTrustScope
    private let lock = NSLock()
    private var closed = false
    private var startingUp = true
    private var connectionsStarted = false
    private var managedSettingsSourceBound = false
    private var managedSettingsSourcePath: URL?
    private let sessionID: String
    private let workingDirectory: URL
    private let environment: [String: String]
    private let launchPermissionOptions: CLIPermissionOptions
    private let runtime: LiveFolderTrustRuntimeState
    private let permissionPipeline: PermissionPipeline?
    private let hookPresentationStore: LiveHookPresentationStore
    private let connections: MCPSessionConnections
    private let toolset: FinalizedToolset
    private let mcpConfiguration: LiveFolderTrustStartupMCPConfiguration

    init(
        sessionID: String,
        workingDirectory: URL,
        environment: [String: String],
        launchPermissionOptions: CLIPermissionOptions,
        runtime: LiveFolderTrustRuntimeState,
        permissionPipeline: PermissionPipeline?,
        hookPresentationStore: LiveHookPresentationStore,
        connections: MCPSessionConnections,
        toolset: FinalizedToolset,
        mcpConfiguration: LiveFolderTrustStartupMCPConfiguration
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
        self.mcpConfiguration = mcpConfiguration
    }

    var isActive: Bool {
        lock.withLock { !closed }
    }

    var administratorManagedSettingsPath: URL? {
        lock.withLock { managedSettingsSourcePath }
    }

    func bindAdministratorManagedSettingsPath(_ path: URL?) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            if managedSettingsSourceBound {
                return managedSettingsSourcePath == path
            }
            managedSettingsSourcePath = path
            managedSettingsSourceBound = true
            return true
        }
    }

    private var canDeferStartupConnections: Bool {
        lock.withLock { startingUp && !connectionsStarted && !closed }
    }

    func finishStartup() {
        lock.withLock { startingUp = false }
    }

    func beginStartupConnections() {
        lock.withLock { connectionsStarted = true }
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

    @discardableResult
    func reload(trusted: Bool) async -> Int {
        guard isActive else { return 0 }
        let previousDeclarations = runtime.begin(trusted: trusted)
        var options = launchPermissionOptions
        options.trustFolder = false
        let security = LiveSecurityContext.resolve(
            workspaceRoot: workingDirectory,
            environment: environment,
            isInteractive: false,
            cli: options,
            managedSettingsPath: administratorManagedSettingsPath
        )
        guard security.projectTrusted == trusted, isActive else {
            runtime.failClosed()
            return 0
        }
        mcpConfiguration.replace(document: security.document)

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

        if canDeferStartupConnections {
            runtime.finish(trusted: trusted, declarations: declarationsFor(security))
            return loadedHooks.result.registry.count
        }

        let declarations = declarationsFor(security)
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

    private func declarationsFor(_ security: LiveSecurityContext) -> [MCPServerDeclaration] {
        let disabled = disabledMCPServers(in: security.document)
        return MCPConfigLoader.load(from: security.document).enabledServers
            .filter { !disabled.contains($0.name) }
    }
}

actor LiveFolderTrustExecutorRegistry {
    static let shared = LiveFolderTrustExecutorRegistry()

    private struct WeakBinding {
        weak var value: LiveFolderTrustExecutorBinding?
    }

    private struct WeakStartup {
        weak var value: LiveFolderTrustStartupReservation?
    }

    private var registrations: [LiveFolderTrustScope: [WeakBinding]] = [:]
    private var startups: [LiveFolderTrustScope: [WeakStartup]] = [:]
    private var blocked: Set<LiveFolderTrustScope> = []
    private var decisions: [LiveFolderTrustScope: Bool] = [:]

    func reserveStartup(_ reservation: LiveFolderTrustStartupReservation) {
        var current = startups[reservation.scope, default: []].filter { $0.value?.isPending == true }
        current.append(WeakStartup(value: reservation))
        startups[reservation.scope] = current
        if blocked.contains(reservation.scope) || decisions[reservation.scope] == false {
            reservation.invalidate()
        }
    }

    func cancelStartup(_ reservation: LiveFolderTrustStartupReservation) {
        reservation.consume()
        let remaining = startups[reservation.scope, default: []].filter {
            guard let value = $0.value else { return false }
            return value.id != reservation.id && value.isPending
        }
        if remaining.isEmpty {
            startups.removeValue(forKey: reservation.scope)
        } else {
            startups[reservation.scope] = remaining
        }
    }

    func admitStartup(
        _ binding: LiveFolderTrustExecutorBinding,
        reservation: LiveFolderTrustStartupReservation,
        proposed: LiveSecurityContext,
        workingDirectory: URL,
        environment: [String: String],
        permissionOptions: CLIPermissionOptions
    ) -> LiveFolderTrustStartupAdmission {
        guard reservation.isPending,
              binding.scope == reservation.scope,
              !blocked.contains(binding.scope)
        else {
            return .blocked
        }
        guard binding.bindAdministratorManagedSettingsPath(
            proposed.managedMCPPolicy.sourcePath
        ) else {
            return .blocked
        }

        var options = permissionOptions
        options.trustFolder = false
        let authoritative = LiveSecurityContext.resolve(
            workspaceRoot: workingDirectory,
            environment: environment,
            isInteractive: false,
            cli: options,
            managedSettingsPath: binding.administratorManagedSettingsPath
        )
        guard reconcileStartupDecision(
            scope: binding.scope,
            authoritative: authoritative,
            environment: environment
        ) else {
            return .blocked
        }
        guard proposed.projectTrusted == authoritative.projectTrusted else {
            return .changed(authoritative)
        }

        register(binding)
        cancelStartup(reservation)
        return .admitted
    }

    func authoritativeStartupSecurity(
        for binding: LiveFolderTrustExecutorBinding,
        workingDirectory: URL,
        environment: [String: String],
        permissionOptions: CLIPermissionOptions
    ) -> LiveSecurityContext? {
        guard binding.isActive, !blocked.contains(binding.scope) else { return nil }
        var options = permissionOptions
        options.trustFolder = false
        let security = LiveSecurityContext.resolve(
            workspaceRoot: workingDirectory,
            environment: environment,
            isInteractive: false,
            cli: options,
            managedSettingsPath: binding.administratorManagedSettingsPath
        )
        guard reconcileStartupDecision(
            scope: binding.scope,
            authoritative: security,
            environment: environment
        ) else { return nil }
        return security
    }

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
            if startups[binding.scope, default: []].allSatisfy({ $0.value?.isPending != true }) {
                blocked.remove(binding.scope)
            }
        } else {
            registrations[binding.scope] = survivors
        }
    }

    func block(_ scope: LiveFolderTrustScope) {
        blocked.insert(scope)
        decisions[scope] = false
        for reservation in startups[scope, default: []] {
            reservation.value?.invalidate()
        }
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
                decisions[scope] = trusted
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

    private func reconcileStartupDecision(
        scope: LiveFolderTrustScope,
        authoritative: LiveSecurityContext,
        environment: [String: String]
    ) -> Bool {
        guard decisions[scope] == false, authoritative.projectTrusted else { return true }
        guard PersistentFolderTrustStore(environment: environment)
            .isTrusted(URL(fileURLWithPath: scope.workspace))
        else {
            return false
        }
        decisions[scope] = true
        return true
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
