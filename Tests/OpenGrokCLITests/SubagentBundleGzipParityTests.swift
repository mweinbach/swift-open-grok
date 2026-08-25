import Foundation
import Testing

@testable import OpenGrokCLI

@Suite("portable gzip bundle extraction integrity and parity")
struct SubagentBundleGzipParityTests {
    private static let compressedFixture = Data(base64Encoded:
        "H4sIAAAAAAAAAysuz0wr0c0vSM3TTS/Kz1ZIzs8tKEotLk5NUUgqzUvJSeUCAIgofs4iAAAA"
    )!

    @Test("real dynamically compressed gzip streams decode on every supported platform")
    func dynamicallyCompressedGzip() throws {
        let decoded = try BundleArchiveExtractor.decompressGzip(Self.compressedFixture)
        #expect(String(decoding: decoded, as: UTF8.self) == "swift-open-grok compressed bundle\n")
    }

    @Test("portable stored-block trace archives decode through the same bounded production path")
    func storedTraceGzip() throws {
        let archive = try LiveTraceArchive.make(entries: [
            .init(path: "trace/session.json", contents: Data("private-session".utf8))
        ])
        let decoded = try BundleArchiveExtractor.decompressGzip(archive)
        let entries = try BundleArchiveExtractor.parseTar(decoded)
        #expect(entries.count == 1)
        #expect(entries.first?.path == "trace/session.json")
        #expect(entries.first?.data == Data("private-session".utf8))
    }

    @Test("bundle test fixtures are genuine gzip streams instead of platform-specific raw tar")
    func archiveBuilderAlwaysProducesGzip() throws {
        let archive = TestArchiveBuilder.makeTestArchive(stringEntries: [
            ("bundle.json", TestArchiveBuilder.bundleJSON(version: "portable"))
        ])
        #expect(archive.prefix(3).elementsEqual([0x1F, 0x8B, 0x08]))
        #expect(try BundleArchiveExtractor.parseTar(
            BundleArchiveExtractor.decompressGzip(archive)
        ).first?.path == "bundle.json")
    }

    @Test("gzip checksum and declared decompressed length are independently verified")
    func rejectsCorruptedTrailers() {
        for trailerOffset in [8, 4] {
            var corrupted = Self.compressedFixture
            corrupted[corrupted.count - trailerOffset] ^= 0x80
            #expect(throws: BundleError.self) {
                try BundleArchiveExtractor.decompressGzip(corrupted)
            }
        }
    }

    @Test("truncated and trailing DEFLATE data fail without returning partial output")
    func rejectsMalformedDeflateStreams() {
        var truncated = Self.compressedFixture
        truncated.remove(at: truncated.count - 9)
        #expect(throws: BundleError.self) {
            try BundleArchiveExtractor.decompressGzip(truncated)
        }

        var extended = Self.compressedFixture
        extended.insert(0, at: extended.count - 8)
        #expect(throws: BundleError.self) {
            try BundleArchiveExtractor.decompressGzip(extended)
        }
    }

    @Test("compressed streams and accepted raw tar both enforce the same output ceiling")
    func enforcesDecompressedSize() throws {
        #expect(throws: BundleError.self) {
            try BundleArchiveExtractor.decompressGzip(Self.compressedFixture, maxSize: 8)
        }

        let archive = TestArchiveBuilder.makeTestArchive(stringEntries: [
            ("bundle.json", TestArchiveBuilder.bundleJSON(version: "bounded"))
        ])
        let rawTar = try BundleArchiveExtractor.decompressGzip(archive)
        #expect(throws: BundleError.self) {
            try BundleArchiveExtractor.decompressGzip(rawTar, maxSize: rawTar.count - 1)
        }
    }
}
