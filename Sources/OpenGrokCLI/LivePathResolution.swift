import Foundation
import OpenGrokPaths

func liveResolveURL(_ path: String, relativeTo cwd: String) -> URL {
    if path.hasPrefix("/") || isAbsolutePath(path) {
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    return URL(fileURLWithPath: cwd, isDirectory: true)
        .appendingPathComponent(path)
        .standardizedFileURL
}

func liveResolveWorkingDirectory(_ path: String?) throws -> URL {
    let processCwd = FileManager.default.currentDirectoryPath
    let url = liveResolveURL(path ?? processCwd, relativeTo: processCwd)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
          isDirectory.boolValue
    else {
        throw CLIApplicationError.failed("working directory does not exist: \(url.path)")
    }
    return url
}
