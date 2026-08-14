// WrapClipboardImage.swift
//
// Host clipboard image paste framing protocol mediated by `open-grok wrap`.
//
// Reference: crates/codegen/xai-grok-pager/src/wrap_clipboard_image.rs

import Foundation

/// Successful host image frame magic header.
public let MAGIC_IMG = "GROK_WRAP_IMG"

/// Host has no image magic header (explicit "no image", not a prefix of MAGIC_IMG).
public let MAGIC_NONE = "GROK_WRAP_NONE"

/// Max decoded image bytes on this path (20 MiB).
public let MAX_WRAP_IMAGE_BYTES: Int = 20 * 1024 * 1024

/// OSC body after `ESC ]` for a host image request.
public let REQUEST_BODY = "999;GrokWrapClipboardImage?"

/// Full request sequence written to request host clipboard image (`ESC ]` body `BEL`).
public func requestOscBytes() -> [UInt8] {
    var bytes: [UInt8] = [0x1b, 0x5d]
    bytes.append(contentsOf: REQUEST_BODY.utf8)
    bytes.append(0x07)
    return bytes
}

/// Result of decoding a wrap-injected clipboard paste payload.
public enum WrapImagePaste: Sendable, Equatable {
    case image(data: Data, mimeType: String)
    case noImage
}

/// Decode wrap host-image paste content (`Event::Paste` payload).
///
/// Returns `nil` if the payload does not start with wrap magic (caller treats as normal text).
/// Malformed wrap frames yield `.noImage` so they never land as text.
public func decodeWrapImagePaste(payload: String) -> WrapImagePaste? {
    let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == MAGIC_NONE {
        return .noImage
    }
    guard payload.hasPrefix(MAGIC_IMG) else {
        return nil
    }

    // Split into lines preserving base64 body
    let lines = payload.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard lines.count >= 3, lines[0] == MAGIC_IMG else {
        return .noImage
    }

    let mime = lines[1]
    let b64 = lines[2...].joined()

    if mime.isEmpty || b64.isEmpty || b64.hasPrefix("=") {
        return .noImage
    }

    // Quick size-check before allocating decoded buffer: 4 base64 chars produce ~3 bytes.
    let approxDecoded = (b64.count * 3) / 4
    if approxDecoded > MAX_WRAP_IMAGE_BYTES {
        return .noImage
    }

    guard let data = Data(base64Encoded: b64),
          !data.isEmpty,
          data.count <= MAX_WRAP_IMAGE_BYTES else {
        return .noImage
    }

    return .image(data: data, mimeType: mime)
}

/// Encode image data and MIME type into wrap image payload framing.
public func encodeWrapImagePayload(data: Data, mimeType: String) -> String {
    guard !data.isEmpty, data.count <= MAX_WRAP_IMAGE_BYTES else {
        return MAGIC_NONE
    }
    let base64 = data.base64EncodedString()
    return "\(MAGIC_IMG)\n\(mimeType)\n\(base64)"
}
