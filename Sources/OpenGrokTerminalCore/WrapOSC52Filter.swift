import Foundation

/// One ordered result from the streaming clipboard filter used by `open-grok wrap`.
public struct WrapOSC52FilterOutput: Sendable, Equatable {
    public var passthrough = Data()
    public var clipboardPayloads: [Data] = []
    public var hostImageRequests = 0
    public var controlSequences: [Data] = []

    public init() {}
}

/// Ports `xai-grok-pager/src/wrap_filter.rs`: only recognized OSC clipboard
/// operations are consumed; incomplete frames remain buffered across reads.
public struct WrapOSC52Filter: Sendable {
    public static let maximumEscapeBytes = 1024 * 1024
    public static let maximumClipboardBytes = 768 * 1024
    public static let maximumControlSequenceBytes = 128

    private enum State: Sendable {
        case normal
        case escape
        case controlSequence
        case operatingSystemCommand
        case operatingSystemCommandEscape
        case deviceControlString
        case tmuxOperatingSystemCommand
        case tmuxOperatingSystemCommandEscape
    }

    private static let tmuxPrefix = Array("tmux;\u{1b}\u{1b}]".utf8)
    private static let clipboardPrefix = Array("52;".utf8)

    private var state = State.normal
    private var pending: [UInt8] = []

    public init() {}

    public mutating func consume(_ data: Data) -> WrapOSC52FilterOutput {
        var result = WrapOSC52FilterOutput()
        result.passthrough.reserveCapacity(data.count)

        for byte in data {
            switch state {
            case .normal:
                if byte == 0x1b {
                    pending.removeAll(keepingCapacity: true)
                    pending.append(byte)
                    state = .escape
                } else {
                    result.passthrough.append(byte)
                }

            case .escape:
                pending.append(byte)
                switch byte {
                case 0x5d: state = .operatingSystemCommand
                case 0x50: state = .deviceControlString
                case 0x5b: state = .controlSequence
                default: flush(into: &result)
                }

            case .controlSequence:
                pending.append(byte)
                if (0x40...0x7e).contains(byte) {
                    result.controlSequences.append(Data(pending))
                    flush(into: &result)
                } else if byte == 0x1b {
                    pending.removeLast()
                    result.passthrough.append(contentsOf: pending)
                    pending = [0x1b]
                    state = .escape
                } else if !(0x20...0x3f).contains(byte)
                    || pending.count > Self.maximumControlSequenceBytes
                {
                    flush(into: &result)
                }

            case .operatingSystemCommand:
                pending.append(byte)
                if byte == 0x07 {
                    finishOperatingSystemCommand(into: &result)
                } else if byte == 0x1b {
                    state = .operatingSystemCommandEscape
                }

            case .operatingSystemCommandEscape:
                pending.append(byte)
                if byte == 0x5c {
                    finishOperatingSystemCommand(into: &result)
                } else {
                    state = .operatingSystemCommand
                }

            case .deviceControlString:
                pending.append(byte)
                let position = pending.count - 3
                if position < Self.tmuxPrefix.count,
                   byte == Self.tmuxPrefix[position] {
                    if position + 1 == Self.tmuxPrefix.count {
                        state = .tmuxOperatingSystemCommand
                    }
                } else {
                    flush(into: &result)
                }

            case .tmuxOperatingSystemCommand:
                pending.append(byte)
                if byte == 0x1b {
                    state = .tmuxOperatingSystemCommandEscape
                }

            case .tmuxOperatingSystemCommandEscape:
                pending.append(byte)
                if byte == 0x5c {
                    finishTmuxOperatingSystemCommand(into: &result)
                } else {
                    state = .tmuxOperatingSystemCommand
                }
            }

            if pending.count > Self.maximumEscapeBytes {
                flush(into: &result)
            }
        }

        return result
    }

    private mutating func finishOperatingSystemCommand(
        into output: inout WrapOSC52FilterOutput
    ) {
        let body = stripTerminator(Array(pending.dropFirst(2)))
        if body == Array(REQUEST_BODY.utf8) {
            output.hostImageRequests += 1
            reset()
        } else if let payload = clipboardPayload(body) {
            output.clipboardPayloads.append(payload)
            reset()
        } else {
            flush(into: &output)
        }
    }

    private mutating func finishTmuxOperatingSystemCommand(
        into output: inout WrapOSC52FilterOutput
    ) {
        let prefixLength = 2 + Self.tmuxPrefix.count
        guard pending.count >= prefixLength + 2 else {
            flush(into: &output)
            return
        }
        let body = stripTerminator(Array(pending[prefixLength..<(pending.count - 2)]))
        if let payload = clipboardPayload(body) {
            output.clipboardPayloads.append(payload)
            reset()
        } else {
            flush(into: &output)
        }
    }

    private func clipboardPayload(_ body: [UInt8]) -> Data? {
        guard body.starts(with: Self.clipboardPrefix) else { return nil }
        let suffix = body.dropFirst(Self.clipboardPrefix.count)
        guard let separator = suffix.firstIndex(of: 0x3b) else { return nil }
        var encoded = Array(suffix[suffix.index(after: separator)...])
        switch encoded.count % 4 {
        case 1: return nil
        case 2: encoded.append(contentsOf: [0x3d, 0x3d])
        case 3: encoded.append(0x3d)
        default: break
        }
        guard let decoded = Data(base64Encoded: Data(encoded)),
              decoded.count <= Self.maximumClipboardBytes
        else { return nil }
        return decoded
    }

    private func stripTerminator(_ body: [UInt8]) -> [UInt8] {
        if body.suffix(2).elementsEqual([0x1b, 0x5c]) {
            return Array(body.dropLast(2))
        }
        if body.last == 0x07 {
            return Array(body.dropLast())
        }
        return body
    }

    private mutating func flush(into output: inout WrapOSC52FilterOutput) {
        output.passthrough.append(contentsOf: pending)
        reset()
    }

    private mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        state = .normal
    }
}

/// Tracks only modes enabled by the child, so a clean wrapped exit emits no
/// resets and a disconnected child cannot strand the enclosing terminal.
public struct WrapTerminalModeTracker: Sendable {
    private static let trackedModes: Set<Int> = [
        25, 47, 1000, 1002, 1003, 1004, 1005, 1006,
        1015, 1016, 1047, 1049, 2004, 2026,
    ]
    private static let disableOrder = [1000, 1002, 1003, 1005, 1015, 1016, 1006, 2004, 1004]

    private var activeModes: Set<Int> = []
    private var kittyDepth = 0

    public init() {}

    public mutating func observe(_ sequence: Data) {
        let bytes = Array(sequence)
        guard bytes.count >= 3,
              bytes[0] == 0x1b,
              bytes[1] == 0x5b,
              let final = bytes.last
        else { return }
        let body = bytes[2..<(bytes.count - 1)]

        if final == 0x68 || final == 0x6c {
            guard body.first == 0x3f else { return }
            for parameter in body.dropFirst().split(separator: 0x3b) {
                guard let mode = decimal(parameter), Self.trackedModes.contains(mode) else { continue }
                let setting = final == 0x68
                let active = mode == 25 ? !setting : setting
                if active {
                    activeModes.insert(mode)
                } else {
                    activeModes.remove(mode)
                }
            }
        } else if final == 0x75 {
            if body.first == 0x3e {
                kittyDepth = min(kittyDepth + 1, 1024)
            } else if body.first == 0x3c {
                let count = decimal(body.dropFirst()).flatMap { $0 > 0 ? $0 : nil } ?? 1
                kittyDepth = max(0, kittyDepth - count)
            }
        }
    }

    public var restoreBytes: Data {
        var output = Data()
        if activeModes.contains(2026) { append("\u{1b}[?2026l", to: &output) }
        if activeModes.contains(25) { append("\u{1b}[?25h", to: &output) }
        for mode in Self.disableOrder where activeModes.contains(mode) {
            append("\u{1b}[?\(mode)l", to: &output)
        }
        for _ in 0..<kittyDepth { append("\u{1b}[<u", to: &output) }
        for mode in [1047, 47, 1049] where activeModes.contains(mode) {
            append("\u{1b}[?\(mode)l", to: &output)
        }
        return output
    }

    private func decimal<C: Collection>(_ bytes: C) -> Int? where C.Element == UInt8 {
        guard !bytes.isEmpty else { return nil }
        var value = 0
        for byte in bytes {
            guard (0x30...0x39).contains(byte) else { return nil }
            let (scaled, overflowed) = value.multipliedReportingOverflow(by: 10)
            guard !overflowed else { return nil }
            let (next, additionOverflowed) = scaled.addingReportingOverflow(Int(byte - 0x30))
            guard !additionOverflowed else { return nil }
            value = next
        }
        return value
    }

    private func append(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
    }
}
