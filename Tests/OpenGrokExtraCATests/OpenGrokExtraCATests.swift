import Foundation
import Testing
@testable import OpenGrokExtraCA

private let validCertificatePEM = """
-----BEGIN CERTIFICATE-----
MIIDFTCCAf2gAwIBAgIUT2czXTuxSAjDjEh92UMB1OVahZYwDQYJKoZIhvcNAQEL
BQAwGjEYMBYGA1UEAwwPdGVzdC1leHRyYS1jYS0xMB4XDTI2MDcyOTE4MzUwNFoX
DTM2MDcyNjE4MzUwNFowGjEYMBYGA1UEAwwPdGVzdC1leHRyYS1jYS0xMIIBIjAN
BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA1gNk2BQwUy+n5cCaTFtGpSzVQv//
d7QD+3QWeE411wIGJzp3nrd7np55X8JHxeg/pRhspQvLQAF7bt55LSkL/+sSth3S
QTbBqhftic9CXik3llAwbdQkAM9srz5zXWW9KVjZ57dxjjxrS15SCXu/UmvGZy98
faJcS++TRkczsNFzwQEqeDYARVc/no0C0I++NhGLPaNMfFAevvnu6Kt3CYMI5ls4
KCFgnlau4CjgRCMSfRDCRcwEwUAp+DyX9IU+tvDAQY1ncVoa/05tvaEvw7pQ+UgW
0wRG0lk7PLlcWmUkLcFpO+sL5GRkC8RoWM4cFbIOiXoVxUFks/z2y0GCEQIDAQAB
o1MwUTAdBgNVHQ4EFgQU+lyC70W5aR6BIf4VNtjfiWMNzzkwHwYDVR0jBBgwFoAU
+lyC70W5aR6BIf4VNtjfiWMNzzkwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0B
AQsFAAOCAQEA02972nA7LshRgubz6BwXbh1gA5pLzTd5KEae+94Hq6mP2zJ1T0gk
x+me0NtSgG4BJLdBIylUzo2UmsfB/sz+ght6WX1uB38Vc2UQsp0sRPeeiMovSd6n
I7xZyuZEF3noYJVBBlKQ8XsCUIBNIROlyKlNjNcWY8tGqPh9cepvtZYkBgRZr1vW
hJAE3EOL2ZddrMPF64QeU9UhvCm0Ch+Ceqa1ZWE0MygccggX5s2yQwtXO2ovJdjH
6vW0I02r8sE+NX0d1u8rIPJEKlp89UwCwniD7SxHTNw8bbsTCWz+AMod7vC7De3X
4Daxme+vD8adOfCeOIu5vNrlXLNST2yaTw==
-----END CERTIFICATE-----
"""

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func quietLogger() -> ExtraCALogger {
    ExtraCALogger { _, _ in }
}

@Suite("OpenGrokExtraCA loader")
struct OpenGrokExtraCATests {
    @Test func unsetEnvironmentDoesNotRead() {
        let reads = ReadCounter()
        let loader = OpenGrokExtraCALoader(
            environment: { nil },
            readFile: { _ in
                reads.increment()
                return Data()
            },
            logger: quietLogger()
        )
        #expect(loader.load().isEmpty)
        #expect(reads.count == 0)
    }

    @Test func emptyEnvironmentDoesNotRead() {
        let reads = ReadCounter()
        let loader = OpenGrokExtraCALoader(
            environment: { "" },
            readFile: { _ in
                reads.increment()
                return Data()
            },
            logger: quietLogger()
        )
        #expect(loader.load().isEmpty)
        #expect(reads.count == 0)
    }

    @Test func parsesOneAndMultipleValidPEMBlocks() {
        let one = OpenGrokExtraCA.parsePEM(Data(validCertificatePEM.utf8))
        #expect(one.certificates.count == 1)
        #expect(one.rejectedBlockCount == 0)
        #expect(one.foundCertificateBlock)

        let two = OpenGrokExtraCA.parsePEM(
            Data((validCertificatePEM + "\n" + validCertificatePEM).utf8)
        )
        #expect(two.certificates.count == 2)
        #expect(two.rejectedBlockCount == 0)
    }

    @Test func mixedBundleKeepsValidAndDropsInvalid() {
        let invalid = """
        -----BEGIN CERTIFICATE-----
        MAMBAf8=
        -----END CERTIFICATE-----
        """
        let result = OpenGrokExtraCA.parsePEM(
            Data((validCertificatePEM + "\n" + invalid + "\n" + validCertificatePEM).utf8)
        )
        #expect(result.certificates.count == 2)
        #expect(result.rejectedBlockCount == 1)
    }

    @Test func nonPEMInputProducesNoRoots() {
        let result = OpenGrokExtraCA.parsePEM(Data("not a certificate".utf8))
        #expect(result.certificates.isEmpty)
        #expect(result.rejectedBlockCount == 0)
        #expect(!result.foundCertificateBlock)
    }

    @Test func unreadablePathWarnsAndContinues() {
        let loader = OpenGrokExtraCALoader(
            environment: { "/private/missing/extra-ca.pem" },
            readFile: { _ in throw ExtraCAFileError.unreadable("missing") },
            logger: quietLogger()
        )
        #expect(loader.load().isEmpty)
    }

    @Test func exactLimitIsAcceptedAndLimitPlusOneIsRejected() {
        let atLimit = OpenGrokExtraCALoader(
            environment: { "/tmp/exact-limit.pem" },
            readFile: { _ in Data(repeating: 0x41, count: openGrokExtraCAMaxBundleBytes) },
            logger: quietLogger()
        )
        #expect(atLimit.load().isEmpty)

        let overLimit = OpenGrokExtraCALoader(
            environment: { "/tmp/over-limit.pem" },
            readFile: { _ in Data(repeating: 0x41, count: openGrokExtraCAMaxBundleBytes + 1) },
            logger: quietLogger()
        )
        #expect(overLimit.load().isEmpty)
    }
}
