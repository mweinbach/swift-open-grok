// ProtobufWire.swift
//
// Minimal protobuf binary codec for `xai.grok.tools.v1` messages.
// Hand-maintained (no SwiftProtobuf dependency) to keep R01 self-contained.

import Foundation

public enum ProtoWireError: Error, Sendable, Hashable {
    case truncated
    case invalidVarint
    case invalidUTF8
    case invalidWireType(field: UInt32, wireType: UInt32)
    case malformedMap
}

/// Marker protocol for tools-API protobuf messages.
///
/// Nested value types implement a concrete `init(protobufBytes:)` rather than
/// relying on a protocol-extension initializer that rebinds `self`.
public protocol ProtobufMessage: Sendable, Hashable {
    mutating func merge(from data: Data) throws
    func protobufData() -> Data
}

// MARK: - Writer

public struct ProtoWriter: Sendable {
    public var bytes: [UInt8] = []

    public init() {}

    public mutating func writeVarint(_ value: UInt64) {
        var v = value
        while v > 0x7F {
            bytes.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        bytes.append(UInt8(v & 0x7F))
    }

    public mutating func writeTag(field: UInt32, wireType: UInt32) {
        writeVarint(UInt64((field << 3) | wireType))
    }

    public mutating func writeBool(_ field: UInt32, _ value: Bool) {
        guard value else { return }
        writeTag(field: field, wireType: 0)
        writeVarint(value ? 1 : 0)
    }

    public mutating func writeBoolPresence(_ field: UInt32, _ value: Bool, has: Bool) {
        guard has else { return }
        writeTag(field: field, wireType: 0)
        writeVarint(value ? 1 : 0)
    }

    public mutating func writeUInt32(_ field: UInt32, _ value: UInt32) {
        guard value != 0 else { return }
        writeTag(field: field, wireType: 0)
        writeVarint(UInt64(value))
    }

    public mutating func writeUInt32Presence(_ field: UInt32, _ value: UInt32, has: Bool) {
        guard has else { return }
        writeTag(field: field, wireType: 0)
        writeVarint(UInt64(value))
    }

    public mutating func writeUInt64(_ field: UInt32, _ value: UInt64) {
        guard value != 0 else { return }
        writeTag(field: field, wireType: 0)
        writeVarint(value)
    }

    public mutating func writeUInt64Presence(_ field: UInt32, _ value: UInt64, has: Bool) {
        guard has else { return }
        writeTag(field: field, wireType: 0)
        writeVarint(value)
    }

    public mutating func writeInt32(_ field: UInt32, _ value: Int32) {
        guard value != 0 else { return }
        writeTag(field: field, wireType: 0)
        writeVarint(UInt64(UInt32(bitPattern: value)))
    }

    public mutating func writeInt32Presence(_ field: UInt32, _ value: Int32, has: Bool) {
        guard has else { return }
        writeTag(field: field, wireType: 0)
        writeVarint(UInt64(UInt32(bitPattern: value)))
    }

    public mutating func writeInt64(_ field: UInt32, _ value: Int64) {
        guard value != 0 else { return }
        writeTag(field: field, wireType: 0)
        writeVarint(UInt64(bitPattern: value))
    }

    public mutating func writeEnum(_ field: UInt32, _ value: Int32) {
        guard value != 0 else { return }
        writeTag(field: field, wireType: 0)
        writeVarint(UInt64(UInt32(bitPattern: value)))
    }

    public mutating func writeEnumPresence(_ field: UInt32, _ value: Int32, has: Bool) {
        guard has else { return }
        writeTag(field: field, wireType: 0)
        writeVarint(UInt64(UInt32(bitPattern: value)))
    }

    public mutating func writeString(_ field: UInt32, _ value: String) {
        guard !value.isEmpty else { return }
        let data = Array(value.utf8)
        writeTag(field: field, wireType: 2)
        writeVarint(UInt64(data.count))
        bytes.append(contentsOf: data)
    }

    public mutating func writeStringPresence(_ field: UInt32, _ value: String, has: Bool) {
        guard has else { return }
        let data = Array(value.utf8)
        writeTag(field: field, wireType: 2)
        writeVarint(UInt64(data.count))
        bytes.append(contentsOf: data)
    }

    public mutating func writeBytes(_ field: UInt32, _ value: Data) {
        guard !value.isEmpty else { return }
        writeTag(field: field, wireType: 2)
        writeVarint(UInt64(value.count))
        bytes.append(contentsOf: value)
    }

    public mutating func writeMessage(_ field: UInt32, _ data: Data) {
        guard !data.isEmpty else { return }
        writeTag(field: field, wireType: 2)
        writeVarint(UInt64(data.count))
        bytes.append(contentsOf: data)
    }

    public mutating func writeMessagePresence(_ field: UInt32, _ data: Data?, has: Bool) {
        guard has, let data else { return }
        writeTag(field: field, wireType: 2)
        writeVarint(UInt64(data.count))
        bytes.append(contentsOf: data)
    }

    public var data: Data { Data(bytes) }
}

// MARK: - Reader

public struct ProtoReader: Sendable {
    private let bytes: [UInt8]
    private var index: Int = 0

    public init(_ data: Data) {
        self.bytes = Array(data)
    }

    public var isAtEnd: Bool { index >= bytes.count }

    public mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < bytes.count else { throw ProtoWireError.truncated }
            let b = bytes[index]
            index += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw ProtoWireError.invalidVarint }
        }
    }

    public mutating func readTag() throws -> (field: UInt32, wireType: UInt32)? {
        if isAtEnd { return nil }
        let tag = try readVarint()
        return (UInt32(tag >> 3), UInt32(tag & 0x7))
    }

    public mutating func skip(wireType: UInt32) throws {
        switch wireType {
        case 0: _ = try readVarint()
        case 1:
            guard index + 8 <= bytes.count else { throw ProtoWireError.truncated }
            index += 8
        case 2:
            let len = Int(try readVarint())
            guard index + len <= bytes.count else { throw ProtoWireError.truncated }
            index += len
        case 5:
            guard index + 4 <= bytes.count else { throw ProtoWireError.truncated }
            index += 4
        default:
            throw ProtoWireError.invalidWireType(field: 0, wireType: wireType)
        }
    }

    public mutating func readLengthDelimited() throws -> Data {
        let len = Int(try readVarint())
        guard index + len <= bytes.count else { throw ProtoWireError.truncated }
        let slice = Data(bytes[index..<(index + len)])
        index += len
        return slice
    }

    public mutating func readString() throws -> String {
        let data = try readLengthDelimited()
        guard let s = String(data: data, encoding: .utf8) else { throw ProtoWireError.invalidUTF8 }
        return s
    }

    public mutating func readBool() throws -> Bool {
        try readVarint() != 0
    }

    public mutating func readUInt32() throws -> UInt32 {
        UInt32(truncatingIfNeeded: try readVarint())
    }

    public mutating func readUInt64() throws -> UInt64 {
        try readVarint()
    }

    public mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: UInt32(truncatingIfNeeded: try readVarint()))
    }

    public mutating func readInt64() throws -> Int64 {
        Int64(bitPattern: try readVarint())
    }
}
