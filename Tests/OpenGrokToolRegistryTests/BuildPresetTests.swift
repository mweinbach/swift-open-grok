// BuildPresetTests.swift
//
// The write-capable `.build` preset: composition, capability filtering, and
// config Codable round-trip.

import Foundation
import Testing
@testable import OpenGrokToolRegistry
import OpenGrokShared

@Suite("OpenGrokToolRegistry build preset")
struct BuildPresetTests {

    private func buildConfig() -> ToolServerConfig {
        toolServerConfig(for: .build, catalogKinds: ToolRegistryBuilder().knownToolKinds())
    }

    @Test("build preset carries read, search, and mutation tools with kinds")
    func composition() {
        let config = buildConfig()
        let ids = Set(config.tools.map(\.id))
        #expect(ids.isSuperset(of: [
            "GrokBuild:read_file", "GrokBuild:list_dir", "GrokBuild:grep",
            "GrokBuild:search_replace", "OpenCode:write", "Codex:apply_patch",
        ]))
        let kinds: [String: ProductToolKind] = Dictionary(
            uniqueKeysWithValues: config.tools.compactMap { tool in
                tool.kind.map { (tool.id, $0) }
            }
        )
        #expect(kinds["OpenCode:write"] == .write)
        #expect(kinds["Codex:apply_patch"] == .edit)
        #expect(kinds["GrokBuild:search_replace"] == .edit)
    }

    @Test("build preset never mixes standard and hashline file tools")
    func noHashlineMix() {
        let ids = Set(buildConfig().tools.map(\.id))
        #expect(ids.allSatisfy { !$0.hasPrefix("GrokBuildHashline:") })
    }

    @Test("read-only capability strips the mutation tools from the build preset")
    func readOnlyStripsMutations() {
        let ids = Set(ToolCapabilityMode.readOnly.filter(buildConfig()).tools.map(\.id))
        #expect(ids.contains("GrokBuild:read_file"))
        #expect(ids.contains("GrokBuild:grep"))
        #expect(!ids.contains("OpenCode:write"))
        #expect(!ids.contains("Codex:apply_patch"))
        #expect(!ids.contains("GrokBuild:search_replace"))
    }

    @Test("build preset config round-trips through Codable")
    func codableRoundTrip() throws {
        let config = buildConfig()
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ToolServerConfig.self, from: data)
        #expect(decoded == config)
    }
}
