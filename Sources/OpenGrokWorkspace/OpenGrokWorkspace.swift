// OpenGrokWorkspace.swift
//
// Core workspace library (Swift port of `xai-grok-workspace` and `xai-grok-workspace-daemon`):
// - Permission pipeline (plan gate → PreToolUse hooks → plan-file auto-approve
//   → permission engine), rule DSL, bash segmentation, folder trust, path
//   boundary, path/resource locks, and local FS/process mediation.
// - Process lifecycle: self-daemonization (double-fork + `setsid()` session separation,
//   stdio redirection, OOM protection), single-instance pidfile locking/takeover.
// - In-sandbox preview-proxy supervision (child process lifecycle, exponential backoff,
//   activity scraper and metric scrapers).

import Foundation

