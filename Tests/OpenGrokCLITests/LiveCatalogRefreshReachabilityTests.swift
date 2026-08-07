// LiveCatalogRefreshReachabilityTests.swift
//
// Reachability of the post-readiness background catalog refresh through the
// live seam (AGENTS.md §3). `refreshBackgroundPartitions` had zero callers in
// Sources/ — every remote provider catalog was implemented-unwired and the
// running executable never refreshed one. This test drives the composition
// the executable runs (`makeSessionFoundation` → `makeAgentStack`) and
// asserts the refresh actually fired: the mock provider endpoint received the
// /models fetch and the published picker changed shape. A composition-level
// test would pass just as happily with the spawn deleted; this one cannot.

import Foundation
import Testing
import OpenGrokModels
import OpenGrokSamplingTypes
import OpenGrokTestSupport
@testable import OpenGrokCLI

@Suite("Live background catalog refresh", .serialized)
struct LiveCatalogRefreshReachabilityTests {
    /// End-to-end over the Meta partition, which doubles as the Part A
    /// acceptance run: the session cold-starts on a Meta model authenticated
    /// by META_API_KEY, and the post-readiness refresh fetches Meta's /models
    /// from OPENGROK_META_API_BASE_URL and narrows the curated partition to
    /// what the wire named (`catalog_from_wire`, meta_models.rs:203-224).
    @Test("makeAgentStack fires the background refresh against the live endpoint")
    func backgroundRefreshFiresAfterReadiness() async throws {
        // The mock's GET /v1/models answers `{"data":[{"id":"muse-spark-1.1"}]}`
        // — the exact shape Meta's slug parser reads, naming one of the three
        // curated Muse Spark models.
        let server = try MockInferenceServer(models: [MockModelEntry(id: "muse-spark-1.1")])
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-refresh-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let command = try CLICommandParser.parseOrThrow([
            "headless",
            "--prompt", "hello",
            "--cwd", workspace.path,
            "--model", "meta:muse-spark-1.2",
        ])
        guard case .launch(let options) = command else {
            Issue.record("fixture did not parse to a launch")
            return
        }
        let context = CLIApplicationContext(
            environment: [
                "HOME": home.path,
                "OPENGROK_HOME": home.path,
                "XDG_STATE_HOME": home.appendingPathComponent("state").path,
                "META_API_KEY": "meta-test-key",
                "OPENGROK_META_API_BASE_URL": server.url,
            ],
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, _ in OpenGrokLiveSamplingResponse(output: "ok") }
            }
        )

        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: options,
            context: context,
            dependencies: dependencies
        )
        // Part A end-to-end for a new Meta session: the provider routes as
        // Meta and META_API_KEY resolved as the credential.
        #expect(foundation.samplingConfiguration.provider == .meta)
        #expect(foundation.samplingConfiguration.apiKey == "meta-test-key")

        let stack = await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: context,
            dependencies: dependencies
        )

        // The spawn happened at the composition's post-readiness point; the
        // retained handle exists only because the composition really called
        // `spawnBackgroundRefresh`.
        let refresh = stack.catalogStore.backgroundRefreshTask
        #expect(refresh != nil, "makeAgentStack did not spawn the background catalog refresh")
        await refresh?.value

        // The refresh reached the wire: the provider endpoint got the
        // /models fetch...
        let modelRequests = server.requests().filter { $0.path == "/v1/models" }
        #expect(!modelRequests.isEmpty, "no /models fetch reached the live endpoint")

        // ...and the published catalog changed shape: the curated Meta
        // partition narrowed to exactly the slug the wire named, through the
        // same picker entries the `/model` overlay lists.
        let metaEntries = stack.catalogStore.pickerEntries()
            .filter { $0.providerID == ModelProvider.meta.asString }
        #expect(metaEntries.map(\.id) == ["meta:muse-spark-1.1"])

        await foundation.toolExecutor.shutdown()
        await stack.codeMode?.shutdown()
    }
}
