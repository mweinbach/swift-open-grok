// CsiFragmentFilter.swift
//
// Reassembles stateful CSI fragments leaked across read boundaries.
// Ported from `crates/codegen/xai-grok-pager/src/app/csi_filter.rs`.

import Foundation

/// Persistent stateful filter that reassembles CSI fragments leaked when a
/// control sequence splits across `read()` boundaries — SGR mouse reports
/// `\e[<…M/m` and focus reports `\e[I`/`\e[O`.
public struct CsiFragmentFilter: Sendable {
    private enum State: Sendable, Equatable {
        case idle
        case bracket
        case lessThan
        case digits1
        case semi1
        case digits2
        case semi2
        case digits3
    }

    private enum AdvanceResult {
        case `continue`(State)
        case complete
        case completeFocus
        case reject
    }

    private var state: State = .idle
    private var tentative: [TerminalInputEvent] = []
    private var lastEventWasEsc: Bool = false
    private var hadEsc: Bool = false

    public init() {}

    public mutating func reset() {
        state = .idle
        tentative.removeAll()
        lastEventWasEsc = false
        hadEsc = false
    }

    public mutating func filter(_ events: [TerminalInputEvent]) -> [TerminalInputEvent] {
        var result: [TerminalInputEvent] = []
        result.reserveCapacity(tentative.count + events.count)
        var escBeforeRun = false

        for ev in events {
            if isBareEscPress(ev) {
                result.append(contentsOf: tentative)
                tentative.removeAll()
                state = .idle
                hadEsc = false
                result.append(ev)
                escBeforeRun = true
                lastEventWasEsc = true
                continue
            }

            if let ch = filterableChar(ev) {
                switch advance(state, ch: ch) {
                case .continue(let nextState):
                    if state == .idle && nextState == .bracket {
                        hadEsc = escBeforeRun || lastEventWasEsc
                    }
                    state = nextState
                    tentative.append(ev)
                    lastEventWasEsc = false

                case .complete:
                    tentative.removeAll()
                    if escBeforeRun, !result.isEmpty, isBareEscPress(result.last!) {
                        result.removeLast()
                    }
                    escBeforeRun = false
                    hadEsc = false
                    state = .idle
                    lastEventWasEsc = false

                case .completeFocus:
                    if escBeforeRun || hadEsc {
                        tentative.removeAll()
                        if escBeforeRun, !result.isEmpty, isBareEscPress(result.last!) {
                            result.removeLast()
                        }
                        let focusEvent: TerminalInputEvent = (ch == "I") ? .focusGained : .focusLost
                        result.append(focusEvent)
                        escBeforeRun = false
                        hadEsc = false
                        state = .idle
                        lastEventWasEsc = false
                    } else {
                        result.append(contentsOf: tentative)
                        tentative.removeAll()
                        state = .idle
                        hadEsc = false
                        result.append(ev)
                        lastEventWasEsc = false
                    }

                case .reject:
                    result.append(contentsOf: tentative)
                    tentative.removeAll()
                    escBeforeRun = false
                    hadEsc = false
                    state = .idle
                    lastEventWasEsc = false
                    switch advance(.idle, ch: ch) {
                    case .continue(let nextState):
                        if nextState == .bracket {
                            hadEsc = false
                        }
                        state = nextState
                        tentative.append(ev)
                    default:
                        result.append(ev)
                    }
                }
            } else {
                result.append(contentsOf: tentative)
                tentative.removeAll()
                state = .idle
                escBeforeRun = false
                hadEsc = false
                lastEventWasEsc = false
                result.append(ev)
            }
        }

        return result
    }

    private func advance(_ currentState: State, ch: Character) -> AdvanceResult {
        switch (currentState, ch) {
        case (.idle, "["):
            return .continue(.bracket)
        case (.bracket, "<"):
            return .continue(.lessThan)
        case (.bracket, "I"), (.bracket, "O"):
            return .completeFocus
        case (.lessThan, let c) where c.isNumber, (.digits1, let c) where c.isNumber:
            return .continue(.digits1)
        case (.digits1, ";"):
            return .continue(.semi1)
        case (.semi1, let c) where c.isNumber, (.digits2, let c) where c.isNumber:
            return .continue(.digits2)
        case (.digits2, ";"):
            return .continue(.semi2)
        case (.semi2, let c) where c.isNumber, (.digits3, let c) where c.isNumber:
            return .continue(.digits3)
        case (.digits3, "M"), (.digits3, "m"):
            return .complete
        default:
            return .reject
        }
    }

    private func isBareEscPress(_ event: TerminalInputEvent) -> Bool {
        switch event {
        case .control(.escape):
            return true
        case .key(let key):
            switch key {
            case .character(let str, let modifiers):
                return (str == "\u{1B}" || str == "Esc" || str == "Escape") && modifiers.isEmpty
            default:
                return false
            }
        default:
            return false
        }
    }

    private func filterableChar(_ event: TerminalInputEvent) -> Character? {
        switch event {
        case .text(let str):
            return str.count == 1 ? str.first : nil
        case .key(let key):
            switch key {
            case .character(let str, let modifiers):
                guard modifiers.subtracting(.shift).isEmpty else { return nil }
                return str.count == 1 ? str.first : nil
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
