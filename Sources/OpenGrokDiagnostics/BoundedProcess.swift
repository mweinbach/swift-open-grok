// BoundedProcess.swift
//
// Bounded subprocess adapter shared by the syntax validator and the live
// tmux probe.
//
// Upstream bounds every tmux query at 2 s and every validator run at the
// request's timeout (tmux_probe.rs:6, validator.rs). This port bridges
// `Process.terminationHandler` to a semaphore instead of calling
// `waitUntilExit()`, which can park a run loop forever when the child exits
// before the wait begins (AGENTS.md §2 — this bug wedged serial suites).

import Foundation

enum BoundedProcessOutcome {
    case exited(status: Int32, stdout: Data, stderr: Data)
    case timedOut
    case failedToStart(String)
}

/// Run `executable arguments…` with stdin closed, capturing stdout/stderr,
/// killing the child at `timeout`. Output volumes here are tiny (single
/// option values), so reading after exit cannot deadlock on pipe buffers.
func runBoundedProcess(
    executable: String,
    arguments: [String],
    timeout: TimeInterval
) -> BoundedProcessOutcome {
    let process = Process()
    if executable.contains("/") {
        process.executableURL = URL(fileURLWithPath: executable)
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
    }
    if process.arguments == nil {
        process.arguments = arguments
    }
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = stdout
    process.standardError = stderr

    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }

    do {
        try process.run()
    } catch {
        return .failedToStart(String(describing: error))
    }

    if finished.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        if finished.wait(timeout: .now() + 0.3) == .timedOut {
            #if !os(Windows)
            kill(process.processIdentifier, SIGKILL)
            #endif
            _ = finished.wait(timeout: .now() + 1.0)
        }
        return .timedOut
    }

    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    return .exited(status: process.terminationStatus, stdout: outData, stderr: errData)
}
