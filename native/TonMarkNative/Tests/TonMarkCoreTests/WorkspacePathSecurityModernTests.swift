import Foundation
import Testing
import TonMarkCore

@Test func workspacePathSecurityRejectsSiblingPrefixWithSwiftTesting() {
    let workspaceURL = URL(fileURLWithPath: "/tmp/TonMarkTests/workspace", isDirectory: true)
    let sibling = URL(fileURLWithPath: "/tmp/TonMarkTests/workspace-other/file.md")

    #expect(!WorkspacePathSecurity.isURL(sibling, insideOrSame: workspaceURL))
}

@Test func workspacePathSecurityRejectsParentTraversalWithSwiftTesting() {
    let workspaceURL = URL(fileURLWithPath: "/tmp/TonMarkTests/workspace", isDirectory: true)

    let result = WorkspacePathSecurity.childURL(
        baseDirectory: workspaceURL,
        relativeName: "../outside.md",
        workspaceURL: workspaceURL
    )

    #expect(result == nil)
}
