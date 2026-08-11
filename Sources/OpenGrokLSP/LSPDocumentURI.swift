import Foundation

public enum LSPDocumentURI {
    /// Build a canonical `file://` URI for an absolute or workspace-relative path.
    public static func fileURI(for path: String, workspaceRoot: String) -> String {
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: workspaceRoot))
        }
        return url.standardizedFileURL.absoluteString
    }

    public static func resolvePath(_ path: String, workspaceRoot: String) -> String {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: workspaceRoot))
            .standardizedFileURL.path
    }
}
