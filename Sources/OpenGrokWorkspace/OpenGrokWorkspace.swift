// OpenGrokWorkspace.swift
//
// Core workspace library (Swift port of `xai-grok-workspace`):
// permissions, path boundary, folder trust, and local ops.
//
// Full FS/VCS/hub server runtime continues to land in later slices; this
// target establishes the enforceable security boundary required before
// concrete tools and the session runtime are implemented.

import Foundation
