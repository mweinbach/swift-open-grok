// LiveTodoToolsTests.swift
//
// Covers `todo_write`.
//
// The two behaviours worth pinning are the ones that would quietly destroy the
// user's visible plan if they were wrong: `merge` defaulting to true, and the
// list keeping insertion order across updates.

import Foundation
import OpenGrokShared
import OpenGrokToolRegistry
import Testing
@testable import OpenGrokCLI

private func update(
    _ id: String,
    content: String? = nil,
    status: LiveTodoStatus? = nil
) -> LiveTodoWrite.Update {
    LiveTodoWrite.Update(id: id, content: content, status: status)
}

// MARK: - Merge default

@Test func mergeDefaultsToTrue() {
    // Getting this backwards would discard the rest of the user's plan on every
    // partial update, which is the whole point of the tool.
    #expect(LiveTodoWrite.parseMerge(nil))
    #expect(LiveTodoWrite.parseMerge(.bool(true)))
    #expect(!LiveTodoWrite.parseMerge(.bool(false)))
}

@Test func mergeAcceptsTheStringSpellingsModelsEmit() {
    #expect(!LiveTodoWrite.parseMerge(.string("false")))
    #expect(!LiveTodoWrite.parseMerge(.string("0")))
    #expect(!LiveTodoWrite.parseMerge(.string("no")))
    #expect(LiveTodoWrite.parseMerge(.string("true")))
    // Anything unrecognised keeps the safe default rather than replacing.
    #expect(LiveTodoWrite.parseMerge(.string("maybe")))
}

// MARK: - Parsing

@Test func parsingRejectsDuplicateIDs() {
    let payload: JSONValue = .array([
        .object(["id": .string("a")]),
        .object(["id": .string("a")]),
    ])
    #expect(throws: LiveTodoError.duplicateID("a")) {
        try LiveTodoWrite.parseUpdates(payload)
    }
}

@Test func parsingRequiresANonEmptyID() {
    #expect(throws: LiveTodoError.missingID) {
        try LiveTodoWrite.parseUpdates(.array([.object(["content": .string("no id")])]))
    }
    #expect(throws: LiveTodoError.missingID) {
        try LiveTodoWrite.parseUpdates(.array([.object(["id": .string("   ")])]))
    }
}

@Test func parsingReadsContentAndStatus() throws {
    let updates = try LiveTodoWrite.parseUpdates(.array([
        .object([
            "id": .string("a"),
            "content": .string("Write the thing"),
            "status": .string("in_progress"),
        ]),
    ]))
    #expect(updates == [update("a", content: "Write the thing", status: .inProgress)])
}

@Test func anUnknownStatusIsIgnoredRatherThanFatal() throws {
    // A bad status should not cost the model the whole call; it falls back to
    // the default on insert, or leaves the existing status alone on merge.
    let updates = try LiveTodoWrite.parseUpdates(.array([
        .object(["id": .string("a"), "status": .string("almost_done")]),
    ]))
    #expect(updates.first?.status == nil)
}

// MARK: - Apply

@Test func mergeUpdatesInPlaceAndAppendsNewItems() async {
    let store = LiveTodoStore()
    await LiveTodoWrite.apply(
        updates: [
            update("a", content: "First", status: .pending),
            update("b", content: "Second", status: .pending),
        ],
        merge: true,
        to: store
    )
    // A status flip that sends only id + status must not blank the content.
    await LiveTodoWrite.apply(
        updates: [update("a", status: .completed), update("c", content: "Third")],
        merge: true,
        to: store
    )

    let todos = await store.todos
    #expect(todos.map(\.id) == ["a", "b", "c"])
    #expect(todos[0].content == "First")
    #expect(todos[0].status == .completed)
    #expect(todos[1].status == .pending)
    #expect(todos[2].content == "Third")
    // An item with no explicit status arrives pending.
    #expect(todos[2].status == .pending)
}

@Test func insertionOrderSurvivesUpdates() async {
    // The user is watching this list render; re-ordering on update would make
    // the displayed plan jump around between turns.
    let store = LiveTodoStore()
    await LiveTodoWrite.apply(
        updates: [update("z"), update("m"), update("a")],
        merge: true,
        to: store
    )
    await LiveTodoWrite.apply(updates: [update("m", status: .completed)], merge: true, to: store)
    #expect(await store.todos.map(\.id) == ["z", "m", "a"])
}

@Test func replaceDropsEverythingNotResent() async {
    let store = LiveTodoStore()
    await LiveTodoWrite.apply(
        updates: [update("a", content: "First"), update("b", content: "Second")],
        merge: true,
        to: store
    )
    await LiveTodoWrite.apply(
        updates: [update("c", content: "Only one now")],
        merge: false,
        to: store
    )
    #expect(await store.todos.map(\.id) == ["c"])
}

@Test func anItemWithNoContentFallsBackToItsID() async {
    // Better a row labelled by its id than a blank row in the user's plan.
    let store = LiveTodoStore()
    await LiveTodoWrite.apply(updates: [update("run-tests")], merge: true, to: store)
    #expect(await store.todos.first?.content == "run-tests")

    let empty = LiveTodoStore()
    await LiveTodoWrite.apply(updates: [update("x", content: "")], merge: true, to: empty)
    #expect(await empty.todos.first?.content == "x")
}

// MARK: - Summary

@Test func summaryRendersUpstreamsTaggedLines() {
    let summary = LiveTodoWrite.summarize([
        LiveTodoItem(id: "a", content: "First", status: .completed),
        LiveTodoItem(id: "b", content: "Second", status: .inProgress),
    ])
    #expect(summary == "- [completed] a: First\n- [in_progress] b: Second\n")
}

@Test func anEmptyListSaysSoRatherThanRenderingNothing() {
    #expect(LiveTodoWrite.summarize([]) == "No tasks currently tracked.")
}

// MARK: - Wire shape

@Test func todosSerializeToTheWorkspaceRPCShape() async {
    let store = LiveTodoStore()
    await LiveTodoWrite.apply(
        updates: [update("a", content: "First", status: .inProgress)],
        merge: true,
        to: store
    )
    let wire = await store.summaryWire()
    #expect(wire.count == 1)
    #expect(wire[0].id == "a")
    #expect(wire[0].content == "First")
    // `workspace.list_todos` speaks the snake_case tag.
    #expect(wire[0].status == "in_progress")
}

// MARK: - Catalog

@Test func todoWriteIsCataloguedAsReadScoped() {
    let spec = BuiltinToolCatalog.sessionStateTools.first {
        $0.qualifiedId == BuiltinToolCatalog.todoWriteQualifiedId
    }
    // Read-scoped on purpose: a planning agent under a read-only capability
    // mode still has to be able to record its plan.
    #expect(spec?.kind == .read)
    #expect(spec?.id == "todo_write")
}
