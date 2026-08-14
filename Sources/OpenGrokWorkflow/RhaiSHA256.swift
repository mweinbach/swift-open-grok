// RhaiSHA256.swift
//
// SHA-256 (FIPS 180-4) wrapper for the workflow request hash, forwarding to OpenGrokShared.

import Foundation
import OpenGrokShared

enum RhaiSHA256 {
    static func hash(_ bytes: [UInt8]) -> [UInt8] {
        OpenGrokShared.SHA256.hash(bytes)
    }

    static func hexDigest(_ bytes: [UInt8]) -> String {
        OpenGrokShared.SHA256.hexDigest(bytes)
    }

    static func hexDigest(_ string: String) -> String {
        OpenGrokShared.SHA256.hexDigest(string)
    }
}
