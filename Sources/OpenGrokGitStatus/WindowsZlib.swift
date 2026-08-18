#if os(Windows)
import COpenGrokZlib
import Foundation

private let windowsZlibOK: Int32 = 0
private let windowsZlibBufferError: Int32 = -5
private let windowsZlibDefaultCompression: Int32 = -1

private enum WindowsZlibFailure: Error {
    case unavailable
    case status(Int32)
    case outputLimit
}

func inflateZlibWindows(_ data: Data) throws -> Data {
    do {
        return try windowsZlibInflate(
            data,
            initialCapacity: max(data.count * 4, 4096),
            mayGrow: true
        )
    } catch WindowsZlibFailure.unavailable {
        throw GitStatusError.io("zlib1.dll unavailable on Windows")
    } catch WindowsZlibFailure.status(let status) {
        throw GitStatusError.io("zlib inflate failed: \(status)")
    } catch WindowsZlibFailure.outputLimit {
        throw GitStatusError.io("zlib inflate exceeded output limit")
    }
}

func inflatePackedZlibWindows(
    _ data: Data,
    expectedSize: Int,
    packPath: String
) throws -> Data {
    do {
        let output = try windowsZlibInflate(
            data,
            initialCapacity: max(expectedSize, 1),
            mayGrow: false
        )
        guard output.count == expectedSize else {
            throw GitStatusError.corruptPack(
                path: packPath,
                reason: "inflated object size mismatch"
            )
        }
        return output
    } catch let error as GitStatusError {
        throw error
    } catch WindowsZlibFailure.unavailable {
        throw GitStatusError.corruptPack(
            path: packPath,
            reason: "zlib1.dll unavailable on Windows"
        )
    } catch WindowsZlibFailure.status {
        throw GitStatusError.corruptPack(
            path: packPath,
            reason: "invalid or truncated zlib stream"
        )
    } catch WindowsZlibFailure.outputLimit {
        throw GitStatusError.corruptPack(
            path: packPath,
            reason: "inflated object exceeds declared size"
        )
    }
}

func deflateZlibWindows(_ data: Data) throws -> Data {
    guard open_grok_zlib_is_available() != 0 else {
        throw GitStatusError.io("zlib1.dll unavailable on Windows")
    }
    let capacity = Int(open_grok_zlib_compress_bound(data.count))
    guard capacity > 0 else {
        throw GitStatusError.io("zlib compress bound unavailable")
    }
    var output = Data(count: capacity)
    var outputLength = capacity
    let status = output.withUnsafeMutableBytes { destination in
        data.withUnsafeBytes { source in
            open_grok_zlib_compress(
                destination.bindMemory(to: UInt8.self).baseAddress,
                &outputLength,
                source.bindMemory(to: UInt8.self).baseAddress,
                data.count,
                windowsZlibDefaultCompression
            )
        }
    }
    guard status == windowsZlibOK else {
        throw GitStatusError.io("zlib deflate failed: \(status)")
    }
    output.count = outputLength
    return output
}

private func windowsZlibInflate(
    _ data: Data,
    initialCapacity: Int,
    mayGrow: Bool
) throws -> Data {
    guard open_grok_zlib_is_available() != 0 else {
        throw WindowsZlibFailure.unavailable
    }
    var capacity = max(initialCapacity, 1)
    for _ in 0..<16 {
        var output = Data(count: capacity)
        var outputLength = capacity
        let status = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                open_grok_zlib_uncompress(
                    destination.bindMemory(to: UInt8.self).baseAddress,
                    &outputLength,
                    source.bindMemory(to: UInt8.self).baseAddress,
                    data.count
                )
            }
        }
        if status == windowsZlibOK {
            output.count = outputLength
            return output
        }
        guard status == windowsZlibBufferError, mayGrow,
              capacity <= Int.max / 2 else {
            throw WindowsZlibFailure.status(status)
        }
        capacity *= 2
    }
    throw WindowsZlibFailure.outputLimit
}
#endif
