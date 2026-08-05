// FireworksSchemaNormalizationTests.swift
//
// Covers `normalizeFireworksSchema`, the port of
// `normalize_fireworks_schema` (`xai-grok-sampler/src/provider.rs:409`).
//
// Fireworks 400s a whole request when any tool subschema is unconstrained, so
// the interesting cases are the two shapes it rejects — `true`, and an object
// carrying nothing but annotations — and the recursion that has to find them
// wherever JSON Schema allows a subschema to hide.

import Foundation
import OpenGrokShared
import Testing
@testable import OpenGrokSampler

private func normalized(_ schema: JSONValue) -> JSONValue {
    var copy = schema
    normalizeFireworksSchema(&copy)
    return copy
}

private func isUnconstrainedUnion(_ value: JSONValue?) -> Bool {
    guard case .array(let branches)? = value else { return false }
    let types = branches.compactMap { branch -> String? in
        guard case .object(let object) = branch,
              case .string(let type)? = object["type"]
        else { return nil }
        return type
    }
    return Set(types) == ["null", "boolean", "integer", "number", "string", "array", "object"]
}

@Test func trueSchemaBecomesAnExplicitAnyTypeUnion() {
    guard case .object(let object) = normalized(.bool(true)) else {
        Issue.record("expected `true` to normalize into an object")
        return
    }
    #expect(isUnconstrainedUnion(object["anyOf"]))
}

@Test func falseSchemaIsLeftAlone() {
    // `false` matches nothing, which is a constraint — Fireworks accepts it.
    #expect(normalized(.bool(false)) == .bool(false))
}

@Test func annotationOnlyObjectGainsAUnionAndKeepsItsAnnotations() {
    let schema: JSONValue = .object([
        "description": .string("Freeform tool payload."),
        "title": .string("payload"),
    ])
    guard case .object(let object) = normalized(schema) else {
        Issue.record("expected an object")
        return
    }
    #expect(isUnconstrainedUnion(object["anyOf"]))
    // The annotations are the description the model reads; they must survive.
    #expect(object["description"] == .string("Freeform tool payload."))
    #expect(object["title"] == .string("payload"))
}

@Test func constrainedObjectIsNotGivenAUnion() {
    let schema: JSONValue = .object([
        "type": .string("object"),
        "description": .string("Already constrained."),
    ])
    guard case .object(let object) = normalized(schema) else {
        Issue.record("expected an object")
        return
    }
    #expect(object["anyOf"] == nil)
}

@Test func nestedPropertiesAreNormalized() {
    let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "loose": .bool(true),
            "tight": .object(["type": .string("string")]),
        ]),
    ])
    guard case .object(let object) = normalized(schema),
          case .object(let properties)? = object["properties"],
          case .object(let loose)? = properties["loose"]
    else {
        Issue.record("expected properties to survive normalization")
        return
    }
    #expect(isUnconstrainedUnion(loose["anyOf"]))
    #expect(properties["tight"] == .object(["type": .string("string")]))
}

@Test func subschemaKeywordsAreFollowed() {
    // One representative from each of the three recursion shapes: a single
    // subschema, an array of subschemas, and a name-to-subschema map.
    let schema: JSONValue = .object([
        "items": .bool(true),
        "oneOf": .array([.bool(true), .object(["type": .string("string")])]),
        "$defs": .object(["loose": .bool(true)]),
    ])
    guard case .object(let object) = normalized(schema) else {
        Issue.record("expected an object")
        return
    }
    guard case .object(let items)? = object["items"] else {
        Issue.record("expected items to normalize")
        return
    }
    #expect(isUnconstrainedUnion(items["anyOf"]))

    guard case .array(let oneOf)? = object["oneOf"],
          case .object(let first) = oneOf.first
    else {
        Issue.record("expected oneOf to normalize")
        return
    }
    #expect(isUnconstrainedUnion(first["anyOf"]))
    #expect(oneOf.count == 2)

    guard case .object(let defs)? = object["$defs"],
          case .object(let loose)? = defs["loose"]
    else {
        Issue.record("expected $defs to normalize")
        return
    }
    #expect(isUnconstrainedUnion(loose["anyOf"]))
}

@Test func fireworksAdapterNormalizesEveryToolSchema() {
    var request = ChatCompletionWireRequest(
        model: "accounts/fireworks/models/kimi-k2",
        messages: [],
        tools: [
            .function(name: "loose", description: nil, parameters: .bool(true)),
            .function(
                name: "tight",
                description: nil,
                parameters: .object(["type": .string("object")])
            ),
        ]
    )
    FireworksProvider().sanitizeChatRequest(&request)

    guard case .object(let loose)? = request.tools?.first?.function.parameters else {
        Issue.record("expected the loose tool schema to become an object")
        return
    }
    #expect(isUnconstrainedUnion(loose["anyOf"]))
    #expect(request.tools?.last?.function.parameters == .object(["type": .string("object")]))
}

@Test func fireworksAdapterToleratesAToollessRequest() {
    var request = ChatCompletionWireRequest(
        model: "accounts/fireworks/models/kimi-k2",
        messages: []
    )
    FireworksProvider().sanitizeChatRequest(&request)
    #expect(request.tools == nil)
}
