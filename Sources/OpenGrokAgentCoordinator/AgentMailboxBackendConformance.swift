// AgentMailboxBackendConformance.swift
//
// The coordinator as the mailbox half of the subagent backend.
//
// Rust wires this by giving `ChannelBackend` mailbox methods that forward
// `SubagentEvent::{ListAgents, SendAgentMessage, WaitAgentMessages}` to the
// shared coordinator actor (task/backend.rs:400-466). This port has no
// channel hop — the tool surface calls the coordinator actor directly — so
// the conformance is the whole adapter: the actor's own `listAgents` /
// `sendAgentMessage` / `waitAgentMessages` already carry the coordinator
// semantics (task/coordinator.rs:536-763).

import OpenGrokAgentControlTools

extension OpenGrokAgentCoordinator: AgentMailboxBackend {}
