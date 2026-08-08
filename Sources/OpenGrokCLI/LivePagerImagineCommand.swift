// LivePagerImagineCommand.swift
//
// The `/imagine` slash command — upstream `ImagineCommand`
// (`xai-grok-pager/src/slash/commands/imagine.rs:12-55`). The command is a
// prompt injection, not a tool call: empty args echo the usage message;
// anything else expands to `imagineInstruction(prompt)` — the model
// instruction telling the agent to call `image_gen` with the prompt verbatim
// (`xai-grok-tools-api/src/slash_commands.rs:117-125`) — submitted as the
// turn's prompt, upstream's `CommandResult::InjectSkill` (imagine.rs:47-54).
//
// Registration is gated on the session's advertised toolset actually
// carrying `image_gen` — upstream's `required_tools: [IMAGE_GEN_TOOL_NAME]`
// (imagine.rs:8, 37-39) resolved against `registry.set_available_tools`. The
// gate reads the live executor's advertised list, not the availability
// resolution that fed it, so it inherits every reason the tool might not be
// live (disabled config, missing credentials, a failed `ImageGenClient`
// construction, an agent-profile filter): a session that cannot act on the
// injection never lists the row (AGENTS.md §4 — no dead dropdown entries).

import OpenGrokPager
import OpenGrokToolsAPI

enum LiveImagineCommand {
    /// The conditional registration the interactive composition installs.
    /// Name is `IMAGINE_COMMAND_NAME` (imagine.rs:13-15), description
    /// "Generate an image from a text description" (imagine.rs:17-19) and
    /// usage "/imagine <description>" (imagine.rs:21-23), all verbatim.
    /// Upstream's `arg_placeholder("description of the image to generate")`
    /// (imagine.rs:33-35) has no port channel — `PagerCommandDefinition`
    /// carries no placeholder field — so the usage string is the only
    /// argument hint (recorded divergence, shared with `/docs`/`/fork`).
    static func registrations(
        advertisedToolNames: Set<String>
    ) -> [OpenGrokPagerCommandRegistration] {
        guard advertisedToolNames.contains(imageGenToolName) else { return [] }
        return [OpenGrokPagerCommandRegistration(
            name: imagineCommandName,
            summary: "Generate an image from a text description",
            usage: "/imagine <description>"
        )]
    }

    /// `ImagineCommand::run` (imagine.rs:41-55): `args.trim()`; empty →
    /// the usage message (`CommandResult::Message`, mapped onto the
    /// transcript notice channel like every command message here);
    /// otherwise `imagine_instruction(prompt)` submitted as the turn's
    /// prompt. The caller passes the RAW argument tail (the `/fork`/`/docs`
    /// convention) so prose reaches the instruction as typed — the
    /// tokenizer's rejoin would unquote and re-space it.
    static func outcome(rawArgumentTail: String) -> PagerLocalCommandOutcome {
        let prompt = rawArgumentTail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return .notice(imagineUsageMessage())
        }
        return .submit(imagineInstruction(prompt))
    }
}
