// LiveBundleComposition.swift
//
// Subagent bundle download, installation lifecycle, cache sync, and status.
// Ported from `crates/codegen/xai-grok-shell/src/extensions/bundle.rs` & `remote/client.rs`.

import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokPaths
import OpenGrokShared
import OpenGrokVersion
import struct OpenGrokCLIChatProxyTypes.SubagentBundle

// MARK: - Constants

public let BUNDLE_SYNC_TTL: TimeInterval = 60 * 60

public let NO_BUNDLE_CREDENTIALS_ERROR =
    "bundle sync requires either an authenticated cli-chat-proxy session or a deployment key"

// MARK: - Data Types

public struct BundleSyncResult: Codable, Equatable, Sendable {
    public var updated: Bool
    public var version: String
    public var personasCount: Int
    public var rolesCount: Int
    public var agentsCount: Int
    public var skillsCount: Int

    public init(
        updated: Bool,
        version: String,
        personasCount: Int,
        rolesCount: Int,
        agentsCount: Int,
        skillsCount: Int
    ) {
        self.updated = updated
        self.version = version
        self.personasCount = personasCount
        self.rolesCount = rolesCount
        self.agentsCount = agentsCount
        self.skillsCount = skillsCount
    }
}

public struct PersonaDetail: Codable, Equatable, Sendable {
    public var name: String
    public var description: String?
    public var hasInputs: Bool
    public var hasOutputs: Bool

    public init(name: String, description: String? = nil, hasInputs: Bool = false, hasOutputs: Bool = false) {
        self.name = name
        self.description = description
        self.hasInputs = hasInputs
        self.hasOutputs = hasOutputs
    }
}

public struct RoleDetail: Codable, Equatable, Sendable {
    public var name: String
    public var description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

public struct BundleStatusResult: Codable, Equatable, Sendable {
    public var hasCache: Bool
    public var version: String?
    public var personas: [String]
    public var roles: [String]
    public var agents: [String]
    public var skills: [String]
    public var personaDetails: [PersonaDetail]
    public var roleDetails: [RoleDetail]

    public init(
        hasCache: Bool,
        version: String? = nil,
        personas: [String] = [],
        roles: [String] = [],
        agents: [String] = [],
        skills: [String] = [],
        personaDetails: [PersonaDetail] = [],
        roleDetails: [RoleDetail] = []
    ) {
        self.hasCache = hasCache
        self.version = version
        self.personas = personas
        self.roles = roles
        self.agents = agents
        self.skills = skills
        self.personaDetails = personaDetails
        self.roleDetails = roleDetails
    }
}

public struct EntryGetResult: Codable, Equatable, Sendable {
    public var kind: String
    public var name: String
    public var content: String

    public init(kind: String, name: String, content: String) {
        self.kind = kind
        self.name = name
        self.content = content
    }
}

public enum FetchedBundle: Sendable {
    case archive(Data)
    case legacy(SubagentBundle)
}

// MARK: - Credentials & Freshness

public func hasBundleCredentials(
    authManager: AuthManager?,
    deploymentKey: String?
) async -> Bool {
    if deploymentKey != nil {
        return true
    }
    if let authManager {
        return await authManager.currentOrExpired() != nil
    }
    return false
}

public func bundleCacheIsFresh(root: URL, ttl: TimeInterval = BUNDLE_SYNC_TTL) -> Bool {
    let manifestURL = root.appendingPathComponent("manifest.json")
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: manifestURL.path),
          let modifiedDate = attributes[.modificationDate] as? Date else {
        return false
    }

    let elapsed = Date().timeIntervalSince(modifiedDate)
    guard elapsed >= 0 && elapsed < ttl else {
        return false
    }

    return (try? readCachedManifest(root: root)) != nil
}

// MARK: - Status & Inspection

public func statusBundleAt(root: URL) throws -> BundleStatusResult {
    guard let manifest = try readCachedManifest(root: root) else {
        return BundleStatusResult(
            hasCache: false,
            version: nil,
            personas: [],
            roles: [],
            agents: [],
            skills: [],
            personaDetails: [],
            roleDetails: []
        )
    }

    let personas = listCachedEntries(root: root, manifest: manifest, dirName: "personas", extensionName: "toml")
    let roles = listCachedEntries(root: root, manifest: manifest, dirName: "roles", extensionName: "toml")
    let agents = listCachedEntries(root: root, manifest: manifest, dirName: "agents", extensionName: "md")
    let skills = listCachedSkillEntries(root: root, manifest: manifest)

    let personaDetails = personas.compactMap { personaDetailFromTOML(name: $0, root: root) }
    let roleDetails = roles.compactMap { roleDetailFromTOML(name: $0, root: root) }

    return BundleStatusResult(
        hasCache: true,
        version: manifest.version,
        personas: personas,
        roles: roles,
        agents: agents,
        skills: skills,
        personaDetails: personaDetails,
        roleDetails: roleDetails
    )
}

public func getEntryAt(root: URL, kind: String, name: String) throws -> EntryGetResult {
    try validateEntryName(name)
    let (dirName, ext): (String, String)
    switch kind {
    case "persona":
        dirName = "personas"; ext = "toml"
    case "role":
        dirName = "roles"; ext = "toml"
    case "agent":
        dirName = "agents"; ext = "md"
    default:
        throw BundleError.unknownEntryKind(kind)
    }

    let filePath = root.appendingPathComponent(dirName).appendingPathComponent("\(name).\(ext)")
    guard FileManager.default.fileExists(atPath: filePath.path),
          let content = try? String(contentsOf: filePath, encoding: .utf8) else {
        throw BundleError.entryNotFound(kind: kind, name: name)
    }

    return EntryGetResult(kind: kind, name: name, content: content)
}

private func validateEntryName(_ name: String) throws {
    if name.isEmpty
        || name.contains("/")
        || name.contains("\\")
        || name.contains("..")
        || name == "."
    {
        throw BundleError.invalidBundleName("invalid entry name: \(name)")
    }
}

private func listCachedEntries(
    root: URL,
    manifest: BundleManifest,
    dirName: String,
    extensionName: String
) -> [String] {
    let dir = root.appendingPathComponent(dirName)
    guard let fileURLs = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
        return []
    }

    var names: [String] = []
    for fileURL in fileURLs {
        let fileName = fileURL.lastPathComponent
        let relativePath = "\(dirName)/\(fileName)"
        guard manifest.checksums.keys.contains(relativePath) else {
            continue
        }
        if fileURL.pathExtension == extensionName {
            let stem = fileURL.deletingPathExtension().lastPathComponent
            names.append(stem)
        }
    }
    names.sort()
    return names
}

private func listCachedSkillEntries(root: URL, manifest: BundleManifest) -> [String] {
    let prefix = "skills/"
    let suffix = "/SKILL.md"
    var names: [String] = []

    for key in manifest.checksums.keys {
        if key.hasPrefix(prefix) && key.hasSuffix(suffix) {
            let skillName = String(key.dropFirst(prefix.count).dropLast(suffix.count))
            let fullPath = root.appendingPathComponent(key)
            if FileManager.default.fileExists(atPath: fullPath.path) {
                names.append(skillName)
            }
        }
    }
    names.sort()
    return names
}

private func extractFirstParagraph(_ text: String) -> String? {
    let paragraphs = text.components(separatedBy: "\n\n")
    for p in paragraphs {
        let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
    }
    return nil
}

private func personaDetailFromTOML(name: String, root: URL) -> PersonaDetail? {
    let path = root.appendingPathComponent("personas").appendingPathComponent("\(name).toml")
    guard let content = try? String(contentsOf: path, encoding: .utf8),
          let parsed = try? parseTOML(Data(content.utf8)),
          case .table(let table) = parsed else {
        return nil
    }

    var desc: String?
    if let d = table["description"]?.stringValue, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        desc = d
    } else if let inst = table["instructions"]?.stringValue {
        desc = extractFirstParagraph(inst)
    }

    let hasInputs = (table["inputs"]?.arrayValue?.isEmpty == false)
    let hasOutputs = (table["outputs"]?.arrayValue?.isEmpty == false)

    return PersonaDetail(
        name: name,
        description: desc,
        hasInputs: hasInputs,
        hasOutputs: hasOutputs
    )
}

private func roleDetailFromTOML(name: String, root: URL) -> RoleDetail? {
    let path = root.appendingPathComponent("roles").appendingPathComponent("\(name).toml")
    guard let content = try? String(contentsOf: path, encoding: .utf8),
          let parsed = try? parseTOML(Data(content.utf8)),
          case .table(let table) = parsed else {
        return nil
    }

    let desc = table["description"]?.stringValue ?? ""
    return RoleDetail(name: name, description: desc)
}

// MARK: - Remote Fetching & Sync

public func fetchBundle(
    proxyBaseURL: String,
    authManager: AuthManager? = nil,
    deploymentKey: String? = nil,
    alphaTestKey: String? = nil,
    transport: (any HTTPTransport)? = nil
) async throws -> FetchedBundle {
    let httpTransport = transport ?? URLSessionHTTPTransport()
    let trimmedBase = proxyBaseURL.hasSuffix("/") ? String(proxyBaseURL.dropLast()) : proxyBaseURL

    // 1. Try archive endpoint first: GET /bundle/archive
    guard let archiveURL = URL(string: "\(trimmedBase)/bundle/archive") else {
        throw BundleError.fileIO("invalid bundle archive URL: \(trimmedBase)/bundle/archive")
    }

    var headers: [String: String] = [
        "x-grok-client-version": OpenGrokVersion.compiledVersion,
    ]

    if let deploymentKey {
        headers["authorization"] = "Bearer \(deploymentKey)"
    } else if let authManager, let auth = await authManager.current() {
        headers["authorization"] = "Bearer \(auth.key)"
        headers["x-userid"] = auth.userID
        if let email = auth.email {
            headers["x-email"] = email
        }
    }
    if let alphaTestKey {
        headers["x-alpha-test-key"] = alphaTestKey
    }

    let archiveReq = HTTPRequest(
        method: .get,
        url: archiveURL,
        headers: headers,
        timeout: 30
    )

    let archiveResp = try await httpTransport.send(archiveReq)
    let archiveMeta = archiveResp.metadata
    let archiveData = archiveResp.body
    if archiveMeta.statusCode >= 200 && archiveMeta.statusCode < 300 {
        return .archive(archiveData)
    }

    if archiveMeta.statusCode == 401 {
        let msg = String(data: archiveData, encoding: .utf8) ?? "unauthorized"
        throw BundleError.fileIO("HTTP 401 unauthorized: \(msg)")
    }

    // 2. Fallback to legacy JSON endpoint: GET /v1/subagents/bundle
    guard let legacyURL = URL(string: "\(trimmedBase)/v1/subagents/bundle") else {
        throw BundleError.fileIO("invalid legacy bundle URL: \(trimmedBase)/v1/subagents/bundle")
    }

    let legacyReq = HTTPRequest(
        method: .get,
        url: legacyURL,
        headers: headers,
        timeout: 30
    )

    let legacyResp = try await httpTransport.send(legacyReq)
    let legacyMeta = legacyResp.metadata
    let legacyData = legacyResp.body
    guard legacyMeta.statusCode >= 200 && legacyMeta.statusCode < 300 else {
        let msg = String(data: legacyData, encoding: .utf8) ?? "HTTP \(legacyMeta.statusCode)"
        throw BundleError.fileIO("failed to fetch legacy bundle: \(msg)")
    }

    let bundle = try JSONDecoder().decode(SubagentBundle.self, from: legacyData)
    return .legacy(bundle)
}

public func syncBundleToRoot(
    root: URL,
    proxyBaseURL: String,
    authManager: AuthManager? = nil,
    deploymentKey: String? = nil,
    alphaTestKey: String? = nil,
    force: Bool = false,
    transport: (any HTTPTransport)? = nil
) async throws -> BundleSyncResult {
    guard await hasBundleCredentials(authManager: authManager, deploymentKey: deploymentKey) else {
        throw BundleError.fileIO(NO_BUNDLE_CREDENTIALS_ERROR)
    }

    let fetched = try await fetchBundle(
        proxyBaseURL: proxyBaseURL,
        authManager: authManager,
        deploymentKey: deploymentKey,
        alphaTestKey: alphaTestKey,
        transport: transport
    )

    switch fetched {
    case .archive(let bytes):
        let manifest = try extractBundleArchive(root: root, archiveBytes: bytes)
        let personasCount = countEntriesByPrefix(manifest: manifest, prefix: "personas/")
        let rolesCount = countEntriesByPrefix(manifest: manifest, prefix: "roles/")
        let agentsCount = countEntriesByPrefix(manifest: manifest, prefix: "agents/")
        let skillsCount = countEntriesByPrefix(manifest: manifest, prefix: "skills/")
        return BundleSyncResult(
            updated: true,
            version: manifest.version,
            personasCount: personasCount,
            rolesCount: rolesCount,
            agentsCount: agentsCount,
            skillsCount: skillsCount
        )
    case .legacy(let bundle):
        let version = bundle.version
        let personasCount = bundle.personas.count
        let rolesCount = bundle.roles.count
        let agentsCount = bundle.agents.count
        let skillsCount = bundle.skills.count
        _ = try writeBundleToCache(root: root, bundle: bundle)
        return BundleSyncResult(
            updated: true,
            version: version,
            personasCount: personasCount,
            rolesCount: rolesCount,
            agentsCount: agentsCount,
            skillsCount: skillsCount
        )
    }
}

public func maybeSyncBundleToRoot(
    root: URL,
    proxyBaseURL: String,
    authManager: AuthManager? = nil,
    deploymentKey: String? = nil,
    alphaTestKey: String? = nil,
    force: Bool = false,
    ttl: TimeInterval = BUNDLE_SYNC_TTL,
    transport: (any HTTPTransport)? = nil
) async throws -> BundleSyncResult? {
    guard await hasBundleCredentials(authManager: authManager, deploymentKey: deploymentKey) else {
        return nil
    }
    if !force && bundleCacheIsFresh(root: root, ttl: ttl) {
        return nil
    }
    return try await syncBundleToRoot(
        root: root,
        proxyBaseURL: proxyBaseURL,
        authManager: authManager,
        deploymentKey: deploymentKey,
        alphaTestKey: alphaTestKey,
        force: force,
        transport: transport
    )
}

// MARK: - ACP Handler

public struct LiveBundleACPHandler: ACPAgentExtensionHandler, Sendable {
    public static let methods = [
        "x.ai/bundle/sync",
        "x.ai/bundle/status",
        "x.ai/bundle/entry/get",
    ]

    private let root: URL
    private let proxyBaseURL: String
    private let authManager: AuthManager?
    private let deploymentKey: String?
    private let alphaTestKey: String?
    private let transport: (any HTTPTransport)?

    public init(
        root: URL,
        proxyBaseURL: String = "https://api.x.ai",
        authManager: AuthManager? = nil,
        deploymentKey: String? = nil,
        alphaTestKey: String? = nil,
        transport: (any HTTPTransport)? = nil
    ) {
        self.root = root
        self.proxyBaseURL = proxyBaseURL
        self.authManager = authManager
        self.deploymentKey = deploymentKey
        self.alphaTestKey = alphaTestKey
        self.transport = transport
    }

    public func handle(
        method: String,
        params: JSONValue
    ) async throws -> JSONValue {
        switch method {
        case "x.ai/bundle/sync":
            struct SyncParams: Codable {
                var force: Bool?
            }
            let data = try JSONEncoder().encode(params)
            let force = (try? JSONDecoder().decode(SyncParams.self, from: data))?.force ?? false
            let result = try await syncBundleToRoot(
                root: root,
                proxyBaseURL: proxyBaseURL,
                authManager: authManager,
                deploymentKey: deploymentKey,
                alphaTestKey: alphaTestKey,
                force: force,
                transport: transport
            )
            let resData = try JSONEncoder().encode(result)
            return try JSONDecoder().decode(JSONValue.self, from: resData)

        case "x.ai/bundle/status":
            let result = try statusBundleAt(root: root)
            let resData = try JSONEncoder().encode(result)
            return try JSONDecoder().decode(JSONValue.self, from: resData)

        case "x.ai/bundle/entry/get":
            struct EntryGetParams: Codable {
                var kind: String
                var name: String
            }
            let data = try JSONEncoder().encode(params)
            let req = try JSONDecoder().decode(EntryGetParams.self, from: data)
            let result = try getEntryAt(root: root, kind: req.kind, name: req.name)
            let resData = try JSONEncoder().encode(result)
            return try JSONDecoder().decode(JSONValue.self, from: resData)

        default:
            throw ACPExtensionMethodRouter.unknownExtensionMethodError(method)
        }
    }
}
