import Foundation
import XCTest
@testable import TonMarkCore

final class WorkspacePathSecurityTests: XCTestCase {
    private let workspaceURL = URL(fileURLWithPath: "/tmp/TonMarkTests/workspace", isDirectory: true)

    func testAllowsNestedRelativePathInsideWorkspace() {
        let base = workspaceURL.appendingPathComponent("drafts", isDirectory: true)

        let result = WorkspacePathSecurity.childURL(
            baseDirectory: base,
            relativeName: "chapter-1.md",
            workspaceURL: workspaceURL
        )

        XCTAssertEqual(result?.path, "/tmp/TonMarkTests/workspace/drafts/chapter-1.md")
    }

    func testRejectsAbsolutePath() {
        let result = WorkspacePathSecurity.childURL(
            baseDirectory: workspaceURL,
            relativeName: "/etc/passwd",
            workspaceURL: workspaceURL
        )

        XCTAssertNil(result)
    }

    func testRejectsParentTraversalOutsideWorkspace() {
        let result = WorkspacePathSecurity.childURL(
            baseDirectory: workspaceURL,
            relativeName: "../../escape.md",
            workspaceURL: workspaceURL
        )

        XCTAssertNil(result)
    }

    func testDoesNotTreatSiblingPrefixAsChild() {
        let sibling = URL(fileURLWithPath: "/tmp/TonMarkTests/workspace-other/file.md")

        XCTAssertFalse(WorkspacePathSecurity.isURL(sibling, insideOrSame: workspaceURL))
    }
}
