import Foundation
import Testing
@testable import OpenGrokToolRegistry

@Suite("Workflow registry")
struct WorkflowRegistryTests {
    @Test("discovery enforces filename, duplicate, and exclusive selection")
    func discoverySelectionRules() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent(".opengrok/workflows", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = "let meta = #{ name: \"demo\", description: \"d\" }; complete(\"ok\");"
        try script.write(to: directory.appendingPathComponent("demo.rhai"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try WorkflowRegistryIndex.discover(projectRoot: root, userHome: nil, opengrokHome: nil)
        #expect(index.sources.map(\.name) == ["demo"])
        #expect(try index.resolve(name: "demo").path.hasSuffix("demo.rhai"))
        #expect(throws: WorkflowRegistryError.self) { try index.resolve(name: "demo", path: "demo.rhai") }
    }
}
