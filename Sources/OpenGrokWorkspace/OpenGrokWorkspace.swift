// OpenGrokWorkspace.swift
//
// Core workspace library (Swift port of `xai-grok-workspace`):
// permission pipeline (plan gate → PreToolUse hooks → plan-file auto-approve
// → permission engine), rule DSL, bash segmentation, folder trust, path
// boundary, path/resource locks, and local FS/process mediation.
//
// Full FS/VCS/hub server runtime continues to land in later slices; this
// target establishes the enforceable security boundary required before
// concrete tools and the session runtime are implemented.

import Foundation
