// PagerDocsHelpers.swift

import Foundation

public enum PagerDocsExtractionResult: Sendable, Equatable {
    case extracted(version: String)
    case unchanged(version: String)
}

extension PagerDocs {
    static let extractionVersionFileName = ".opengrok-corpus-version"

    public static func getHowtoDoc(title: String) -> String? {
        find(title: title)?.content
    }

    public static var userGuideCorpusVersion: String {
        var hash: UInt64 = 0xcbf29ce484222325
        for doc in userGuide {
            for byte in doc.filename.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
            hash ^= 0
            hash = hash &* 0x100000001b3
            for byte in doc.content.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
            hash ^= 0xFF
            hash = hash &* 0x100000001b3
        }
        let hexadecimal = String(hash, radix: 16)
        return "v1-" + String(repeating: "0", count: 16 - hexadecimal.count) + hexadecimal
    }

    @discardableResult
    public static func extractUserGuideDocs(
        to destination: URL
    ) throws -> PagerDocsExtractionResult {
        try extractUserGuideDocs(to: destination, didStageDocument: { _, _ in })
    }

    @discardableResult
    static func extractUserGuideDocs(
        to destination: URL,
        didStageDocument: (PagerDoc, Int) throws -> Void
    ) throws -> PagerDocsExtractionResult {
        let fileManager = FileManager.default
        let version = userGuideCorpusVersion
        let versionFile = destination.appendingPathComponent(extractionVersionFileName)
        if let installedVersion = try? String(contentsOf: versionFile, encoding: .utf8),
           installedVersion.trimmingCharacters(in: .whitespacesAndNewlines) == version {
            return .unchanged(version: version)
        }

        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).staging",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        var published = false
        defer {
            if !published {
                try? fileManager.removeItem(at: staging)
            }
        }

        if fileManager.fileExists(atPath: destination.path) {
            for existing in try fileManager.contentsOfDirectory(
                at: destination,
                includingPropertiesForKeys: nil
            ) {
                let name = existing.lastPathComponent
                guard name != extractionVersionFileName, !isManagedUserGuideFile(name) else {
                    continue
                }
                try fileManager.copyItem(
                    at: existing,
                    to: staging.appendingPathComponent(name)
                )
            }
        }

        for (index, doc) in userGuide.enumerated() {
            try Data(doc.content.utf8).write(
                to: staging.appendingPathComponent(doc.filename)
            )
            try didStageDocument(doc, index)
        }
        try Data("\(version)\n".utf8).write(
            to: staging.appendingPathComponent(extractionVersionFileName)
        )

        #if os(Windows)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
        #else
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
        #endif
        published = true
        return .extracted(version: version)
    }

    static func isManagedUserGuideFile(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        return bytes.count > 3
            && bytes[0].isASCIIDigit
            && bytes[1].isASCIIDigit
            && bytes[2] == 0x2D
            && name.hasSuffix(".md")
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool { (0x30 ... 0x39).contains(self) }
}
