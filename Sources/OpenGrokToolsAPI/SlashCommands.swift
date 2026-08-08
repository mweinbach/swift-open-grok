// SlashCommands.swift
//
// Open Grok — Swift port of `xai-grok-tools-api/src/slash_commands.rs`.
//
// Canonical slash-command wording shared by every front-end so expansions
// cannot drift.

import Foundation

/// Canonical tool name advertised by the scheduler create tool. Gating code
/// (shell `CommandAvailability`, pager `required_tools`, host command lists)
/// keys `/loop` availability on this name.
public let schedulerCreateToolName = "scheduler_create"

/// Usage hint shown when `/loop` is invoked with no arguments.
public func loopUsageMessage() -> String {
    """
    Usage: /loop [interval] <prompt>
    Example: /loop 30m check deploy status
    Example: /loop check deploy status every hour

    Tell me how often it should run (e.g. 30m, 1 hour, every 2 days).
    """
}

/// Where a scheduled fire runs, which decides what the stored prompt can rely on.
///
/// Resolved from `[scheduler] background_loops` (env, config, managed policy and
/// remote settings all feed it), so `/loop` describes the runtime the user
/// actually has rather than hedging across both.
public enum LoopFireMode: Sendable, Equatable {
    /// Each fire runs in a detached background subagent that cannot see this
    /// conversation. The default.
    case detached
    /// Each fire runs as a turn in this conversation, where earlier results from
    /// the same task may still be visible.
    case inSession
}

/// Build the model instruction that `/loop` expands into for `args`.
///
/// The model, not brittle host parsing, turns the request into the
/// `scheduler_create` interval, accepting every natural phrasing and erroring
/// on bad input rather than silently defaulting. See `loopUsageMessage()`.
///
/// Only the framing differs by `mode`; the stop condition and length guidance
/// are identical, because both hold wherever the fire runs.
public func loopScheduleInstruction(_ args: String, mode: LoopFireMode) -> String {
    // The rendered text has no indentation on wrapped lines: upstream builds
    // it with Rust `\`-continuations, which strip the continuation line's
    // leading whitespace (`slash_commands.rs:41-96`). Indenting these lines
    // "nicely" here would break byte parity.
    let fireContext: String
    switch mode {
    case .detached:
        fireContext = """
        Each fire runs in a detached background subagent, not in this conversation,
        so the prompt you store must stand on its own.

        ## Writing a prompt that survives a fresh fire
        - Inline the state a fire needs: paths, job/PR/branch ids, the command that checks
        status, and what "healthy" looks like. A fire cannot see this conversation, and
        a long-running task restarts from a short summary every few iterations.
        - Only a short status comes back here, so say what that status must contain.
        """
    case .inSession:
        fireContext = """
        Each fire arrives as a new turn in this conversation, and earlier results from
        the same task may still be above it. The stored prompt is re-sent verbatim every
        time, so write a standing order rather than a one-off request.

        ## Writing a prompt that reads well on every fire
        - Name the state that must not be guessed: paths, job/PR/branch ids, the command
        that checks status, and what "healthy" looks like. This conversation is
        compacted as it grows, so do not rely on details staying visible.
        - Earlier fires may be above you: continue from them instead of restarting.
        """
    }
    return """
    # /loop -- schedule a recurring prompt

    Turn the input below into a scheduler_create call. \(fireContext)
    - Say what one fire does and when it bails: "if still pending, report one line and
    stop." A fire must not poll inline.
    - Give it a stop condition and an exit: "when <condition> holds, report it and call
    scheduler_delete <task_id>." Without that the loop runs until it expires.
    - Keep it short and concrete -- the stored prompt is re-sent on every fire.

    ## Deriving the interval
    Convert the user's cadence -- however phrased, at either end of the request -- into a
    compact `<number><unit>` string (`s`/`m`/`h`/`d`); the remaining text is the prompt.
    The minimum is 60 seconds and shorter values are raised, so say so when it applies.
    If no cadence is given, ask the user how often it should run -- never invent one.

    ## Action
    Schedule from what the user already gave you \u{2014} do not explore the workspace or run
    checks before scheduling; the first fire does that.
    1. Call scheduler_create with the interval, the prompt, and fire_immediately: true.
    If the interval is rejected, fix the string rather than guessing.
    2. Confirm what's scheduled, the cadence, its stop condition, that it auto-expires
    after 7 days, and the task_id to cancel with scheduler_delete.
    3. Do NOT execute the prompt inline. The scheduler fires it immediately.

    ## Wrong tool for the job
    - "Tell me when X finishes" -> a background command or watch tool that wakes you on
    the event, not a recurring loop that re-checks on a timer.
    - "Do X once in N minutes" -> background `sleep <secs> && <command>`; scheduling is
    recurring-only.

    ## Changing an existing loop
    Call scheduler_create with its task_id and only the changed fields; do not
    delete and recreate. If later work changes what a loop should do, update its
    prompt the same way.

    ## Input
    \(args)
    """
}

/// Canonical name of the image generation tool; gates `/imagine`.
public let imageGenToolName = "image_gen"

/// Advertised name of the /imagine command.
public let imagineCommandName = "imagine"

/// Canonical name of the image-to-video tool; gates `/imagine-video`.
public let imageToVideoToolName = "image_to_video"

/// Advertised name of the /imagine-video command.
public let imagineVideoCommandName = "imagine-video"

/// Usage hint shown when `/imagine` is invoked with no arguments.
public func imagineUsageMessage() -> String {
    """
    Usage: /imagine <description>
    Provide a text description to generate an image.
    """
}

/// Build the model instruction that `/imagine` expands into for `prompt`.
public func imagineInstruction(_ prompt: String) -> String {
    """
    Call the image_gen tool immediately, passing the user's prompt below \
    verbatim — do not rewrite, embellish, or expand it. \
    After the tool completes, briefly acknowledge and mention \
    where the image was saved.

    Prompt: \(prompt)
    """
}

/// Usage hint shown when `/imagine-video` is invoked with no arguments.
public func imagineVideoUsageMessage() -> String {
    """
    Usage: /imagine-video <description>
    Provide a text description to generate a video.
    """
}

/// Video workflow guidance injected by `/imagine-video`.
private let imagineVideoSkill = """
# Imagine Video

Video starts from an image — there is no text-to-video tool. \
Default to `image_to_video`; use `reference_to_video` only when the user \
explicitly asks for it or a shot genuinely needs multiple reference images.

## Default: single clip

Unless the user asks for a long video, multiple scenes, or a multi-shot sequence, \
generate **one** video:

1. Create a source image with `image_gen` that stages the first frame \
(composition, subject, lighting).
2. Call `image_to_video` with that image and a short prompt describing the motion \
or camera move (1–2 sentences, present tense).
3. After the tool completes, mention the saved file path so the user can find it.

## Longer / multi-shot videos

When the user requests a longer video, multiple scenes, or a narrative sequence:

1. **Plan the story as shots** — break the idea into distinct shots, one beat each.
2. **Favor frequent, short shots** — prefer more 6s clips over fewer long ones; more cuts keep it dynamic.
3. **Create each shot's source image** with `image_gen` (or `image_edit` to combine references), keeping characters and settings consistent across shots.
4. **Animate each shot with `image_to_video`** — the source image becomes frame 1.
5. **Assemble with FFmpeg** using stream copy (`ffmpeg -f concat ... -c copy` — never re-encode). \
Keep every shot at the same resolution and frame rate so the concat works. \
After assembly, mention the final output path.

## Shot guidance

- **Prompt-craft:** one short, vivid moment in present tense with a clear camera movement, in 1–2 sentences.
- **Minimal but interesting:** one clear subject, one simple motion or camera move per shot. Avoid complex multi-action animation; make the shot compelling through composition, lighting, and a strong moment.
- **Complex source image?** Intricate frames (busy geometry, fine detail, heavy reflections) warp when animated. Keep the subject fixed and move only the camera (slow push-in, orbit, or parallax), or break into simpler shots. For new shots, generate a simpler, animation-friendly base image rather than animating a busy one.
- **`image_to_video` animates from frame 1** — stage the first frame with `image_gen`/`image_edit` before animating.
- **Aspect ratio:** set it on the source image (`image_gen` `aspect_ratio`); don't re-crop an existing video.
- **Duration:** 6s or 10s only (prefer 6s); round to the nearest.
- **Real people:** reference-first — drive the video from a verified reference image; never animate a named person without one.
- Don't loop the same clip unless asked.
"""

/// Build the model instruction that `/imagine-video` expands into for `prompt`.
public func imagineVideoInstruction(_ prompt: String) -> String {
    """
    \(imagineVideoSkill)

    User prompt: \(prompt)
    """
}

public let updateGoalToolName = "update_goal"

public let goalCommandName = "goal"

/// Bare subcommand tokens reserved for goal lifecycle control.
public let goalReservedSubcommands: [String] = ["status", "pause", "resume", "clear", "edit"]

public func goalUsageMessage() -> String {
    """
    Usage: /goal <objective>
    Set an objective to work toward until it is complete.
    """
}

public func goalInstruction(_ objective: String) -> String {
    """
    # /goal -- pursue an objective

    A goal has been set: \(objective)

    Work directly on this goal and carry it as far as you can. Deliver \
    everything the user asked for yourself: no follow-up questions, no \
    manual steps left for the user. If the conversation continues, keep \
    pursuing the goal until it is complete.

    TRACKING: break the objective into concrete steps and track them \
    (use your todo tool if one is available), marking each done as you \
    finish it.

    VERIFY AS YOU GO: test each change on the real path before moving on. \
    A completion claim must be backed by evidence produced in this \
    session, not assumptions.

    Call update_goal(completed: true, message: "summary") ONLY when the \
    goal is fully achieved. Call update_goal(blocked_reason: "reason") \
    only when truly stuck after 3+ consecutive failed attempts at the \
    same problem. Call update_goal(message: "status note") to log \
    progress along the way. If update_goal returns an error, continue \
    working the goal and report status in your reply instead.

    Start now.
    """
}
