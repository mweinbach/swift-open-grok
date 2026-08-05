// OpenGrokConfigTests.swift
//
// R04 — Rust-derived fixtures for OpenGrokConfig.
// Covers TOML boundary parsing, session-directory encoding (urlencoding +
// BLAKE3), path/home resolution, shell helpers, signed-policy dark build,
// layered merge precedence, and managed-cache marker basics.

import Foundation
import Testing
@testable import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokPaths
import OpenGrokCLIChatProxyTypes
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - BLAKE3 official vectors

@Suite("Blake3")
struct Blake3Tests {
    @Test("empty message matches official vector")
    func empty() {
        #expect(Blake3.hexDigest([]) == "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262")
    }

    @Test("abc matches official vector")
    func abc() {
        #expect(Blake3.hexDigest(Array("abc".utf8)) == "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85")
    }

    @Test("hello matches Rust blake3::hash")
    func hello() {
        #expect(Blake3.hexDigest(Array("hello".utf8)) == "ea8f163db38682925e4491c5e58d4bb3506ef8c14eb78a86e908c5624a67200f")
    }

    @Test("cwd path prefixes match Rust first-16 hex")
    func cwdPrefixes() {
        #expect(Blake3.hexPrefix("/Users/foo/project", length: 16) == "9c5515242a1255ef")
        #expect(Blake3.hexPrefix("/tmp", length: 16) == "0cd2874cee42764d")
    }
}

// MARK: - TOML boundary fixtures

@Suite("TOML")
struct TOMLTests {
    @Test("hexadecimal integers")
    func hex() throws {
        let v = try parseTOML("a = 0xDEAD_BEEF\nb = 0x10\nc = -0xFF")
        #expect(v["a"]?.int64Value == 0xDEAD_BEEF)
        #expect(v["b"]?.int64Value == 0x10)
        #expect(v["c"]?.int64Value == -0xFF)
    }

    @Test("octal integers")
    func octal() throws {
        let v = try parseTOML("a = 0o755\nb = 0o10")
        #expect(v["a"]?.int64Value == 0o755)
        #expect(v["b"]?.int64Value == 8)
    }

    @Test("binary integers")
    func binary() throws {
        let v = try parseTOML("a = 0b1010_0001\nb = 0b0")
        #expect(v["a"]?.int64Value == 0b1010_0001)
        #expect(v["b"]?.int64Value == 0)
    }

    @Test("signed decimal with underscores")
    func signedUnderscored() throws {
        let v = try parseTOML("a = 1_000\nb = -42\nc = +7")
        #expect(v["a"]?.int64Value == 1000)
        #expect(v["b"]?.int64Value == -42)
        #expect(v["c"]?.int64Value == 7)
    }

    @Test("integer overflow is rejected or saturated")
    func overflow() throws {
        // Far beyond Int64 — parser should error or saturate.
        do {
            let v = try parseTOML("a = 999999999999999999999999999999")
            // If it parses, must not silently wrap to a small value.
            if let i = v["a"]?.int64Value {
                #expect(i == Int64.max || i == Int64.min)
            }
        } catch is TOMLError {
            // Acceptable: out of range.
        }
    }

    @Test("malformed radix rejected")
    func malformedRadix() {
        #expect(throws: TOMLError.self) {
            _ = try parseTOML("a = 0x")
        }
        #expect(throws: TOMLError.self) {
            _ = try parseTOML("a = 0b")
        }
        #expect(throws: TOMLError.self) {
            _ = try parseTOML("a = 0o")
        }
    }

    @Test("floats, inf, nan")
    func floats() throws {
        let v = try parseTOML("""
        a = 3.14
        b = -0.5
        c = 1e2
        d = inf
        e = -inf
        f = nan
        """)
        #expect(v["a"]?.doubleValue == 3.14)
        #expect(v["b"]?.doubleValue == -0.5)
        #expect(v["c"]?.doubleValue == 100.0)
        #expect(v["d"]?.doubleValue == Double.infinity)
        #expect(v["e"]?.doubleValue == -Double.infinity)
        #expect(v["f"]?.doubleValue?.isNaN == true)
    }

    @Test("datetime kept as raw lexical form")
    func datetime() throws {
        let v = try parseTOML("a = 1979-05-27T07:32:00Z\nb = 1979-05-27")
        #expect(v["a"] != nil)
        if case let .datetime(s) = v["a"]! {
            #expect(s.contains("1979-05-27"))
        } else {
            Issue.record("expected datetime")
        }
        if case let .datetime(s) = v["b"]! {
            #expect(s == "1979-05-27")
        }
    }

    @Test("arrays including nested and heterogeneous")
    func arrays() throws {
        let v = try parseTOML("a = [1, 2, 3]\nb = [\"x\", 1, true]\nc = [[1, 2], [3]]")
        #expect(v["a"]?.arrayValue?.count == 3)
        #expect(v["b"]?.arrayValue?.count == 3)
        #expect(v["c"]?.arrayValue?.count == 2)
    }

    @Test("inline tables")
    func inlineTables() throws {
        let v = try parseTOML("a = { x = 1, y = \"z\" }")
        #expect(v["a"]?["x"]?.int64Value == 1)
        #expect(v["a"]?["y"]?.stringValue == "z")
    }

    @Test("tables and array-of-tables preserve unknown keys")
    func tablesAndUnknown() throws {
        let src = """
        title = "TOML"
        [owner]
        name = "Tom"
        future_knob = true
        [[products]]
        name = "Hammer"
        sku = 123
        [[products]]
        name = "Nail"
        """
        let v = try parseTOML(src)
        #expect(v["title"]?.stringValue == "TOML")
        #expect(v["owner"]?["name"]?.stringValue == "Tom")
        #expect(v["owner"]?["future_knob"]?.boolValue == true)
        let products = v["products"]?.arrayValue
        #expect(products?.count == 2)
        #expect(products?[0]["name"]?.stringValue == "Hammer")
        #expect(products?[1]["name"]?.stringValue == "Nail")
    }

    @Test("duplicate key rejected")
    func duplicateKey() {
        #expect(throws: TOMLError.self) {
            _ = try parseTOML("a = 1\na = 2")
        }
    }

    @Test("booleans and strings with escapes")
    func boolsAndStrings() throws {
        let v2 = try parseTOML("""
        a = true
        b = false
        c = "hello\\nworld"
        d = 'raw\\n'
        """)
        #expect(v2["a"]?.boolValue == true)
        #expect(v2["b"]?.boolValue == false)
        #expect(v2["c"]?.stringValue == "hello\nworld")
        #expect(v2["d"]?.stringValue == "raw\\n")
    }

    @Test("error messages never include source line")
    func errorRedaction() {
        do {
            _ = try parseTOML("secret = 0x")
            Issue.record("expected error")
        } catch let e as TOMLError {
            #expect(!e.description.contains("secret"))
            #expect(e.description.contains("line"))
        } catch {
            Issue.record("expected TOMLError")
        }
    }
}

// MARK: - Session directory encoding

@Suite("Paths CWD encoding")
struct PathsCwdTests {
    @Test("short paths percent-encode slash")
    func shortPercentEncodeSlash() {
        #expect(encodeCwdDirname("/Users/foo/project") == "%2FUsers%2Ffoo%2Fproject")
        #expect(encodeCwdDirname("/tmp") == "%2Ftmp")
    }

    @Test("short CJK paths round-trip via URL decode")
    func shortCjkRoundTrip() {
        let cwd = "/Users/user/Documents/project-名前"
        let encoded = encodeCwdDirname(cwd)
        #expect(encoded == urlEncodePath(cwd))
        #expect(encoded.utf8.count <= 255)
        #expect(urlDecodePath(encoded) == cwd)
    }

    @Test("long paths use slug-blake3 form within name max")
    func longUsesHash() {
        let long = "/Users/test/" + String(repeating: "中", count: 30)
        let encoded = encodeCwdDirname(long)
        #expect(encoded.utf8.count <= 255)
        #expect(!encoded.hasPrefix("%2F"))
        #expect(encoded.contains("-"))
        // Must match Rust blake3 first-16.
        let expectedHash = Blake3.hexPrefix(long, length: 16)
        #expect(encoded.hasSuffix(expectedHash))
    }

    @Test("different long paths produce different hashes")
    func differentLongHashes() {
        let a = "/Users/test/" + String(repeating: "中", count: 30)
        let b = "/Users/test/" + String(repeating: "日", count: 30)
        #expect(encodeCwdDirname(a) != encodeCwdDirname(b))
    }

    @Test("slugify basics")
    func slugifyBasics() {
        #expect(slugify("Hello World!", maxLen: 40) == "hello-world")
        #expect(slugify("深层目录", maxLen: 40) == "")
        #expect(slugify(String(repeating: "a", count: 100), maxLen: 10).count == 10)
    }

    @Test("ensureSessionsCwdDir writes .cwd only for hash form and is idempotent")
    func ensureSessionsCwdDirIdempotent() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-config-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let env = [OpenGrokPathPolicy.homeEnvironmentVariable: tmp.path]

        // Short path: no .cwd file.
        let short = "/Users/foo/project"
        let shortDir = try ensureSessionsCwdDir(short, environment: env)
        #expect(!FileManager.default.fileExists(atPath: shortDir.appendingPathComponent(".cwd").path))
        #expect(decodeCwdFromDirname(shortDir) == short)

        // Long path: .cwd written once; second call does not overwrite.
        let long = "/Users/test/" + String(repeating: "中", count: 30)
        let longDir = try ensureSessionsCwdDir(long, environment: env)
        let cwdFile = longDir.appendingPathComponent(".cwd")
        #expect(FileManager.default.fileExists(atPath: cwdFile.path))
        #expect(try String(contentsOf: cwdFile, encoding: .utf8) == long)
        // Second ensure must not throw / must leave content intact.
        _ = try ensureSessionsCwdDir(long, environment: env)
        #expect(try String(contentsOf: cwdFile, encoding: .utf8) == long)
        #expect(decodeCwdFromDirname(longDir) == long)
    }

    @Test("defaultGrokHome ends with .opengrok never .grok")
    func defaultHomeBranding() {
        let home = defaultGrokHome(environment: ["HOME": "/tmp/fake-home-ogrok"])
        #expect(home.lastPathComponent == ".opengrok")
        #expect(!home.path.contains("/.grok"))
    }

    @Test("OPENGROK_HOME wins over default")
    func openGrokHomeWins() {
        let tmp = "/tmp/ogrok-home-override-\(UUID().uuidString)"
        let home = grokHome(environment: [OpenGrokPathPolicy.homeEnvironmentVariable: tmp])
        #expect(home.path == tmp || home.standardizedFileURL.path == URL(fileURLWithPath: tmp).standardizedFileURL.path)
        try? FileManager.default.removeItem(atPath: tmp)
    }

    @Test("systemConfigDir is /etc/opengrok on Unix")
    func systemConfig() {
        #if os(Windows)
        #expect(systemConfigDir() == nil)
        #else
        #expect(systemConfigDir()?.path == "/etc/opengrok")
        #endif
    }

    @Test("grokApplication points at open-grok under home/bin")
    func applicationPath() {
        let tmp = "/tmp/ogrok-app-\(UUID().uuidString)"
        let app = grokApplication(environment: [OpenGrokPathPolicy.homeEnvironmentVariable: tmp])
        #expect(app.lastPathComponent == "open-grok" || app.lastPathComponent == "open-grok.exe")
        #expect(app.path.contains("/bin/"))
        try? FileManager.default.removeItem(atPath: tmp)
    }
}

// MARK: - Layered config / merge

@Suite("Config layers and merge")
struct ConfigLayerTests {
    @Test("deepMergeTOML later overrides earlier; tables recurse")
    func deepMerge() {
        var base = try! parseTOML("""
        a = 1
        [section]
        x = 1
        y = 2
        """)
        let over = try! parseTOML("""
        a = 2
        [section]
        y = 3
        z = 4
        """)
        deepMergeTOML(&base, overrides: over)
        #expect(base["a"]?.int64Value == 2)
        #expect(base["section"]?["x"]?.int64Value == 1)
        #expect(base["section"]?["y"]?.int64Value == 3)
        #expect(base["section"]?["z"]?.int64Value == 4)
    }

    @Test("loadTomlFile expands $VAR and missing file is empty table")
    func loadTomlExpandAndMissing() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-toml-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "name = \"open-grok\"\n".write(to: tmp, atomically: true, encoding: .utf8)
        let v = try loadTomlFile(at: tmp)
        #expect(v["name"]?.stringValue == "open-grok")

        let missing = tmp.deletingLastPathComponent().appendingPathComponent("no-such-\(UUID().uuidString).toml")
        let empty = try loadTomlFile(at: missing)
        #expect(empty.isTableEmpty)
    }

    @Test("effectiveConfigBase order: system managed < managed < user < requirements")
    func layerOrder() {
        // Construct layers without disk.
        let layers = ConfigLayers(
            systemManaged: try! parseTOML("a = 1\nb = 1"),
            managed: try! parseTOML("b = 2\nc = 2"),
            user: try! parseTOML("c = 3\nd = 3"),
            userRequirements: try! parseTOML("d = 4\ne = 4"),
            systemRequirements: try! parseTOML("e = 5"),
            mdmRequirements: nil
        )
        let merged = layers.effectiveConfigBase()
        #expect(merged["a"]?.int64Value == 1)
        #expect(merged["b"]?.int64Value == 2)
        #expect(merged["c"]?.int64Value == 3)
        #expect(merged["d"]?.int64Value == 4)
        #expect(merged["e"]?.int64Value == 5)
    }

    @Test("unknown keys survive parse and merge")
    func unknownKeysPreserved() throws {
        let src = """
        [experimental]
        future_flag = true
        nested = { keep_me = 1 }
        """
        let v = try parseTOML(src)
        #expect(v["experimental"]?["future_flag"]?.boolValue == true)
        #expect(v["experimental"]?["nested"]?["keep_me"]?.int64Value == 1)
    }
}

// MARK: - Signed policy

@Suite("Signed policy", .serialized)
struct SignedPolicyTests {
    @Test("dark build: verification inactive with empty embedded keys")
    func darkBuild() {
        clearEmbeddedKeysOverride()
        #expect(verificationActive() == false)
        #expect(signedCacheCompromised(
            URL(fileURLWithPath: "/tmp"),
            expectedPrincipal: "team",
            nowUnix: 1
        ) == .inactive)
    }

    @Test("test seam activates verification")
    func testSeam() throws {
        // 32 zero bytes is a structurally valid public key length; verification
        // will fail signatures but the key set is non-empty.
        setEmbeddedKeys([("v1", [UInt8](repeating: 0, count: 32))])
        defer { clearEmbeddedKeysOverride() }
        #expect(verificationActive() == true)
        #expect(embeddedKeyIdTrusted("v1") == true)
        #expect(embeddedKeyIdTrusted("v2") == false)
    }

    @Test("bad payload and unknown key id fail closed")
    func failClosedBasics() {
        setEmbeddedKeys([("v1", [UInt8](repeating: 1, count: 32))])
        defer { clearEmbeddedKeysOverride() }
        #expect(throws: SigError.self) {
            _ = try verifySignedPayload("not-json", signatureB64: "YQ==", trustedKeys: [("v1", [UInt8](repeating: 1, count: 32))])
        }
        // Valid-looking JSON with wrong typ / missing fields → badPayload or wrongType.
        let payload = #"{"typ":"wrong","key_id":"v1","expires_at":1}"#
        // Signature won't verify; either bad encoding or mismatch is fine.
        do {
            _ = try verifySignedPayload(
                payload,
                signatureB64: Data(repeating: 0, count: 64).base64EncodedString(),
                trustedKeys: [("v1", [UInt8](repeating: 1, count: 32))]
            )
            Issue.record("expected verify to fail")
        } catch is SigError {
            // ok
        } catch {
            Issue.record("expected SigError, got \(error)")
        }
    }

    @Test("Ed25519 round-trip with CryptoKit keypair")
    func ed25519RoundTrip() throws {
        #if canImport(CryptoKit)
        let kp = Curve25519.Signing.PrivateKey()
        let pub = [UInt8](kp.publicKey.rawRepresentation)
        let body = #"{"typ":"grok.managed_policy.v1","version":1,"team_id":"team-007","fail_closed":true,"expires_at":4000000000,"key_id":"v1"}"#
        let sig = try kp.signature(for: Data(body.utf8))
        let sigB64 = sig.base64EncodedString()
        let out = try verifySignedPayload(body, signatureB64: sigB64, trustedKeys: [("v1", pub)])
        #expect(out.teamId == "team-007")
        #expect(out.failClosed == true)
        // Tamper
        let tampered = body.replacingOccurrences(of: "team-007", with: "team-evil")
        #expect(throws: SigError.self) {
            _ = try verifySignedPayload(tampered, signatureB64: sigB64, trustedKeys: [("v1", pub)])
        }
        // Pure-Swift path must agree with CryptoKit on the same vector.
        #expect(Ed25519Portable.isValidSignature(sig, for: Data(body.utf8), publicKey: Data(pub)))
        #expect(!Ed25519Portable.isValidSignature(sig, for: Data(tampered.utf8), publicKey: Data(pub)))
        #endif
    }

    @Test("pure-Swift Ed25519 accepts RFC 8032 vectors")
    func ed25519Rfc8032Portable() {
        // SHA-512 empty-message sanity (FIPS vector) — verifier depends on it.
        let emptyHash = SHA512.hash([])
        #expect(emptyHash.map { String(format: "%02x", $0) }.joined()
            == "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e")

        // RFC 8032 Test 1: empty message.
        let pk1 = Data(hex: "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        let sig1 = Data(hex: "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
        #expect(Ed25519Portable.isValidSignature(sig1, for: Data(), publicKey: pk1))
        // Tampered message must fail.
        #expect(!Ed25519Portable.isValidSignature(sig1, for: Data([0x00]), publicKey: pk1))
        // Tampered signature must fail.
        var badSig = [UInt8](sig1)
        badSig[0] ^= 0x01
        #expect(!Ed25519Portable.isValidSignature(Data(badSig), for: Data(), publicKey: pk1))

        // RFC 8032 Test 2: one-byte message 0x72.
        let pk2 = Data(hex: "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")
        let sig2 = Data(hex: "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00")
        #expect(Ed25519Portable.isValidSignature(sig2, for: Data([0x72]), publicKey: pk2))

        // Structural rejects.
        #expect(!Ed25519Portable.isValidSignature(Data([0]), for: Data(), publicKey: pk1))
        #expect(!Ed25519Portable.isValidSignature(sig1, for: Data(), publicKey: Data([0])))
    }

    @Test("checkFetchIdentity binding and expiry")
    func fetchIdentity() throws {
        #if canImport(CryptoKit)
        let kp = Curve25519.Signing.PrivateKey()
        let pub = [UInt8](kp.publicKey.rawRepresentation)
        let body = #"{"typ":"grok.managed_policy.v1","version":1,"team_id":"team-007","fail_closed":false,"expires_at":4000000000,"key_id":"v1"}"#
        let sig = try kp.signature(for: Data(body.utf8))
        let payload = try verifySignedPayload(
            body,
            signatureB64: sig.base64EncodedString(),
            trustedKeys: [("v1", pub)]
        )
        #expect(throws: SigError.self) {
            try checkFetchIdentity(payload: payload, activeTeamId: "team-evil", nowUnix: 1000)
        }
        #expect(throws: SigError.self) {
            try checkFetchIdentity(payload: payload, activeTeamId: "team-007", nowUnix: 4_000_000_001)
        }
        try checkFetchIdentity(payload: payload, activeTeamId: "team-007", nowUnix: 1000)
        try checkFetchIdentity(payload: payload, activeTeamId: nil, nowUnix: 1000)
        #endif
    }

    @Test("sidecar write is owner-only atomic and on-disk match")
    func sidecarWriteAndMatch() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-sig-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let envelope = SignatureEnvelope(
            signedPayload: #"{"typ":"grok.managed_policy.v1"}"#,
            signature: "AAAA",
            keyId: "v1"
        )
        try writeSidecar(tmp, sidecar: envelope)
        let path = tmp.appendingPathComponent(SIGNATURE_SIDECAR_FILE)
        #expect(FileManager.default.fileExists(atPath: path.path))
        #if !os(Windows)
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        if let perms = attrs[.posixPermissions] as? NSNumber {
            #expect((perms.intValue & 0o077) == 0) // owner-only
        }
        #endif
    }
}

// MARK: - Shell

@Suite("Shell")
struct ShellTests {
    @Test("detectUnixShellKind from SHELL")
    func detectShell() {
        #expect(detectUnixShellKind(environment: ["SHELL": "/bin/zsh"]) == .zsh)
        #expect(detectUnixShellKind(environment: ["SHELL": "/bin/bash"]) == .bash)
        #expect(detectUnixShellKind(environment: [:]) == .bash)
    }

    @Test("chainSeparator is platform-appropriate")
    func chainSep() {
        let sep = chainSeparator()
        #expect(sep == "&&" || sep == ";")
    }
}

// MARK: - Atomic write

@Suite("FsAtomic")
struct FsAtomicTests {
    @Test("writeAtomically replaces contents")
    func atomicWrite() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-atomic-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeAtomically(tmp, contents: "one", mode: 0o600)
        #expect(try String(contentsOf: tmp, encoding: .utf8) == "one")
        try writeAtomically(tmp, contents: "two", mode: 0o600)
        #expect(try String(contentsOf: tmp, encoding: .utf8) == "two")
    }
}

// MARK: - envBool re-export

@Suite("envBool")
struct EnvBoolConfigTests {
    @Test("truthy and falsy matrix")
    func matrix() {
        #expect(OpenGrokConfig.envBool("X", environment: ["X": "1"]) == true)
        #expect(OpenGrokConfig.envBool("X", environment: ["X": "true"]) == true)
        #expect(OpenGrokConfig.envBool("X", environment: ["X": "0"]) == false)
        #expect(OpenGrokConfig.envBool("X", environment: ["X": "no"]) == false)
        #expect(OpenGrokConfig.envBool("X", environment: ["X": "maybe"]) == nil)
        #expect(OpenGrokConfig.envBool("X", environment: [:]) == nil)
    }
}

// MARK: - Managed cache wire name

@Suite("Managed cache")
struct ManagedCacheTests {
    @Test("writes canonical managed_config_cache.json and migrates legacy")
    func wireNameAndMigration() throws {
        #expect(MANAGED_CONFIG_CACHE_FILE == "managed_config_cache.json")
        #expect(MANAGED_CONFIG_CACHE_FILE_LEGACY == "managed_config.cache.json")

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-mcache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        // Seed legacy marker only.
        let legacy = home.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE_LEGACY)
        let body = #"{"synced_at":100,"principal":"team-a","had_managed_config":true,"had_requirements":false,"fail_closed":true,"rollback_floor":100}"#
        try body.write(to: legacy, atomically: true, encoding: .utf8)

        // Reading via any public path that loads the marker migrates legacy → canonical.
        // Identity change check reads the marker (and migrates on the way).
        #expect(managedConfigIdentityChangedAt(home, newPrincipal: "team-b", newKeyFingerprint: nil) == true)
        let canonical = home.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE)
        #expect(FileManager.default.fileExists(atPath: canonical.path))
        // Legacy is removed after migration.
        #expect(!FileManager.default.fileExists(atPath: legacy.path))

        // Fresh write always uses the Rust wire name.
        markManagedConfigSyncedAt(home, SyncMarker(
            principal: "team-c",
            hadManagedConfig: true,
            hadRequirements: true,
            keyFingerprint: "fp1",
            failClosed: true
        ))
        #expect(FileManager.default.fileExists(atPath: canonical.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(managedDeploymentIdAt(home, keyFingerprint: "fp1") == "team-c")
        let raw = try String(contentsOf: canonical, encoding: .utf8)
        #expect(raw.contains("synced_at"))
        #expect(raw.contains("key_fingerprint") || raw.contains("fp1"))
    }
}

// MARK: - Authority composition / project config

@Suite("Authority composition")
struct AuthorityCompositionTests {
    @Test("project .opengrok/config.toml merges over user; requirements win")
    func projectAndRequirementsOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-auth-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("proj", isDirectory: true)
        let ogrok = projectDir.appendingPathComponent(".opengrok", isDirectory: true)
        try FileManager.default.createDirectory(at: ogrok, withIntermediateDirectories: true)
        try "a = 10\nb = 10\n".write(
            to: ogrok.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let project = try loadProjectConfig(cwd: projectDir)
        #expect(project["a"]?.int64Value == 10)

        let composition = AuthorityComposition(
            systemManaged: try parseTOML("a = 1\nz = 1"),
            managed: try parseTOML("a = 2"),
            user: try parseTOML("a = 3\nb = 3"),
            project: project,
            environment: try parseTOML("b = 4"),
            cli: try parseTOML("c = 5"),
            userRequirements: try parseTOML("a = 99\nc = 99"),
            systemRequirements: nil,
            mdmRequirements: nil
        )
        let eff = composition.effective()
        // requirements (99) beat project (10) beat user (3) beat managed (2) beat system (1)
        #expect(eff["a"]?.int64Value == 99)
        // env (4) beats project (10) for b, but requirements don't touch b → env wins over project
        #expect(eff["b"]?.int64Value == 4)
        // requirements beat cli for c
        #expect(eff["c"]?.int64Value == 99)
        #expect(eff["z"]?.int64Value == 1)
    }

    @Test("findProjectConfigs excludes user home config and is root-first")
    func findProjectExcludesHome() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-find-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let userHome = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: userHome.appendingPathComponent(".opengrok", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "from = \"home\"\n".write(
            to: userHome.appendingPathComponent(".opengrok/config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let nested = root.appendingPathComponent("repo/sub", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested.appendingPathComponent(".opengrok", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "from = \"project\"\n".write(
            to: nested.appendingPathComponent(".opengrok/config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let found = findProjectConfigs(cwd: nested, stopAt: root, userHome: userHome)
        #expect(found.count == 1)
        #expect(found[0].path.contains("/repo/sub/"))
    }

    @Test("restart-required paths detected")
    func restartRequired() throws {
        let baseline = try parseTOML("[ui]\nscreen_mode = \"full\"\n")
        let updated = try parseTOML("[ui]\nscreen_mode = \"minimal\"\n")
        #expect(restartRequiredChanged(from: baseline, to: updated) == true)
        #expect(restartRequiredChanged(from: baseline, to: baseline) == false)
        let patch = try parseTOMLTable("ui = { code_mode = \"code_mode\" }")
        #expect(touchesRestartRequired(patch) == true)
    }

    /// Pins `RESTART_REQUIRED_PATHS` to the upstream settings registry.
    ///
    /// Upstream carries no path list — `restart_required` is a per-setting
    /// flag and each setting names the config key it writes. Code Mode lives
    /// at `[ui] code_mode`, cited by:
    ///
    /// - `xai-grok-pager/src/settings/defs.rs:1010-1012` — the registry entry
    ///   is commented "SHELL-owned `[ui].code_mode`" and carries
    ///   `restart_required: true`.
    /// - `xai-grok-pager/src/settings/registry.rs:846-847` — the current value
    ///   resolves from `ui.code_mode`.
    /// - `xai-grok-shell/src/util/config/settings_writes.rs:488-490` —
    ///   `set_code_mode` persists `cfg.ui.code_mode`.
    /// - `xai-grok-pager/tests/settings_e2e.rs:537-545` — upstream's own
    ///   contract test asserts `meta.restart_required` for key `code_mode`.
    ///
    /// There is no `[features]` table upstream; an earlier spelling of
    /// `["features", "code_mode"]` here matched nothing on disk, so a
    /// `[ui] code_mode` edit never flagged restart-required.
    @Test("restart-required paths pin the upstream settings registry")
    func restartRequiredPathsPinUpstream() throws {
        #expect(
            RESTART_REQUIRED_PATHS == [
                ["ui", "code_mode"],
                ["ui", "screen_mode"],
                ["cli", "use_leader"],
                ["cli", "worktree_type"],
            ]
        )
        #expect(!RESTART_REQUIRED_PATHS.contains(["features", "code_mode"]))

        // The path must match the table `[ui] code_mode` actually decodes from,
        // so an edit to the real key is detected.
        let before = try parseTOML("[ui]\ncode_mode = \"direct\"\n")
        let after = try parseTOML("[ui]\ncode_mode = \"code_mode_only\"\n")
        #expect(restartRequiredChanged(from: before, to: after) == true)

        // A `[features]` table is not a config surface and must not trigger.
        let features = try parseTOMLTable("features = { code_mode = true }")
        #expect(touchesRestartRequired(features) == false)
    }
}

// MARK: - TOML dotted-key edges

extension TOMLTests {
    @Test("dotted keys and malformed dotted headers")
    func dottedKeys() throws {
        let v = try parseTOML("a.b.c = 1\n[x.y]\nz = 2\n")
        #expect(v["a"]?["b"]?["c"]?.int64Value == 1)
        #expect(v["x"]?["y"]?["z"]?.int64Value == 2)
        #expect(throws: TOMLError.self) {
            _ = try parseTOML("[]\n")
        }
        #expect(throws: TOMLError.self) {
            _ = try parseTOML("[.]\n")
        }
        #expect(throws: TOMLError.self) {
            _ = try parseTOML("= 1\n")
        }
    }
}

// MARK: - Hex Data helper

private extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            bytes.append(UInt8(hex[idx..<next], radix: 16)!)
            idx = next
        }
        self.init(bytes)
    }
}
