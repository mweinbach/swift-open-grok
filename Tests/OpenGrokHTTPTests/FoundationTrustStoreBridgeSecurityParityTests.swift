import Foundation
import Testing
@testable import OpenGrokHTTP

@Suite("Foundation trust-store bridge security parity", .serialized)
struct FoundationTrustStoreBridgeSecurityParityTests {
    @Test("empty trust configuration succeeds without changing trust environment")
    func emptyRootsDoNotMutateTrustEnvironment() {
        let originalEnvironment = trustEnvironment()

        #expect(FoundationTrustStoreBridge.prepare(extraRootCertificates: []))
        #expect(trustEnvironment() == originalEnvironment)
    }

    #if os(Linux)
    @Test("Linux reports session-local custom trust as unavailable")
    func linuxCustomRootsFailClosed() {
        let originalEnvironment = trustEnvironment()
        let certificate = Data([0x30, 0x03, 0x02, 0x01, 0x01])

        #expect(!FoundationTrustStoreBridge.supportsAdditionalTrustRoots)
        #expect(!HTTPTransportSessionDelegate.supportsAdditionalTrustRoots)
        #expect(!FoundationTrustStoreBridge.prepare(extraRootCertificates: [certificate]))

        let delegate = HTTPTransportSessionDelegate(
            validateCertificates: true,
            extraRootCertificates: [certificate]
        )
        #expect(!delegate.additionalTrustRootsApplied)
        #expect(delegate.additionalTrustRootsUnavailable)
        #expect(delegate.validateCertificates)
        #expect(trustEnvironment() == originalEnvironment)
    }

    @Test("custom roots never create or replace the predictable shared PEM")
    func linuxDoesNotCreatePredictableSharedBundle() throws {
        let sharedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok", isDirectory: true)
        let predictableBundle = sharedDirectory.appendingPathComponent(
            "foundation-ca-\(ProcessInfo.processInfo.processIdentifier).pem"
        )
        let originalDirectory = pathSnapshot(sharedDirectory)
        let originalBundle = pathSnapshot(predictableBundle)
        let originalEnvironment = trustEnvironment()

        #expect(!FoundationTrustStoreBridge.prepare(
            extraRootCertificates: [Data([0x30, 0x00])]
        ))

        #expect(pathSnapshot(sharedDirectory) == originalDirectory)
        #expect(pathSnapshot(predictableBundle) == originalBundle)
        #expect(trustEnvironment() == originalEnvironment)
    }

    @Test("precreated world-writable directories and PEM symlinks remain untouched")
    func linuxDoesNotFollowHostileBundleSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-hostile-ca-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let hostileDirectory = root.appendingPathComponent("open-grok", isDirectory: true)
        try FileManager.default.createDirectory(
            at: hostileDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: hostileDirectory.path
        )

        let protectedTarget = root.appendingPathComponent("protected-target.pem")
        let originalContents = Data("attacker-controlled target must remain unchanged".utf8)
        try originalContents.write(to: protectedTarget)

        let predictableBundle = hostileDirectory.appendingPathComponent(
            "foundation-ca-\(ProcessInfo.processInfo.processIdentifier).pem"
        )
        try FileManager.default.createSymbolicLink(
            at: predictableBundle,
            withDestinationURL: protectedTarget
        )

        let originalDirectory = pathSnapshot(hostileDirectory)
        let originalBundle = pathSnapshot(predictableBundle)
        let originalDestination = try FileManager.default.destinationOfSymbolicLink(
            atPath: predictableBundle.path
        )
        let originalEnvironment = trustEnvironment()

        #expect(!FoundationTrustStoreBridge.prepare(
            extraRootCertificates: [Data([0x30, 0x00])]
        ))

        #expect(pathSnapshot(hostileDirectory) == originalDirectory)
        #expect(pathSnapshot(predictableBundle) == originalBundle)
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: predictableBundle.path
        ) == originalDestination)
        #expect(try Data(contentsOf: protectedTarget) == originalContents)
        #expect(trustEnvironment() == originalEnvironment)
    }

    @Test("repeated custom-root requests cannot accumulate process-wide trust")
    func linuxRepeatedRootsRemainIsolated() {
        let originalEnvironment = trustEnvironment()

        for byte in UInt8.min...15 {
            #expect(!FoundationTrustStoreBridge.prepare(
                extraRootCertificates: [Data([0x30, 0x01, byte])]
            ))
        }

        #expect(trustEnvironment() == originalEnvironment)
    }
    #elseif canImport(Darwin) && canImport(Security)
    @Test("Darwin continues installing additional roots on its session delegate")
    func darwinSessionLocalTrustRemainsAvailable() {
        let originalEnvironment = trustEnvironment()
        let delegate = HTTPTransportSessionDelegate(
            validateCertificates: true,
            extraRootCertificates: [Data([0x30, 0x00])]
        )

        #expect(HTTPTransportSessionDelegate.supportsAdditionalTrustRoots)
        #expect(delegate.additionalTrustRootsApplied)
        #expect(!delegate.additionalTrustRootsUnavailable)
        #expect(trustEnvironment() == originalEnvironment)
    }
    #endif

    private func trustEnvironment() -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        return environment.filter {
            $0.key == "CURL_CA_BUNDLE" || $0.key == "SSL_CERT_FILE"
        }
    }

    #if os(Linux)
    private func pathSnapshot(_ url: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ) else {
            return "absent"
        }

        let type = (attributes[.type] as? FileAttributeType)?.rawValue ?? "unknown"
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return "\(type):\(inode):\(mode):\(size)"
    }
    #endif
}
