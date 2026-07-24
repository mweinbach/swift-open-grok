// OpenGrokConfigTypesTests.swift
//
// R04 — Rust-derived fixtures for OpenGrokConfigTypes leaf schemas:
// flags, permissions, memory, MCP, pool, remote settings.

import Foundation
import Testing
@testable import OpenGrokConfigTypes
import OpenGrokShared

// MARK: - envBool / BoolFlag

@Suite("ConfigTypes flags")
struct ConfigTypesFlagsTests {
    @Test("envBool truthy/falsy/unrecognized")
    func envBoolMatrix() {
        #expect(envBool("F", environment: ["F": "1"]) == true)
        #expect(envBool("F", environment: ["F": "YES"]) == true)
        #expect(envBool("F", environment: ["F": "on"]) == true)
        #expect(envBool("F", environment: ["F": "0"]) == false)
        #expect(envBool("F", environment: ["F": "disabled"]) == false)
        #expect(envBool("F", environment: ["F": ""]) == nil)
        #expect(envBool("F", environment: ["F": "maybe"]) == nil)
        #expect(envBool("F", environment: [:]) == nil)
    }

    @Test("BoolFlag precedence: requirement > cli > env > config > managed > feature > default")
    func boolFlagPrecedence() {
        let env = ["MY_FLAG": "true"]
        // requirement wins over everything
        let r = BoolFlag(envVar: "MY_FLAG")
            .requirement(false)
            .cli(true)
            .config(true)
            .managed(true)
            .featureFlag(true)
            .defaultValue(true)
            .resolve(environment: env)
        #expect(r.value == false)
        #expect(r.source == .requirement)

        // cli over env
        let c = BoolFlag(envVar: "MY_FLAG")
            .cli(false)
            .resolve(environment: env)
        #expect(c.value == false)
        #expect(c.source == .cli)

        // env over config
        let e = BoolFlag(envVar: "MY_FLAG")
            .config(false)
            .resolve(environment: env)
        #expect(e.value == true)
        #expect(e.source == .env)

        // default when nothing set
        let d = BoolFlag(envVar: "UNSET")
            .defaultValue(true)
            .resolve(environment: [:])
        #expect(d.value == true)
        #expect(d.source == .default)
    }

    @Test("ConfigSource wire names")
    func configSourceWire() throws {
        let enc = JSONEncoder()
        let data = try enc.encode(ConfigSource.systemManagedConfig)
        let s = String(data: data, encoding: .utf8)
        #expect(s?.contains("system_managed_config") == true)
    }

    @Test("LazinessDetectorPerModelConfig defaults and snake_case")
    func lazinessDefaults() throws {
        let empty = try JSONDecoder().decode(LazinessDetectorPerModelConfig.self, from: Data("{}".utf8))
        #expect(empty.enabled == false)
        #expect(empty.maxNudgesPerSession == 0)

        let partial = try JSONDecoder().decode(
            LazinessDetectorPerModelConfig.self,
            from: Data(#"{"enabled":true,"max_nudges_per_session":2}"#.utf8)
        )
        #expect(partial.enabled == true)
        #expect(partial.maxNudgesPerSession == 2)
    }
}

// MARK: - Permission

@Suite("PermissionConfig")
struct PermissionConfigTests {
    @Test("defaults are fail-closed (deny / any / glob)")
    func defaults() throws {
        let rule = try JSONDecoder().decode(PermissionRule.self, from: Data("{}".utf8))
        #expect(rule.action == .deny)
        #expect(rule.tool == .any)
        #expect(rule.patternMode == .glob)

        let cfg = try JSONDecoder().decode(PermissionConfig.self, from: Data("{}".utf8))
        #expect(cfg.rules.isEmpty)
    }

    @Test("permission rule wire form snake_case")
    func wireForm() throws {
        let json = """
        {"rules":[{"action":"allow","tool":"web_fetch","pattern":"example.com","pattern_mode":"domain"}]}
        """
        let cfg = try JSONDecoder().decode(PermissionConfig.self, from: Data(json.utf8))
        #expect(cfg.rules.count == 1)
        #expect(cfg.rules[0].action == .allow)
        #expect(cfg.rules[0].tool == .webFetch)
        #expect(cfg.rules[0].pattern == "example.com")
        #expect(cfg.rules[0].patternMode == .domain)

        // Round-trip
        let enc = JSONEncoder()
        let data = try enc.encode(cfg)
        let again = try JSONDecoder().decode(PermissionConfig.self, from: data)
        #expect(again == cfg)
    }

    @Test("unknown action/tool fall back safely")
    func unknownFallbacks() throws {
        let json = #"{"action":"explode","tool":"teleport","pattern_mode":"weird"}"#
        let rule = try JSONDecoder().decode(PermissionRule.self, from: Data(json.utf8))
        #expect(rule.action == .deny)
        #expect(rule.tool == .any)
        #expect(rule.patternMode == .glob)
    }
}

// MARK: - Pool

@Suite("PoolConfig")
struct PoolConfigTests {
    @Test("defaults match Rust serde helpers")
    func defaults() throws {
        let empty = try JSONDecoder().decode(PoolConfig.self, from: Data("{}".utf8))
        #expect(empty.enabled == true)
        #expect(empty.poolSize == 2)
        #expect(empty.fileCountThreshold == 50_000)
        #expect(empty.parallelism == 3)
        #expect(empty == PoolConfig())
    }

    @Test("partial override keeps other field defaults")
    func partial() throws {
        let c = try JSONDecoder().decode(PoolConfig.self, from: Data(#"{"enabled":false}"#.utf8))
        #expect(c.enabled == false)
        #expect(c.poolSize == 2)
        #expect(c.fileCountThreshold == 50_000)
        #expect(c.parallelism == 3)
    }

    @Test("snake_case wire keys round-trip")
    func snakeCaseRoundTrip() throws {
        let json = #"{"enabled":false,"pool_size":4,"file_count_threshold":1000,"parallelism":8}"#
        let c = try JSONDecoder().decode(PoolConfig.self, from: Data(json.utf8))
        #expect(c.enabled == false)
        #expect(c.poolSize == 4)
        #expect(c.fileCountThreshold == 1000)
        #expect(c.parallelism == 8)
        let encoded = try JSONEncoder().encode(c)
        let again = try JSONDecoder().decode(PoolConfig.self, from: encoded)
        #expect(again == c)
        let s = String(data: encoded, encoding: .utf8) ?? ""
        #expect(s.contains("pool_size"))
        #expect(s.contains("file_count_threshold"))
    }
}

// MARK: - Memory

@Suite("Memory configs")
struct MemoryConfigTests {
    @Test("MemoryIndexConfig defaults and snake_case")
    func indexDefaults() throws {
        let empty = try JSONDecoder().decode(MemoryIndexConfig.self, from: Data("{}".utf8))
        #expect(empty.maxChunkChars == 1600)
        #expect(empty.chunkOverlapChars == 320)
        let partial = try JSONDecoder().decode(
            MemoryIndexConfig.self,
            from: Data(#"{"max_chunk_chars":800}"#.utf8)
        )
        #expect(partial.maxChunkChars == 800)
        #expect(partial.chunkOverlapChars == 320)
        let enc = try JSONEncoder().encode(partial)
        #expect(String(data: enc, encoding: .utf8)?.contains("max_chunk_chars") == true)
    }

    @Test("MemorySearchConfig defaults, mmr clamp, half-life resolution")
    func searchDefaultsAndBehavior() throws {
        let empty = try JSONDecoder().decode(MemorySearchConfig.self, from: Data("{}".utf8))
        #expect(empty.maxResults == 6)
        #expect(empty.minScore == 0.35)
        #expect(empty.vectorWeight == 0.7)
        #expect(empty.textWeight == 0.3)
        #expect(empty.recencyDecay == MemorySearchConfig.defaultRecencyDecay)
        #expect(empty.temporalDecay.enabled == true)
        #expect(empty.temporalDecay.halfLifeDays == 7.0)
        #expect(empty.mmr.enabled == false)
        #expect(empty.mmr.lambda == 0.7)
        #expect(empty.effectiveHalfLifeDays() == 7.0)

        let clamped = try JSONDecoder().decode(
            MemorySearchConfig.self,
            from: Data(#"{"mmr":{"enabled":true,"lambda":2.5}}"#.utf8)
        )
        #expect(clamped.mmr.enabled == true)
        #expect(clamped.mmr.lambda == 1.0)

        let legacy = try JSONDecoder().decode(
            MemorySearchConfig.self,
            from: Data(#"{"temporal_decay":{"enabled":false},"recency_decay":0.5}"#.utf8)
        )
        #expect(legacy.effectiveHalfLifeDays() != nil)
    }

    @Test("MemorySessionConfig and MemoryDreamConfig defaults")
    func sessionAndDream() throws {
        let session = try JSONDecoder().decode(MemorySessionConfig.self, from: Data("{}".utf8))
        #expect(session.saveOnEnd == true)
        let dream = try JSONDecoder().decode(MemoryDreamConfig.self, from: Data("{}".utf8))
        #expect(dream.enabled == true)
        #expect(dream.minHours == 4)
        #expect(dream.minSessions == 3)
        #expect(dream.staleLockSecs == 3600)
        #expect(dream.checkIntervalSecs == nil)
        let partial = try JSONDecoder().decode(
            MemoryDreamConfig.self,
            from: Data(#"{"min_hours":2,"check_interval_secs":60}"#.utf8)
        )
        #expect(partial.minHours == 2)
        #expect(partial.checkIntervalSecs == 60)
        #expect(partial.minSessions == 3)
    }
}

// MARK: - MCP

@Suite("MCP config types")
struct McpConfigTypesTests {
    @Test("McpServerPreferences snake_case and round-trip")
    func mcpPreferences() throws {
        let json = #"{"values":{"site":"us5"},"source":{"kind":"user"},"updated_at":"2026-01-01T00:00:00Z"}"#
        let prefs = try JSONDecoder().decode(McpServerPreferences.self, from: Data(json.utf8))
        #expect(prefs.values["site"] == "us5")
        #expect(prefs.source?.kind == "user")
        #expect(prefs.updatedAt == "2026-01-01T00:00:00Z")
        let again = try JSONDecoder().decode(McpServerPreferences.self, from: try JSONEncoder().encode(prefs))
        #expect(again == prefs)
    }

    @Test("site-select setup schema resolves urlTemplate")
    func siteSelectResolve() throws {
        let siteSelect = """
        {
            "type": "http",
            "urlTemplate": "{{url}}",
            "setup": {
                "fields": [{
                    "id": "site",
                    "label": "Site",
                    "type": "select",
                    "required": true,
                    "default": "us1",
                    "options": [
                        {"label": "US1", "value": "us1"},
                        {"label": "US5", "value": "us5"}
                    ]
                }],
                "values": {
                    "url": {
                        "from": "site",
                        "map": {
                            "us1": "https://mcp.example.com/v1/mcp",
                            "us5": "https://mcp.us5.example.com/v1/mcp"
                        }
                    }
                }
            }
        }
        """
        let cfg = try JSONDecoder().decode(McpServerConfig.self, from: Data(siteSelect.utf8))
        #expect(cfg.setup?.fields.count == 1)
        #expect(cfg.setup?.variables["url"]?.from == "site")
        if case let .streamableHttp(url, transportType, _, _, _, _, _) = cfg.transport {
            #expect(url == "{{url}}")
            #expect(transportType == "http")
        } else {
            Issue.record("expected streamableHttp transport")
        }

        // Missing prefs → required
        if case .required = cfg.resolveSetup(preferences: nil) {
            // ok
        } else {
            Issue.record("expected setup required without prefs")
        }

        let prefs = McpServerPreferences(values: ["site": "us5"])
        switch cfg.resolveSetup(preferences: prefs) {
        case let .resolved(resolved):
            if case let .streamableHttp(url, _, _, _, _, _, _) = resolved.transport {
                #expect(url == "https://mcp.us5.example.com/v1/mcp")
            } else {
                Issue.record("expected resolved streamableHttp")
            }
            #expect(resolved.setup == nil)
        default:
            Issue.record("expected resolved setup")
        }

        // Invalid multi-field schema
        var multi = cfg
        if var setup = multi.setup {
            setup.fields.append(
                McpSetupField(id: "region", label: "Region", options: [McpSetupOption(label: "A", value: "a")])
            )
            multi.setup = setup
        }
        if case .invalid = multi.resolveSetup(preferences: prefs) {
            // ok
        } else {
            Issue.record("expected invalid multi-field setup")
        }
    }

    @Test("stdio transport decodes command/args")
    func stdioTransport() throws {
        let json = #"{"command":"npx","args":["-y","server"],"env":{"A":"1"},"enabled":false}"#
        let cfg = try JSONDecoder().decode(McpServerConfig.self, from: Data(json.utf8))
        #expect(cfg.enabled == false)
        if case let .stdio(command, args, env, _) = cfg.transport {
            #expect(command == "npx")
            #expect(args == ["-y", "server"])
            #expect(env?["A"] == "1")
        } else {
            Issue.record("expected stdio")
        }
    }
}

// MARK: - Remote settings / campaigns

@Suite("Remote settings")
struct RemoteSettingsTests {
    @Test("DoomLoopRecoverySettings all-optional decode")
    func doomLoop() throws {
        let empty = try JSONDecoder().decode(DoomLoopRecoverySettings.self, from: Data("{}".utf8))
        #expect(empty.enabled == nil)
        #expect(empty.maxThreshold == nil)
        #expect(empty.maxRetries == nil)
        let partial = try JSONDecoder().decode(
            DoomLoopRecoverySettings.self,
            from: Data(#"{"enabled":true,"max_retries":3,"max_threshold":8}"#.utf8)
        )
        #expect(partial.enabled == true)
        #expect(partial.maxRetries == 3)
        #expect(partial.maxThreshold == 8)
        let enc = try JSONEncoder().encode(partial)
        let s = String(data: enc, encoding: .utf8) ?? ""
        #expect(s.contains("max_retries"))
        #expect(s.contains("max_threshold"))
    }

    @Test("DisplayRefreshSettings tolerant decode and unknown fields")
    func displayRefresh() throws {
        let empty = try JSONDecoder().decode(
            OpenGrokConfigTypes.DisplayRefreshSettings.self,
            from: Data("{}".utf8)
        )
        #expect(empty.probeEnabled == nil)
        #expect(empty.autoCadenceEnabled == nil)
        #expect(empty.isDefault == true)
        let partial = try JSONDecoder().decode(
            OpenGrokConfigTypes.DisplayRefreshSettings.self,
            from: Data(#"{"probe_enabled":false,"future_knob":true}"#.utf8)
        )
        #expect(partial.probeEnabled == false)
        #expect(partial.extra["future_knob"] != nil)
        // Wrong type → nil (tolerant)
        let bad = try JSONDecoder().decode(
            OpenGrokConfigTypes.DisplayRefreshSettings.self,
            from: Data(#"{"probe_enabled":"nope","floor_ms":"x"}"#.utf8)
        )
        #expect(bad.probeEnabled == nil)
        #expect(bad.floorMs == nil)
    }

    @Test("CampaignOverride id alias and patch preservation")
    func campaignOverride() throws {
        let withAlias = try JSONDecoder().decode(
            CampaignOverride.self,
            from: Data(#"{"campaign_id":"c1","theme":"dark"}"#.utf8)
        )
        #expect(withAlias.id == "c1")
        #expect(withAlias.patch["theme"] == JSONValue.string("dark"))

        let withId = try JSONDecoder().decode(
            CampaignOverride.self,
            from: Data(#"{"id":"c2","ui":{"screen_mode":"minimal"}}"#.utf8)
        )
        #expect(withId.id == "c2")
        #expect(withId.patch["ui"] != nil)

        let empty = try JSONDecoder().decode(CampaignOverride.self, from: Data("{}".utf8))
        #expect(empty.id == nil)
        #expect(empty.patch.isEmpty)
    }
}
