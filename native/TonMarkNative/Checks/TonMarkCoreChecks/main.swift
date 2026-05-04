import Foundation
import TonMarkCore

@main
struct TonMarkCoreChecks {
    static func main() throws {
        let workspaceURL = URL(fileURLWithPath: "/tmp/TonMarkTests/workspace", isDirectory: true)
        let draftsURL = workspaceURL.appendingPathComponent("drafts", isDirectory: true)

        try check(
            WorkspacePathSecurity.childURL(
                baseDirectory: draftsURL,
                relativeName: "chapter-1.md",
                workspaceURL: workspaceURL
            )?.path == "/tmp/TonMarkTests/workspace/drafts/chapter-1.md",
            "allows nested relative path inside workspace"
        )

        try check(
            WorkspacePathSecurity.childURL(
                baseDirectory: workspaceURL,
                relativeName: "/etc/passwd",
                workspaceURL: workspaceURL
            ) == nil,
            "rejects absolute path"
        )

        try check(
            WorkspacePathSecurity.childURL(
                baseDirectory: workspaceURL,
                relativeName: "../../escape.md",
                workspaceURL: workspaceURL
            ) == nil,
            "rejects parent traversal outside workspace"
        )

        let sibling = URL(fileURLWithPath: "/tmp/TonMarkTests/workspace-other/file.md")
        try check(
            !WorkspacePathSecurity.isURL(sibling, insideOrSame: workspaceURL),
            "does not treat sibling prefix as child"
        )

        print("TonMarkCoreChecks passed")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw CheckFailure(message: message)
        }
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        "Check failed: \(message)"
    }
}
