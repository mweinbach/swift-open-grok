// ScheduledTaskInfo.swift
//
// Open Grok — Swift port of the pager display DTO `ScheduledTaskInfo`
// (`xai-grok-pager/src/app/agent.rs:351-362`). The `/tasks` pane render and
// the `/loop` preview consume this shape; it is display-only and never
// persisted, which is why it carries pre-rendered strings (`humanSchedule`,
// `nextFireAt`) rather than the raw task fields.

import Foundation

/// State for a scheduled (loop) task, displayed in the tasks pane.
public struct ScheduledTaskInfo: Equatable, Sendable {
    public var taskId: String
    public var prompt: String
    public var humanSchedule: String
    /// Upstream stores a monotonic `std::time::Instant` here for elapsed-age
    /// display. This package's macOS 12 floor predates `ContinuousClock`
    /// (13+), and a `Date` keeps the field testable against the same
    /// injectable clock as the rest of this library. The cost: a wall-clock
    /// jump (NTP, manual set) can skew a displayed age where upstream's
    /// could not. Recorded divergence.
    public var createdAt: Date
    public var nextFireAt: String?
    /// Tag shown in the tasks pane (e.g. "loop", "check").
    public var tag: String
    public var lastSubagentId: String?

    public init(
        taskId: String,
        prompt: String,
        humanSchedule: String,
        createdAt: Date,
        nextFireAt: String?,
        tag: String,
        lastSubagentId: String?
    ) {
        self.taskId = taskId
        self.prompt = prompt
        self.humanSchedule = humanSchedule
        self.createdAt = createdAt
        self.nextFireAt = nextFireAt
        self.tag = tag
        self.lastSubagentId = lastSubagentId
    }
}
