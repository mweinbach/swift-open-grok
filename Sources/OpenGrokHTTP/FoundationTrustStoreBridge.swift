import Foundation

public enum FoundationTrustStoreBridge {
    public static var supportsAdditionalTrustRoots: Bool {
        false
    }

    @discardableResult
    public static func prepare(extraRootCertificates: [Data]) -> Bool {
        guard !extraRootCertificates.isEmpty else { return true }

        // Linux FoundationNetworking cannot install session-local trust anchors.
        // Environment-backed bundles would also trust these roots in unrelated
        // clients and inherited subprocesses, so preserve strict system trust.
        return false
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
