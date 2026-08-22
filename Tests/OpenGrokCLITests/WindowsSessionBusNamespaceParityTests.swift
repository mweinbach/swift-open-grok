import OpenGrokHTTP
import Testing

@Suite("Windows IPC namespace Rust path-hash parity")
struct WindowsSessionBusNamespaceParityTests {
    @Test("Verbatim Windows prefixes retain their exact Rust path semantics")
    func verbatimPathGoldenVectors() {
        let vectors: [(String, String)] = [
            (#"\\?\C:\session-bus\.\p42.sock"#, "0aada76c2ac32a99"),
            (#"\\?\c:\session-bus\.\p42.sock"#, "0aada76c2ac32a99"),
            (#"\\?\C:\session-bus\p42.sock"#, "673bade6ce883da6"),
            (#"\\?\C:/session-bus/p42.sock"#, "4e017c6c42b430a8"),
            (#"\\?\UNC\server\share\p42.sock"#, "5674b5a4a638db97"),
            (#"\\?\UNC/server\share\p42.sock"#, "5674b5a4a638db97"),
            (#"\\?\UNC\server/share\p42.sock"#, "b468266461819175"),
            (#"\\?\Volume{abc}\session\p42.sock"#, "d3aa96ab22c4590c"),
            (#"//?/C:/session-bus/p42.sock"#, "cd55c5bde49e1ec0"),
        ]

        for (path, expectedHash) in vectors {
            #expect(
                WindowsNamedPipeName.leafName(forPath: path, namespace: .sessionBus)
                    == "grok-sbus-\(expectedHash)",
                "Rust Windows prefix mismatch for \(path)"
            )
        }
    }

    @Test("Device, UNC, drive, root, relative, and Unicode paths match Rust")
    func remainingPrefixGoldenVectors() {
        let vectors: [(String, String)] = [
            (#"\\.\pipe\grok.sock"#, "a1e6d6f93799190a"),
            (#"//./pipe/grok.sock"#, "a1e6d6f93799190a"),
            (#"\\server\\share\p42.sock"#, "30a5cbbaedf3e968"),
            (#"\\server\share\.\p42.sock"#, "4d745ad05f23fe90"),
            (#"C:relative\session.sock"#, "c8db1ad3ee372701"),
            (#"C:\relative\session.sock"#, "c8db1ad3ee372701"),
            (#".\session-bus\p42.sock"#, "1a2a1268900185ff"),
            (#"session-bus\p42.sock"#, "8ae6f58a44e4a0b8"),
            (#"session-bus\..\p42.sock"#, "db4cb57d41e6efaa"),
            (#"session-bus\p42.sock\"#, "8ae6f58a44e4a0b8"),
            (#"session-bus\.\p42.sock"#, "8ae6f58a44e4a0b8"),
            (#"\session-bus\p42.sock"#, "8ae6f58a44e4a0b8"),
            (#"/session-bus/p42.sock"#, "8ae6f58a44e4a0b8"),
            (#"C:\δοκιμή\会話.sock"#, "86f0f1b165214fc6"),
            ("", "99ca5097b5dfbb72"),
            (".", "853f8640179a2e64"),
            (#"\"#, "99ca5097b5dfbb72"),
            (#"C:"#, "857da2ea54401510"),
            (#"C:\"#, "857da2ea54401510"),
        ]

        for (path, expectedHash) in vectors {
            #expect(
                WindowsNamedPipeName.fullName(forPath: path, namespace: .sessionBus)
                    == #"\\.\pipe\grok-sbus-"# + expectedHash,
                "Rust Windows path mismatch for \(path)"
            )
        }
    }

    @Test("Leader and session-bus namespaces preserve the same Rust path hash")
    func namespacesRemainDistinct() {
        let path = #"\\?\UNC\server\share\p42.sock"#
        #expect(
            WindowsNamedPipeName.fullName(forPath: path, namespace: .leader)
                == #"\\.\pipe\grok-leader-5674b5a4a638db97"#
        )
        #expect(
            WindowsNamedPipeName.fullName(forPath: path, namespace: .sessionBus)
                == #"\\.\pipe\grok-sbus-5674b5a4a638db97"#
        )
    }
}
