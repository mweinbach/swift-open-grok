import Foundation
import OpenGrokShared
import OpenGrokWorkflow

/// The session-owned template map. Production is empty because upstream's
/// session factory supplies an empty map; injected maps exercise the host
/// contract without granting a project or script a new template authority.
struct LiveWorkflowTemplates: Sendable, Equatable {
    static let maximumOutputBytes = 1_048_576
    static let empty = LiveWorkflowTemplates(entries: [:])

    private let entries: [String: String]

    init(entries: [String: String]) {
        self.entries = entries
    }

    func render(name: String, variables: JSONValue) throws -> String {
        guard var output = entries[name] else {
            throw RhaiHostError.failed("unknown template: \(name)")
        }
        guard output.utf8.count <= Self.maximumOutputBytes else {
            throw RhaiHostError.failed("template exceeds \(Self.maximumOutputBytes) bytes")
        }
        guard case let .object(values) = variables else { return output }

        for key in values.keys.sorted() {
            guard let value = values[key] else { continue }
            let replacement: String
            if case let .string(string) = value {
                replacement = string
            } else {
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                    replacement = String(decoding: try encoder.encode(value), as: UTF8.self)
                } catch {
                    throw RhaiHostError.failed("cannot render template variable '\(key)': \(error)")
                }
            }

            let placeholder = "{\(key)}"
            let count = occurrenceCount(of: placeholder, in: output)
            if count > 0 {
                let removed = count.multipliedReportingOverflow(by: placeholder.utf8.count)
                let inserted = count.multipliedReportingOverflow(by: replacement.utf8.count)
                guard !removed.overflow, !inserted.overflow,
                      output.utf8.count >= removed.partialValue
                else {
                    throw RhaiHostError.failed("rendered template exceeds \(Self.maximumOutputBytes) bytes")
                }
                let retained = output.utf8.count - removed.partialValue
                let projected = retained.addingReportingOverflow(inserted.partialValue)
                guard !projected.overflow, projected.partialValue <= Self.maximumOutputBytes else {
                    throw RhaiHostError.failed("rendered template exceeds \(Self.maximumOutputBytes) bytes")
                }
                output = output.replacingOccurrences(of: placeholder, with: replacement)
            }
        }

        return output
    }

    private func occurrenceCount(of needle: String, in text: String) -> Int {
        var count = 0
        var start = text.startIndex
        while let range = text.range(of: needle, range: start..<text.endIndex) {
            count += 1
            start = range.upperBound
        }
        return count
    }
}
