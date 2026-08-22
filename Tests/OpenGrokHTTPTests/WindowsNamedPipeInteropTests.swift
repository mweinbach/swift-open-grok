import Testing
@testable import OpenGrokHTTP

@Suite("Rust-compatible Windows local IPC pipe names")
struct WindowsNamedPipeInteropTests {
    @Test("leader and session-bus namespaces share Rust's path digest")
    func independentNamespaces() {
        let path = #"C:\Users\me\.grok\leader.sock"#

        #expect(WindowsNamedPipeName.leafName(forPath: path)
            == "grok-leader-b1ee14cfc418ef29")
        #expect(WindowsNamedPipeName.fullName(forPath: path)
            == #"\\.\pipe\grok-leader-b1ee14cfc418ef29"#)
        #expect(WindowsNamedPipeName.fullName(forPath: path, namespace: .leader)
            == #"\\.\pipe\grok-leader-b1ee14cfc418ef29"#)
        #expect(WindowsNamedPipeName.leafName(forPath: path, namespace: .sessionBus)
            == "grok-sbus-b1ee14cfc418ef29")
        #expect(WindowsNamedPipeName.pipePath(for: path, namespace: .sessionBus)
            == #"\\.\pipe\grok-sbus-b1ee14cfc418ef29"#)
        #expect(WindowsNamedPipeName.pipePath(for: path)
            == #"\\.\pipe\grok-leader-b1ee14cfc418ef29"#)
    }

    @Test("drive case, duplicate separators, and interior current-directory components normalize")
    func driveAndSeparatorNormalization() {
        let canonical = #"C:\Users\me\.grok\leader.sock"#
        let normalized = #"c:/Users//me/./.grok/leader.sock"#

        #expect(WindowsNamedPipeName.fullName(forPath: canonical)
            == #"\\.\pipe\grok-leader-b1ee14cfc418ef29"#)
        #expect(WindowsNamedPipeName.fullName(forPath: normalized)
            == #"\\.\pipe\grok-leader-b1ee14cfc418ef29"#)
    }

    @Test("filename components preserve case even though drive letters do not")
    func componentCaseSensitivity() {
        #expect(WindowsNamedPipeName.leafName(
            forPath: #"C:\Users\me\.grok\leader.sock"#
        ) == "grok-leader-b1ee14cfc418ef29")
        #expect(WindowsNamedPipeName.leafName(
            forPath: #"C:\USERS\me\.grok\leader.sock"#
        ) == "grok-leader-ea446ea4553622f0")
    }

    @Test("live session-bus filesystem paths match independent Rust golden vectors")
    func sessionBusGoldenVectors() {
        let vectors: [(String, String)] = [
            (
                #"C:\Users\me\.opengrok\session-bus\p42-deadbeef.sock"#,
                "8579e5da79e6a016"
            ),
            (
                #"D:\repo\session-bus\p1234-abcdef12.sock"#,
                "8ff30c6f5895e2ba"
            ),
            (
                #"\\server\share\session-bus\p42-deadbeef.sock"#,
                "07f5d797c68fd022"
            ),
            (
                #"session-bus\p42-deadbeef.sock"#,
                "5965cb4f3ac97468"
            ),
        ]

        for (path, digest) in vectors {
            #expect(WindowsNamedPipeName.fullName(forPath: path, namespace: .sessionBus)
                == #"\\.\pipe\grok-sbus-"# + digest)
            #expect(WindowsNamedPipeName.fullName(forPath: path, namespace: .leader)
                == #"\\.\pipe\grok-leader-"# + digest)
        }
    }

    @Test("root-only paths retain Rust's intentional component-hash collisions")
    func rootAndDriveGoldenVectors() {
        for path in ["", "/", "\\"] {
            #expect(WindowsNamedPipeName.leafName(forPath: path)
                == "grok-leader-99ca5097b5dfbb72")
        }

        for path in [#"C:\"#, "c:/", "C:"] {
            #expect(WindowsNamedPipeName.leafName(forPath: path)
                == "grok-leader-857da2ea54401510")
        }
    }

    @Test("UNC prefixes hash typed server/share components and reject empty shares")
    func uncPrefixSemantics() {
        #expect(WindowsNamedPipeName.leafName(
            forPath: #"\\server\share\session-bus\p42-deadbeef.sock"#
        ) == "grok-leader-07f5d797c68fd022")
        #expect(WindowsNamedPipeName.leafName(
            forPath: #"\\server\\share\session.sock"#
        ) == "grok-leader-1f4d0c4aeffaac04")
    }

    @Test("verbatim drives preserve forward slashes and require an exact drive prefix")
    func verbatimDiskSemantics() {
        #expect(WindowsNamedPipeName.leafName(
            forPath: #"\\?\c:\Users\me\.opengrok\leader.sock"#
        ) == "grok-leader-352049f9117285f9")
        #expect(WindowsNamedPipeName.leafName(
            forPath: #"\\?\C:\Users/me\.opengrok\leader.sock"#
        ) == "grok-leader-cf8ad42064ee7fe6")
        #expect(WindowsNamedPipeName.leafName(
            forPath: #"\\?\C:not-a-disk\session.sock"#
        ) == "grok-leader-54ad5e814fa87433")
    }

    @Test("verbatim UNC, device, and mixed-slash pseudo-verbatim prefixes remain distinct")
    func extendedWindowsPrefixes() {
        #expect(WindowsNamedPipeName.leafName(
            forPath: #"\\?\UNC\server\share\session-bus\p42-deadbeef.sock"#
        ) == "grok-leader-2ef857b374c0ba82")
        #expect(WindowsNamedPipeName.leafName(
            forPath: #"\\?\UNC\\share\socket.sock"#
        ) == "grok-leader-17efe8cce9c0f9c5")
        #expect(WindowsNamedPipeName.leafName(
            forPath: #"\\.\COM42\session.sock"#
        ) == "grok-leader-4b1023b313abdee7")
        #expect(WindowsNamedPipeName.leafName(
            forPath: #"//?/C:/Users/me/.grok/leader.sock"#
        ) == "grok-leader-fa46e55556ac4be8")
    }

    @Test("relative parents and Unicode filenames hash their exact encoded components")
    func relativeAndUnicodeGoldenVectors() {
        #expect(WindowsNamedPipeName.leafName(
            forPath: #".\folder\..\socket.sock"#
        ) == "grok-leader-e51305078b456744")
        #expect(WindowsNamedPipeName.leafName(
            forPath: #"C:\Users\José\💡.sock"#
        ) == "grok-leader-1b688d84a648798b")
    }

    @Test("rotated component lengths prevent equal-byte segmentation collisions")
    func componentBoundaryMetadata() {
        let first = WindowsNamedPipeName.leafName(forPath: #"C:\ab\c.sock"#)
        let second = WindowsNamedPipeName.leafName(forPath: #"C:\a\bc.sock"#)

        #expect(first != second)
    }
}
