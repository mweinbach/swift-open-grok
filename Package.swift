// swift-tools-version: 6.1
//
// Open Grok — Swift port package manifest.
//
// Bootstrap-owned by slice W0-S1. This manifest predeclares EVERY Swift target
// and dependency edge required by PORT_PLAN.md so that later parallel
// implementation slices never need to edit Package.swift. Feature slices own
// only their `Sources/<Target>/` and `Tests/<Target>Tests/` directories and
// replace the bootstrap stubs placed there.
//
// Invariants:
//   * One executable product: `open-grok`.
//   * Dependencies only flow from later waves to earlier waves (acyclic).
//   * Same-wave targets never depend on another same-wave concrete target;
//     they consume protocols from earlier waves. Intra-slice edges are strictly
//     forward (base -> dependent) within a slice and never form a cycle.
//   * All names are valid Swift module identifiers (`OpenGrok...`).

import PackageDescription

let package = Package(
    name: "swift-open-grok",
    // Declared explicitly so the Apple deployment target does not float with
    // the host toolchain's default: `OpenGrokTestSupport` uses Network.framework
    // (10.14+), which fails to compile under the 10.13 default. macOS 12 matches
    // the compatibility floor the sources already document. Linux is unaffected.
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "open-grok", targets: ["OpenGrokExecutable"]),
    ],
    targets: targets(),
    swiftLanguageModes: [.v6]
)

// MARK: - Target graph

/// Build the full, predeclared target list.
///
/// Slice-group arrays double as the canonical list of library target names for
/// each implementation slice. `dep(_:)` flattens slice groups into declared
/// target dependencies; `tests(_:)` generates the matching per-target test
/// targets so later slices never touch this manifest to add tests.
private func targets() -> [Target] {
    // Wave 0 slice groups (library target names).
    let w0s1 = ["OpenGrokBuildSupport"]
    let w0s2 = ["OpenGrokTestSupport", "OpenGrokTestUtilities"]
    let w0s3 = ["OpenGrokPaths", "OpenGrokEnvironment", "OpenGrokVersion"]
    let w0s4 = ["OpenGrokShared", "OpenGrokCLIChatProxyTypes"]

    // Wave 1.
    let w1s1 = ["OpenGrokToolTypes", "OpenGrokToolProtocol", "OpenGrokToolRuntime", "OpenGrokToolsAPI"]
    let w1s2 = ["OpenGrokACP", "OpenGrokAgentLifecycle", "OpenGrokInterjection", "OpenGrokPromptQueue"]
    let w1s3 = ["OpenGrokSamplingTypes", "OpenGrokChatState", "OpenGrokTokenEstimation"]
    let w1s4 = ["OpenGrokWorkspaceTypes", "OpenGrokHooksPluginTypes", "OpenGrokCodeModeProtocol"]
    let w1s5 = ["OpenGrokConfigTypes", "OpenGrokConfig"]

    // Wave 2.
    let w2s1 = ["OpenGrokExtraCA", "OpenGrokHTTP", "OpenGrokCircuitBreaker", "OpenGrokTracing", "OpenGrokTelemetry"]
    let w2s2 = ["OpenGrokSQLiteJournal", "OpenGrokSecrets", "OpenGrokFileUtils"]
    let w2s3 = ["OpenGrokFSNotify", "OpenGrokGitStatus", "OpenGrokCodebaseGraph", "OpenGrokHunkTracker"]
    let w2s4 = ["OpenGrokPTY", "OpenGrokPTYCLI", "OpenGrokTTY", "OpenGrokSystemPower", "OpenGrokCrashHandler"]
    let w2s5 = ["OpenGrokTerminalCore", "OpenGrokTextArea"]

    // Wave 3.
    let w3s1 = ["OpenGrokAuth"]
    let w3s2 = ["OpenGrokModels"]
    let w3s3 = ["OpenGrokSampler"]

    // Wave 4.
    let w4s1 = ["OpenGrokSandbox"]
    let w4s2 = ["OpenGrokFastWorktree"]
    let w4s3 = ["OpenGrokWorkspace"]
    let w4s4 = ["OpenGrokComputerHubCore", "OpenGrokComputerHubSDK", "OpenGrokWorkspaceClient"]

    // Wave 5.
    let w5s1 = ["OpenGrokToolRegistry", "OpenGrokFileTools"]
    let w5s2 = ["OpenGrokExecutionTools", "OpenGrokWebMediaTools"]
    let w5s3 = ["OpenGrokAgentControlTools"]
    let w5s4 = ["OpenGrokMCP", "OpenGrokComputerHubMCPAdapter"]
    let w5s5 = ["OpenGrokHooks", "OpenGrokPluginMarketplace"]
    let w5s6 = ["OpenGrokAgentDefinitions", "OpenGrokAnnouncements", "OpenGrokUpdate", "OpenGrokVoice"]

    // Wave 6.
    let w6s1 = ["OpenGrokCodeMode", "OpenGrokJavaScriptRuntime"]
    let w6s2 = ["OpenGrokCompaction"]
    let w6s3 = ["OpenGrokMemory", "OpenGrokGoalState"]
    let w6s4 = ["OpenGrokShellBase", "OpenGrokShellSessionSupport"]
    let w6s5 = ["OpenGrokSubagentResolution"]
    let w6s6 = ["OpenGrokWorkflow"]

    // Wave 7.
    let w7s1 = ["OpenGrokSessionRuntime"]
    let w7s2 = ["OpenGrokSessionPersistence"]
    let w7s3 = ["OpenGrokProviderSession"]
    let w7s4 = ["OpenGrokAgentCoordinator"]
    let w7s5 = ["OpenGrokACPRuntime"]

    // Wave 8.
    let w8s1 = ["OpenGrokMarkdownCore", "OpenGrokMarkdown"]
    let w8s2 = ["OpenGrokMermaidLayout", "OpenGrokMermaid"]
    let w8s3 = ["OpenGrokPagerRender"]
    let w8s4 = ["OpenGrokPagerModel"]
    let w8s5 = ["OpenGrokShell"]

    // Wave 9.
    let w9s1 = ["OpenGrokPagerRuntime"]
    let w9s2 = ["OpenGrokPagerConversationUI"]
    let w9s3 = ["OpenGrokPagerCommandUI"]
    let w9s4 = ["OpenGrokPagerOperationsUI"]
    let w9s5 = ["OpenGrokPagerMinimal"]

    // Wave 10.
    let w10s1 = ["OpenGrokPager"]
    let w10s2 = ["OpenGrokCLI"]

    // Wave 11 (libraries; executable declared explicitly below).
    let w11s1Lib = ["OpenGrokDistributionSupport"]
    let w11s3Lib = ["OpenGrokPagerPTYHarness"]
    let w11s5Lib = ["OpenGrokReleaseValidation"]

    var t: [Target] = []

    // ---- Wave 0 ----
    t.append(.target(name: "OpenGrokBuildSupport", dependencies: dep()))
    // W0-S2: the two Rust crates (`xai-grok-test-support`,
    // `xai-test-utils`) are independent, but the Swift port of
    // `OpenGrokTestSupport` imports `OpenGrokTestUtilities` (HermeticEnv,
    // HermeticGit, RealOpengrokHome) from its AcpClient/EnvGuard/Headless/
    // Leader/MockServer sources. The library dependency edge is therefore
    // declared here so the SwiftPM graph is valid and a clean
    // `swift build --build-tests` resolves without cached build order.
    t.append(.target(name: "OpenGrokTestUtilities", dependencies: dep()))
    t.append(.target(name: "OpenGrokTestSupport", dependencies: dep(["OpenGrokTestUtilities"])))
    // W0-S3: OpenGrokPaths and OpenGrokEnvironment are simple targets.
    // OpenGrokVersion is declared separately with a build-tool plugin
    // (OpenGrokVersionBuildPlugin) that generates CompiledVersion.generated.swift
    // from the GROK_VERSION env var at build time, and an exclude for the
    // manual regeneration script (which is no longer a compiled source).
    t.append(.target(name: "OpenGrokPaths", dependencies: dep()))
    t.append(.target(name: "OpenGrokEnvironment", dependencies: dep()))
    t.append(.target(
        name: "OpenGrokVersion",
        dependencies: dep(),
        exclude: ["regenerate-compiled-version.sh", "CompiledVersion.generated.swift"],
        plugins: [.plugin(name: "OpenGrokVersionBuildPlugin")]
    ))
    t.append(.executableTarget(name: "OpenGrokVersionGenerator"))
    // W0-S4: the Rust `xai-grok-shared` crate depends on
    // `prod-mc-cli-chat-proxy-types` and re-exports
    // `FeedbackTerminalInfo`. The Swift port mirrors that edge:
    // `OpenGrokShared` depends on `OpenGrokCLIChatProxyTypes` and
    // re-exports the proxy `FeedbackTerminalInfo` type so downstream
    // consumers can use the Rust-compatible `OpenGrokShared` boundary.
    t.append(.target(name: "OpenGrokCLIChatProxyTypes", dependencies: dep()))
    t.append(.target(name: "OpenGrokShared", dependencies: dep(["OpenGrokCLIChatProxyTypes"])))

    // ---- Wave 1 ----
    // W1-S1: layered tool stack (types -> protocol -> runtime -> api).
    t.append(.target(name: "OpenGrokToolTypes", dependencies: dep(w0s4)))
    t.append(.target(name: "OpenGrokToolProtocol", dependencies: dep(w0s4, ["OpenGrokToolTypes"])))
    t.append(.target(name: "OpenGrokToolRuntime", dependencies: dep(w0s4, ["OpenGrokToolTypes", "OpenGrokToolProtocol"])))
    t.append(.target(name: "OpenGrokToolsAPI", dependencies: dep(w0s4, ["OpenGrokToolTypes", "OpenGrokToolProtocol", "OpenGrokToolRuntime"])))
    t.append(contentsOf: libs(w1s2, dep(w0s4)))
    // W1-S3: ChatState builds on SamplingTypes + TokenEstimation.
    t.append(.target(name: "OpenGrokSamplingTypes", dependencies: dep(w0s4)))
    t.append(.target(name: "OpenGrokTokenEstimation", dependencies: dep(w0s4)))
    t.append(.target(name: "OpenGrokChatState", dependencies: dep(w0s4, ["OpenGrokSamplingTypes", "OpenGrokTokenEstimation"])))
    t.append(contentsOf: libs(w1s4, dep(w0s4)))
    // W1-S5: Config builds on ConfigTypes.
    t.append(.target(name: "OpenGrokConfigTypes", dependencies: dep(w0s3, w0s4)))
    t.append(.target(name: "OpenGrokConfig", dependencies: dep(w0s3, w0s4, ["OpenGrokConfigTypes"])))

    // ---- Wave 2 ----
    // W2-S1: Tracing/CircuitBreaker base; HTTP -> both; Telemetry -> both.
    t.append(.target(name: "OpenGrokCircuitBreaker", dependencies: dep(w0s3, w0s4, w1s5)))
    t.append(.target(name: "OpenGrokTracing", dependencies: dep(w0s3, w0s4, w1s5)))
    t.append(.target(
        name: "COpenGrokSockets",
        path: "Sources/COpenGrokSockets",
        publicHeadersPath: "include",
        linkerSettings: [.linkedLibrary("ws2_32", .when(platforms: [.windows]))]
    ))
    t.append(.target(name: "OpenGrokExtraCA", dependencies: dep(w0s2, w0s3, w0s4, ["OpenGrokTracing"])))
    t.append(.target(name: "OpenGrokHTTP", dependencies: dep(w0s3, w0s4, w1s5, ["OpenGrokCircuitBreaker", "OpenGrokTracing", "COpenGrokSockets", "OpenGrokExtraCA"])))
    t.append(.target(name: "OpenGrokTelemetry", dependencies: dep(w0s3, w0s4, w1s5, ["OpenGrokTracing", "OpenGrokHTTP"])))
    // W2-S2: FileUtils base; SQLiteJournal/Secrets build on it.
    t.append(.target(name: "OpenGrokFileUtils", dependencies: dep(w0s2, w0s3, w0s4, w1s5)))
    t.append(.target(name: "OpenGrokSQLiteJournal", dependencies: dep(w0s2, w0s3, w0s4, w1s5, ["OpenGrokFileUtils"])))
    t.append(.target(name: "OpenGrokSecrets", dependencies: dep(w0s2, w0s3, w0s4, w1s5, ["OpenGrokFileUtils"])))
    // W2-S3: FSNotify / CodebaseGraph / HunkTracker share base deps; GitStatus
    // depends on a thin C zlib shim for portable inflate/deflate when Apple
    // Compression is unavailable (notably Linux). Apple hosts prefer Compression.
    t.append(.target(
        name: "COpenGrokZlib",
        path: "Sources/COpenGrokZlib",
        publicHeadersPath: "include",
        linkerSettings: [
            .linkedLibrary("z"),
        ]
    ))
    t.append(.target(name: "OpenGrokFSNotify", dependencies: dep(w0s2, w0s3, w0s4)))
    t.append(.target(
        name: "OpenGrokGitStatus",
        dependencies: dep(w0s2, w0s3, w0s4, ["COpenGrokZlib"])
    ))
    t.append(.target(name: "OpenGrokCodebaseGraph", dependencies: dep(w0s2, w0s3, w0s4)))
    t.append(.target(name: "OpenGrokHunkTracker", dependencies: dep(w0s2, w0s3, w0s4)))
    // W2-S4: TTY base; PTY -> TTY; PTYCLI -> PTY/TTY.
    // C shims must live in separate targets: SwiftPM rejects mixed-language
    // Sources/<Target> trees (OpenGrokPTY + OpenGrokCrashHandler).
    t.append(.target(
        name: "OpenGrokPTYC",
        publicHeadersPath: "include"
    ))
    t.append(.target(
        name: "OpenGrokCrashHandlerC",
        publicHeadersPath: "include"
    ))
    t.append(.target(name: "OpenGrokTTY", dependencies: dep(w0s2, w0s3, w0s4)))
    t.append(.target(name: "OpenGrokPTY", dependencies: dep(w0s2, w0s3, w0s4, ["OpenGrokTTY", "OpenGrokPTYC"])))
    t.append(.target(name: "OpenGrokPTYCLI", dependencies: dep(w0s2, w0s3, w0s4, ["OpenGrokPTY", "OpenGrokTTY"])))
    t.append(.target(name: "OpenGrokSystemPower", dependencies: dep(w0s2, w0s3, w0s4)))
    t.append(.target(name: "OpenGrokCrashHandler", dependencies: dep(w0s2, w0s3, w0s4, ["OpenGrokCrashHandlerC"])))
    // W2-S5: TerminalCore base; TextArea -> TerminalCore.
    t.append(.target(name: "OpenGrokTerminalCore", dependencies: dep(w0s2, w0s4)))
    t.append(.target(name: "OpenGrokTextArea", dependencies: dep(w0s2, w0s4, ["OpenGrokTerminalCore"])))

    // ---- Wave 3 ----
    t.append(contentsOf: libs(w3s1, dep(w0s2, w0s3, w0s4, w1s3, w1s5, w2s1, w2s2)))
    t.append(contentsOf: libs(w3s2, dep(w0s2, w0s3, w0s4, w1s3, w1s5, w2s1)))
    t.append(contentsOf: libs(w3s3, dep(w0s2, w0s3, w0s4, w1s1, w1s3, w1s5, w2s1)))

    // ---- Wave 4 ----
    t.append(contentsOf: libs(w4s1, dep(w0s2, w0s3, w1s4, w1s5, w2s2, w2s4)))
    t.append(contentsOf: libs(w4s2, dep(w0s2, w0s3, w2s2, w2s3)))
    t.append(contentsOf: libs(w4s3, dep(w0s2, w0s3, w0s4, w1s1, w1s4, w1s5, w2s2, w2s3, w2s4)))
    // W4-S4: Core base; SDK -> Core; WorkspaceClient -> Core/SDK.
    t.append(.target(name: "OpenGrokComputerHubCore", dependencies: dep(w0s2, w0s4, w1s1, w1s4, w2s1, w2s4)))
    t.append(.target(name: "OpenGrokComputerHubSDK", dependencies: dep(w0s2, w0s4, w1s1, w1s4, w2s4, ["OpenGrokComputerHubCore", "OpenGrokHTTP"])))
    t.append(.target(name: "OpenGrokWorkspaceClient", dependencies: dep(w0s2, w0s4, w1s1, w1s4, w2s1, w2s4, ["OpenGrokComputerHubCore", "OpenGrokComputerHubSDK"])))

    // ---- Wave 5 ----
    // W5-S1: ToolRegistry base; FileTools -> ToolRegistry.
    t.append(.target(name: "OpenGrokToolRegistry", dependencies: dep(w0s2, w1s1, w1s3, w1s4, w2s2, w2s3, w4s3)))
    t.append(.target(name: "OpenGrokFileTools", dependencies: dep(w0s2, w1s1, w1s3, w1s4, w2s2, w2s3, w4s3, ["OpenGrokToolRegistry"])))
    t.append(contentsOf: libs(w5s2, dep(w0s2, w0s4, w1s1, w1s3, w2s1, w2s4, w3s3, w4s3, w4s4, w4s1)))
    t.append(contentsOf: libs(w5s3, dep(w0s2, w1s1, w1s2, w1s4, w4s2, w4s3)))
    // W5-S4: MCP base; ComputerHubMCPAdapter -> MCP.
    t.append(.target(name: "OpenGrokMCP", dependencies: dep(w0s2, w0s3, w1s1, w1s4, w1s5, w2s1, w2s2, w4s4, w4s1)))
    t.append(.target(name: "OpenGrokComputerHubMCPAdapter", dependencies: dep(w0s2, w0s3, w1s1, w1s4, w1s5, w2s1, w2s2, w4s4, ["OpenGrokMCP"])))
    // W5-S5: Hooks base; PluginMarketplace -> Hooks.
    t.append(.target(name: "OpenGrokHooks", dependencies: dep(w0s2, w0s3, w1s4, w1s5, w2s1, w2s2, w4s3, w4s1)))
    t.append(.target(name: "OpenGrokPluginMarketplace", dependencies: dep(w0s2, w0s3, w1s4, w1s5, w2s1, w2s2, w4s3, ["OpenGrokHooks"])))
    t.append(contentsOf: libs(w5s6, dep(w0s2, w0s3, w0s4, w1s3, w1s5, w2s1, w2s2, w2s4, w3s3)))

    // ---- Wave 6 ----
    // W6-S1: JavaScriptRuntime base; CodeMode -> JavaScriptRuntime.
    t.append(.target(name: "OpenGrokJavaScriptRuntime", dependencies: dep(w0s2, w1s1, w1s3, w1s4, w2s1)))
    t.append(.target(name: "OpenGrokCodeMode", dependencies: dep(w0s2, w1s1, w1s3, w1s4, w2s1, w5s1, w5s2, w5s3, ["OpenGrokJavaScriptRuntime"])))
    t.append(contentsOf: libs(w6s2, dep(w0s2, w1s3, w2s1, w3s2, w3s3)))
    t.append(contentsOf: libs(w6s3, dep(w0s2, w0s3, w0s4, w1s3, w1s5, w2s2, w2s3, w3s3)))
    // W6-S4: ShellBase base; ShellSessionSupport -> ShellBase.
    t.append(.target(name: "OpenGrokShellBase", dependencies: dep(w0s2, w0s3, w0s4, w1s1, w1s2, w1s3, w1s4, w1s5, w2s1, w2s2, w3s1, w3s2, w3s3, w4s1, w4s3, w5s1)))
    t.append(.target(name: "OpenGrokShellSessionSupport", dependencies: dep(w0s2, w0s3, w0s4, w1s1, w1s2, w1s3, w1s4, w1s5, w2s1, w2s2, w3s1, w3s2, w3s3, w4s3, w5s1, ["OpenGrokShellBase"])))
    t.append(contentsOf: libs(w6s5, dep(w0s2, w0s4, w1s1, w1s4, w1s5, w4s2, w5s6)))
    t.append(.target(name: "OpenGrokWorkflow", dependencies: dep(w0s4, ["OpenGrokToolTypes"])))

    // ---- Wave 7 ----
    t.append(contentsOf: libs(w7s1, dep(w0s2, w1s1, w1s2, w1s3, w2s1, w3s3, w4s3, w5s1, w5s2, w5s3, w6s1, w6s4, w6s6, w7s2, w7s4)))
    t.append(contentsOf: libs(w7s2, dep(w0s2, w0s3, w0s4, w1s3, w2s2, w6s2, w6s3, w6s4)))
    t.append(contentsOf: libs(w7s3, dep(w0s2, w1s3, w1s5, w3s1, w3s2, w3s3, w5s2, w6s1, w6s2, w6s3, w6s4)))
    t.append(contentsOf: libs(w7s4, dep(w0s2, w1s2, w1s3, w4s2, w4s3, w5s3, w6s4, w6s5)))
    t.append(contentsOf: libs(w7s5, dep(w0s2, w0s3, w0s4, w1s2, w1s4, w2s1, w4s3, w6s4)))

    // ---- Wave 8 ----
    // W8-S1: MarkdownCore base; Markdown -> MarkdownCore.
    t.append(.target(name: "OpenGrokMarkdownCore", dependencies: dep(w0s2, w0s4, w1s3, w2s5)))
    t.append(.target(name: "OpenGrokMarkdown", dependencies: dep(w0s2, w0s4, w1s3, w2s5, ["OpenGrokMarkdownCore"])))
    // W8-S2: MermaidLayout base; Mermaid -> MermaidLayout.
    t.append(.target(name: "OpenGrokMermaidLayout", dependencies: dep(w0s2, w0s4, w2s2, w2s5)))
    t.append(.target(name: "OpenGrokMermaid", dependencies: dep(w0s2, w0s4, w2s2, w2s5, ["OpenGrokMermaidLayout"])))
    t.append(contentsOf: libs(w8s3, dep(w0s2, w0s4, w1s5, w2s5)))
    t.append(contentsOf: libs(w8s4, dep(w0s2, w0s4, w1s2, w1s3, w1s4, w1s5, w2s5, w7s5)))
    t.append(contentsOf: libs(w8s5, dep(w7s1, w7s2, w7s3, w7s4, w7s5)))

    // ---- Wave 9 ----
    t.append(contentsOf: libs(w9s1, dep(w2s4, w2s5, w5s2, w7s5, w8s3, w8s4, w8s5)))
    t.append(contentsOf: libs(w9s2, dep(w1s1, w1s3, w2s5, w5s1, w6s1, w8s1, w8s2, w8s3, w8s4)))
    t.append(contentsOf: libs(w9s3, dep(w1s5, w3s2, w4s3, w5s3, w5s4, w5s5, w5s6, w8s3, w8s4)))
    t.append(contentsOf: libs(w9s4, dep(w3s1, w3s2, w5s6, w7s2, w7s3, w7s4, w7s5, w8s3, w8s4)))
    t.append(contentsOf: libs(w9s5, dep(w2s5, w7s1, w7s2, w7s5, w8s3, w8s4, w8s5)))

    // ---- Wave 10 ----
    // W10-S1 imports markdown, pager render, and terminal core directly (pager
    // markdown rendering); those were only reachable transitively before.
    // `w1s2` brings in OpenGrokInterjection, which the interactive controller
    // uses to buffer mid-turn steers ("send now") until the next prompt.
    t.append(contentsOf: libs(w10s1, dep(w1s2, w2s5, w8s1, w8s3, w8s5, w9s1, w9s2, w9s3, w9s4, w9s5)))
    // W10-S2 (OpenGrokCLI) also needs branding/paths/env/version, shared
    // identifiers, and configuration — declared here so the frozen manifest
    // already has every edge the real CLI parser will require.
    // `w6s3` (OpenGrokMemory, OpenGrokGoalState) was predeclared as a target
    // pair but never given an edge to anything, so both libraries were
    // unreachable from the executable. The CLI is where they become live: the
    // memory index backs first-turn injection and the `memory_search` /
    // `memory_get` tools, and the goal tracker backs `update_goal`.
    // `w6s5` (OpenGrokSubagentResolution) and `w7s4` (OpenGrokAgentCoordinator)
    // join on the same grounds: the live session stack owns subagent
    // definition resolution and the per-session child coordinator for the
    // `spawn_subagent` tool. Both were previously reachable only transitively.
    t.append(contentsOf: libs(w10s2, dep(w0s3, w0s4, w1s3, w1s5, w2s1, w2s4, w2s5, w3s1, w3s2, w3s3, w4s2, w4s3, w4s4, w5s4, w5s5, w5s6, w6s3, w6s4, w6s5, w7s3, w7s4, w8s1, w8s3, w8s4, w8s5, w4s1, w9s5, w10s1, ["OpenGrokFileTools", "OpenGrokToolRegistry", "OpenGrokToolTypes", "OpenGrokCodeMode", "OpenGrokReleaseValidation"])))

    // ---- Wave 11 (libraries + executable) ----
    // Distribution support only imports build support, version, and update
    // metadata. Keeping the edge narrow matters now that the CLI consumes the
    // release validator; a reverse CLI dependency here would recreate a cycle.
    t.append(contentsOf: libs(w11s1Lib, dep(w0s1, w0s3, w5s6)))
    t.append(contentsOf: libs(w11s3Lib, dep(w10s1, w10s2, w2s4, w2s5, w0s2)))
    // `OpenGrokDistributionSupport` is on this edge so `OpenGrokReleaseValidation`
    // can reach the package's single SHA-256 (`ReleaseChecksum.generate`, which
    // wraps `OpenGrokBuildSupport.SHA256`) and the single release-version rule
    // (`ReleaseVersion.isValid`). Without it, `ChecksumValidation` could only
    // take a digest it was handed and `SmokeValidation` had to carry a second
    // copy of the version pattern.
    t.append(contentsOf: libs(w11s5Lib, dep(["OpenGrokDistributionSupport"])))
    t.append(.executableTarget(
        name: "OpenGrokExecutable",
        dependencies: dep(["OpenGrokCLI", "OpenGrokPager", "OpenGrokPagerMinimal", "OpenGrokShell", "OpenGrokVersion", "OpenGrokDistributionSupport"])
    ))

    // ---- Test targets (one per library target) ----
    t.append(contentsOf: tests(w0s1))
    // W0-S2: `OpenGrokTestSupportTests` exercises both libraries in the slice
    // — it drives `TestEnv`/`SseEvents`/`MockInferenceServer` from
    // `OpenGrokTestSupport` and uses `HermeticEnv`/`HermeticGit`/
    // `RealOpengrokHome` fixtures from `OpenGrokTestUtilities`. The two Rust
    // crates (`xai-grok-test-support`, `xai-test-utils`) are independent,
    // but the Swift port of `OpenGrokTestSupport` imports
    // `OpenGrokTestUtilities` (declared as a library edge above), so this
    // test target legitimately spans both Swift modules of the slice.
    // Declared here so W0-S2 never edits Package.swift.
    t.append(.testTarget(
        name: "OpenGrokTestSupportTests",
        dependencies: dep(["OpenGrokTestSupport", "OpenGrokTestUtilities"])
    ))
    t.append(.testTarget(
        name: "OpenGrokTestUtilitiesTests",
        dependencies: dep(["OpenGrokTestUtilities"])
    ))
    t.append(contentsOf: tests(w0s3))
    t.append(contentsOf: tests(w0s4))
    t.append(contentsOf: tests(["OpenGrokToolTypes", "OpenGrokToolProtocol", "OpenGrokToolRuntime", "OpenGrokToolsAPI"]))
    t.append(contentsOf: tests(w1s2))
    t.append(contentsOf: tests(["OpenGrokSamplingTypes", "OpenGrokChatState", "OpenGrokTokenEstimation"]))
    t.append(contentsOf: tests(w1s4))
    t.append(contentsOf: tests(["OpenGrokConfigTypes", "OpenGrokConfig"]))
    t.append(contentsOf: tests(["OpenGrokExtraCA", "OpenGrokCircuitBreaker", "OpenGrokTracing", "OpenGrokHTTP", "OpenGrokTelemetry"]))
    t.append(contentsOf: tests(["OpenGrokFileUtils", "OpenGrokSQLiteJournal", "OpenGrokSecrets"]))
    t.append(contentsOf: tests(w2s3))
    t.append(contentsOf: tests(["OpenGrokTTY", "OpenGrokPTY", "OpenGrokPTYCLI", "OpenGrokSystemPower", "OpenGrokCrashHandler"]))
    t.append(contentsOf: tests(["OpenGrokTerminalCore", "OpenGrokTextArea"]))
    t.append(contentsOf: tests(w3s1))
    t.append(contentsOf: tests(w3s2))
    t.append(contentsOf: tests(w3s3))
    t.append(contentsOf: tests(w4s1))
    t.append(contentsOf: tests(w4s2))
    t.append(contentsOf: tests(w4s3))
    t.append(contentsOf: tests(["OpenGrokComputerHubCore", "OpenGrokComputerHubSDK", "OpenGrokWorkspaceClient"]))
    t.append(contentsOf: tests(["OpenGrokToolRegistry", "OpenGrokFileTools"]))
    t.append(.testTarget(
        name: "OpenGrokExecutionToolsTests",
        dependencies: dep(["OpenGrokExecutionTools", "OpenGrokTTY"])
    ))
    t.append(contentsOf: tests(["OpenGrokWebMediaTools"]))
    t.append(contentsOf: tests(w5s3))
    t.append(contentsOf: tests(["OpenGrokMCP", "OpenGrokComputerHubMCPAdapter"]))
    t.append(contentsOf: tests(["OpenGrokHooks", "OpenGrokPluginMarketplace"]))
    t.append(contentsOf: tests(w5s6))
    t.append(contentsOf: tests(["OpenGrokJavaScriptRuntime", "OpenGrokCodeMode"]))
    t.append(contentsOf: tests(w6s2))
    t.append(contentsOf: tests(w6s3))
    t.append(contentsOf: tests(["OpenGrokShellBase", "OpenGrokShellSessionSupport"]))
    t.append(contentsOf: tests(w6s5))
    t.append(.testTarget(
        name: "OpenGrokWorkflowTests",
        dependencies: dep(["OpenGrokWorkflow", "OpenGrokShared", "OpenGrokToolTypes"])
    ))
    t.append(.testTarget(
        name: "OpenGrokSessionRuntimeTests",
        dependencies: dep(["OpenGrokSessionRuntime", "OpenGrokSessionPersistence", "OpenGrokWorkflow"])
    ))
    t.append(contentsOf: tests(w7s2))
    t.append(contentsOf: tests(w7s3))
    t.append(contentsOf: tests(w7s4))
    t.append(.testTarget(
        name: "OpenGrokACPRuntimeTests",
        dependencies: dep(["OpenGrokACPRuntime", "OpenGrokShared"])
    ))
    t.append(contentsOf: tests(["OpenGrokMarkdownCore", "OpenGrokMarkdown"]))
    t.append(contentsOf: tests(["OpenGrokMermaidLayout", "OpenGrokMermaid"]))
    t.append(contentsOf: tests(w8s3))
    t.append(contentsOf: tests(w8s4))
    t.append(contentsOf: tests(w8s5))
    t.append(contentsOf: tests(w9s1))
    t.append(contentsOf: tests(w9s2))
    t.append(contentsOf: tests(w9s3))
    t.append(contentsOf: tests(w9s4))
    t.append(contentsOf: tests(w9s5))
    t.append(contentsOf: tests(w10s1))
    // Declared explicitly rather than through `tests(_:)`: the CLI suite reaches
    // the Computer Hub targets (w4s4) for the workspace-route tests and
    // OpenGrokWorkspace (w4s3) for the permission-mediation assertions, and the
    // helper gives a test target only its own library.
    t.append(.testTarget(
        name: "OpenGrokCLITests",
        dependencies: dep(w10s2, w4s4, w4s3)
    ))
    // OpenGrokExecutable tests exercise the composition via libraries (test
    // targets do not depend on the executable target directly).
    t.append(.testTarget(name: "OpenGrokExecutableTests", dependencies: dep(["OpenGrokCLI", "OpenGrokDistributionSupport", "OpenGrokShell", "OpenGrokPager"])))
    t.append(contentsOf: tests(w11s1Lib))
    t.append(contentsOf: tests(w11s3Lib))
    t.append(contentsOf: tests(w11s5Lib))

    // ---- Standalone Wave 11 test/harness targets ----
    t.append(.testTarget(name: "OpenGrokCompatibilityTests", dependencies: dep(["OpenGrokPager", "OpenGrokCLI", "OpenGrokTestSupport", "OpenGrokTestUtilities", "OpenGrokACP", "OpenGrokToolProtocol", "OpenGrokSamplingTypes", "OpenGrokSampler", "OpenGrokShell", "OpenGrokDistributionSupport"])))
    // `OpenGrokPTY`/`OpenGrokTTY` are direct here because the scenarios name
    // `ProcessExit` and `TerminalSize` in their own assertions.
    t.append(.testTarget(name: "OpenGrokPagerPTYTests", dependencies: dep(["OpenGrokPagerPTYHarness", "OpenGrokPTY", "OpenGrokTTY", "OpenGrokTestSupport", "OpenGrokTestUtilities"])))
    t.append(.testTarget(name: "OpenGrokFuzzingTests", dependencies: dep(["OpenGrokPager", "OpenGrokCLI", "OpenGrokMarkdownCore", "OpenGrokMarkdown", "OpenGrokSampler", "OpenGrokToolRegistry", "OpenGrokFileTools", "OpenGrokShell"])))
    t.append(.testTarget(name: "OpenGrokPerformanceTests", dependencies: dep(["OpenGrokPager", "OpenGrokCLI", "OpenGrokMarkdown", "OpenGrokSampler", "OpenGrokSamplingTypes", "OpenGrokShared", "OpenGrokShell", "OpenGrokShellBase", "OpenGrokMemory"])))
    t.append(.testTarget(name: "OpenGrokSecurityTests", dependencies: dep([
        "OpenGrokReleaseValidation", "OpenGrokPager", "OpenGrokCLI", "OpenGrokSandbox",
        "OpenGrokAuth", "OpenGrokFileTools", "OpenGrokWorkspace", "OpenGrokProviderSession",
        "OpenGrokSamplingTypes", "OpenGrokShellBase"
    ])))

    // ---- Build support plugins ----
    // Read-only validation of checked-in protocol fixtures. Regeneration is
    // performed by `scripts/regenerate-protocol-manifest.sh` so that this
    // command stays sandboxed and frictionless to run in CI.
    t.append(.plugin(
        name: "OpenGrokProtoBuildPlugin",
        capability: .command(
            intent: .custom(
                verb: "ogrok-validate-protocols",
                description: "Validate that checked-in Open Grok protocol fixtures and generated manifests are up to date (no network access)."
            )
        ),
        dependencies: []
    ))

    // Build-tool plugin that generates `CompiledVersion.generated.swift`
    // from the `GROK_VERSION` environment variable at build time — the
    // SwiftPM equivalent of the Rust crate's
    // `option_env!("GROK_VERSION")` + `cargo:rerun-if-env-changed=GROK_VERSION`
    // directive. Attached to the `OpenGrokVersion` target above via
    // `plugins: [.plugin(name: "OpenGrokVersionBuildPlugin")]`.
    t.append(.plugin(
        name: "OpenGrokVersionBuildPlugin",
        capability: .buildTool(),
        dependencies: [.target(name: "OpenGrokVersionGenerator")]
    ))

    return t
}

// MARK: - Helpers

/// Declare a set of library targets that all share the same dependency list.
private func libs(_ names: [String], _ dependencies: [Target.Dependency]) -> [Target] {
    names.map { .target(name: $0, dependencies: dependencies) }
}

/// Generate one `<Name>Tests` test target per library target, depending on its
/// library. Owning slices replace the bootstrap stub test files in place.
private func tests(_ names: [String]) -> [Target] {
    names.map { name in
        .testTarget(name: "\(name)Tests", dependencies: [.target(name: name)])
    }
}

/// Flatten slice-group name arrays into target dependencies. Accepts both
/// predeclared slice-group arrays and inline ad-hoc name arrays.
private func dep(_ groups: [String]...) -> [Target.Dependency] {
    groups.flatMap { $0 }.map { .target(name: $0) }
}
