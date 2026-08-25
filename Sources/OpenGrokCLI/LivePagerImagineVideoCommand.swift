// LivePagerImagineVideoCommand.swift
//
// `/imagine-video` injects the upstream video-generation workflow into a
// normal model turn; it never calls a tool directly. Registration follows the
// actual advertised `image_to_video` tool so sessions that cannot fulfill the
// instruction do not expose an unusable command.
//
// Rust reference, pin 00e176c8:
// `xai-grok-pager/src/slash/commands/imagine_video.rs:9-55`.

import OpenGrokPager
import OpenGrokToolsAPI

enum LiveImagineVideoCommand {
    static func registrations(
        advertisedToolNames: Set<String>
    ) -> [OpenGrokPagerCommandRegistration] {
        guard advertisedToolNames.contains(imageToVideoToolName) else { return [] }
        return [OpenGrokPagerCommandRegistration(
            name: imagineVideoCommandName,
            summary: "Generate a video from a text description",
            usage: "/imagine-video <description>"
        )]
    }

    static func outcome(rawArgumentTail: String) -> PagerLocalCommandOutcome {
        let prompt = rawArgumentTail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return .notice(imagineVideoUsageMessage())
        }
        return .submit(imagineVideoInstruction(prompt))
    }
}
