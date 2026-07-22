// OpenGrokTextArea.swift
//
// Deterministic, framework-independent text-area primitives for the future
// pager/TUI. Port of xai-ratatui-textarea.
//
// Modules:
//   - EditBuffer / EditCommand / plan-apply editing with grapheme safety
//   - Key classification (emacs-style chords)
//   - TextArea state: wrap, selection, undo/redo, elements, clipboard
//
// No SwiftUI, AppKit, UIKit, or shell dependency.

import Foundation
import OpenGrokTerminalCore
