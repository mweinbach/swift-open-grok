import Foundation
import Testing
@testable import OpenGrokSandbox

@Suite("sandbox deny profile enforcement")
struct SandboxDenyFoundationTests {
    @Test(
        "malformed and traversable deny patterns prevent custom profile resolution",
        arguments: [
            "../secrets/**",
            "./secrets/**",
            "secrets//*.pem",
            "secrets/**/",
            "secrets/a**b",
            "secrets/*.{pem,key}",
            "secrets/[unterminated",
        ]
    )
    func invalidDenyPatternsFailClosed(pattern: String) {
        let configuration = SandboxConfig(profiles: [
            "guarded": ProfileConfig(extends: "workspace", deny: [pattern]),
        ])

        #expect(throws: SandboxError.self) {
            try ProfileName.custom("guarded").resolve(
                workspace: URL(fileURLWithPath: "/workspace"),
                config: configuration
            )
        }
    }

    @Test("valid deny character classes remain glob restrictions")
    func characterClassDeniesRemainGlobs() throws {
        let configuration = SandboxConfig(profiles: [
            "guarded": ProfileConfig(extends: "workspace", deny: ["secrets/[a-c].pem"]),
        ])

        let resolved = try ProfileName.custom("guarded").resolve(
            workspace: URL(fileURLWithPath: "/workspace"),
            config: configuration
        )

        #expect(resolved.denyEntries == ["secrets/[a-c].pem"])
        #expect(resolved.deny.isEmpty)

        let regex = try NSRegularExpression(pattern: "^\(globTailToRegex("[a-c].pem"))$")
        func matches(_ value: String) -> Bool {
            regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }

        #expect(matches("a.pem"))
        #expect(matches("b.pem"))
        #expect(matches("c.pem"))
        #expect(matches("z.pem") == false)
        #expect(matches("-.pem") == false)
    }
}
