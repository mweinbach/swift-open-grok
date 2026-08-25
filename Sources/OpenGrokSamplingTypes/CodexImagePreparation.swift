import Foundation

public let CODEX_IMAGE_PROCESSING_ERROR_PLACEHOLDER =
    "image content omitted because it could not be processed"
public let CODEX_REMOTE_IMAGE_URL_PLACEHOLDER =
    "image content omitted because remote image URLs are not supported"
public let CODEX_UNSUPPORTED_LOW_DETAIL_PLACEHOLDER =
    "image content omitted because detail 'low' is not supported; use 'high', 'original', or 'auto'"

extension ConversationRequest {
    /// Replace images that Codex rejects outright while retaining conversation order.
    @discardableResult
    public mutating func prepareImagesForCodex() -> Int {
        var prepared = 0

        for itemIndex in items.indices {
            switch items[itemIndex] {
            case .user(var user):
                for contentIndex in user.content.indices {
                    guard case .image(let imageURL) = user.content[contentIndex],
                          let placeholder = codexImagePlaceholder(imageURL, detail: nil)
                    else { continue }
                    user.content[contentIndex] = .text(text: placeholder)
                    prepared += 1
                }
                items[itemIndex] = .user(user)

            case .toolResult(var result):
                let imageCount = result.images.count
                result.images.removeAll { part in
                    guard case .image(let imageURL) = part else { return false }
                    return codexImagePlaceholder(imageURL, detail: nil) != nil
                }

                let dropped = imageCount - result.images.count
                if dropped > 0 {
                    prepared += dropped
                    if result.content.isEmpty {
                        result.content = CODEX_IMAGE_PROCESSING_ERROR_PLACEHOLDER
                    } else if !result.content.contains("image content omitted") {
                        result.content += "\n[\(CODEX_IMAGE_PROCESSING_ERROR_PLACEHOLDER)]"
                    }
                }

                for contentIndex in result.orderedContent.indices {
                    guard case .image(let imageURL, let detail) = result.orderedContent[contentIndex],
                          let placeholder = codexImagePlaceholder(imageURL, detail: detail)
                    else { continue }
                    result.orderedContent[contentIndex] = .text(text: placeholder)
                    prepared += 1
                }
                items[itemIndex] = .toolResult(result)

            case .customToolOutput(var output):
                for contentIndex in output.content.indices {
                    guard case .image(let imageURL, let detail) = output.content[contentIndex],
                          let placeholder = codexImagePlaceholder(imageURL, detail: detail)
                    else { continue }
                    output.content[contentIndex] = .text(text: placeholder)
                    prepared += 1
                }
                items[itemIndex] = .customToolOutput(output)

            case .system, .assistant, .backendToolCall, .reasoning:
                break
            }
        }

        return prepared
    }
}

private func codexImagePlaceholder(
    _ imageURL: String,
    detail: CustomToolOutputImageDetail?
) -> String? {
    let schemeParts = imageURL.split(
        separator: ":",
        maxSplits: 1,
        omittingEmptySubsequences: false
    )
    if schemeParts.count == 2 {
        let scheme = schemeParts[0].lowercased()
        if scheme == "http" || scheme == "https" {
            return CODEX_REMOTE_IMAGE_URL_PLACEHOLDER
        }
    }

    if detail == .low {
        return CODEX_UNSUPPORTED_LOW_DETAIL_PLACEHOLDER
    }

    guard imageURL.prefix(5).lowercased() == "data:" else {
        return nil
    }

    let components = imageURL.dropFirst(5).split(
        separator: ",",
        maxSplits: 1,
        omittingEmptySubsequences: false
    )
    guard components.count == 2 else {
        return CODEX_IMAGE_PROCESSING_ERROR_PLACEHOLDER
    }

    let metadata = components[0].split(separator: ";", omittingEmptySubsequences: false)
    let mime = metadata.first.map {
        String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    } ?? ""
    let payload = components[1]

    guard mime.hasPrefix("image/"),
          metadata.contains(where: { $0.lowercased() == "base64" }),
          !payload.isEmpty,
          payload.utf8.count.isMultiple(of: 4),
          !payload.utf8.contains(where: { byte in
              byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
          }),
          Data(base64Encoded: String(payload)) != nil
    else {
        return CODEX_IMAGE_PROCESSING_ERROR_PLACEHOLDER
    }

    return nil
}
