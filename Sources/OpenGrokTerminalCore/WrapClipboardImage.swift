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
    if payload == MAGIC_NONE {
        return .noImage
    }
    guard payload.hasPrefix(MAGIC_IMG) else {
        return nil
    }

    let frame = payload.dropFirst(MAGIC_IMG.count)
    guard frame.first == "\n" else {
        return .noImage
    }

    let imageFields = frame.dropFirst()
    guard let mimeSeparator = imageFields.utf8.firstIndex(of: 0x0A) else {
        return .noImage
    }

    let mimeBytes = imageFields.utf8[..<mimeSeparator]
    let base64Start = imageFields.utf8.index(after: mimeSeparator)
    var base64 = imageFields[base64Start...]
    while let last = base64.last, last.isWhitespace {
        base64 = base64.dropLast()
    }

    guard !mimeBytes.isEmpty,
          !base64.isEmpty,
          !base64.utf8.contains(where: { $0 == 0x0A || $0 == 0x0D }) else {
        return .noImage
    }

    // Bound the encoded length before multiplication or decoded-buffer allocation.
    let encodedByteCount = base64.utf8.count
    guard encodedByteCount <= (MAX_WRAP_IMAGE_BYTES / 3 + 1) * 4,
          (encodedByteCount * 3) / 4 <= MAX_WRAP_IMAGE_BYTES else {
        return .noImage
    }

    guard let data = Data(base64Encoded: String(base64)),
          !data.isEmpty,
          data.count <= MAX_WRAP_IMAGE_BYTES else {
        return .noImage
    }

    return .image(data: data, mimeType: String(decoding: mimeBytes, as: UTF8.self))
}

/// Encode image data and MIME type into wrap image payload framing.
public func encodeWrapImagePayload(data: Data, mimeType: String) -> String {
    guard !data.isEmpty, data.count <= MAX_WRAP_IMAGE_BYTES else {
        return MAGIC_NONE
    }
    let base64 = data.base64EncodedString()
    return "\(MAGIC_IMG)\n\(mimeType)\n\(base64)"
}
