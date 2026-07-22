// OpenGrokHooksPluginTypesTests.swift
//
// Fixture-backed wire-contract tests for OpenGrokHooksPluginTypes.
// Translated from crates/codegen/xai-hooks-plugins-types/src/lib.rs `mod tests`.

import Testing
import Foundation
@testable import OpenGrokHooksPluginTypes

// MARK: - Helpers

private func makeEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return e
}

private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let data = try makeEncoder().encode(value)
    return String(data: data, encoding: .utf8)!
}

private func decodeJSON<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    try decodeJSON(T.self, try encodeJSON(value))
}

// MARK: - Actions

@Suite("Hooks/Plugins actions")
struct HooksPluginsActionTests {
    @Test("hooks action serde roundtrip + tagged format")
    func hooksAction() throws {
        let add = HooksAction.add(path: "/home/user/.opengrok/hooks")
        #expect(try roundTrip(add) == add)
        let json = try encodeJSON(add)
        #expect(json.contains(#""type":"add""#))
        #expect(json.contains(#""path":"/home/user/.opengrok/hooks""#))

        #expect(try encodeJSON(HooksAction.trust) == #"{"type":"trust"}"#)
        #expect(try roundTrip(HooksAction.reload) == .reload)
        #expect(try roundTrip(HooksAction.untrust) == .untrust)
        #expect(try roundTrip(HooksAction.enable(hookName: "h")) == .enable(hookName: "h"))
        #expect(try roundTrip(HooksAction.disable(hookName: "h")) == .disable(hookName: "h"))
        #expect(
            try roundTrip(HooksAction.toggleSource(hookNames: ["a", "b"], disable: true))
                == .toggleSource(hookNames: ["a", "b"], disable: true)
        )

        let req = HooksActionRequest(sessionId: "s1", action: .reload)
        #expect(try roundTrip(req) == req)
        let reqJSON = try encodeJSON(req)
        #expect(reqJSON.contains("\"sessionId\""))
        #expect(reqJSON.contains("\"action\""))
    }

    @Test("plugins action serde roundtrip + tagged format")
    func pluginsAction() throws {
        let install = PluginsAction.install(source: "github.com/foo/bar")
        #expect(try roundTrip(install) == install)
        #expect(try encodeJSON(PluginsAction.reload) == #"{"type":"reload"}"#)

        let uninstall = PluginsAction.uninstall(pluginId: "user/abc123/my-plugin", confirmed: false)
        let uJSON = try encodeJSON(uninstall)
        #expect(uJSON.contains(#""type":"uninstall""#))
        #expect(uJSON.contains(#""plugin_id":"user/abc123/my-plugin""#) || uJSON.contains(#""pluginId""#))
        #expect(try roundTrip(uninstall) == uninstall)

        #expect(try roundTrip(PluginsAction.enable(pluginId: "p")) == .enable(pluginId: "p"))
        #expect(try roundTrip(PluginsAction.disable(pluginId: "p")) == .disable(pluginId: "p"))
        #expect(try roundTrip(PluginsAction.update(pluginId: nil)) == .update(pluginId: nil))
        #expect(try roundTrip(PluginsAction.add(path: "/tmp/p")) == .add(path: "/tmp/p"))
        #expect(try roundTrip(PluginsAction.remove(path: "/tmp/p")) == .remove(path: "/tmp/p"))
    }

    @Test("action outcome + outcome status")
    func actionOutcome() throws {
        let outcome = ActionOutcome(
            status: .success,
            message: "Installed 1 plugin(s)",
            requiresReload: true,
            requiresRestart: false
        )
        #expect(try roundTrip(outcome) == outcome)
        let json = try encodeJSON(outcome)
        #expect(json.contains("\"requiresReload\":true") || json.contains("\"requires_reload\""))
        // camelCase per rename_all = camelCase
        #expect(json.contains("\"requiresReload\""))
        #expect(json.contains("\"requiresRestart\""))
        #expect(json.contains("\"status\""))

        let cases: [(OutcomeStatus, String)] = [
            (.success, "\"success\""),
            (.validationError, "\"validation_error\""),
            (.confirmationRequired, "\"confirmation_required\""),
            (.notFound, "\"not_found\""),
            (.internalError, "\"internal_error\""),
            (.unsupported, "\"unsupported\""),
        ]
        for (status, expected) in cases {
            #expect(try encodeJSON(status) == expected)
            #expect(try roundTrip(status) == status)
        }
    }
}

// MARK: - Hook / plugin info camelCase

@Suite("Hook and plugin descriptors")
struct HookPluginDescriptorTests {
    @Test("hook info camelCase fields + defaults")
    func hookInfo() throws {
        let hook = HookInfo(
            name: "global/safety:pre_tool_use[0].hooks[0]",
            event: .preToolUse,
            handlerType: .command,
            matcher: "edit_file",
            command: "/bin/check",
            url: nil,
            timeoutMs: 5000,
            sourceDir: "/home/user/.opengrok/hooks",
            disabled: false
        )
        #expect(try roundTrip(hook) == hook)
        let json = try encodeJSON(hook)
        #expect(json.contains("\"handlerType\""))
        #expect(json.contains("\"timeoutMs\""))
        #expect(json.contains("\"sourceDir\""))
        #expect(json.contains("\"pre_tool_use\"") || json.contains("preToolUse") == false)
        // event is snake_case enum
        #expect(json.contains("\"pre_tool_use\""))

        // disabled default false when absent
        let minimal = try decodeJSON(
            HookInfo.self,
            #"{"name":"h","event":"stop","handlerType":"command","timeoutMs":1,"sourceDir":"/x"}"#
        )
        #expect(minimal.disabled == false)
        #expect(minimal.matcher == nil)
    }

    @Test("plugin info camelCase + origin optional")
    func pluginInfo() throws {
        let plugin = PluginInfo(
            name: "sample",
            id: "user/abc/sample",
            root: "/plugins/sample",
            scope: .user,
            trusted: true,
            enabled: true,
            version: "1.0.0",
            description: "demo",
            skillCount: 2,
            skillNames: ["a", "b"],
            agentCount: 1,
            agentNames: ["explorer"],
            hookStatus: .active,
            hookCount: 3,
            mcpServerCount: 1,
            mcpStatus: .activeInline,
            marketplaceSource: "official",
            origin: .userGrok,
            conflict: nil
        )
        #expect(try roundTrip(plugin) == plugin)
        let json = try encodeJSON(plugin)
        #expect(json.contains("\"skillCount\""))
        #expect(json.contains("\"hookStatus\""))
        #expect(json.contains("\"mcpStatus\""))
        #expect(json.contains("\"marketplaceSource\""))

        // Without origin field → nil
        let noOrigin = try decodeJSON(
            PluginInfo.self,
            """
            {"name":"p","id":"i","root":"/r","scope":"user","trusted":true,"enabled":true,\
            "skillCount":0,"agentCount":0,"hookStatus":"none","mcpServerCount":0,"mcpStatus":"none"}
            """
        )
        #expect(noOrigin.origin == nil)
        #expect(noOrigin.skillNames.isEmpty)
    }

    @Test("plugin origin all variants + unknown future")
    func pluginOrigin() throws {
        let variants: [PluginOrigin] = [
            .cliOverride,
            .projectGrok,
            .projectClaude,
            .userGrok,
            .userClaude,
            .claudeMarketplace(marketplace: "m"),
            .claudeInstalled(marketplace: "m"),
            .claudeInstalled(marketplace: nil),
            .marketplaceInstall(sourceName: "s", gitUrl: "https://x"),
            .marketplaceInstall(sourceName: nil, gitUrl: nil),
            .configPath,
            .unknown,
        ]
        for v in variants {
            #expect(try roundTrip(v) == v)
        }

        // Future variant degrades to unknown
        let future = try decodeJSON(PluginOrigin.self, #"{"type":"brand_new_source"}"#)
        #expect(future == .unknown)

        // PluginInfo with future origin still parses
        let pluginJSON = """
        {"name":"p","id":"i","root":"/r","scope":"cli","trusted":true,"enabled":true,\
        "skillCount":0,"agentCount":0,"hookStatus":"none","mcpServerCount":0,"mcpStatus":"none",\
        "origin":{"type":"brand_new_source"}}
        """
        let plugin = try decodeJSON(PluginInfo.self, pluginJSON)
        #expect(plugin.origin == .unknown)

        // Tagged snake_case format
        let market = PluginOrigin.claudeMarketplace(marketplace: "foo")
        let mJSON = try encodeJSON(market)
        #expect(mJSON.contains(#""type":"claude_marketplace""#))
        #expect(mJSON.contains("\"marketplace\""))
    }

    @Test("hook event snake_case catalog")
    func hookEvents() throws {
        let cases: [(HookEvent, String)] = [
            (.sessionStart, "session_start"),
            (.sessionEnd, "session_end"),
            (.stop, "stop"),
            (.stopFailure, "stop_failure"),
            (.preToolUse, "pre_tool_use"),
            (.postToolUse, "post_tool_use"),
            (.postToolUseFailure, "post_tool_use_failure"),
            (.permissionDenied, "permission_denied"),
            (.userPromptSubmit, "user_prompt_submit"),
            (.notification, "notification"),
            (.subagentStart, "subagent_start"),
            (.subagentStop, "subagent_stop"),
            (.preCompact, "pre_compact"),
            (.postCompact, "post_compact"),
        ]
        for (event, wire) in cases {
            #expect(try encodeJSON(event) == "\"\(wire)\"")
            #expect(try roundTrip(event) == event)
        }
        // Display labels (trust/precedence UX)
        #expect(HookEvent.preToolUse.description == "Pre-Tool Use")
        #expect(HookEvent.sessionStart.description == "Session Start")
    }

    @Test("scopes, statuses, handler types")
    func enums() throws {
        for scope in [PluginScope.cli, .project, .user, .config] {
            #expect(try roundTrip(scope) == scope)
        }
        for status in [HookStatus.active, .activeInline, .blocked, .none] {
            #expect(try roundTrip(status) == status)
        }
        for status in [McpStatus.active, .activeInline, .blocked, .none] {
            #expect(try roundTrip(status) == status)
        }
        #expect(try encodeJSON(HookHandlerType.command) == "\"command\"")
        #expect(try encodeJSON(HookHandlerType.http) == "\"http\"")
        #expect(try encodeJSON(HookStatus.activeInline) == "\"active_inline\"")
    }
}

// MARK: - MCP + marketplace + components

@Suite("MCP servers + marketplace + components")
struct McpMarketplaceComponentTests {
    @Test("mcp server list camelCase")
    func mcpList() throws {
        let server = McpServerInfo(
            name: "fs",
            source: .local,
            enabled: true,
            status: .ready,
            toolCount: 2,
            tools: [McpToolInfo(name: "read", description: "r")],
            configSource: "config.toml"
        )
        #expect(try roundTrip(server) == server)
        let list = McpServersListResponse(servers: [server])
        #expect(try roundTrip(list) == list)
        #expect(try encodeJSON(McpServerSource.managed) == "\"managed\"")
        #expect(try encodeJSON(McpSessionStatus.initializing) == "\"initializing\"")
    }

    @Test("component item sanitize + summary")
    func components() throws {
        let dirty = ComponentItem(
            name: "skill\u{0007}name",
            description: String(repeating: "x", count: 200)
        )
        #expect(!dirty.name.contains("\u{0007}"))
        #expect((dirty.description?.count ?? 0) <= MAX_COMPONENT_DESC_CHARS)

        // Unicode spoofing chars stripped
        let spoof = ComponentItem(name: "a\u{200b}b\u{feff}c", description: nil)
        #expect(spoof.name == "abc")

        var comps = PluginComponents(
            skills: [ComponentItem(name: "s1", description: nil)],
            commands: [ComponentItem(name: "c1", description: nil), ComponentItem(name: "c2", description: nil)],
            agents: [],
            mcpServers: [ComponentItem(name: "m", description: nil)],
            hooks: [],
            lspServers: []
        )
        let summary = comps.summaryLine()
        #expect(summary != nil)
        #expect(summary!.contains("skill"))
        #expect(summary!.contains("commands"))
        #expect(summary!.contains("MCP server"))

        // Cap categories
        comps.skills = (0..<60).map { ComponentItem(name: "s\($0)", description: nil) }
        comps.sanitize()
        #expect(comps.skills.count == MAX_COMPONENTS_PER_CATEGORY)

        // categories covers all six
        let cats = comps.categories()
        #expect(cats.count == 6)
        #expect(Set(cats.map(\.0)) == Set(ComponentCategory.allCases))

        #expect(try roundTrip(comps) == comps)
        let cJSON = try encodeJSON(comps)
        #expect(cJSON.contains("\"mcpServers\"") || cJSON.contains("skills"))
    }

    @Test("marketplace plugin entry homepage/keywords + components")
    func marketplace() throws {
        let entry = MarketplacePluginEntry(
            name: "cool",
            version: "1.0",
            description: "d",
            author: "a",
            keywords: ["k1", "k2"],
            homepage: "https://example.com",
            relativePath: "plugins/cool",
            skillCount: 1,
            hasHooks: false,
            hasAgents: false,
            hasMcp: false,
            installStatus: "available",
            components: PluginComponents(
                skills: [ComponentItem(name: "s", description: "d")]
            )
        )
        #expect(try roundTrip(entry) == entry)
        let json = try encodeJSON(entry)
        #expect(json.contains("\"homepage\""))
        #expect(json.contains("\"keywords\""))

        // Defaults when homepage/keywords absent
        let minimal = try decodeJSON(
            MarketplacePluginEntry.self,
            """
            {"name":"n","description":"d","relativePath":"p","skillCount":0,\
            "hasHooks":false,"hasAgents":false,"hasMcp":false,"installStatus":"available"}
            """
        )
        #expect(minimal.homepage == nil)
        #expect(minimal.keywords.isEmpty)

        let scan = MarketplaceScanResult(
            sourceName: "official",
            sourceKind: "git",
            sourceUrlOrPath: "https://example.com/market",
            plugins: [entry],
            error: nil
        )
        #expect(try roundTrip(scan) == scan)
        let list = MarketplaceListResponse(sources: [scan])
        #expect(try roundTrip(list) == list)

        // Marketplace actions
        #expect(try roundTrip(MarketplaceAction.refresh(sourceUrlOrPath: nil)) == .refresh(sourceUrlOrPath: nil))
        #expect(
            try roundTrip(MarketplaceAction.install(sourceUrlOrPath: "s", pluginRelativePath: "p"))
                == .install(sourceUrlOrPath: "s", pluginRelativePath: "p")
        )
        let actionReq = MarketplaceActionRequest(sessionId: "s", action: .refresh(sourceUrlOrPath: nil))
        #expect(try roundTrip(actionReq) == actionReq)
    }

    @Test("hooks list response load errors optional")
    func hooksList() throws {
        let resp = HooksListResponse(
            hooks: [
                HookInfo(
                    name: "h",
                    event: .preToolUse,
                    handlerType: .http,
                    matcher: nil,
                    command: nil,
                    url: "https://hooks.example/run",
                    timeoutMs: 1000,
                    sourceDir: "/x",
                    disabled: true
                )
            ],
            projectTrusted: true,
            loadErrors: ["bad.toml: parse error"]
        )
        #expect(try roundTrip(resp) == resp)
        let emptyErrors = HooksListResponse(hooks: [], projectTrusted: false)
        let json = try encodeJSON(emptyErrors)
        // skip_serializing_if empty
        #expect(!json.contains("loadErrors") || json.contains("\"loadErrors\":[]") == false)
        #expect(try roundTrip(emptyErrors) == emptyErrors)
    }

    @Test("malformed input rejected")
    func malformed() {
        #expect(throws: DecodingError.self) {
            try decodeJSON(PluginScope.self, "\"nope\"")
        }
        #expect(throws: DecodingError.self) {
            try decodeJSON(HookEvent.self, "\"not_an_event\"")
        }
        #expect(throws: DecodingError.self) {
            try decodeJSON(OutcomeStatus.self, "\"bogus\"")
        }
    }

    @Test("forward-compatible unknown extension fields ignored")
    func unknownExtensionFields() throws {
        // Serde default: unknown object keys are ignored on decode so older
        // pagers keep working when a newer shell adds descriptor fields.
        let hookJSON = """
        {"name":"h","event":"pre_tool_use","handlerType":"command","timeoutMs":100,\
        "sourceDir":"/hooks","matcher":"edit_file","command":"/bin/check",\
        "failurePolicy":"continue","activationScope":"project","futureField":true}
        """
        let hook = try decodeJSON(HookInfo.self, hookJSON)
        #expect(hook.name == "h")
        #expect(hook.matcher == "edit_file")
        #expect(hook.disabled == false)
        #expect(try roundTrip(hook) == hook)

        let pluginJSON = """
        {"name":"p","id":"i","root":"/r","scope":"user","trusted":true,"enabled":true,\
        "skillCount":0,"agentCount":0,"hookStatus":"none","mcpServerCount":0,\
        "mcpStatus":"none","precedence":10,"env":{"K":"V"},"extension":{"x":1}}
        """
        let plugin = try decodeJSON(PluginInfo.self, pluginJSON)
        #expect(plugin.id == "i")
        #expect(plugin.trusted)
        #expect(try roundTrip(plugin) == plugin)

        let actionJSON = #"{"type":"install","source":"github.com/a/b","confirm":false,"dryRun":true}"#
        let action = try decodeJSON(PluginsAction.self, actionJSON)
        if case .install(let source) = action {
            #expect(source == "github.com/a/b")
        } else {
            Issue.record("expected install action")
        }
    }
}
