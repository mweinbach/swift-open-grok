// SlashCommands.swift
//
// Open Grok — Swift port of `xai-grok-tools-api/src/slash_commands.rs`.
//
// Canonical slash-command wording shared by every front-end so expansions
// cannot drift.

import Foundation

/// Canonical tool name advertised by the scheduler create tool.
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

/// Build the model instruction that `/loop` expands into for `args`.
public func loopScheduleInstruction(_ args: String) -> String {
    """
    # /loop -- schedule a recurring prompt

    Parse the input below into an interval and a prompt, then schedule it with scheduler_create.

    ## Deriving the interval
    Read how often to run from the user's request — however they phrase it — and convert it
    to a compact `<number><unit>` string, where unit is one of `s` (seconds), `m` (minutes),
    `h` (hours), or `d` (days). The interval may appear at the start or end of the request;
    extract it and use the remaining text as the prompt.

    The minimum interval is 60 seconds; shorter values are raised to 60s, so tell the user if that applies.

    If the request contains no interval at all, ask the user how often it should run before
    scheduling. Do NOT invent or assume a default interval.

    ## Action
    1. Call scheduler_create with: interval (the compact string you derived), prompt,
       recurring: true, fire_immediately: true. If the interval is unparseable, the tool
       returns an error — fix the interval string rather than guessing.
    2. Confirm: what's scheduled, the cadence, that it auto-expires after 7 days,
       and that they can cancel with scheduler_delete (include the job ID).
    3. Do NOT execute the prompt inline. The scheduler will fire it immediately.

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
