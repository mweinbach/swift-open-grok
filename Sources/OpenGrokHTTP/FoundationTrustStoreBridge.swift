import Foundation

#if os(Linux)
import Glibc
#endif

public enum FoundationTrustStoreBridge {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var systemBundle: Data?
        var extraRoots: Set<Data> = []
        var generatedBundlePath: String?
    }

    private static let state = State()

    public static var supportsAdditionalTrustRoots: Bool {
        #if os(Linux)
        return systemBundleURL(environment: ProcessInfo.processInfo.environment) != nil
        #else
        return false
        #endif
    }

    @discardableResult
    public static func prepare(extraRootCertificates: [Data]) -> Bool {
        guard !extraRootCertificates.isEmpty else { return true }
        #if os(Linux)
        state.lock.lock()
        defer { state.lock.unlock() }

        if state.systemBundle == nil {
            guard let source = systemBundleURL(environment: ProcessInfo.processInfo.environment),
                  let data = try? Data(contentsOf: source),
                  !data.isEmpty
            else { return false }
            state.systemBundle = data
        }

        state.extraRoots.formUnion(extraRootCertificates)
        guard let systemBundle = state.systemBundle else { return false }
        let bundle = combinedPEMBundle(
            systemPEM: systemBundle,
            extraRootCertificates: Array(state.extraRoots)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent(
                "foundation-ca-\(ProcessInfo.processInfo.processIdentifier).pem"
            )
            try bundle.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            guard setenv("CURL_CA_BUNDLE", url.path, 1) == 0,
                  setenv("SSL_CERT_FILE", url.path, 1) == 0
            else { return false }
            state.generatedBundlePath = url.path
            return true
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    public static func combinedPEMBundle(
        systemPEM: Data,
        extraRootCertificates: [Data]
    ) -> Data {
        var result = systemPEM
        if !result.isEmpty, result.last != 0x0A {
            result.append(0x0A)
        }
        for certificate in extraRootCertificates {
            result.append(Data("-----BEGIN CERTIFICATE-----\n".utf8))
            let encoded = certificate.base64EncodedString(
                options: [.lineLength64Characters, .endLineWithLineFeed]
            )
            result.append(Data(encoded.utf8))
            if result.last != 0x0A { result.append(0x0A) }
            result.append(Data("-----END CERTIFICATE-----\n".utf8))
        }
        return result
    }

    static func systemBundleURL(environment: [String: String]) -> URL? {
        let configured = [environment["CURL_CA_BUNDLE"], environment["SSL_CERT_FILE"]]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        let defaults = [
            "/etc/ssl/certs/ca-certificates.crt",
            "/etc/pki/tls/certs/ca-bundle.crt",
            "/etc/ssl/ca-bundle.pem",
            "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
        ]
        for path in configured + defaults where FileManager.default.isReadableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
