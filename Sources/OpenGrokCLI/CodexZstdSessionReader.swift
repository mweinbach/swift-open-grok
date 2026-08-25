import Dispatch
import Foundation
import OpenGrokFileUtils

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum CodexZstdSessionReaderError: Error, Equatable, Sendable {
    case unsupportedPlatform
    case unavailableTrustedLibrary
    case compressedInputLimitExceeded
    case invalidFrame
    case windowLimitExceeded
    case expansionRatioExceeded
    case deadlineExceeded
    case cancelled
}

/// Bounded, first-frame-only decoding matching the pinned Rust Codex scanner.
///
/// Apple Compression and zlib cannot decode zstd. Resolve the genuine zstd C
/// ABI only from canonical, owner-safe system or package-manager installations;
/// an unsupported host fails closed instead of treating zstd bytes as JSONL.
enum CodexZstdSessionReader {
    static let maxCompressedBytes = 256 * 1024
    static let maxDecompressedBytes = 64 * 1024
    static let maxWindowLog: Int32 = 23
    static let maxExpansionRatio = 1_024
    static let expansionGraceBytes = 4 * 1024
    static let decodeTimeoutNanoseconds: UInt64 = 250_000_000

    static var isAvailable: Bool {
        #if canImport(Darwin) || canImport(Glibc)
        return CodexZstdDynamicLibrary.load() != nil
        #else
        return false
        #endif
    }

    static func decodeHead(
        _ compressed: Data,
        timeoutNanoseconds: UInt64 = decodeTimeoutNanoseconds,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> Data {
        guard !compressed.isEmpty else { throw CodexZstdSessionReaderError.invalidFrame }
        guard compressed.count <= maxCompressedBytes else {
            throw CodexZstdSessionReaderError.compressedInputLimitExceeded
        }
        guard !isCancelled() else { throw CodexZstdSessionReaderError.cancelled }
        guard timeoutNanoseconds > 0 else {
            throw CodexZstdSessionReaderError.deadlineExceeded
        }

        #if canImport(Darwin) || canImport(Glibc)
        guard let library = CodexZstdDynamicLibrary.load() else {
            throw CodexZstdSessionReaderError.unavailableTrustedLibrary
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let limit = started.addingReportingOverflow(timeoutNanoseconds)
        let deadline = limit.overflow ? UInt64.max : limit.partialValue

        guard let stream = library.createStream() else {
            throw CodexZstdSessionReaderError.invalidFrame
        }
        defer { library.freeStream(stream) }

        let initialized = library.initializeStream(stream)
        guard !library.isError(initialized) else {
            throw library.classify(initialized)
        }
        let window = library.setParameter(stream, 100, maxWindowLog)
        guard !library.isError(window) else {
            throw CodexZstdSessionReaderError.windowLimitExceeded
        }

        return try compressed.withUnsafeBytes { inputBytes in
            guard let base = inputBytes.baseAddress else {
                throw CodexZstdSessionReaderError.invalidFrame
            }
            let declared = library.frameContentSize(base, inputBytes.count)
            guard declared != UInt64.max - 1 else {
                throw CodexZstdSessionReaderError.invalidFrame
            }
            if declared != UInt64.max {
                let visible = min(declared, UInt64(maxDecompressedBytes))
                let allowance = max(
                    UInt64(expansionGraceBytes),
                    UInt64(inputBytes.count) * UInt64(maxExpansionRatio)
                )
                guard visible <= allowance else {
                    throw CodexZstdSessionReaderError.expansionRatioExceeded
                }
            }

            var input = CodexZstdInputBuffer(source: base, size: inputBytes.count, position: 0)
            var output = Data()
            output.reserveCapacity(min(maxDecompressedBytes, 4 * 1024))

            while output.count < maxDecompressedBytes {
                guard !isCancelled() else { throw CodexZstdSessionReaderError.cancelled }
                guard DispatchTime.now().uptimeNanoseconds < deadline else {
                    throw CodexZstdSessionReaderError.deadlineExceeded
                }

                let remaining = maxDecompressedBytes - output.count
                var chunk = [UInt8](repeating: 0, count: min(4 * 1024, remaining))
                let previousPosition = input.position
                var produced = 0
                let status = chunk.withUnsafeMutableBytes { bytes -> Int in
                    var buffer = CodexZstdOutputBuffer(
                        destination: bytes.baseAddress,
                        size: bytes.count,
                        position: 0
                    )
                    let result = withUnsafeMutablePointer(to: &input) { inputPointer in
                        withUnsafeMutablePointer(to: &buffer) { outputPointer in
                            library.decompressStream(
                                stream,
                                UnsafeMutableRawPointer(outputPointer),
                                UnsafeMutableRawPointer(inputPointer)
                            )
                        }
                    }
                    produced = buffer.position
                    return result
                }

                guard !library.isError(status), produced >= 0, produced <= chunk.count else {
                    throw library.classify(status)
                }
                if produced > 0 {
                    output.append(contentsOf: chunk.prefix(produced))
                }

                let consumed = max(input.position, 1)
                let ratioLimit = max(expansionGraceBytes, consumed * maxExpansionRatio)
                guard output.count <= ratioLimit else {
                    throw CodexZstdSessionReaderError.expansionRatioExceeded
                }
                guard DispatchTime.now().uptimeNanoseconds < deadline else {
                    throw CodexZstdSessionReaderError.deadlineExceeded
                }

                if status == 0 {
                    guard !output.isEmpty else { throw CodexZstdSessionReaderError.invalidFrame }
                    return output
                }
                if output.count == maxDecompressedBytes { return output }
                guard input.position > previousPosition || produced > 0 else {
                    throw CodexZstdSessionReaderError.invalidFrame
                }
                if input.position == input.size, produced < chunk.count {
                    throw CodexZstdSessionReaderError.invalidFrame
                }
            }
            return output
        }
        #else
        throw CodexZstdSessionReaderError.unsupportedPlatform
        #endif
    }
}

#if canImport(Darwin) || canImport(Glibc)
private struct CodexZstdInputBuffer {
    var source: UnsafeRawPointer?
    var size: Int
    var position: Int
}

private struct CodexZstdOutputBuffer {
    var destination: UnsafeMutableRawPointer?
    var size: Int
    var position: Int
}

private final class CodexZstdDynamicLibrary {
    private typealias CreateStream = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias FreeStream = @convention(c) (UnsafeMutableRawPointer?) -> Int
    private typealias InitializeStream = @convention(c) (UnsafeMutableRawPointer?) -> Int
    private typealias SetParameter = @convention(c) (
        UnsafeMutableRawPointer?, Int32, Int32
    ) -> Int
    private typealias DecompressStream = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> Int
    private typealias IsError = @convention(c) (Int) -> UInt32
    private typealias ErrorName = @convention(c) (Int) -> UnsafePointer<CChar>?
    private typealias FrameContentSize = @convention(c) (UnsafeRawPointer?, Int) -> UInt64

    private let handle: UnsafeMutableRawPointer
    private let create: CreateStream
    private let free: FreeStream
    private let initialize: InitializeStream
    private let parameter: SetParameter
    private let decompress: DecompressStream
    private let error: IsError
    private let errorName: ErrorName
    private let contentSize: FrameContentSize

    private init?(candidate: String) {
        guard let path = Self.canonicalTrustedPath(candidate) else { return nil }
        let opened = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard opened >= 0 else { return nil }
        defer { close(opened) }

        var expected = stat()
        guard fstat(opened, &expected) == 0,
              expected.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              expected.st_uid == 0 || expected.st_uid == geteuid(),
              expected.st_mode & mode_t(0o022) == 0,
              let loaded = dlopen(path, RTLD_NOW | RTLD_LOCAL)
        else { return nil }

        var observed = stat()
        guard lstat(path, &observed) == 0,
              expected.st_dev == observed.st_dev,
              expected.st_ino == observed.st_ino,
              let create: CreateStream = Self.symbol(loaded, "ZSTD_createDStream"),
              let free: FreeStream = Self.symbol(loaded, "ZSTD_freeDStream"),
              let initialize: InitializeStream = Self.symbol(loaded, "ZSTD_initDStream"),
              let parameter: SetParameter = Self.symbol(loaded, "ZSTD_DCtx_setParameter"),
              let decompress: DecompressStream = Self.symbol(loaded, "ZSTD_decompressStream"),
              let error: IsError = Self.symbol(loaded, "ZSTD_isError"),
              let errorName: ErrorName = Self.symbol(loaded, "ZSTD_getErrorName"),
              let contentSize: FrameContentSize = Self.symbol(loaded, "ZSTD_getFrameContentSize")
        else {
            dlclose(loaded)
            return nil
        }

        handle = loaded
        self.create = create
        self.free = free
        self.initialize = initialize
        self.parameter = parameter
        self.decompress = decompress
        self.error = error
        self.errorName = errorName
        self.contentSize = contentSize
    }

    deinit {
        dlclose(handle)
    }

    static func load() -> CodexZstdDynamicLibrary? {
        for candidate in candidates {
            if let library = CodexZstdDynamicLibrary(candidate: candidate) {
                return library
            }
        }
        return nil
    }

    private static var candidates: [String] {
        #if canImport(Darwin)
        return [
            "/usr/lib/libzstd.1.dylib",
            "/usr/lib/libzstd.dylib",
            "/opt/zerobrew/prefix/opt/zstd/lib/libzstd.1.dylib",
            "/opt/zerobrew/prefix/opt/zstd/lib/libzstd.dylib",
            "/opt/homebrew/opt/zstd/lib/libzstd.1.dylib",
            "/opt/homebrew/lib/libzstd.1.dylib",
            "/opt/homebrew/lib/libzstd.dylib",
            "/usr/local/opt/zstd/lib/libzstd.1.dylib",
            "/usr/local/lib/libzstd.1.dylib",
            "/usr/local/lib/libzstd.dylib",
        ]
        #else
        return [
            "/usr/lib/x86_64-linux-gnu/libzstd.so.1",
            "/usr/lib/aarch64-linux-gnu/libzstd.so.1",
            "/usr/lib64/libzstd.so.1",
            "/usr/lib/libzstd.so.1",
            "/lib/x86_64-linux-gnu/libzstd.so.1",
            "/lib/aarch64-linux-gnu/libzstd.so.1",
            "/lib64/libzstd.so.1",
            "/lib/libzstd.so.1",
            "/usr/local/lib/libzstd.so.1",
        ]
        #endif
    }

    private static func canonicalTrustedPath(_ candidate: String) -> String? {
        guard let canonical = try? PathSecurity.canonicalize(URL(fileURLWithPath: candidate)),
              trustedPrefixes.contains(where: { canonical.path.hasPrefix($0) })
        else { return nil }

        var directory = canonical.deletingLastPathComponent()
        while true {
            var information = stat()
            guard directory.path.withCString({ lstat($0, &information) }) == 0,
                  information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  information.st_uid == 0 || information.st_uid == geteuid(),
                  information.st_mode & mode_t(0o022) == 0
            else { return nil }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return canonical.path
    }

    private static var trustedPrefixes: [String] {
        #if canImport(Darwin)
        return [
            "/usr/lib/",
            "/usr/local/lib/",
            "/usr/local/Cellar/zstd/",
            "/opt/homebrew/Cellar/zstd/",
            "/opt/zerobrew/prefix/Cellar/zstd/",
        ]
        #else
        return ["/usr/lib/", "/usr/lib64/", "/usr/local/lib/", "/lib/", "/lib64/"]
        #endif
    }

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String) -> T? {
        guard let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }

    func createStream() -> UnsafeMutableRawPointer? {
        create()
    }

    func freeStream(_ stream: UnsafeMutableRawPointer) {
        free(stream)
    }

    func initializeStream(_ stream: UnsafeMutableRawPointer) -> Int {
        initialize(stream)
    }

    func setParameter(_ stream: UnsafeMutableRawPointer, _ key: Int32, _ value: Int32) -> Int {
        parameter(stream, key, value)
    }

    func decompressStream(
        _ stream: UnsafeMutableRawPointer,
        _ output: UnsafeMutableRawPointer,
        _ input: UnsafeMutableRawPointer
    ) -> Int {
        decompress(stream, output, input)
    }

    func frameContentSize(_ bytes: UnsafeRawPointer, _ count: Int) -> UInt64 {
        contentSize(bytes, count)
    }

    func isError(_ value: Int) -> Bool {
        error(value) != 0
    }

    func classify(_ value: Int) -> CodexZstdSessionReaderError {
        guard isError(value), let reason = errorName(value) else { return .invalidFrame }
        let message = String(cString: reason).lowercased()
        return message.contains("window") || message.contains("memory")
            ? .windowLimitExceeded
            : .invalidFrame
    }
}
#endif
