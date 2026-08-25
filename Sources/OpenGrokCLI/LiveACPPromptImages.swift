import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokProviderSession
import OpenGrokShared
import OpenGrokShell
import OpenGrokWebMediaTools

struct LiveACPPromptImages: Sendable {
    let gateway: ACPNotificationGateway
    let history: LiveConversationHistory
    let modelSwitch: LiveModelSwitchCoordinator
    let providerConfiguration: ProviderSessionConfiguration
    let rootSessionID: String

    var callbacks: ProviderBackedACPPromptDriver.ImageStaging {
        let gateway = gateway
        let history = history
        let modelSwitch = modelSwitch
        let providerConfiguration = providerConfiguration
        let rootSessionID = rootSessionID

        return ProviderBackedACPPromptDriver.ImageStaging(
            stage: { wireSessionID, promptID, images in
                guard !promptID.isEmpty,
                      promptID.utf8.count <= 128,
                      await gateway.ownsSession(wireSessionID),
                      await history.sessionID == rootSessionID
                else {
                    throw OpenGrokShellError.invalidTurnRequest(
                        "ACP prompt images require their authenticated owning session"
                    )
                }

                let route = await modelSwitch.snapshot()
                let wireModelID = providerConfiguration.modelCatalog[route.modelID]?.model
                guard LivePromptImageCapability.supports(modelID: route.modelID),
                      wireModelID.map(LivePromptImageCapability.supports(modelID:)) ?? true
                else {
                    throw CLIApplicationError.failed(LivePromptImageCapability.textOnlyError)
                }

                let attachments = try Self.validatedAttachments(images)
                try OpenGrokPagerImageAttachmentValidator.validate(attachments)

                guard await gateway.ownsSession(wireSessionID),
                      await history.sessionID == rootSessionID
                else {
                    throw OpenGrokShellError.invalidTurnRequest(
                        "ACP prompt image ownership changed before staging"
                    )
                }
                await history.stagePromptImages(promptID: promptID, images: attachments)

                guard await gateway.ownsSession(wireSessionID),
                      await history.sessionID == rootSessionID
                else {
                    _ = await history.consumePromptImages(promptID: promptID)
                    throw OpenGrokShellError.invalidTurnRequest(
                        "ACP prompt image ownership changed after staging"
                    )
                }
            },
            clear: { _, promptID in
                guard await history.sessionID == rootSessionID else { return }
                _ = await history.consumePromptImages(promptID: promptID)
            }
        )
    }

    static func validatedAttachments(_ images: [OpenGrokACP.ImageContent]) throws -> [PastedImage] {
        guard !images.isEmpty, images.count <= maxPlaceholdersPerPrompt else {
            throw OpenGrokShellError.invalidTurnRequest(
                "ACP prompt image count exceeds its supported limit"
            )
        }

        var attachments: [PastedImage] = []
        var totalBytes = 0
        for (index, image) in images.enumerated() {
            let maximumBytes = OpenGrokPagerImageAttachmentValidator.maximumBytes
            guard image.uri == nil,
                  image.data.utf8.count <= ((maximumBytes + 2) / 3) * 4,
                  let data = Data(base64Encoded: image.data),
                  !data.isEmpty,
                  data.count <= maximumBytes,
                  totalBytes <= 8_000_000 - data.count
            else {
                throw OpenGrokPagerImageAttachmentError.invalidImageData
            }

            let mimeType = image.mimeType.lowercased()
            let expectedFormat: ImageFormat
            switch mimeType {
            case "image/png": expectedFormat = .png
            case "image/jpeg": expectedFormat = .jpeg
            case "image/webp": expectedFormat = .webp
            case "image/gif": expectedFormat = .gif
            default:
                throw OpenGrokPagerImageAttachmentError.unsupportedMIMEType(image.mimeType)
            }

            guard ImageNormalizer.detectFormat(in: data) == expectedFormat,
                  let dimensions = ImageNormalizer.detectDimensions(in: data),
                  let width = UInt32(exactly: dimensions.width),
                  let height = UInt32(exactly: dimensions.height)
            else {
                throw OpenGrokPagerImageAttachmentError.invalidImageData
            }
            try OpenGrokPagerImageAttachmentValidator.validateDimensions(
                width: width,
                height: height
            )

            totalBytes += data.count
            attachments.append(PastedImage(
                displayNumber: index + 1,
                mimeType: mimeType,
                dimensions: (width: width, height: height),
                byteLen: data.count,
                encodedBytes: data
            ))
        }
        return attachments
    }
}
