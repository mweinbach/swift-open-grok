// LegacyWorkflowProductionImportTests.swift
//
// Wave 20 C1b: inventory proof that the legacy JavaScript `WorkflowHost` /
// `WorkflowEngine` pair has no live production consumer. The Rhai engine is the
// only wired runtime (`RhaiWorkflowRunRegistry` → `RhaiWorkflowEngine.run`).

import Foundation
import Testing

@Suite("Legacy WorkflowHost production import inventory")
struct LegacyWorkflowProductionImportTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let sourcesRoot = repoRoot.appendingPathComponent("Sources", isDirectory: true)

    private static func swiftSources(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        var paths: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            paths.append(url)
        }
        return paths.sorted { $0.path < $1.path }
    }

    private static func relativePath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
    }

    /// Drop `//` comments so inventory scans do not false-positive on
    /// documentation strings (OpenGrokWorkflow.swift cites the symbols it
    /// retires without calling them).
    private static func codeLine(from line: Substring) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { return "" }
        if let range = line.range(of: "//") {
            return String(line[..<range.lowerBound])
        }
        return String(line)
    }

    private static func codeLines(from text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { codeLine(from: $0) }
    }

    @Test("WorkflowEngine.run is defined only in OpenGrokWorkflow.swift under Sources/")
    func workflowEngineRunHasNoProductionCallSites() throws {
        let legacyEngineFile = "Sources/OpenGrokWorkflow/OpenGrokWorkflow.swift"
        var offenders: [String] = []
        for url in Self.swiftSources(under: Self.sourcesRoot) {
            let text = try String(contentsOf: url, encoding: .utf8)
            let hits = Self.codeLines(from: text).contains { line in
                line.contains("WorkflowEngine.run") && !line.contains("RhaiWorkflowEngine.run")
            }
            guard hits else { continue }
            let path = Self.relativePath(url)
            if path != legacyEngineFile {
                offenders.append(path)
            }
        }
        #expect(offenders.isEmpty, "unexpected WorkflowEngine.run references: \(offenders)")
    }

    @Test("OpenGrokSessionRuntime is never constructed under Sources/")
    func sessionRuntimeHasNoProductionInstantiations() throws {
        var offenders: [String] = []
        for url in Self.swiftSources(under: Self.sourcesRoot) {
            let text = try String(contentsOf: url, encoding: .utf8)
            let hits = Self.codeLines(from: text).contains { $0.contains("OpenGrokSessionRuntime(") }
            guard hits else { continue }
            offenders.append(Self.relativePath(url))
        }
        #expect(offenders.isEmpty, "unexpected OpenGrokSessionRuntime constructions: \(offenders)")
    }

    @Test("legacy WorkflowHost type references are confined to the retire-candidate seam")
    func legacyWorkflowHostReferencesAreExpected() throws {
        let allowed = Set([
            "Sources/OpenGrokWorkflow/OpenGrokWorkflow.swift",
            "Sources/OpenGrokSessionRuntime/OpenGrokSessionRuntime.swift",
            "Sources/OpenGrokWorkflow/RhaiHost.swift",
        ])
        var offenders: [String] = []
        for url in Self.swiftSources(under: Self.sourcesRoot) {
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = Self.codeLines(from: text).joined(separator: "\n")
            guard code.contains("WorkflowHost") else { continue }
            // `RhaiWorkflowHost` and `LiveWorkflowHost` are the live seam; ignore them.
            let stripped = code
                .replacingOccurrences(of: "RhaiWorkflowHost", with: "")
                .replacingOccurrences(of: "LiveWorkflowHost", with: "")
            guard stripped.contains("WorkflowHost") else { continue }
            let path = Self.relativePath(url)
            if !allowed.contains(path) {
                offenders.append(path)
            }
        }
        #expect(offenders.isEmpty, "unexpected legacy WorkflowHost references: \(offenders)")
    }
}
