// OTLPProtobuf.swift
//
// Minimal, dependency-free protobuf encoder for OTLP trace export.
//
// Produces a valid `opentelemetry.proto.collector.trace.v1.ExportTraceServiceRequest`
// containing one resource span / scope span / span. Used by product and external
// OTLP HTTP/protobuf and (pre-framing) gRPC export paths so collectors receive
// real protobuf rather than JSON labeled `application/x-protobuf`.

import Foundation
import OpenGrokShared

/// Pure OTLP trace protobuf codec (encode only; hermetic, no network).
enum OTLPProtobuf {
    /// Encode `ExportTraceServiceRequest` with a single span.
    static func encodeExportTraceServiceRequest(
        name: String,
        attributes: [String: JSONValue],
        serviceName: String = "open-grok",
        nowNanos: UInt64? = nil
    ) -> Data {
        let nanos = nowNanos ?? unixNanosNow()
        let (traceID, spanID) = deterministicIDs(name: name, attributes: attributes)

        var span = Data()
        // Span.trace_id = 1 (bytes, 16)
        appendBytesField(1, traceID, into: &span)
        // Span.span_id = 2 (bytes, 8)
        appendBytesField(2, spanID, into: &span)
        // Span.name = 5 (string)
        appendStringField(5, name, into: &span)
        // Span.kind = 6 (enum SPAN_KIND_INTERNAL = 1)
        appendVarintField(6, 1, into: &span)
        // Span.start_time_unix_nano = 7 (fixed64)
        appendFixed64Field(7, nanos, into: &span)
        // Span.end_time_unix_nano = 8 (fixed64)
        appendFixed64Field(8, nanos, into: &span)
        // Span.attributes = 9 (KeyValue messages)
        for key in attributes.keys.sorted() {
            guard let value = attributes[key] else { continue }
            appendLengthDelimitedField(9, encodeKeyValue(key: key, value: value), into: &span)
        }

        var scopeSpans = Data()
        // ScopeSpans.scope = 1 — InstrumentationScope with name "open-grok"
        var scope = Data()
        appendStringField(1, "open-grok", into: &scope)
        appendLengthDelimitedField(1, scope, into: &scopeSpans)
        // ScopeSpans.spans = 2
        appendLengthDelimitedField(2, span, into: &scopeSpans)

        var resource = Data()
        // Resource.attributes = 1 — service.name
        appendLengthDelimitedField(
            1,
            encodeKeyValue(key: "service.name", value: .string(serviceName)),
            into: &resource
        )

        var resourceSpans = Data()
        // ResourceSpans.resource = 1
        appendLengthDelimitedField(1, resource, into: &resourceSpans)
        // ResourceSpans.scope_spans = 2
        appendLengthDelimitedField(2, scopeSpans, into: &resourceSpans)

        var request = Data()
        // ExportTraceServiceRequest.resource_spans = 1
        appendLengthDelimitedField(1, resourceSpans, into: &request)
        return request
    }

    /// Heuristic: body starts with field 1 length-delimited (tag 0x0A) and is
    /// not a JSON object/array.
    static func looksLikeExportTraceServiceRequest(_ body: Data) -> Bool {
        guard !body.isEmpty else { return false }
        if let first = body.first, first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            return false
        }
        // Tag for field 1, wire type 2 (length-delimited) is (1 << 3) | 2 = 0x0A.
        return body.first == 0x0A
    }

    // MARK: - KeyValue / AnyValue

    private static func encodeKeyValue(key: String, value: JSONValue) -> Data {
        var kv = Data()
        appendStringField(1, key, into: &kv)
        appendLengthDelimitedField(2, encodeAnyValue(value), into: &kv)
        return kv
    }

    private static func encodeAnyValue(_ value: JSONValue) -> Data {
        var any = Data()
        switch value {
        case .null:
            // Empty AnyValue (no oneof set) is valid; collectors treat as empty.
            break
        case .bool(let b):
            // bool_value = 2
            appendVarintField(2, b ? 1 : 0, into: &any)
        case .number(let n):
            // Prefer int_value when the double is a safe integer (exact in Double
            // mantissa / int64). Otherwise emit IEEE-754 double_value.
            if n.rounded() == n, n >= -9_007_199_254_740_991, n <= 9_007_199_254_740_991 {
                // int_value = 3 (int64 is plain varint of two's complement bits)
                appendVarintField(3, zigzagNotNeededInt64(Int64(n)), into: &any)
            } else {
                // double_value = 4 (fixed64 IEEE-754)
                appendFixed64Field(4, n.bitPattern, into: &any)
            }
        case .string(let s):
            // string_value = 1
            appendStringField(1, s, into: &any)
        case .array(let items):
            // array_value = 5 → ArrayValue { values = 1 repeated AnyValue }
            var arr = Data()
            for item in items {
                appendLengthDelimitedField(1, encodeAnyValue(item), into: &arr)
            }
            appendLengthDelimitedField(5, arr, into: &any)
        case .object(let obj):
            // kvlist_value = 6 → KeyValueList { values = 1 repeated KeyValue }
            var list = Data()
            for k in obj.keys.sorted() {
                guard let v = obj[k] else { continue }
                appendLengthDelimitedField(1, encodeKeyValue(key: k, value: v), into: &list)
            }
            appendLengthDelimitedField(6, list, into: &any)
        }
        return any
    }

    /// Protobuf int64 encoding: sign-extend into varint bits (two's complement).
    private static func zigzagNotNeededInt64(_ value: Int64) -> UInt64 {
        UInt64(bitPattern: value)
    }

    // MARK: - IDs / time

    private static func unixNanosNow() -> UInt64 {
        let seconds = Date().timeIntervalSince1970
        if seconds <= 0 { return 0 }
        return UInt64(seconds * 1_000_000_000.0)
    }

    /// Deterministic 16-byte trace id + 8-byte span id from name/attrs so
    /// hermetic tests do not depend on RNG, while remaining non-zero.
    private static func deterministicIDs(
        name: String,
        attributes: [String: JSONValue]
    ) -> (Data, Data) {
        var material = Data(name.utf8)
        for key in attributes.keys.sorted() {
            material.append(0)
            material.append(contentsOf: key.utf8)
            material.append(0)
            if let value = attributes[key] {
                material.append(contentsOf: stableJSONBytes(value))
            }
        }
        // FNV-1a 64-bit expanded into 16/8 bytes (not cryptographic; IDs only).
        var h: UInt64 = 0xcbf29ce484222325
        for b in material {
            h ^= UInt64(b)
            h &*= 0x100000001b3
        }
        var trace = Data(count: 16)
        var span = Data(count: 8)
        var h1 = h
        var h2 = h &+ 0x9e3779b97f4a7c15
        let mixed = h1 &+ h2
        for i in 0..<8 {
            trace[i] = UInt8((h1 >> (i * 8)) & 0xFF)
            trace[i + 8] = UInt8((h2 >> (i * 8)) & 0xFF)
            span[i] = UInt8((mixed >> (i * 8)) & 0xFF)
        }
        // Ensure non-all-zero IDs (OTLP invalid).
        if trace.allSatisfy({ $0 == 0 }) { trace[0] = 1 }
        if span.allSatisfy({ $0 == 0 }) { span[0] = 1 }
        return (trace, span)
    }

    private static func stableJSONBytes(_ value: JSONValue) -> Data {
        switch value {
        case .null: return Data("null".utf8)
        case .bool(let b): return Data((b ? "true" : "false").utf8)
        case .number(let n): return Data(String(n).utf8)
        case .string(let s): return Data(s.utf8)
        case .array(let items):
            var d = Data("[".utf8)
            for (i, item) in items.enumerated() {
                if i > 0 { d.append(UInt8(ascii: ",")) }
                d.append(stableJSONBytes(item))
            }
            d.append(UInt8(ascii: "]"))
            return d
        case .object(let obj):
            var d = Data("{".utf8)
            for (i, key) in obj.keys.sorted().enumerated() {
                if i > 0 { d.append(UInt8(ascii: ",")) }
                d.append(contentsOf: key.utf8)
                d.append(UInt8(ascii: ":"))
                if let v = obj[key] { d.append(stableJSONBytes(v)) }
            }
            d.append(UInt8(ascii: "}"))
            return d
        }
    }

    // MARK: - Protobuf primitives

    private static func appendVarint(_ value: UInt64, into data: inout Data) {
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            data.append(byte)
        } while v != 0
    }

    private static func appendTag(field: UInt32, wireType: UInt32, into data: inout Data) {
        appendVarint(UInt64((field << 3) | wireType), into: &data)
    }

    private static func appendVarintField(_ field: UInt32, _ value: UInt64, into data: inout Data) {
        appendTag(field: field, wireType: 0, into: &data)
        appendVarint(value, into: &data)
    }

    private static func appendFixed64Field(_ field: UInt32, _ value: UInt64, into data: inout Data) {
        appendTag(field: field, wireType: 1, into: &data)
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendLengthDelimitedField(_ field: UInt32, _ payload: Data, into data: inout Data) {
        appendTag(field: field, wireType: 2, into: &data)
        appendVarint(UInt64(payload.count), into: &data)
        data.append(payload)
    }

    private static func appendStringField(_ field: UInt32, _ string: String, into data: inout Data) {
        appendLengthDelimitedField(field, Data(string.utf8), into: &data)
    }

    private static func appendBytesField(_ field: UInt32, _ bytes: Data, into data: inout Data) {
        appendLengthDelimitedField(field, bytes, into: &data)
    }
}
