// SchedulerState.swift
//
// Open Grok — Swift port of `SchedulerState` (`scheduler/types.rs:292-305`)
// plus the in-memory create/update/delete/list state machine that upstream
// hosts inside `SchedulerActor::handle_command` (`scheduler/actor.rs:770-883`).
//
// Upstream splits the two: the struct is the persisted value, the actor owns
// the mutations (plus versioning, notifications, and durable-removal
// barriers). This port keeps the mutations on the value type so they are
// deterministic and directly testable; the runtime slice wraps this in its
// actor and owns everything transactional. The occurrence journal
// (`types.rs:297-302`) is deliberately not ported here — it exists to dedupe
// replayed fires, which is actor territory. Decoding ignores the
// `occurrenceJournal` key; encoding omits it, which matches upstream's
// `skip_serializing_if = "is_empty"` for the empty journal.

import Foundation

/// Resource-store address of the persisted scheduler state, from
/// `register_resource!("grok_build", "Scheduler", SchedulerState)`
/// (`types.rs:305`). The runtime slice keys its persistence on these.
public enum SchedulerResourceKey {
    public static let namespace = "grok_build"
    public static let name = "Scheduler"
}

/// Persisted scheduler state and its in-memory task-list state machine.
public struct SchedulerState: Codable, Equatable, Sendable {
    /// Hard cap on concurrent tasks, from `MAX_SCHEDULED_TASKS`
    /// (`actor.rs:26`), enforced on create (`actor.rs:780-782`). Distinct
    /// from `MAX_SCHEDULER_TRANSITIONS` (`types.rs:234`), which caps version
    /// -clock reservations and only coincidentally shares the value 50.
    public static let maxScheduledTasks = 50

    public var tasks: [ScheduledTask]

    public init(tasks: [ScheduledTask] = []) {
        self.tasks = tasks
    }

    /// Append a task, enforcing the cap. Port of the in-memory half of
    /// `SchedulerCommand::Create` (`actor.rs:772-790`).
    public mutating func create(_ task: ScheduledTask) throws {
        if tasks.count >= Self.maxScheduledTasks {
            throw SchedulerError.taskLimitReached(Self.maxScheduledTasks)
        }
        tasks.append(task)
    }

    /// Patch a task in place. Port of the in-memory half of
    /// `SchedulerCommand::Update` (`actor.rs:792-835`):
    ///
    /// - Unknown id throws `taskNotFound` (`actor.rs:805-808`); update never
    ///   falls back to create.
    /// - A *changed* prompt is a new job: it sets `chainResetPending` and
    ///   zeroes `iterationsSinceFresh` (`actor.rs:811-819`). Re-sending the
    ///   identical prompt does not reset the chain.
    /// - An interval change keeps the schedule's phase, except when the new
    ///   interval would make the task already overdue — then the anchor is
    ///   reset to `now` so it does not fire instantly (`actor.rs:822-827`).
    ///   This is the one mutation that needs the clock.
    @discardableResult
    public mutating func update(
        id: String,
        prompt: String?,
        intervalSecs: UInt64?,
        now: Date
    ) throws -> ScheduledTask {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            throw SchedulerError.taskNotFound(id)
        }
        if let prompt {
            if prompt != tasks[index].prompt {
                tasks[index].chainResetPending = true
                tasks[index].iterationsSinceFresh = 0
            }
            tasks[index].prompt = prompt
        }
        if let intervalSecs {
            tasks[index].intervalSecs = intervalSecs
            if tasks[index].nextFireAt() <= now {
                tasks[index].lastFiredAt = now
            }
        }
        return tasks[index]
    }

    /// Remove a task by id, reporting whether it existed. Port of the
    /// in-memory half of `SchedulerCommand::Delete`: a missing id is not an
    /// error — upstream replies `Ok(false)` (`actor.rs:854-856`). The
    /// durable-removal barrier around the upstream delete is actor territory.
    public mutating func delete(id: String) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else {
            return false
        }
        tasks.remove(at: index)
        return true
    }

    /// Snapshot of the current tasks, in creation order. Port of the
    /// in-memory half of `SchedulerCommand::List` (`actor.rs:871-881`).
    public func list() -> [ScheduledTask] {
        tasks
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case tasks
    }

    /// `tasks` carries `#[serde(default)]` upstream (`types.rs:295-296`), so
    /// an empty or journal-only state document decodes to no tasks.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decodeIfPresent([ScheduledTask].self, forKey: .tasks) ?? []
    }
}
