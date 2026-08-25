import Dispatch
import Foundation
#if canImport(COpenGrokZlib)
import COpenGrokZlib
#endif

enum DocumentExtractionError: Error, LocalizedError, Sendable {
    case invalid(String)
    case limit(String)
    case unsupported(String)
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .limit(let message), .unsupported(let message):
            return message
        case .timedOut:
            return "Document processing timed out after 60 seconds"
        case .cancelled:
            return "Document processing was cancelled"
        }
    }
}

struct DocumentExtractionDeadline: Sendable {
    private let started = DispatchTime.now().uptimeNanoseconds

    func check() throws {
        guard !Task.isCancelled else { throw DocumentExtractionError.cancelled }
        let current = DispatchTime.now().uptimeNanoseconds
        guard current >= started,
              current - started < 60_000_000_000
        else {
            throw DocumentExtractionError.timedOut
        }
    }
}

enum DocumentExtraction {
    static let maximumDocumentBytes = 50 * 1024 * 1024
    static let maximumXMLBytes = 64 * 1024 * 1024
    static let maximumPDFPagesPerRead = 20
    static let automaticPDFPageLimit = 10

    enum Format: Sendable {
        case pdf
        case pptx
    }

    static func identify(path: String) throws -> Format? {
        let url = URL(fileURLWithPath: path)
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "pptx": return .pptx
        default:
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value >= 5
            else { return nil }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let signature = try handle.read(upToCount: 5)
            return signature == Data("%PDF-".utf8) ? .pdf : nil
        }
    }

    static func readBounded(path: String, label: String) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw DocumentExtractionError.invalid("\(label) must be a regular file")
        }
        guard let size = attributes[.size] as? NSNumber,
              size.int64Value >= 0,
              size.int64Value <= Int64(maximumDocumentBytes)
        else {
            throw DocumentExtractionError.limit("\(label) file exceeds the 50 MB limit")
        }
        let data = try SessionFS.readBytes(at: path)
        guard data.count <= maximumDocumentBytes else {
            throw DocumentExtractionError.limit("\(label) file exceeds the 50 MB limit")
        }
        return data
    }

    static func parsePageRange(_ specification: String, pageCount: Int) throws -> [Int] {
        var pages = Set<Int>()
        for component in specification.split(separator: ",", omittingEmptySubsequences: false) {
            let part = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if let separator = part.firstIndex(of: "-") {
                let startString = part[..<separator].trimmingCharacters(in: .whitespaces)
                let endString = part[part.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                guard let start = Int(startString), start >= 1, start <= pageCount else {
                    throw DocumentExtractionError.invalid(
                        "page \(startString) out of range (document has \(pageCount) pages)"
                    )
                }
                let end: Int
                if endString.isEmpty {
                    end = pageCount
                } else if let parsed = Int(endString) {
                    end = parsed
                } else {
                    throw DocumentExtractionError.invalid("invalid page number: '\(endString)'")
                }
                guard start <= end else {
                    throw DocumentExtractionError.invalid(
                        "invalid page range: \(start)-\(end) (start must be ≤ end)"
                    )
                }
                for page in start...min(end, pageCount) {
                    pages.insert(page - 1)
                    guard pages.count <= maximumPDFPagesPerRead else {
                        throw DocumentExtractionError.limit(
                            "requested more than \(maximumPDFPagesPerRead) pages, maximum is \(maximumPDFPagesPerRead) per call"
                        )
                    }
                }
            } else {
                guard let page = Int(part), page >= 1, page <= pageCount else {
                    throw DocumentExtractionError.invalid(
                        "page \(part) out of range (document has \(pageCount) pages)"
                    )
                }
                pages.insert(page - 1)
            }
        }
        guard !pages.isEmpty else {
            throw DocumentExtractionError.invalid("no pages specified")
        }
        guard pages.count <= maximumPDFPagesPerRead else {
            throw DocumentExtractionError.limit(
                "requested \(pages.count) pages, maximum is \(maximumPDFPagesPerRead) per call"
            )
        }
        return pages.sorted()
    }

    static func selectedPages(specification: String?, count: Int) throws -> [Int] {
        guard count > 0 else {
            throw DocumentExtractionError.invalid("PDF has no pages")
        }
        if let specification {
            return try parsePageRange(specification, pageCount: count)
        }
        guard count <= automaticPDFPageLimit else {
            throw DocumentExtractionError.limit(
                "PDF has \(count) pages which exceeds the \(automaticPDFPageLimit) page auto-read limit. "
                    + "Use the `pages` parameter (for example pages=\"1-5\"). "
                    + "Maximum \(maximumPDFPagesPerRead) pages per call."
            )
        }
        return Array(0..<count)
    }
}

enum DocumentInflater {
    static func inflate(
        _ compressed: Data,
        raw: Bool,
        expectedSize: Int?,
        maximumOutput: Int,
        deadline: DocumentExtractionDeadline
    ) throws -> Data {
        try deadline.check()
        guard maximumOutput > 0,
              expectedSize.map({ $0 >= 0 && $0 <= maximumOutput }) ?? true
        else {
            throw DocumentExtractionError.limit("Compressed document entry exceeds the output limit")
        }

        #if os(Windows) && canImport(COpenGrokZlib)
        guard open_grok_zlib_is_available() != 0,
              open_grok_zlib_inflater_is_available() != 0
        else {
            throw DocumentExtractionError.unsupported("The Windows zlib provider is unavailable")
        }

        return try compressed.withUnsafeBytes { source in
            guard let inflater = open_grok_zlib_inflater_create(
                source.bindMemory(to: UInt8.self).baseAddress,
                compressed.count,
                raw ? 1 : 0
            ) else {
                throw DocumentExtractionError.invalid("Unable to initialize document decompression")
            }
            defer { open_grok_zlib_inflater_destroy(inflater) }

            var output = Data()
            output.reserveCapacity(min(expectedSize ?? compressed.count * 4, maximumOutput))
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            while true {
                try deadline.check()
                let remainingBefore = open_grok_zlib_inflater_remaining_input(inflater)
                var written = buffer.count
                let status = buffer.withUnsafeMutableBufferPointer { destination in
                    open_grok_zlib_inflater_step(inflater, destination.baseAddress, &written)
                }

                guard written <= maximumOutput - output.count else {
                    throw DocumentExtractionError.limit("Compressed document entry exceeds the output limit")
                }
                if written > 0 {
                    output.append(contentsOf: buffer.prefix(written))
                }
                if status == 1 { break }

                let remainingAfter = open_grok_zlib_inflater_remaining_input(inflater)
                guard status == 0, written > 0 || remainingAfter < remainingBefore else {
                    throw DocumentExtractionError.invalid("Invalid or truncated compressed document stream")
                }
            }

            guard open_grok_zlib_inflater_remaining_input(inflater) == 0,
                  expectedSize.map({ $0 == output.count }) ?? true
            else {
                throw DocumentExtractionError.invalid("Compressed document size does not match its declaration")
            }
            return output
        }
        #elseif canImport(COpenGrokZlib)
        var stream = z_stream()
        let status = inflateInit2_(
            &stream,
            raw ? -MAX_WBITS : MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            throw DocumentExtractionError.invalid("Unable to initialize document decompression")
        }
        defer { _ = inflateEnd(&stream) }

        var mutableInput = compressed
        var output = Data()
        output.reserveCapacity(min(expectedSize ?? compressed.count * 4, maximumOutput))
        try mutableInput.withUnsafeMutableBytes { input in
            stream.next_in = input.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(compressed.count)
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            while true {
                try deadline.check()
                let (result, written) = buffer.withUnsafeMutableBufferPointer { destination -> (Int32, Int) in
                    stream.next_out = destination.baseAddress
                    stream.avail_out = uInt(destination.count)
                    let result = COpenGrokZlib.inflate(&stream, Z_NO_FLUSH)
                    return (result, destination.count - Int(stream.avail_out))
                }
                guard written <= maximumOutput - output.count else {
                    throw DocumentExtractionError.limit("Compressed document entry exceeds the output limit")
                }
                if written > 0 {
                    output.append(contentsOf: buffer.prefix(written))
                }
                if result == Z_STREAM_END { break }
                guard result == Z_OK, written > 0 || stream.avail_in > 0 else {
                    throw DocumentExtractionError.invalid("Invalid or truncated compressed document stream")
                }
            }
        }
        guard stream.avail_in == 0,
              expectedSize.map({ $0 == output.count }) ?? true
        else {
            throw DocumentExtractionError.invalid("Compressed document size does not match its declaration")
        }
        return output
        #else
        throw DocumentExtractionError.unsupported("Document decompression is unavailable on this platform")
        #endif
    }
}
