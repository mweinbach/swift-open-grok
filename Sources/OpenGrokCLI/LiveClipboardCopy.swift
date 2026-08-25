import Foundation
import OpenGrokFileUtils
import OpenGrokTerminalCore
import OpenGrokWebMediaTools

enum LiveClipboardCopy {
    typealias NativeWriter = (String, [String: String]) throws -> Void

    enum Delivery: Equatable {
        case native(backup: URL?)
        case terminal(backup: URL?)
        case file(URL)
    }

    enum Failure: Error, Equatable {
        case noAvailableDestination
    }

    static func copy(
        _ text: String,
        environment: [String: String],
        nativeWrite: NativeWriter? = nil,
        writeEscape: (Data) throws -> Void
    ) throws -> Delivery {
        let writer = nativeWrite ?? writeNative
        let nativeSucceeded: Bool
        do {
            try writer(text, environment)
            nativeSucceeded = true
        } catch {
            nativeSucceeded = false
        }

        let backup: URL?
        if let destination = fallbackPath(environment: environment) {
            do {
                try AtomicFile.write(destination, contents: text, options: .ownerOnly)
                backup = destination
            } catch {
                backup = nil
            }
        } else {
            backup = nil
        }

        let insideTmux = environment["TMUX"]?.isEmpty == false
        let remote = environment["SSH_CONNECTION"]?.isEmpty == false
            || environment["SSH_CLIENT"]?.isEmpty == false
            || environment["SSH_TTY"]?.isEmpty == false
        let hasWrapSink = environment["GROK_OSC52_SINK"] != nil
            || environment["LC_GROK_OSC52_SINK"] != nil
        #if os(Linux)
        let alwaysEmit = true
        #else
        let alwaysEmit = false
        #endif

        let shouldEmit = environment["GROK_CLIPBOARD_NO_OSC52"] == nil
            && (alwaysEmit || insideTmux || remote || hasWrapSink || !nativeSucceeded)
        var terminalSucceeded = false
        if shouldEmit {
            do {
                try writeEscape(osc52Sequence(text: text, tmuxPassthrough: insideTmux))
                terminalSucceeded = true
            } catch {
                if !nativeSucceeded, backup == nil {
                    throw error
                }
            }
        }

        if nativeSucceeded {
            return .native(backup: backup)
        }
        if terminalSucceeded {
            return .terminal(backup: backup)
        }
        if let backup {
            return .file(backup)
        }
        throw Failure.noAvailableDestination
    }

    static func fallbackPath(environment: [String: String]) -> URL? {
        if let custom = environment["GROK_COPY_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            let expanded: String
            if custom == "~" || custom.hasPrefix("~/") {
                guard let home = environment["HOME"], home.hasPrefix("/") else {
                    return nil
                }
                expanded = home + custom.dropFirst()
            } else {
                expanded = custom
            }
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }

        if let state = environment["OPENGROK_HOME"], state.hasPrefix("/") {
            return URL(fileURLWithPath: state, isDirectory: true)
                .appendingPathComponent("last-copy.txt")
        }

        guard let home = environment["HOME"], home.hasPrefix("/") else {
            return nil
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".opengrok", isDirectory: true)
            .appendingPathComponent("last-copy.txt")
    }

    private static func writeNative(
        _ text: String,
        environment: [String: String]
    ) throws {
        let provider = SystemClipboardProvider(environment: environment)
        guard provider.capabilityStatus()[.clipboardText] == true else {
            throw Failure.noAvailableDestination
        }

        let commands: [(String, [String])]
        switch provider.platform {
        case .macOS:
            commands = [("pbcopy", [])]
        case .linux:
            var available: [(String, [String])] = []
            if environment["WAYLAND_DISPLAY"]?.isEmpty == false {
                available.append(("wl-copy", []))
            }
            if environment["DISPLAY"]?.isEmpty == false {
                available.append(("xclip", ["-selection", "clipboard"]))
                available.append(("xsel", ["--clipboard", "--input"]))
            }
            commands = available
        case .windows:
            commands = [("powershell.exe", [
                "-NoProfile", "-Command", "Set-Clipboard -Value ([Console]::In.ReadToEnd())"
            ])]
        case .other:
            commands = []
        }

        for (executable, arguments) in commands {
            do {
                let result = try provider.commandRunner.run(
                    executable: executable,
                    arguments: arguments,
                    input: Data(text.utf8),
                    timeout: provider.commandTimeout
                )
                if result.succeeded {
                    return
                }
            } catch {
                continue
            }
        }
        throw Failure.noAvailableDestination
    }
}
