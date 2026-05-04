import Foundation

public enum WorkspacePathSecurity {
    public static func childURL(baseDirectory: URL, relativeName: String, workspaceURL: URL) -> URL? {
        let trimmed = relativeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }

        let targetURL = baseDirectory.appendingPathComponent(trimmed).standardizedFileURL
        guard isURL(targetURL, insideOrSame: workspaceURL) else { return nil }
        return targetURL
    }

    public static func isURL(_ childURL: URL, insideOrSame parentURL: URL) -> Bool {
        let childPath = childURL.standardizedFileURL.path
        let parentPath = parentURL.standardizedFileURL.path
        let parentPrefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath == parentPath || childPath.hasPrefix(parentPrefix)
    }
}
