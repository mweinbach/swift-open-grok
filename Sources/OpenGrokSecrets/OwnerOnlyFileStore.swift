// OwnerOnlyFileStore.swift
//
// Explicit, documented owner-only file fallback for platforms without a
// system secret service. Callers observe `backend == .ownerOnlyFallback`
// and may also receive `SecretStoreError.ownerOnlyFallbackActive` from the
// platform factory — plaintext fallback is NEVER silent.
//
// Security contract:
//  * Root and lock directories are created/verified as owner-only (0700).
//  * Account filenames are collision-free (SHA-256 of UTF-8 account).
//  * Envelope.account must equal the requested account on read.
//  * Permission checks use no-follow descriptor opens (never chmod a symlink).

import Foundation
import OpenGrokFileUtils

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// JSON envelope persisted under owner-only permissions.
private struct StoredCredentialEnvelope: Codable, Sendable {
    var version: Int
    var account: String
    var secret: String
    var metadata: [String: String]

    init(account: String, secret: String, metadata: [String: String]) {
        self.version = 1
        self.account = account
        self.secret = secret
        self.metadata = metadata
    }
}

/// Owner-only file-backed credential store (explicit fallback).
///
/// Files live under `rootDirectory` with mode `0o600`; the root itself is
/// `0o700`. Concurrent access is serialized by an actor and an advisory lock
/// beside each credential file.
public actor OwnerOnlyFileSecretStore: SecretStore {
    public nonisolated let backend: SecretStoreBackend = .ownerOnlyFallback
    private let root: URL

    public init(rootDirectory: URL) throws {
        // Assign before any throw so stored properties are initialized on all paths.
        self.root = rootDirectory
        #if os(Windows)
        // Without an owner-only DACL adapter this store cannot uphold its
        // security contract on Windows.
        throw SecretStoreError.unsupported(
            "Windows owner-only file store requires DACL adapter; Credential Manager pending"
        )
        #else
        try PathSecurity.rejectHostileLexical(rootDirectory.path)
        try Self.createOwnerOnlyDirectory(at: rootDirectory)
        #endif
    }

    public func read(account: String) async throws -> Credential {
        try Task.checkCancellation()
        let path = fileURL(for: account)
        let data: Data
        do {
            // Verify owner-only via no-follow open (O_NOFOLLOW + fstat/fchmod).
            // Never chmod-then-open through a following stat path.
            if FileManager.default.fileExists(atPath: path.path) {
                try SecureFile.ensureOwnerOnlyPermissions(at: path)
            }
            data = try PathSecurity.readNoFollow(path)
        } catch let err as FileUtilsError {
            if case .notFound = err {
                throw SecretStoreError.notFound(account)
            }
            throw SecretStoreError.accessDenied("credential read failed")
        }
        let env: StoredCredentialEnvelope
        do {
            env = try JSONDecoder().decode(StoredCredentialEnvelope.self, from: data)
        } catch {
            throw SecretStoreError.accessDenied("corrupt credential envelope")
        }
        // Authenticated account field must match the request (collision/mix-up guard).
        guard env.account == account else {
            throw SecretStoreError.accessDenied("credential account mismatch")
        }
        return Credential(account: env.account, secret: env.secret, metadata: env.metadata)
    }

    public func write(_ credential: Credential) async throws {
        try Task.checkCancellation()
        let path = fileURL(for: credential.account)
        let lockPath = lockURL(for: credential.account)
        let lock: AdvisoryLock
        do {
            lock = try AdvisoryFileLock.acquire(at: lockPath)
        } catch {
            throw SecretStoreError.accessDenied("credential lock unavailable")
        }
        defer { lock.release() }

        let env = StoredCredentialEnvelope(
            account: credential.account,
            secret: credential.secret,
            metadata: credential.metadata
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(env)
        } catch {
            throw SecretStoreError.accessDenied("encode failed")
        }
        do {
            try SecureFile.write(at: path, contents: data)
        } catch {
            throw SecretStoreError.accessDenied("persist failed")
        }
    }

    public func delete(account: String) async throws {
        try Task.checkCancellation()
        let path = fileURL(for: account)
        let lockPath = lockURL(for: account)
        let lock = try? AdvisoryFileLock.acquire(at: lockPath)
        defer { lock?.release() }
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw SecretStoreError.notFound(account)
        }
        do {
            try FileManager.default.removeItem(at: path)
        } catch {
            throw SecretStoreError.accessDenied("delete failed")
        }
    }

    /// Enumerate account names only (from envelopes — never secret bodies).
    public func listAccounts() async throws -> [String] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        var accounts: [String] = []
        for url in contents where url.pathExtension == "json" {
            guard let data = try? PathSecurity.readNoFollow(url),
                  let env = try? JSONDecoder().decode(StoredCredentialEnvelope.self, from: data)
            else {
                continue
            }
            accounts.append(env.account)
        }
        return accounts.sorted()
    }

    /// Collision-free filename: SHA-256 hex of UTF-8 account bytes.
    private func fileURL(for account: String) -> URL {
        let digest = FileChecksum.sha256Hex(Data(account.utf8))
        return root.appendingPathComponent("\(digest).json")
    }

    private func lockURL(for account: String) -> URL {
        let digest = FileChecksum.sha256Hex(Data(account.utf8))
        return root.appendingPathComponent("\(digest).lock")
    }

    #if !os(Windows)
    /// Create `url` as an owner-only directory (`0700`), or verify an existing
    /// directory has owner-only bits (tighten if needed).
    private static func createOwnerOnlyDirectory(at url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw SecretStoreError.accessDenied("secret root is not a directory")
            }
        } else {
            try fm.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        var st = stat()
        let rc = url.path.withCString { lstat($0, &st) }
        if rc != 0 {
            throw SecretStoreError.accessDenied("secret root lstat failed")
        }
        if (st.st_mode & S_IFMT) == S_IFLNK {
            throw SecretStoreError.accessDenied("secret root must not be a symlink")
        }
        let mode = st.st_mode & 0o777
        if mode != 0o700 {
            let crc = url.path.withCString { chmod($0, 0o700) }
            if crc != 0 {
                throw SecretStoreError.accessDenied("secret root chmod 0700 failed")
            }
        }
    }
    #endif
}
