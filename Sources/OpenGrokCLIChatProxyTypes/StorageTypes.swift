// StorageTypes.swift
//
// Signed upload URL and batch upload types shared between cli-chat-proxy
// (server) and grok-shell (client). Ported from
// prod/mc/cli-chat-proxy-types/src/storage_types.rs.

import Foundation

/// Request body for batch-existence check.
/// POST /v1/storage/batch_exists
public struct BatchExistsRequest: Hashable, Sendable, Codable, Equatable {
    public var paths: [String]

    public init(paths: [String] = []) {
        self.paths = paths
    }
}

/// Response from batch-existence check.
public struct BatchExistsResponse: Hashable, Sendable, Codable, Equatable {
    public var exists: [String]
    public var missing: [String]

    public init(exists: [String] = [], missing: [String] = []) {
        self.exists = exists
        self.missing = missing
    }
}

/// Response from the signed upload URL endpoint.
/// POST /v1/storage/signed-upload-url
public struct SignedUploadURLResponse: Hashable, Sendable, Codable, Equatable {
    public var signedURL: String
    public var bucket: String
    public var path: String
    public var contentType: String
    public var expiresInSecs: UInt64

    public init(signedURL: String, bucket: String, path: String, contentType: String, expiresInSecs: UInt64) {
        self.signedURL = signedURL
        self.bucket = bucket
        self.path = path
        self.contentType = contentType
        self.expiresInSecs = expiresInSecs
    }

    // Rust uses `#[serde(rename_all = "camelCase")]` on SignedUploadUrlResponse.
    // serde's camelCase conversion maps `signed_url` → `signedUrl` (lower-casing
    // the `U` after `_`), NOT Swift's `signedURL` acronym preservation. Pin the
    // raw value explicitly so Swift emits/accepts `signedUrl`.
    enum CodingKeys: String, CodingKey {
        case signedURL = "signedUrl"
        case bucket
        case path
        case contentType
        case expiresInSecs
    }
}

/// Status of a single batch upload result.
public enum BatchUploadStatus: String, Sendable, Codable, Equatable {
    case ok
    case error
    case skipped
}

/// One file's batch upload result.
public struct BatchUploadResult: Hashable, Sendable, Codable, Equatable {
    public var path: String
    public var status: BatchUploadStatus
    public var bucket: String?
    public var size: Int64?
    public var generation: Int64?
    public var error: String?

    public init(
        path: String,
        status: BatchUploadStatus,
        bucket: String? = nil,
        size: Int64? = nil,
        generation: Int64? = nil,
        error: String? = nil
    ) {
        self.path = path
        self.status = status
        self.bucket = bucket
        self.size = size
        self.generation = generation
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case path
        case status
        case bucket
        case size
        case generation
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        status = try container.decode(BatchUploadStatus.self, forKey: .status)
        bucket = try container.decodeIfPresent(String.self, forKey: .bucket)
        size = try container.decodeIfPresent(Int64.self, forKey: .size)
        generation = try container.decodeIfPresent(Int64.self, forKey: .generation)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(bucket, forKey: .bucket)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(generation, forKey: .generation)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

/// Response from batch upload.
public struct BatchUploadResponse: Hashable, Sendable, Codable, Equatable {
    public var results: [BatchUploadResult]

    public init(results: [BatchUploadResult] = []) {
        self.results = results
    }
}

/// JSON request body for `POST /v1/storage/batch_upload_json`.
public struct BatchUploadRequest: Hashable, Sendable, Codable, Equatable {
    public var files: [BatchUploadFile]

    public init(files: [BatchUploadFile] = []) {
        self.files = files
    }
}

/// A single file entry in a `BatchUploadRequest`.
public struct BatchUploadFile: Hashable, Sendable, Codable, Equatable {
    public var path: String
    public var contentType: String
    public var data: String

    public init(path: String, contentType: String, data: String) {
        self.path = path
        self.contentType = contentType
        self.data = data
    }

    // Rust `BatchUploadFile` is a default-serde struct (no rename_all), so
    // the wire key is `content_type` — NOT the Swift camelCase `contentType`.
    // Pin the raw value explicitly so Swift round-trips with Rust peers.
    enum CodingKeys: String, CodingKey {
        case path
        case contentType = "content_type"
        case data
    }
}
