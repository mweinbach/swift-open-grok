import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokShellSessionSupport

@Suite("Expanded-provider xAI export isolation")
struct ProviderExpansionExportBoundaryTests {
    @Test(
        "every expanded provider permanently closes all xAI share and upload gates",
        arguments: [ModelProvider.runinfra, .gemini, .openRouter]
    )
    func expandedProvidersCloseEveryExportGate(_ provider: ModelProvider) {
        let boundary = ExportBoundary()

        #expect(boundary.observe(provider))
        #expect(!boundary.observe(.xai))
        #expect(!boundary.allowsXaiExport)
        #expect(!ShareExportGate.cloudUploadPermitted(liveBoundary: boundary))
        #expect(throws: ShareRefusal.nonXaiProviderBoundary) {
            try ShareExportGate.authorizeExport(
                persistedEverUsedNonXAI: false,
                liveBoundary: boundary,
                messageCount: 1
            )
        }
        #expect(throws: ShareRefusal.boundaryCrossedDuringShare) {
            try ShareExportGate.authorizePostExport(liveBoundary: boundary)
        }
    }
}
