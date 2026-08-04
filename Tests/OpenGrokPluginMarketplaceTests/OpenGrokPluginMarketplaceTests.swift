import Foundation
import Testing
@testable import OpenGrokPluginMarketplace

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-marketplace-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func makeEntry(
    name: String = "demo",
    relativePath: String = "plugins/demo",
    remoteURL: String? = nil,
    remoteRef: String? = nil,
    remoteSHA: String? = nil,
    remoteSubdirectory: String? = nil,
    version: String? = "1.0.0"
) -> MarketplaceEntry {
    MarketplaceEntry(
        name: name,
        version: version,
        description: "Demo plugin",
        relativePath: relativePath,
        remoteURL: remoteURL,
        remoteRef: remoteRef,
        remoteSHA: remoteSHA,
        remoteSubdirectory: remoteSubdirectory
    )
}

private func makeProvenance(
    source: String,
    path: String = "plugins/demo"
) -> MarketplaceProvenance {
    MarketplaceProvenance(sourceURLOrPath: source, sourceDisplayName: "Test", pluginSubdirectory: path)
}

private func expectMarketplaceError(
    _ expected: MarketplaceError,
    operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("expected marketplace error \(expected)")
    } catch let error as MarketplaceError {
        #expect(error == expected)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Suite("Marketplace paths and manifests")
struct MarketplacePathAndManifestTests {
    @Test("normalizes safe paths and rejects traversal and prefixes")
    func pathValidation() throws {
        #expect(try MarketplaceRelativePath("./plugins\\demo").value == "plugins/demo")
        let rejected: [(String, MarketplacePathError)] = [
            ("", .empty),
            ("/plugins/demo", .absolute),
            ("\\\\server\\share", .absolute),
            ("plugins/../secret", .parentComponent),
            ("plugins/./demo", .currentComponent),
            ("C:\\plugins\\demo", .prefix),
            ("plugins//demo", .prefix),
        ]
        for (path, reason) in rejected {
            expectMarketplaceError(.invalidPath(path: path, reason: reason), operation: {
                _ = try MarketplaceRelativePath(path)
            })
        }
    }

    @Test("resolving a symlink outside the marketplace fails closed")
    func symlinkEscape() throws {
        #if !os(Windows)
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        do {
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("escape"),
                withDestinationURL: outside
            )
        } catch {
            return
        }
        expectMarketplaceError(.invalidPath(path: "escape", reason: .escapesRoot), operation: {
            _ = try MarketplaceRelativePath("escape").resolve(under: root)
        })
        #endif
    }

    @Test("manifest defaults, camel-case component fields, and validation")
    func manifestParsing() throws {
        let root = try temporaryDirectory()
        let plugin = root.appendingPathComponent("plugin.json")
        try write(#"{"name":"demo","mcpServers":".mcp.json","unknown":true}"#, to: plugin)
        let result = try loadPluginManifest(from: root)
        guard case let .found(manifest) = result else {
            Issue.record("expected manifest")
            return
        }
        #expect(manifest.name == "demo")
        #expect(manifest.keywords.isEmpty)
        #expect(manifest.mcpServers == .path(".mcp.json"))

        try write(#"{"name":"Bad_Name"}"#, to: plugin)
        expectMarketplaceError(
            .invalidManifest(path: plugin.path, reason: "name must be 1-64 chars, lowercase alphanumeric + hyphens, with no leading or trailing hyphens"),
            operation: { _ = try loadPluginManifest(from: root) }
        )
    }

    @Test("manifest component paths cannot escape the plugin root")
    func manifestComponentSafety() throws {
        let root = try temporaryDirectory()
        let manifest = PluginManifest(name: "demo", skills: .single("../skills"))
        #expect(manifest.componentDirectories(manifest.skills, root: root, defaultName: "skills").isEmpty)
    }
}

@Suite("Marketplace indexes and catalogs")
struct MarketplaceIndexAndCatalogTests {
    @Test("index accepts shorthand, remote sources, and missing arrays")
    func indexFormats() throws {
        let root = try temporaryDirectory()
        try write(
            #"{"name":"mixed","plugins":[{"name":"local","source":"./plugins/local"},{"name":"remote","source":{"source":"url","url":"https://example.com/repo.git","ref":"main","path":"plugins/remote"}}]}"#,
            to: root.appendingPathComponent(".opengrok-plugin/marketplace.json")
        )
        guard let index = try loadMarketplaceIndex(from: root) else {
            Issue.record("expected index")
            return
        }
        #expect(index.plugins.count == 2)
        #expect(try index.plugins[0].resolvedMarketplacePath().value == "plugins/local")
        #expect(index.plugins[1].remoteURL?.url == "https://example.com/repo.git")
        #expect(index.plugins[1].remoteSubdirectory == "plugins/remote")
        #expect(index.plugins[1].tags.isEmpty)
    }

    @Test("catalog precedence, defaults, sanitization, and SHA gating")
    func catalogSafety() throws {
        let root = try temporaryDirectory()
        try write(
            #"{"version":1,"plugins":{"demo":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","components":{"skills":[{"name":"a\u001b[31mb","description":"x\u0007y"}]}}}}"#,
            to: root.appendingPathComponent(".opengrok-plugin/plugin-index.json")
        )
        try write(
            #"{"version":1,"plugins":{"other":{"components":{"skills":[{"name":"wrong"}]}}}}"#,
            to: root.appendingPathComponent(".claude-plugin/plugin-index.json")
        )
        guard let catalog = loadPluginCatalog(from: root) else {
            Issue.record("expected catalog")
            return
        }
        #expect(catalog.plugins["other"] == nil)
        #expect(catalog.components(for: "demo", indexSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")?.skills.first?.name == "a[31mb")
        #expect(catalog.components(for: "demo", indexSHA: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") == nil)
        #expect(catalog.components(for: "demo", indexSHA: nil)?.skills.first?.description == "xy")
    }

    @Test("broken preferred catalog does not fall back")
    func brokenCatalogPrecedence() throws {
        let root = try temporaryDirectory()
        try write("not json", to: root.appendingPathComponent(".opengrok-plugin/plugin-index.json"))
        try write(#"{"version":1,"plugins":{}}"#, to: root.appendingPathComponent(".claude-plugin/plugin-index.json"))
        #expect(loadPluginCatalog(from: root) == nil)
    }
}

@Suite("Marketplace scanning and compatibility")
struct MarketplaceScanningTests {
    @Test("filesystem fallback discovers convention components")
    func filesystemScan() throws {
        let root = try temporaryDirectory()
        let plugin = root.appendingPathComponent("plugins/demo")
        try write(#"{"name":"demo","version":"1.2.0"}"#, to: plugin.appendingPathComponent("plugin.json"))
        try write("# skill", to: plugin.appendingPathComponent("skills/one/SKILL.md"))
        try FileManager.default.createDirectory(at: plugin.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try write("{}", to: plugin.appendingPathComponent("hooks/hooks.json"))
        try write("{}", to: plugin.appendingPathComponent(".mcp.json"))

        let scan = scanMarketplace(root)
        #expect(scan.catalogLoaded == false)
        #expect(scan.entries.count == 1)
        #expect(scan.entries[0].name == "demo")
        #expect(scan.entries[0].skillCount == 1)
        #expect(scan.entries[0].hasAgents)
        #expect(scan.entries[0].hasHooks)
        #expect(scan.entries[0].hasMcp)
    }

    @Test("indexed scan enriches local entries and keeps remote entries offline")
    func indexedScan() throws {
        let root = try temporaryDirectory()
        let plugin = root.appendingPathComponent("plugins/local")
        try write(#"{"name":"local"}"#, to: plugin.appendingPathComponent("plugin.json"))
        try write(
            #"{"name":"m","plugins":[{"name":"local","description":"indexed","source":{"type":"local","path":"./plugins/local"},"keywords":["editor"]},{"name":"remote","source":{"source":"url","url":"https://example.com/repo.git"}}]}"#,
            to: root.appendingPathComponent(".opengrok-plugin/marketplace.json")
        )
        let scan = scanMarketplace(root)
        #expect(scan.entries.count == 2)
        #expect(scan.entries[0].description == "indexed")
        #expect(scan.entries[0].keywords == ["editor"])
        #expect(scan.entries[1].remoteURL == "https://example.com/repo.git")
        #expect(scan.entries[1].skillCount == 0)
    }

    @Test("matcher honors domains, boundaries, longest match, and insertion ties")
    func matcher() {
        let candidates = [
            MarketplaceKeywordCandidate(name: "short", keywords: ["editor"]),
            MarketplaceKeywordCandidate(name: "long", keywords: ["code editor"]),
            MarketplaceKeywordCandidate(name: "design", domains: ["https://www.figma.com/board"]),
        ]
        #expect(matchPluginKeyword("use a code editor", candidates: candidates) == 1)
        #expect(matchPluginKeyword("open https://figma.com/x", candidates: candidates) == 2)
        #expect(matchPluginKeyword("i am boxing", candidates: [MarketplaceKeywordCandidate(name: "box", keywords: ["box"])]) == nil)
        #expect(matchPluginKeyword("wave and atom", candidates: [
            MarketplaceKeywordCandidate(name: "a", keywords: ["wave"]),
            MarketplaceKeywordCandidate(name: "b", keywords: ["atom"]),
        ]) == 0)
    }
}

@Suite("Marketplace source resolution")
struct MarketplaceResolutionTests {
    @Test("canonical GitHub forms and official source detection")
    func officialSource() {
        for url in [
            officialMarketplaceSourceGitURL,
            "https://GitHub.com/XAI-org/Plugin-Marketplace",
            "git@github.com:xai-org/plugin-marketplace.git",
            "ssh://git@github.com/xai-org/plugin-marketplace.git/",
        ] {
            #expect(isOfficialMarketplaceSourceURL(url))
            #expect(canonicalGitHubOwnerRepository(url) == "xai-org/plugin-marketplace")
        }
        #expect(!isOfficialMarketplaceSourceURL("https://github.com/acme/other.git"))
    }

    @Test("marketplace references reject paths and resolve qualified sources")
    func referencesAndQualifiers() {
        #expect(parseMarketplaceReference("demo") == MarketplaceRef(name: "demo"))
        #expect(parseMarketplaceReference("demo@xai-org/plugin-marketplace") == MarketplaceRef(name: "demo", qualifier: "xai-org/plugin-marketplace"))
        #expect(parseMarketplaceReference("C:/plugins/demo") == nil)
        #expect(parseMarketplaceReference("owner/repo@main") == nil)

        let sources = [
            MarketplaceSource(name: "xAI Official", kind: .git(url: officialMarketplaceSourceGitURL, branch: nil)),
            MarketplaceSource(name: "Local Dev", kind: .local(path: "/tmp/plugins")),
            MarketplaceSource(name: "Self Hosted", kind: .git(url: "https://git.example.com/org/repo.git", branch: nil)),
        ]
        #expect(resolveMarketplaceQualifier("xai-org/plugin-marketplace.git", sources: sources) == .success(0))
        #expect(resolveMarketplaceQualifier("local/local-dev", sources: sources) == .success(1))
        #expect(resolveMarketplaceQualifier("git/self-hosted", sources: sources) == .success(2))
        #expect(resolveMarketplaceQualifier("missing", sources: sources) == .failure(.unknown))
    }

    @Test("bare name selection prioritizes one official copy")
    func bareNameSelection() {
        let entry = makeEntry()
        let scanned = [
            (source: MarketplaceSource(name: "Third Party", kind: .git(url: "https://github.com/acme/plugins.git", branch: nil)), entry: entry),
            (source: MarketplaceSource(name: "Official", kind: .git(url: officialMarketplaceSourceGitURL, branch: nil)), entry: entry),
        ]
        #expect(selectMarketplaceEntry(name: "DEMO", scanned: scanned) == .success(BareNameSelection(chosen: 1, otherCount: 1)))
    }
}

@Suite("Marketplace planning and integrity")
struct MarketplacePlanningTests {
    @Test("local install planning is OPENGROK_HOME isolated and deterministic")
    func localInstallPlan() throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("plugins/demo"), withIntermediateDirectories: true)
        let home = try temporaryDirectory()
        let environment = ["OPENGROK_HOME": home.appendingPathComponent("custom-home").path]
        let provenance = makeProvenance(source: root.path, path: "./plugins/demo")
        guard case let .planned(plan) = try planMarketplaceInstall(root: root, entry: makeEntry(), provenance: provenance, environment: environment) else {
            Issue.record("expected install plan")
            return
        }
        #expect(plan.operation == .install)
        #expect(plan.requiresNetwork == false)
        #expect(plan.provenance.pluginSubdirectory == "plugins/demo")
        #expect(plan.finalPath.hasPrefix(home.appendingPathComponent("custom-home/installed-plugins").path))
        #expect(plan.repositoryKey.hasPrefix("demo-"))
        guard case let .planned(repeatedPlan) = try planMarketplaceInstall(root: root, entry: makeEntry(), provenance: provenance, environment: environment) else {
            Issue.record("expected repeated install plan")
            return
        }
        #expect(plan == repeatedPlan)
    }

    @Test("remote full SHA in ref is hoisted and unpinned remotes are refused")
    func remoteIntegrityPlan() throws {
        let sha = String(repeating: "a", count: 40)
        let provenance = makeProvenance(source: "https://example.com/repo.git", path: "remote")
        let entry = makeEntry(name: "remote", relativePath: "remote", remoteURL: "https://example.com/repo.git", remoteRef: sha)
        guard case let .planned(plan) = try planMarketplaceInstall(root: try temporaryDirectory(), entry: entry, provenance: provenance, requireSHA: true) else {
            Issue.record("expected remote plan")
            return
        }
        guard let source = plan.source, case let .remote(url, ref, pinnedSHA, subdirectory) = source else {
            Issue.record("expected remote source")
            return
        }
        #expect(url == "https://example.com/repo.git")
        #expect(ref == nil)
        #expect(pinnedSHA == sha)
        #expect(subdirectory == nil)

        let unpinned = makeEntry(name: "remote", relativePath: "remote", remoteURL: "https://example.com/repo.git", remoteRef: "main")
        expectMarketplaceError(.unpinnedRemote(plugin: "remote", url: "https://example.com/repo.git"), operation: {
            _ = try planMarketplaceInstall(root: try temporaryDirectory(), entry: unpinned, provenance: provenance, requireSHA: true)
        })
        #expect(throws: MarketplaceError.self) {
            try verifyMarketplaceIntegrity(expected: sha, actual: String(repeating: "b", count: 40))
        }
    }

    @Test("already installed, update, remove, and managed path safety")
    func lifecyclePlans() throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("plugins/demo"), withIntermediateDirectories: true)
        let home = try temporaryDirectory()
        let environment = ["OPENGROK_HOME": home.path]
        let provenance = makeProvenance(source: root.path)
        let installDirectory = marketplaceInstallDirectory(environment: environment)
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        let key = marketplaceRepositoryKey(source: .local(root: root.path, relativePath: "plugins/demo"), fallbackPluginName: "demo")
        let installedPath = installDirectory.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: installedPath, withIntermediateDirectories: true)
        let installed = InstalledMarketplacePlugin(key: key, name: "demo", version: "0.9.0", path: installedPath.path, provenance: provenance, installedAt: "a", updatedAt: "b")

        guard case .alreadyInstalled(let installedPlugin) = try planMarketplaceInstall(root: root, entry: makeEntry(), provenance: provenance, installed: [installed], environment: environment) else {
            Issue.record("expected already-installed result")
            return
        }
        #expect(installedPlugin == installed)
        let update = try planMarketplaceUpdate(root: root, entry: makeEntry(version: "1.0.0"), provenance: provenance, installed: [installed], environment: environment)
        #expect(update.operation == .update)
        #expect(update.oldVersion == "0.9.0")
        #expect(update.newVersion == "1.0.0")
        let remove = try planMarketplaceRemove(pluginName: "demo", provenance: provenance, installed: [installed], keepData: true, environment: environment)
        #expect(remove.operation == .remove)
        #expect(remove.keepData)

        let outside = try temporaryDirectory()
        let unsafe = InstalledMarketplacePlugin(key: key, name: "demo", path: outside.path, provenance: provenance, installedAt: "a", updatedAt: "b")
        expectMarketplaceError(.invalidPath(path: outside.path, reason: .escapesRoot), operation: {
            _ = try planMarketplaceRemove(pluginName: "demo", provenance: provenance, installed: [unsafe], environment: environment)
        })
    }

    @Test("source config parser scopes require_sha and preserves source semantics")
    func sourceConfiguration() throws {
        let home = try temporaryDirectory()
        let config = """
        [marketplace]
        require_sha = true
        [[marketplace.sources]]
        name = "Local #1"
        path = "~/plugins"
        [[marketplace.sources]]
        name = 'Remote'
        git = "https://example.com/repo.git"
        branch = "main"
        """
        let sources = loadMarketplaceSources(from: config, homeDirectory: home)
        #expect(sources.count == 2)
        #expect(sources[0].sourceURLOrPath == home.appendingPathComponent("plugins").path)
        #expect(sources[1].sourceURLOrPath == "https://example.com/repo.git")
        #expect(marketplaceRequireSHA(configurationText: config, environment: [:]))
        #expect(!marketplaceRequireSHA(configurationText: "[other]\nrequire_sha = true", environment: [:]))

        let settingsRoot = try temporaryDirectory()
        try write(
            #"""
            {
              "extraKnownMarketplaces": {
                "z": { "source": { "source": "github", "repo": "acme/z" } },
                "a": { "source": { "source": "git", "url": "https://example.com/repo.git" } },
                "local": { "source": { "source": "local", "path": "/tmp/local" } }
              }
            }
            """#,
            to: settingsRoot.appendingPathComponent("settings.json")
        )
        let extra = loadExtraMarketplaceSources(existing: sources, roots: [settingsRoot])
        #expect(extra.count == 2)
        #expect(extra[0].name == "local")
        #expect(extra[1].name == "z")
    }
}
