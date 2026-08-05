// LiveTodoTools.swift
//
// `todo_write` — the structured task list the user watches live.
//
// Upstream ships it in grok-build, codex, concise, plan and orchestrator, and it
// is the *only* tool in the `plan` preset beyond read/list/grep: upstream treats
// a todo list as the minimum viable state for a planning agent. Swift advertised
// nothing, so a plan-preset session had no way to record or show a plan at all.
//
// Port of `grok_build::TodoWriteTool`
// (`xai-grok-tools/src/implementations/grok_build/todo/mod.rs`).
//
// State is per session and in-memory, held by `LiveTodoStore`. Upstream keeps it
// in `State<TodoState>` on the session's Resources with the same lifetime.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokWorkspaceTypes

// MARK: - State

enum LiveTodoStatus: String, Sendable, Equatable, CaseIterable {
    case pending
    case inProgress = "in_progress"
    case completed
    case cancelled

    /// The tag upstream renders in the summary line.
    var tag: String { "[\(rawValue)]" }

    static func fromCanonical(_ raw: String) -> LiveTodoStatus? {
        LiveTodoStatus(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

struct LiveTodoItem: Sendable, Equatable {
    var id: String
    var content: String
    var status: LiveTodoStatus
}

/// The session's todo list.
///
/// Insertion-ordered on purpose: upstream stores an `IndexMap`, and the user is
/// watching this list render. Re-sorting on update, or losing the order a
/// dictionary would, would make the displayed plan jump around between turns.
actor LiveTodoStore {
    private var order: [String] = []
    private var items: [String: LiveTodoItem] = [:]

    init() {}

    var todos: [LiveTodoItem] {
        order.compactMap { items[$0] }
    }

    var isEmpty: Bool { order.isEmpty }

    func clear() {
        order.removeAll()
        items.removeAll()
    }

    func upsert(_ item: LiveTodoItem) {
        if items[item.id] == nil { order.append(item.id) }
        items[item.id] = item
    }

    /// Partial update of an existing item. Returns false when the id is unknown,
    /// which is the caller's signal to insert instead.
    func update(id: String, content: String?, status: LiveTodoStatus?) -> Bool {
        guard var existing = items[id] else { return false }
        // An empty content string means "leave it alone", not "blank it".
        if let content, !content.isEmpty { existing.content = content }
        if let status { existing.status = status }
        items[id] = existing
        return true
    }

    /// The slim DTO the workspace RPC (`workspace.list_todos`) already speaks,
    /// so post-compaction `<system-reminder>` state has a shape to serialize.
    func summaryWire() -> [TodoSummaryWire] {
        todos.map { TodoSummaryWire(id: $0.id, content: $0.content, status: $0.status.rawValue) }
    }
}

// MARK: - Errors

enum LiveTodoError: Error, Equatable, CustomStringConvertible {
    case duplicateID(String)
    case missingID

    var description: String {
        switch self {
        case .duplicateID(let id): return "Duplicate Todo ID in response: \(id)"
        case .missingID: return "Missing Todo ID"
        }
    }
}

// MARK: - Apply

enum LiveTodoWrite {
    static let toolName = "todo_write"

    /// Upstream's description, which is doing real work: it tells the model the
    /// user can see the list, which is the whole reason to keep it current.
    static let description = """
        Create and manage a structured task list. The user sees this list live — it is your primary way to show progress.

        Use for any task with 3+ steps. Skip for trivial single-step work.
        """

    static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "merge": .object([
                "type": .string("boolean"),
                "description": .string("Optional. When true (default), merges the provided todos into the existing list by id — send only the items you are changing, and to flip status without changing content send just id + status. When false, the provided todos replace the existing list."),
            ]),
            "todos": .object([
                "type": .string("array"),
                "description": .string("Array of todo items to write to the workspace"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("Unique identifier for the todo item"),
                        ]),
                        "content": .object([
                            "type": .string("string"),
                            "description": .string("The description/content of the todo item"),
                        ]),
                        "status": .object([
                            "type": .string("string"),
                            "enum": .array(LiveTodoStatus.allCases.map { .string($0.rawValue) }),
                            "description": .string("The status of the todo item: pending, in_progress, completed, or cancelled"),
                        ]),
                    ]),
                    "required": .array([.string("id")]),
                ]),
            ]),
        ]),
        "required": .array([.string("todos")]),
    ])

    /// One parsed entry of the `todos` array.
    struct Update: Sendable, Equatable {
        var id: String
        var content: String?
        var status: LiveTodoStatus?

        /// Upstream treats a missing *or empty* content the same way.
        var hasNoContent: Bool { content?.isEmpty ?? true }
    }

    static func parseUpdates(_ value: JSONValue?) throws -> [Update] {
        guard case .array(let items)? = value else { return [] }
        var updates: [Update] = []
        var seen: Set<String> = []
        for item in items {
            guard case .object(let object) = item,
                  case .string(let rawID)? = object["id"]
            else {
                throw LiveTodoError.missingID
            }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { throw LiveTodoError.missingID }
            guard seen.insert(id).inserted else {
                throw LiveTodoError.duplicateID(id)
            }
            var content: String?
            if case .string(let raw)? = object["content"] { content = raw }
            var status: LiveTodoStatus?
            if case .string(let raw)? = object["status"] {
                status = LiveTodoStatus.fromCanonical(raw)
            }
            updates.append(Update(id: id, content: content, status: status))
        }
        return updates
    }

    /// `merge` defaults to **true**: the model is expected to send only what
    /// changed. Getting this backwards would silently discard the rest of the
    /// user's visible plan on every partial update.
    static func parseMerge(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool(let flag): return flag
        case .string(let raw):
            // Lenient, matching upstream's `deserialize_lenient_bool`.
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "false", "0", "no", "off": return false
            default: return true
            }
        default: return true
        }
    }

    static func apply(
        updates: [Update],
        merge: Bool,
        to store: LiveTodoStore
    ) async {
        if !merge { await store.clear() }
        for update in updates {
            if merge,
               await store.update(id: update.id, content: update.content, status: update.status) {
                continue
            }
            // A new item, or a replace. An update that carried no content falls
            // back to its own id, so the list never renders a blank row.
            await store.upsert(LiveTodoItem(
                id: update.id,
                content: update.hasNoContent ? update.id : (update.content ?? update.id),
                status: update.status ?? .pending
            ))
        }
    }

    static func summarize(_ todos: [LiveTodoItem]) -> String {
        guard !todos.isEmpty else { return "No tasks currently tracked." }
        return todos.map { "- \($0.status.tag) \($0.id): \($0.content)" }
            .joined(separator: "\n") + "\n"
    }
}

// MARK: - Handler

/// `ToolHandler` for `todo_write`.
///
/// Read-scoped upstream despite mutating the list: it touches no file and runs
/// no process, so it carries `ToolScope::Read` and never prompts. Keeping that
/// matters — a planning agent under a read-only capability mode still has to be
/// able to record its plan.
struct LiveTodoToolHandler: ToolHandler {
    let store: LiveTodoStore

    func invoke(
        clientName: String,
        args: JSONValue,
        ctx: ToolCallContext,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        _ = ctx
        _ = resources
        guard let toolId = try? ToolId(clientName) else {
            return .failure(.invalidArguments("todo tool name is not a valid ToolId"))
        }
        guard case .object(let object) = args else {
            return .failure(.invalidArguments("todo_write requires an object argument"))
        }

        let updates: [LiveTodoWrite.Update]
        do {
            updates = try LiveTodoWrite.parseUpdates(object["todos"])
        } catch let error as LiveTodoError {
            return .failure(.invalidArguments(error.description))
        } catch {
            return .failure(.invalidArguments(String(describing: error)))
        }

        await LiveTodoWrite.apply(
            updates: updates,
            merge: LiveTodoWrite.parseMerge(object["merge"]),
            to: store
        )

        let todos = await store.todos
        let summary = LiveTodoWrite.summarize(todos)
        return .success(TypedToolOutput(
            toolId: toolId,
            value: .object([
                "summary": .string(summary),
                "todos": .array(todos.map {
                    .object([
                        "id": .string($0.id),
                        "content": .string($0.content),
                        "status": .string($0.status.rawValue),
                    ])
                }),
            ]),
            modelOutput: [.text(text: summary)]
        ))
    }
}
