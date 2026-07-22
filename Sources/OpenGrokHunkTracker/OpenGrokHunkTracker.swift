// OpenGrokHunkTracker.swift
//
// Track file hunks with explicit agent/session attribution.
// Port of xai-hunk-tracker.
//
// Invariant: filesystem notifications are never authorship evidence.
// Only `recordAgentWrite` creates `.agentEdit` sources.

import Foundation
