import Foundation
import Testing
@testable import OpenGrokConfig

#if os(Windows)
import COpenGrokSockets

@Suite("Windows native owner-private directory path ancestry")
struct WindowsOwnerDirectoryPathTests {
    @Test("native drive ancestry never visits Foundation's synthetic slash root")
    func driveAncestryStopsAtNativeVolumeRoot() throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-native-ancestry")
            .appendingPathComponent("nested-state")

        let ancestry = try windowsOwnerDirectoryNativeAncestry(target)

        let volumeRoot = try #require(ancestry.first)
        let volumeBytes = Array(volumeRoot.dropFirst("\\\\?\\".count).utf8)
        #expect(volumeBytes.count == 3)
        #expect(volumeBytes[1] == 58)
        #expect(volumeBytes[2] == 92)
        #expect(ancestry.allSatisfy { $0 != "/" && $0.hasPrefix("\\\\?\\") })
        let finalPath = try #require(ancestry.last)
        #expect(finalPath.hasSuffix("\\nested-state"))
    }

    @Test("native state and session chains remain owner-private without crossing volume root")
    func nativeStateChainRetainsPrivateBoundaries() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-native-ancestry-\(UUID().uuidString)")
        let state = fixture.appendingPathComponent("owner/.opengrok")
        let session = state.appendingPathComponent("sessions/workspace/session")
        defer { try? FileManager.default.removeItem(at: fixture) }

        try createDirAllOwnerOnly(session, stateRoot: state)

        for directory in [state, state.appendingPathComponent("sessions"), session] {
            #expect(directory.path.withCString {
                og_path_is_private_to_current_user($0, 1)
            } == 1)
        }
    }

    @Test("synthetic slash roots remain invalid and never become application state")
    func syntheticSlashFailsClosed() {
        let synthetic = URL(fileURLWithPath: "/", isDirectory: true)

        #expect(throws: (any Error).self) {
            try createDirAllOwnerOnly(synthetic, stateRoot: synthetic)
        }
    }
}
#endif
