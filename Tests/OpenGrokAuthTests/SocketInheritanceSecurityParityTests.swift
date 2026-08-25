import COpenGrokSockets
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

@Suite("Socket descriptor and handle inheritance security", .serialized)
struct SocketInheritanceSecurityParityTests {
    @Test("TCP listeners, connected clients, and accepted peers cannot enter spawned children")
    func tcpSocketsNeverInherit() throws {
        var listener: OGSocketHandle = -1
        var port: UInt16 = 0
        let listenStatus = "127.0.0.1".withCString {
            og_socket_tcp_listen($0, 0, &listener, &port)
        }
        #expect(listenStatus == 0)
        guard listenStatus == 0 else { return }
        defer { #expect(og_socket_close(listener) == 0) }
        #expect(port != 0)
        try assertNonInheritable(listener)

        var client: OGSocketHandle = -1
        let connectStatus = "127.0.0.1".withCString {
            og_socket_tcp_connect($0, port, 5, &client)
        }
        #expect(connectStatus == 0)
        guard connectStatus == 0 else { return }
        defer { #expect(og_socket_close(client) == 0) }
        try assertNonInheritable(client)

        var accepted: OGSocketHandle = -1
        let acceptStatus = og_socket_accept(listener, &accepted)
        #expect(acceptStatus == 0)
        guard acceptStatus == 0 else { return }
        defer { #expect(og_socket_close(accepted) == 0) }
        try assertNonInheritable(accepted)
    }

    #if !os(Windows)
    @Test("Unix-domain listeners, connected clients, and accepted peers are close-on-exec")
    func unixSocketsNeverInherit() throws {
        let path = "/tmp/ogsk-\(UUID().uuidString).sock"

        var listener: OGSocketHandle = -1
        let listenStatus = path.withCString { og_socket_unix_listen($0, &listener) }
        #expect(listenStatus == 0)
        guard listenStatus == 0 else { return }
        defer { #expect(path.withCString { unlink($0) } == 0) }
        defer { #expect(og_socket_close(listener) == 0) }
        try assertNonInheritable(listener)

        var client: OGSocketHandle = -1
        let connectStatus = path.withCString { og_socket_unix_connect($0, 5, &client) }
        #expect(connectStatus == 0)
        guard connectStatus == 0 else { return }
        defer { #expect(og_socket_close(client) == 0) }
        try assertNonInheritable(client)

        var accepted: OGSocketHandle = -1
        let acceptStatus = og_socket_accept(listener, &accepted)
        #expect(acceptStatus == 0)
        guard acceptStatus == 0 else { return }
        defer { #expect(og_socket_close(accepted) == 0) }
        try assertNonInheritable(accepted)
    }
    #endif

    private func assertNonInheritable(_ handle: OGSocketHandle) throws {
        #if os(Windows)
        let nativeHandle = try #require(HANDLE(bitPattern: Int(handle)))
        var flags: DWORD = 0
        #expect(GetHandleInformation(nativeHandle, &flags))
        #expect(flags & DWORD(HANDLE_FLAG_INHERIT) == 0)
        #else
        let flags = fcntl(Int32(handle), F_GETFD)
        #expect(flags >= 0)
        #expect(flags & FD_CLOEXEC != 0)
        #endif
    }
}
