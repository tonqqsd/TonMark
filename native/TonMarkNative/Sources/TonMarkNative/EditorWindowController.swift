import AppKit
import CoreServices
import QuartzCore
import TonMarkCore
import UniformTypeIdentifiers
import WebKit

private let workspaceNodePasteboardType = NSPasteboard.PasteboardType("io.tonmark.workspace-node")

final class EditorWindowController: NSWindowController, WKScriptMessageHandler, WKNavigationDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSToolbarDelegate, NSSearchFieldDelegate, NSMenuDelegate, NSWindowDelegate {
    var recentFilesDidChange: (() -> Void)?
    var recentWorkspacesDidChange: (() -> Void)?

    private let webView: EditorWebView
    private let assetSchemeHandler = TonMarkAssetSchemeHandler()
    private let rootView = NSView()
    private let sidebarView = NSVisualEffectView()
    private let sidebarBackdropView = SidebarBackdropView()
    private let sidebarResizeHandle = SidebarResizeHandle()
    private let editorTitlebarView = EditorTitlebarView()
    private let titlebarDragRegionView = TitlebarDragRegionView()
    private weak var sidebarTitleField: NSTextField?
    private let workspaceNameField = NSTextField(labelWithString: "未打开文件夹")
    private let sidebarStatusField = NSTextField(labelWithString: "打开文件夹后显示 Markdown 文件")
    private let searchField = NSSearchField()
    private let sortPopup = NSPopUpButton()
    private let sortDirectionButton = NSButton(title: "升序", target: nil, action: nil)
    private let fileOutline = WorkspaceOutlineView()
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var sidebarResizeHandleWidthConstraint: NSLayoutConstraint?
    private var editorTitlebarLeadingToSidebarConstraint: NSLayoutConstraint?
    private var editorTitlebarLeadingToRootConstraint: NSLayoutConstraint?
    private var webViewLeadingToSidebarConstraint: NSLayoutConstraint?
    private var webViewLeadingToRootConstraint: NSLayoutConstraint?
    private var currentFileURL: URL?
    private var workspaceURL: URL?
    private var allWorkspaceFiles: [WorkspaceFile] = []
    private var filteredWorkspaceFiles: [WorkspaceFile] = []
    private var allWorkspaceFolders: [WorkspaceFolder] = []
    private var filteredWorkspaceFolders: [WorkspaceFolder] = []
    private var filteredWorkspaceRootNodes: [WorkspaceNode] = []
    private var nodeByRelativePath: [String: WorkspaceNode] = [:]
    private var favoriteWorkspacePaths: Set<String> = []
    private var isSidebarHidden = false
    private var isDocumentDirty = false
    private var isClosingAfterUnsavedCheck = false
    private var isSelectingWorkspaceContextItem = false
    private var isRestoringWorkspaceExpansion = false
    private var isEditorReady = false
    private var didRestoreLastOpenFile = false
    private var pendingExternalOpenURLs: [URL] = []
    private var workspaceEventStream: FSEventStreamRef?
    private var workspaceRefreshWorkItem: DispatchWorkItem?
    private var workspaceRefreshGeneration = 0
    private var quickOpenController: QuickOpenPanelController?
    private var workspaceSearchController: WorkspaceSearchPanelController?
    private var snapshotHistoryController: SnapshotHistoryPanelController?
    private var workspaceFavoriteMenuItem: NSMenuItem?
    private var titlebarDragEventMonitor: Any?
    private var toolbarHoverEventMonitor: Any?
    private var toolbarTooltipKey: String?
    private var isDraggingWindowFromTitlebar = false
    private var titlebarDragStartMouseLocation = NSPoint.zero
    private var titlebarDragStartWindowOrigin = NSPoint.zero
    private var sidebarVisualStyle = SidebarVisualStyle.dark
    private var appliedNativeTheme: String?
    private var sidebarResizeStartMouseX: CGFloat = 0
    private var sidebarResizeStartConstraintWidth: CGFloat = 0
    private let recentFilesKey = "TonMark.RecentFiles"
    private let recentWorkspacesKey = "TonMark.RecentWorkspaces"
    private let sidebarWidthKey = "TonMark.SidebarWidth"
    private let workspaceSortKey = "TonMark.WorkspaceSortMode"
    private let workspaceSortDirectionKey = "TonMark.WorkspaceSortDirection"
    private let lastWorkspaceKey = "TonMark.LastWorkspace"
    private let lastOpenFileKey = "TonMark.LastOpenFile"
    private let expandedWorkspaceFoldersKey = "TonMark.ExpandedWorkspaceFolders"
    private let favoriteWorkspacePathsKey = "TonMark.FavoriteWorkspacePaths"
    private let minimumSidebarWidth: CGFloat = 216
    private let defaultSidebarWidth: CGFloat = 296
    private let maximumSidebarWidth: CGFloat = 560
    private let sidebarResizeHandleWidth: CGFloat = 18
    private let toolbarReservedDragHeight: CGFloat = 42
    private let titlebarDragLeadingInset: CGFloat = 140
    private let titlebarToolbarReservedWidth: CGFloat = 430
    private let toolbarTooltipLabels: Set<String> = [
        "侧边栏",
        "快速打开",
        "全文搜索",
        "大纲",
        "新建",
        "打开",
        "文件夹",
        "保存",
        "导出",
        "外观",
        "模式"
    ]
    private let editorTopBorderHeight: CGFloat = 0
    private let editorSurfaceColor = NSColor(calibratedRed: 0.067, green: 0.074, blue: 0.071, alpha: 1)
    private var editorTitlebarHeight: CGFloat {
        toolbarReservedDragHeight + editorTopBorderHeight
    }

    init() {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(assetSchemeHandler, forURLScheme: "tonmark-asset")

        webView = EditorWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TonMark"
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.acceptsMouseMovedEvents = true
        window.isOpaque = false
        window.backgroundColor = editorSurfaceColor
        window.toolbarStyle = .unifiedCompact
        window.center()
        window.contentView = rootView

        super.init(window: window)

        window.delegate = self
        assetSchemeHandler.allowedRootsProvider = { [weak self] in
            self?.assetReadRoots() ?? []
        }
        userContentController.add(self, name: "native")
        webView.navigationDelegate = self
        buildLayout()
        restoreLastWorkspace()
        syncDockRecentDocumentsWithWorkspaces()
        configureToolbar(for: window)
        installTitlebarDragRegion()
        installTitlebarDragMonitor()
        installToolbarHoverMonitor()
        loadEditor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let titlebarDragEventMonitor {
            NSEvent.removeMonitor(titlebarDragEventMonitor)
        }
        if let toolbarHoverEventMonitor {
            NSEvent.removeMonitor(toolbarHoverEventMonitor)
        }
        stopWorkspaceWatcher()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "native")
    }

    func newDocument() {
        continueAfterUnsavedChanges(actionName: "新建文档") { [weak self] in
            guard let self else { return }
            self.currentFileURL = nil
            UserDefaults.standard.removeObject(forKey: self.lastOpenFileKey)
            self.window?.title = "Untitled.md - TonMark"
            self.sendToWeb(["type": "newDocument"])
        }
    }

    func openDocument() {
        continueAfterUnsavedChanges(actionName: "打开文件") { [weak self] in
            self?.showOpenDocumentPanel()
        }
    }

    private func showOpenDocumentPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = supportedOpenTypes()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openDocumentURLAfterUnsaved(url)
        }
    }

    func openWorkspace() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setWorkspaceURL(url, remember: true)
        }
    }

    func openRecentFile(_ path: String) {
        continueAfterUnsavedChanges(actionName: "打开最近文件") { [weak self] in
            guard let self else { return }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                self.removeRecentFile(path)
                self.sendToWeb(["type": "toast", "message": "最近文件不存在"])
                return
            }

            self.openDocumentURLAfterUnsaved(url)
        }
    }

    func openRecentWorkspace(_ path: String) {
        continueAfterUnsavedChanges(actionName: "打开最近文件夹") { [weak self] in
            guard let self else { return }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                self.removeRecentWorkspace(path)
                self.sendToWeb(["type": "toast", "message": "最近文件夹不存在"])
                return
            }

            self.setWorkspaceURL(url, remember: true)
        }
    }

    func clearRecentFiles() {
        UserDefaults.standard.removeObject(forKey: recentFilesKey)
        recentFilesDidChange?()
    }

    func clearRecentWorkspaces() {
        UserDefaults.standard.removeObject(forKey: recentWorkspacesKey)
        syncDockRecentDocumentsWithWorkspaces()
        recentWorkspacesDidChange?()
    }

    func syncDockRecentWorkspaces() {
        syncDockRecentDocumentsWithWorkspaces()
    }

    func windowDidResize(_ notification: Notification) {
        updateTitlebarDragRegionFrame()
    }

    func recentFileMenuItems() -> [(title: String, path: String)] {
        recentFilePaths().compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let parent = url.deletingLastPathComponent().lastPathComponent
            let title = parent.isEmpty ? url.lastPathComponent : "\(url.lastPathComponent) - \(parent)"
            return (title: title, path: path)
        }
    }

    func recentWorkspaceMenuItems() -> [(title: String, path: String)] {
        recentWorkspacePaths().compactMap { path in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }

            let parent = url.deletingLastPathComponent().lastPathComponent
            let title = parent.isEmpty ? url.lastPathComponent : "\(url.lastPathComponent) - \(parent)"
            return (title: title, path: path)
        }
    }

    func openExternalURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard isEditorReady else {
            pendingExternalOpenURLs.append(contentsOf: urls)
            return
        }

        continueAfterUnsavedChanges(actionName: "打开外部项目") { [weak self] in
            guard let self else { return }
            let validURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard let firstURL = validURLs.first else {
                self.sendToWeb(["type": "toast", "message": "文件不存在"])
                return
            }

            validURLs.dropFirst().forEach { url in
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    self.rememberRecentWorkspace(url)
                } else {
                    self.rememberRecentFile(url)
                }
            }

            if validURLs.count > 1 {
                self.sendToWeb(["type": "toast", "message": "当前窗口已打开第一个文件，其余已加入最近使用"])
            }

            self.openExternalURLAfterUnsaved(firstURL)
        }
    }

    func saveDocument() {
        evaluateCommand("TonMark.commands.save()")
    }

    func saveDocumentAs() {
        evaluateCommand("TonMark.commands.saveAs()")
    }

    func exportHTML() {
        exportCurrentDocumentHTML()
    }

    func exportPDF() {
        exportCurrentDocumentPDF()
    }

    func setTheme(_ theme: String) {
        applyNativeThemePreference(theme)
        evaluateCommand("TonMark.commands.setTheme(\(javaScriptStringLiteral(theme)))")
    }

    func adjustFontSize(by delta: Int) {
        evaluateCommand("TonMark.commands.adjustFontSize(\(delta))")
    }

    func adjustLineHeight(by delta: Double) {
        evaluateCommand("TonMark.commands.adjustLineHeight(\(delta))")
    }

    func resetTypography() {
        evaluateCommand("TonMark.commands.resetTypography()")
    }

    func copyChapterBody() {
        evaluateCommand("TonMark.commands.copyChapterBody()")
    }

    func saveSnapshot() {
        guard let currentFileURL else {
            sendToWeb(["type": "toast", "message": "请先保存文档，再创建快照"])
            return
        }

        webView.evaluateJavaScript("window.TonMark?.commands?.currentMarkdown()") { [weak self] result, _ in
            guard let self else { return }
            guard let content = result as? String else {
                self.sendToWeb(["type": "toast", "message": "无法读取当前文档"])
                return
            }

            if self.writeDocumentSnapshot(content: content, for: currentFileURL) {
                self.sendToWeb(["type": "toast", "message": "已保存快照"])
            } else {
                self.sendToWeb(["type": "toast", "message": "快照保存失败"])
            }
        }
    }

    func showSnapshotHistory() {
        guard let currentFileURL else {
            sendToWeb(["type": "toast", "message": "请先打开或保存一个文档"])
            return
        }

        let snapshots = documentSnapshots(for: currentFileURL)
        guard !snapshots.isEmpty else {
            sendToWeb(["type": "toast", "message": "当前文档还没有快照"])
            return
        }

        let controller = SnapshotHistoryPanelController(
            fileName: currentFileURL.lastPathComponent,
            snapshots: snapshots
        ) { [weak self] snapshot in
            guard let self else { return }
            do {
                let content = try String(contentsOf: snapshot.url, encoding: .utf8)
                self.sendToWeb(["type": "restoreSnapshot", "content": content])
                self.window?.makeFirstResponder(self.webView)
            } catch {
                self.sendToWeb(["type": "toast", "message": "快照读取失败"])
            }
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, self.snapshotHistoryController === controller else { return }
            self.snapshotHistoryController = nil
        }
        snapshotHistoryController = controller

        if let sheet = controller.window, let window {
            window.beginSheet(sheet)
        }
    }

    func toggleFileTree() {
        isSidebarHidden.toggle()
        sendSidebarVisibilityState()
        if !isSidebarHidden {
            sidebarView.isHidden = false
            sidebarResizeHandle.isHidden = false
            sidebarView.alphaValue = 0
            sidebarResizeHandle.alphaValue = 0
        }
        updateEditorLeadingConstraints()

        let targetWidth = isSidebarHidden ? 0 : savedSidebarWidth()
        let targetHandleWidth: CGFloat = isSidebarHidden ? 0 : sidebarResizeHandleWidth
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sidebarWidthConstraint?.animator().constant = targetWidth
            sidebarResizeHandleWidthConstraint?.animator().constant = targetHandleWidth
            sidebarView.animator().alphaValue = isSidebarHidden ? 0 : 1
            sidebarResizeHandle.animator().alphaValue = isSidebarHidden ? 0 : 1
            rootView.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.sidebarView.isHidden = self.isSidebarHidden
            self.sidebarResizeHandle.isHidden = self.isSidebarHidden
            self.sidebarResizeHandleWidthConstraint?.constant = targetHandleWidth
            if !self.isSidebarHidden {
                self.sidebarView.alphaValue = 1
                self.sidebarResizeHandle.alphaValue = 1
            }
            self.updateEditorLeadingConstraints()
        }
    }

    func togglePreview() {
        evaluateCommand("TonMark.commands.togglePreview()")
    }

    func showFindPanel() {
        evaluateCommand("TonMark.commands.showFind(false)")
    }

    func showReplacePanel() {
        evaluateCommand("TonMark.commands.showFind(true)")
    }

    func showDocumentOutline() {
        evaluateCommand("TonMark.commands.toggleOutlineSidebar()")
    }

    func showSettings() {
        evaluateCommand("TonMark.commands.showSettings()")
    }

    func toggleFocusMode() {
        evaluateCommand("TonMark.commands.toggleFocusMode()")
    }

    func toggleTypewriterMode() {
        evaluateCommand("TonMark.commands.toggleTypewriterMode()")
    }

    func findNext() {
        evaluateCommand("TonMark.commands.findNext()")
    }

    func findPrevious() {
        evaluateCommand("TonMark.commands.findPrevious()")
    }

    func showQuickOpen() {
        guard workspaceURL != nil else {
            sendToWeb(["type": "toast", "message": "请先打开工作区"])
            return
        }

        if allWorkspaceFiles.isEmpty {
            refreshWorkspaceFiles(showToast: false)
        }

        guard !allWorkspaceFiles.isEmpty else {
            sendToWeb(["type": "toast", "message": "当前工作区没有可打开的文档"])
            return
        }

        let controller = QuickOpenPanelController(
            files: allWorkspaceFiles,
            currentFileURL: currentFileURL,
            visualStyle: sidebarVisualStyle
        ) { [weak self] selectedFile in
            guard let self else { return }
            self.openQuickOpenFile(selectedFile)
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, self.quickOpenController === controller else { return }
            self.quickOpenController = nil
        }
        quickOpenController = controller

        presentFloatingSearchPanel(controller)
        controller.startOutsideClickDismissal()
    }

    func showWorkspaceSearch() {
        guard workspaceURL != nil else {
            sendToWeb(["type": "toast", "message": "请先打开工作区"])
            return
        }

        if allWorkspaceFiles.isEmpty {
            refreshWorkspaceFiles(showToast: false)
        }

        guard !allWorkspaceFiles.isEmpty else {
            sendToWeb(["type": "toast", "message": "当前工作区没有可搜索的文档"])
            return
        }

        let controller = WorkspaceSearchPanelController(files: allWorkspaceFiles, visualStyle: sidebarVisualStyle) { [weak self] result in
            self?.openWorkspaceSearchResult(result)
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, self.workspaceSearchController === controller else { return }
            self.workspaceSearchController = nil
        }
        workspaceSearchController = controller

        presentFloatingSearchPanel(controller)
        controller.startOutsideClickDismissal()
    }

    private func presentFloatingSearchPanel(_ controller: NSWindowController) {
        guard let panel = controller.window else { return }

        if let searchPanel = panel as? NSPanel {
            searchPanel.isFloatingPanel = true
            searchPanel.hidesOnDeactivate = true
        }
        panel.animationBehavior = .utilityWindow

        guard let window else {
            controller.showWindow(nil)
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let parentFrame = window.frame
        let panelFrame = panel.frame
        let origin = NSPoint(
            x: parentFrame.midX - panelFrame.width / 2,
            y: min(parentFrame.maxY - panelFrame.height - 84, parentFrame.midY - panelFrame.height / 2)
        )
        panel.setFrameOrigin(NSPoint(
            x: max(parentFrame.minX + 24, origin.x),
            y: max(parentFrame.minY + 24, origin.y)
        ))
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isClosingAfterUnsavedCheck || !isDocumentDirty {
            return true
        }

        continueAfterUnsavedChanges(actionName: "关闭窗口") { [weak self, weak sender] in
            guard let self, let sender else { return }
            self.isClosingAfterUnsavedCheck = true
            sender.close()
            self.isClosingAfterUnsavedCheck = false
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isDocumentDirty else { return .terminateNow }

        continueAfterUnsavedChanges(
            actionName: "退出应用",
            onCancel: {
                sender.reply(toApplicationShouldTerminate: false)
            },
            proceed: {
                sender.reply(toApplicationShouldTerminate: true)
            }
        )
        return .terminateLater
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any],
              let type = payload["type"] as? String else {
            return
        }

        switch type {
        case "ready":
            isEditorReady = true
            sendSidebarVisibilityState()
            refreshWorkspaceFiles(showToast: false)
            if pendingExternalOpenURLs.isEmpty {
                restoreLastOpenFileIfNeeded()
            } else {
                let urls = pendingExternalOpenURLs
                pendingExternalOpenURLs.removeAll()
                openExternalURLs(urls)
            }
        case "dirtyChanged":
            isDocumentDirty = payload["dirty"] as? Bool ?? false
        case "themeChanged":
            updateEditorSurface(theme: payload["theme"] as? String ?? "dark")
        case "openFile":
            openDocument()
        case "openWorkspace":
            openWorkspace()
        case "readWorkspaceFile":
            if let path = payload["path"] as? String {
                readWorkspaceFile(path)
            }
        case "save":
            saveText(payload["content"] as? String ?? "", forcePanel: false)
        case "saveAs":
            saveText(payload["content"] as? String ?? "", forcePanel: true)
        case "importImage":
            importImage(
                name: payload["name"] as? String ?? "image.png",
                dataURL: payload["dataURL"] as? String ?? ""
            )
        case "draftRestored":
            restoreDraftMetadata(
                path: payload["path"] as? String ?? "",
                name: payload["name"] as? String ?? "Recovered.md"
            )
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if navigationAction.navigationType == .linkActivated {
            if shouldOpenExternalURL(url) {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }

        if isTrustedEditorURL(url) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    private func shouldOpenExternalURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            return true
        default:
            return false
        }
    }

    private func isTrustedEditorURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return isURL(url, insideOrSame: webRootURL())
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? WorkspaceNode else {
            return filteredWorkspaceRootNodes.count
        }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? WorkspaceNode else {
            return filteredWorkspaceRootNodes[index]
        }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? WorkspaceNode)?.isFolder == true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? WorkspaceNode else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("FileCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? FileCellView ?? FileCellView()
        cell.identifier = identifier
        cell.configure(name: node.name, path: node.displayPath, isFolder: node.isFolder, isFavorite: node.isFavorite, style: sidebarVisualStyle)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SidebarOutlineRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? WorkspaceNode, node.url != nil else { return nil }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(node.relativePath, forType: workspaceNodePasteboardType)
        return pasteboardItem
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let nodes = topLevelWorkspaceNodes(from: workspaceNodes(from: info.draggingPasteboard))
        guard !nodes.isEmpty, let destinationURL = workspaceDropDestinationURL(for: item) else {
            return []
        }

        for node in nodes {
            guard let sourceURL = node.url else { continue }
            if node.isFolder && isURL(destinationURL, insideOrSame: sourceURL) {
                return []
            }
        }

        let dropTarget = workspaceDropTargetItem(for: item)
        outlineView.setDropItem(dropTarget, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let nodes = topLevelWorkspaceNodes(from: workspaceNodes(from: info.draggingPasteboard))
        guard !nodes.isEmpty, let destinationURL = workspaceDropDestinationURL(for: item) else {
            return false
        }

        let performMove: () -> Void = { [weak self] in
            self?.moveWorkspaceNodes(nodes, to: destinationURL)
        }

        if selectedNodesContainCurrentFile(nodes) && isDocumentDirty {
            continueAfterUnsavedChanges(actionName: "移动文件", proceed: performMove)
        } else {
            performMove()
        }
        return true
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSelectingWorkspaceContextItem else { return }
        guard fileOutline.selectedRowIndexes.count == 1 else { return }
        guard let node = selectedWorkspaceNode(), !node.isFolder else { return }
        openSelectedWorkspaceFile(nil)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        saveExpandedWorkspaceFolderPaths()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        saveExpandedWorkspaceFolderPaths()
    }

    func controlTextDidChange(_ obj: Notification) {
        applyWorkspaceFilter()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let event = NSApp.currentEvent else { return }
        let point = fileOutline.convert(event.locationInWindow, from: nil)
        let row = fileOutline.row(at: point)
        if row >= 0, !fileOutline.selectedRowIndexes.contains(row) {
            isSelectingWorkspaceContextItem = true
            defer { isSelectingWorkspaceContextItem = false }
            fileOutline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateWorkspaceFavoriteMenuItem()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarIdentifiers.toggleSidebar,
            .flexibleSpace,
            ToolbarIdentifiers.quickOpen,
            ToolbarIdentifiers.workspaceSearch,
            ToolbarIdentifiers.documentOutline,
            ToolbarIdentifiers.newDocument,
            ToolbarIdentifiers.openDocument,
            ToolbarIdentifiers.openWorkspace,
            ToolbarIdentifiers.saveDocument,
            ToolbarIdentifiers.exportDocument,
            ToolbarIdentifiers.appearance,
            ToolbarIdentifiers.togglePreview
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)

        switch itemIdentifier {
        case ToolbarIdentifiers.toggleSidebar:
            configureToolbarItem(item, label: "侧边栏", symbol: "sidebar.left", action: #selector(toolbarToggleSidebar(_:)))
        case ToolbarIdentifiers.quickOpen:
            configureToolbarItem(item, label: "快速打开", symbol: "magnifyingglass", action: #selector(toolbarQuickOpen(_:)))
        case ToolbarIdentifiers.workspaceSearch:
            configureToolbarItem(item, label: "全文搜索", symbol: "text.magnifyingglass", action: #selector(toolbarWorkspaceSearch(_:)))
        case ToolbarIdentifiers.documentOutline:
            configureToolbarItem(item, label: "大纲", symbol: "list.bullet.indent", action: #selector(toolbarDocumentOutline(_:)))
        case ToolbarIdentifiers.newDocument:
            configureToolbarItem(item, label: "新建", symbol: "square.and.pencil", action: #selector(toolbarNewDocument(_:)))
        case ToolbarIdentifiers.openDocument:
            configureToolbarItem(item, label: "打开", symbol: "doc", action: #selector(toolbarOpenDocument(_:)))
        case ToolbarIdentifiers.openWorkspace:
            configureToolbarItem(item, label: "文件夹", symbol: "folder", action: #selector(toolbarOpenWorkspace(_:)))
        case ToolbarIdentifiers.saveDocument:
            configureToolbarItem(item, label: "保存", symbol: "tray.and.arrow.down", action: #selector(toolbarSaveDocument(_:)))
        case ToolbarIdentifiers.exportDocument:
            return makeExportToolbarItem(itemIdentifier: itemIdentifier)
        case ToolbarIdentifiers.appearance:
            return makeAppearanceToolbarItem(itemIdentifier: itemIdentifier)
        case ToolbarIdentifiers.togglePreview:
            configureToolbarItem(item, label: "模式", symbol: "rectangle.split.2x1", action: #selector(toolbarTogglePreview(_:)))
        default:
            return nil
        }

        return item
    }

    private func loadEditor() {
        let url = webRootURL().appendingPathComponent("index.html")
        webView.loadFileURL(url, allowingReadAccessTo: webRootURL())
    }

    private func webRootURL() -> URL {
        if let root = ProcessInfo.processInfo.environment["TONMARK_NATIVE_WEB_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: root, isDirectory: true)
        }

        if let resourceURL = Bundle.main.resourceURL {
            return resourceURL.appendingPathComponent("Web", isDirectory: true)
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    private func assetReadRoots() -> [URL] {
        var roots: [URL] = []
        if let currentFileURL {
            roots.append(currentFileURL.deletingLastPathComponent())
        }
        if let workspaceURL {
            roots.append(workspaceURL)
        }
        return roots
    }

    private func loadFile(_ url: URL, relativePath: String? = nil, revealLine: Int? = nil) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            currentFileURL = url
            UserDefaults.standard.set(url.path, forKey: lastOpenFileKey)
            window?.title = "\(url.lastPathComponent) - TonMark"
            rememberRecentFile(url)
            sendToWeb([
                "type": "fileOpened",
                "name": url.lastPathComponent,
                "path": url.path,
                "basePath": url.deletingLastPathComponent().path,
                "content": content
            ])
            if let revealLine {
                sendToWeb(["type": "revealLine", "line": revealLine])
            }
            selectWorkspaceFile(relativePath: relativePath, url: url)
        } catch {
            sendToWeb(["type": "toast", "message": "打开失败"])
        }
    }

    private func openDocumentURLAfterUnsaved(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        if let workspaceURL, isURL(standardizedURL, insideOrSame: workspaceURL) {
            loadFile(standardizedURL, relativePath: relativeWorkspacePath(for: standardizedURL))
            return
        }

        let documentFolder = standardizedURL.deletingLastPathComponent()
        setWorkspaceURL(documentFolder, remember: true, showToast: false)
        loadFile(standardizedURL, relativePath: relativeWorkspacePath(for: standardizedURL))
    }

    private func openExternalURLAfterUnsaved(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory) else {
            sendToWeb(["type": "toast", "message": "文件不存在"])
            return
        }

        if isDirectory.boolValue {
            setWorkspaceURL(standardizedURL, remember: true)
        } else {
            openDocumentURLAfterUnsaved(standardizedURL)
        }
    }

    private func openQuickOpenFile(_ file: WorkspaceFile) {
        if currentFileURL?.path == file.url.path {
            selectWorkspaceFile(relativePath: file.relativePath, url: file.url)
            window?.makeFirstResponder(webView)
            return
        }

        continueAfterUnsavedChanges(
            actionName: "快速打开文件",
            proceed: { [weak self] in
                self?.loadFile(file.url, relativePath: file.relativePath)
            }
        )
    }

    private func openWorkspaceSearchResult(_ result: WorkspaceSearchResult) {
        if currentFileURL?.path == result.file.url.path {
            selectWorkspaceFile(relativePath: result.file.relativePath, url: result.file.url)
            sendToWeb(["type": "revealLine", "line": result.line])
            window?.makeFirstResponder(webView)
            return
        }

        continueAfterUnsavedChanges(
            actionName: "打开搜索结果",
            proceed: { [weak self] in
                self?.loadFile(result.file.url, relativePath: result.file.relativePath, revealLine: result.line)
            }
        )
    }

    private func readWorkspaceFile(_ relativePath: String) {
        guard let workspaceURL else { return }
        guard let url = workspaceChildURL(baseDirectory: workspaceURL, relativeName: relativePath),
              allWorkspaceFiles.contains(where: {
                $0.relativePath == relativePath && $0.url.standardizedFileURL.path == url.standardizedFileURL.path
              }) else {
            sendToWeb(["type": "toast", "message": "文件不在当前工作区内"])
            return
        }
        continueAfterUnsavedChanges(
            actionName: "切换文件",
            onCancel: { [weak self] in
                self?.selectWorkspaceFile(relativePath: nil, url: self?.currentFileURL)
            },
            proceed: { [weak self] in
                self?.loadFile(url, relativePath: relativePath)
            }
        )
    }

    private func saveText(_ content: String, forcePanel: Bool, completion: ((Bool) -> Void)? = nil) {
        if !forcePanel, let currentFileURL {
            do {
                createPreSaveSnapshotIfNeeded(newContent: content, fileURL: currentFileURL)
                try content.write(to: currentFileURL, atomically: true, encoding: .utf8)
                UserDefaults.standard.set(currentFileURL.path, forKey: lastOpenFileKey)
                window?.title = "\(currentFileURL.lastPathComponent) - TonMark"
                rememberRecentFile(currentFileURL)
                sendToWeb([
                    "type": "saved",
                    "path": currentFileURL.path,
                    "name": currentFileURL.lastPathComponent,
                    "basePath": currentFileURL.deletingLastPathComponent().path
                ])
                completion?(true)
            } catch {
                sendToWeb(["type": "toast", "message": "保存失败"])
                completion?(false)
            }
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = currentFileURL?.lastPathComponent ?? "Untitled.md"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self else {
                completion?(false)
                return
            }
            guard response == .OK, let url = panel.url else {
                completion?(false)
                return
            }
            do {
                self.createPreSaveSnapshotIfNeeded(newContent: content, fileURL: url)
                try content.write(to: url, atomically: true, encoding: .utf8)
                self.currentFileURL = url
                UserDefaults.standard.set(url.path, forKey: self.lastOpenFileKey)
                self.window?.title = "\(url.lastPathComponent) - TonMark"
                self.rememberRecentFile(url)
                self.refreshWorkspaceFiles(showToast: false)
                self.sendToWeb([
                    "type": "saved",
                    "path": url.path,
                    "name": url.lastPathComponent,
                    "basePath": url.deletingLastPathComponent().path
                ])
                completion?(true)
            } catch {
                self.sendToWeb(["type": "toast", "message": "保存失败"])
                completion?(false)
            }
        }
    }

    private func exportCurrentDocumentHTML() {
        webView.evaluateJavaScript("window.TonMark?.commands?.exportHTML()") { [weak self] result, _ in
            guard let self else { return }
            guard let html = result as? String,
                  let data = html.data(using: .utf8) else {
                self.sendToWeb(["type": "toast", "message": "导出 HTML 失败"])
                return
            }

            self.writeExportData(
                data,
                defaultName: self.defaultExportFileName(extension: "html"),
                allowedType: .html,
                successMessage: "HTML 已导出",
                failureMessage: "导出 HTML 失败"
            )
        }
    }

    private func exportCurrentDocumentPDF() {
        guard let window else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = defaultExportFileName(extension: "pdf")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.prepareAndWritePDF(to: url)
        }
    }

    private func prepareAndWritePDF(to url: URL) {
        webView.evaluateJavaScript("window.TonMark?.commands?.preparePrintExport()") { [weak self] result, _ in
            guard let self else { return }
            let previousMode = result as? String ?? "mode-live"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.writePDF(to: url, restoring: previousMode)
            }
        }
    }

    private func writePDF(to url: URL, restoring previousMode: String) {
        let printInfo = NSPrintInfo()
        printInfo.jobDisposition = .save
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.topMargin = 54
        printInfo.bottomMargin = 54
        printInfo.leftMargin = 54
        printInfo.rightMargin = 54
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        let succeeded = operation.run()

        evaluateCommand("window.TonMark?.commands?.finishPrintExport(\(javaScriptStringLiteral(previousMode)))")
        sendToWeb(["type": "toast", "message": succeeded ? "PDF 已导出" : "导出 PDF 失败"])
    }

    private func writeExportData(
        _ data: Data,
        defaultName: String,
        allowedType: UTType,
        successMessage: String,
        failureMessage: String
    ) {
        guard let window else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [allowedType]
        panel.nameFieldStringValue = defaultName
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                self.sendToWeb(["type": "toast", "message": successMessage])
            } catch {
                self.sendToWeb(["type": "toast", "message": failureMessage])
            }
        }
    }

    private func defaultExportFileName(extension ext: String) -> String {
        let baseName = currentFileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        let cleanBase = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(cleanBase.isEmpty ? "Untitled" : cleanBase).\(ext)"
    }

    private func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let arrayLiteral = String(data: data, encoding: .utf8),
              arrayLiteral.count >= 2 else {
            return "\"\""
        }
        return String(arrayLiteral.dropFirst().dropLast())
    }

    private func createPreSaveSnapshotIfNeeded(newContent: String, fileURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let oldContent = try? String(contentsOf: fileURL, encoding: .utf8),
              oldContent != newContent else {
            return
        }
        _ = writeDocumentSnapshot(content: oldContent, for: fileURL)
    }

    private func writeDocumentSnapshot(content: String, for fileURL: URL) -> Bool {
        do {
            let directory = try snapshotDirectory(for: fileURL)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let baseName = formatter.string(from: Date())
            var candidate = directory.appendingPathComponent("\(baseName).md")
            var counter = 2
            while FileManager.default.fileExists(atPath: candidate.path) {
                candidate = directory.appendingPathComponent("\(baseName)-\(counter).md")
                counter += 1
            }

            try content.write(to: candidate, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private func documentSnapshots(for fileURL: URL) -> [DocumentSnapshot] {
        guard let directory = try? snapshotDirectory(for: fileURL),
              let items = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return items.compactMap { url -> DocumentSnapshot? in
            guard url.pathExtension.lowercased() == "md",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                return nil
            }
            return DocumentSnapshot(
                url: url,
                createdAt: values.contentModificationDate ?? .distantPast,
                byteCount: values.fileSize ?? 0
            )
        }.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.url.lastPathComponent > rhs.url.lastPathComponent
        }
    }

    private func snapshotDirectory(for fileURL: URL) throws -> URL {
        let support = try applicationSupportDirectory()
        let key = snapshotKey(for: fileURL)
        return support
            .appendingPathComponent("Snapshots", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }

    private func applicationSupportDirectory() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = base.appendingPathComponent("TonMarkNative", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func snapshotKey(for fileURL: URL) -> String {
        let path = fileURL.standardizedFileURL.path
        return Data(path.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private func continueAfterUnsavedChanges(actionName: String, onCancel: (() -> Void)? = nil, proceed: @escaping () -> Void) {
        guard isDocumentDirty else {
            proceed()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "保存当前文档的更改？"
        alert.informativeText = "如果不保存，\(actionName) 会丢弃当前未保存的修改。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "不保存")

        alert.beginSheetModal(for: window!) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.saveCurrentDocumentBeforeProceed { saved in
                    if saved {
                        proceed()
                    } else {
                        onCancel?()
                    }
                }
            case .alertThirdButtonReturn:
                self.isDocumentDirty = false
                self.evaluateCommand("window.TonMark?.commands?.discardDraft()")
                proceed()
            default:
                onCancel?()
            }
        }
    }

    private func saveCurrentDocumentBeforeProceed(_ completion: @escaping (Bool) -> Void) {
        webView.evaluateJavaScript("window.TonMark?.commands?.currentMarkdown()") { [weak self] result, _ in
            guard let self else {
                completion(false)
                return
            }

            guard let content = result as? String else {
                self.sendToWeb(["type": "toast", "message": "无法读取当前文档"])
                completion(false)
                return
            }

            self.saveText(content, forcePanel: false, completion: completion)
        }
    }

    private func importImage(name: String, dataURL: String) {
        guard let payload = decodeDataURL(dataURL) else {
            sendToWeb(["type": "toast", "message": "图片读取失败"])
            return
        }

        guard let target = imageAssetTarget(originalName: name, mimeType: payload.mimeType) else {
            sendToWeb(["type": "toast", "message": "请先保存文档或打开工作区"])
            return
        }

        do {
            try FileManager.default.createDirectory(at: target.directory, withIntermediateDirectories: true)
            let fileURL = uniqueAssetURL(in: target.directory, preferredName: name, mimeType: payload.mimeType)
            try payload.data.write(to: fileURL, options: .atomic)

            sendToWeb([
                "type": "imageImported",
                "markdown": "![\(fileURL.deletingPathExtension().lastPathComponent)](\(target.relativePath(to: fileURL)))",
                "path": fileURL.path,
                "src": fileURL.absoluteString
            ])
        } catch {
            sendToWeb(["type": "toast", "message": "图片保存失败"])
        }
    }

    private func restoreDraftMetadata(path: String, name: String) {
        guard !path.isEmpty else {
            currentFileURL = nil
            UserDefaults.standard.removeObject(forKey: lastOpenFileKey)
            window?.title = "\(name) - TonMark"
            return
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            currentFileURL = nil
            window?.title = "\(name) - TonMark"
            sendToWeb(["type": "toast", "message": "原文件不存在，请另存"])
            return
        }

        currentFileURL = url
        UserDefaults.standard.set(url.path, forKey: lastOpenFileKey)
        window?.title = "\(url.lastPathComponent) - TonMark"
        rememberRecentFile(url)
        selectWorkspaceFile(relativePath: nil, url: url)
    }

    private func recentFilePaths() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentFilesKey) ?? []
    }

    private func recentWorkspacePaths() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentWorkspacesKey) ?? []
    }

    private func rememberRecentFile(_ url: URL) {
        let path = url.path
        var paths = recentFilePaths().filter { $0 != path && FileManager.default.fileExists(atPath: $0) }
        paths.insert(path, at: 0)
        paths = Array(paths.prefix(12))
        UserDefaults.standard.set(paths, forKey: recentFilesKey)
        recentFilesDidChange?()
    }

    private func rememberRecentWorkspace(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = recentWorkspacePaths().filter { existingPath in
            guard existingPath != path else { return false }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: existingPath, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        paths.insert(path, at: 0)
        paths = Array(paths.prefix(12))
        UserDefaults.standard.set(paths, forKey: recentWorkspacesKey)
        syncDockRecentDocumentsWithWorkspaces()
        recentWorkspacesDidChange?()
    }

    private func removeRecentFile(_ path: String) {
        let paths = recentFilePaths().filter { $0 != path }
        UserDefaults.standard.set(paths, forKey: recentFilesKey)
        recentFilesDidChange?()
    }

    private func removeRecentWorkspace(_ path: String) {
        let paths = recentWorkspacePaths().filter { $0 != path }
        UserDefaults.standard.set(paths, forKey: recentWorkspacesKey)
        syncDockRecentDocumentsWithWorkspaces()
        recentWorkspacesDidChange?()
    }

    private func syncDockRecentDocumentsWithWorkspaces() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        let validPaths = recentWorkspacePaths().filter { path in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        if validPaths != recentWorkspacePaths() {
            UserDefaults.standard.set(validPaths, forKey: recentWorkspacesKey)
            recentWorkspacesDidChange?()
        }
        UserDefaults.standard.synchronize()
        validPaths.reversed().forEach { path in
            NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: path, isDirectory: true))
        }
        UserDefaults.standard.synchronize()
    }

    private func removeRecentFiles(under url: URL) {
        let targetPath = url.standardizedFileURL.path
        let targetPrefix = targetPath.hasSuffix("/") ? targetPath : targetPath + "/"
        let paths = recentFilePaths().filter { path in
            let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            return standardizedPath != targetPath && !standardizedPath.hasPrefix(targetPrefix)
        }
        UserDefaults.standard.set(paths, forKey: recentFilesKey)
        recentFilesDidChange?()
    }

    private func collectWorkspaceContents(in root: URL) -> WorkspaceContents {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .creationDateKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return WorkspaceContents(files: [], folders: [])
        }

        let skippedDirectories = Set(["node_modules", ".git", ".build", "dist", "build", "__pycache__", ".pytest_cache", ".mypy_cache"])
        var files: [WorkspaceFile] = []
        var folders: [WorkspaceFolder] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }

                let relative = relativeWorkspacePath(from: root, to: url)
                if !relative.isEmpty {
                    folders.append(WorkspaceFolder(
                        name: url.lastPathComponent,
                        relativePath: relative,
                        url: url,
                        createdAt: values?.creationDate ?? values?.contentModificationDate ?? .distantPast,
                        modifiedAt: values?.contentModificationDate ?? .distantPast
                    ))
                }
                continue
            }

            guard values?.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            guard ["md", "markdown", "mdown", "mkd", "txt"].contains(ext) else { continue }
            let relative = relativeWorkspacePath(from: root, to: url)
            let createdAt = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            let modifiedAt = values?.contentModificationDate ?? .distantPast
            files.append(WorkspaceFile(name: url.lastPathComponent, relativePath: relative, url: url, createdAt: createdAt, modifiedAt: modifiedAt))
        }

        return WorkspaceContents(
            files: files.sorted { compareWorkspaceText($0.relativePath, $1.relativePath) },
            folders: folders.sorted { compareWorkspaceText($0.relativePath, $1.relativePath) }
        )
    }

    private func relativeWorkspacePath(from root: URL, to url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return "" }
        return String(path.dropFirst(prefix.count))
    }

    private func sendToWeb(_ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        evaluateCommand("window.TonMark.receive(\(json))")
    }

    private func sendSidebarVisibilityState() {
        sendToWeb(["type": "sidebarVisibility", "hidden": isSidebarHidden])
    }

    private func applyNativeThemePreference(_ theme: String) {
        if theme == "system" {
            updateEditorSurface(theme: effectiveSystemEditorTheme())
        } else {
            updateEditorSurface(theme: theme)
        }
    }

    private func effectiveSystemEditorTheme() -> String {
        let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? "dark" : "light"
    }

    private func updateEditorSurface(theme: String) {
        let color: NSColor
        let sidebarStyle: SidebarVisualStyle
        switch theme {
        case "light":
            color = NSColor(calibratedRed: 0.984, green: 0.980, blue: 0.969, alpha: 1)
            sidebarStyle = .light
        case "sepia":
            color = NSColor(calibratedRed: 0.957, green: 0.925, blue: 0.858, alpha: 1)
            sidebarStyle = .sepia
        default:
            color = editorSurfaceColor
            sidebarStyle = .dark
        }
        let shouldRebuildToolbar = appliedNativeTheme != theme
        appliedNativeTheme = theme
        sidebarVisualStyle = sidebarStyle
        applySidebarVisualStyle(sidebarStyle)
        applyToolbarVisualStyle(sidebarStyle, rebuildToolbar: shouldRebuildToolbar)
        rootView.layer?.backgroundColor = color.cgColor
        window?.backgroundColor = color
    }

    private func applyToolbarVisualStyle(_ style: SidebarVisualStyle, rebuildToolbar: Bool) {
        hideToolbarTooltip()
        guard let window else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false

            window.appearance = style.appearance
            window.contentView?.superview?.appearance = style.appearance

            if rebuildToolbar, window.toolbar != nil {
                configureToolbar(for: window)
            }

            window.contentView?.superview?.layoutSubtreeIfNeeded()

            window.toolbar?.visibleItems?.forEach { item in
                item.image?.isTemplate = true
                if let view = item.view {
                    applyAppearance(style.appearance, to: view)
                }
            }

            if let frameView = window.contentView?.superview {
                applyAppearance(style.appearance, to: frameView, within: NSRect(
                    x: 0,
                    y: max(0, frameView.bounds.height - toolbarReservedDragHeight - 8),
                    width: frameView.bounds.width,
                    height: toolbarReservedDragHeight + 8
                ))
                frameView.needsDisplay = true
                frameView.displayIfNeeded()
            }

            window.toolbar?.validateVisibleItems()
        }
    }

    private func applyAppearance(_ appearance: NSAppearance?, to view: NSView) {
        view.appearance = appearance
        view.needsDisplay = true
        view.subviews.forEach { applyAppearance(appearance, to: $0) }
    }

    private func applyAppearance(_ appearance: NSAppearance?, to view: NSView, within clippingRect: NSRect) {
        guard !view.isHidden, view.alphaValue > 0.01 else { return }
        let rect = view.convert(view.bounds, to: view.superview ?? view)
        let rectInRoot = view.superview?.convert(rect, to: window?.contentView?.superview) ?? rect
        if rectInRoot.intersects(clippingRect) {
            view.appearance = appearance
            view.needsDisplay = true
        }
        view.subviews.forEach { applyAppearance(appearance, to: $0, within: clippingRect) }
    }

    private func applySidebarVisualStyle(_ style: SidebarVisualStyle) {
        sidebarBackdropView.palette = style.backdropPalette
        sidebarView.appearance = style.appearance
        fileOutline.appearance = style.appearance
        sidebarTitleField?.textColor = style.primaryText
        workspaceNameField.textColor = style.primaryText
        sidebarStatusField.textColor = style.secondaryText
        SidebarOutlineRowView.selectionColor = style.selectionColor
        fileOutline.reloadData()
        fileOutline.setNeedsDisplay(fileOutline.bounds)
        quickOpenController?.applyVisualStyle(style)
        workspaceSearchController?.applyVisualStyle(style)
    }

    private func evaluateCommand(_ command: String) {
        webView.evaluateJavaScript(command)
    }

    private func decodeDataURL(_ dataURL: String) -> (mimeType: String, data: Data)? {
        let parts = dataURL.split(separator: ",", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }

        let header = parts[0]
        let mimeType = header
            .replacingOccurrences(of: "data:", with: "")
            .replacingOccurrences(of: ";base64", with: "")

        guard let data = Data(base64Encoded: parts[1]) else { return nil }
        return (mimeType, data)
    }

    private func imageAssetTarget(originalName: String, mimeType: String) -> ImageAssetTarget? {
        if let currentFileURL {
            let documentFolder = currentFileURL.deletingLastPathComponent()
            let documentName = currentFileURL.deletingPathExtension().lastPathComponent
            let directory = documentFolder.appendingPathComponent("\(documentName).assets", isDirectory: true)
            return ImageAssetTarget(directory: directory, baseDirectory: documentFolder)
        }

        if let workspaceURL {
            let directory = workspaceURL.appendingPathComponent("assets", isDirectory: true)
            return ImageAssetTarget(directory: directory, baseDirectory: workspaceURL)
        }

        return nil
    }

    private func uniqueAssetURL(in directory: URL, preferredName: String, mimeType: String) -> URL {
        let cleanName = sanitizedAssetName(preferredName, fallbackExtension: imageExtension(for: mimeType))
        let base = URL(fileURLWithPath: cleanName).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: cleanName).pathExtension

        var candidate = directory.appendingPathComponent(cleanName)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(counter).\(ext)")
            counter += 1
        }

        return candidate
    }

    private func sanitizedAssetName(_ name: String, fallbackExtension: String) -> String {
        let url = URL(fileURLWithPath: name)
        let rawBase = url.deletingPathExtension().lastPathComponent
        let rawExtension = url.pathExtension.isEmpty ? fallbackExtension : url.pathExtension
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))

        let base = rawBase.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined().trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        let ext = rawExtension.lowercased().unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : ""
        }.joined()

        return "\((base.isEmpty ? "image" : base)).\((ext.isEmpty ? fallbackExtension : ext))"
    }

    private func imageExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        case "image/tiff":
            return "tiff"
        default:
            return "png"
        }
    }

    private func buildLayout() {
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = editorSurfaceColor.cgColor
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        sidebarResizeHandle.translatesAutoresizingMaskIntoConstraints = false
        editorTitlebarView.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(sidebarView)
        rootView.addSubview(webView)
        rootView.addSubview(editorTitlebarView)
        rootView.addSubview(sidebarResizeHandle)

        sidebarWidthConstraint = sidebarView.widthAnchor.constraint(equalToConstant: savedSidebarWidth())
        sidebarWidthConstraint?.isActive = true
        sidebarResizeHandleWidthConstraint = sidebarResizeHandle.widthAnchor.constraint(equalToConstant: sidebarResizeHandleWidth)
        sidebarResizeHandleWidthConstraint?.isActive = true
        editorTitlebarLeadingToSidebarConstraint = editorTitlebarView.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor)
        editorTitlebarLeadingToRootConstraint = editorTitlebarView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor)
        webViewLeadingToSidebarConstraint = webView.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor)
        webViewLeadingToRootConstraint = webView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor)
        updateEditorLeadingConstraints()
        sidebarResizeHandle.onDragBegan = { [weak self] mouseX in
            guard let self else { return }
            self.sidebarResizeStartMouseX = mouseX
            self.sidebarResizeStartConstraintWidth = self.sidebarWidthConstraint?.constant ?? self.savedSidebarWidth()
        }
        sidebarResizeHandle.onDragged = { [weak self] mouseX in
            guard let self else { return }
            let proposedWidth = self.sidebarResizeStartConstraintWidth + mouseX - self.sidebarResizeStartMouseX
            self.setSidebarWidth(proposedWidth, animated: false, persist: false)
        }
        sidebarResizeHandle.onDragEnded = { [weak self] in
            guard let self else { return }
            let width = self.sidebarWidthConstraint?.constant ?? self.savedSidebarWidth()
            self.setSidebarWidth(width, animated: false, persist: true)
        }
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(resetSidebarWidth(_:)))
        doubleClick.numberOfClicksRequired = 2
        sidebarResizeHandle.addGestureRecognizer(doubleClick)

        NSLayoutConstraint.activate([
            sidebarView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            sidebarView.topAnchor.constraint(equalTo: rootView.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            sidebarResizeHandle.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -(sidebarResizeHandleWidth / 2)),
            sidebarResizeHandle.topAnchor.constraint(equalTo: rootView.topAnchor),
            sidebarResizeHandle.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            editorTitlebarView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            editorTitlebarView.topAnchor.constraint(equalTo: rootView.topAnchor),
            editorTitlebarView.heightAnchor.constraint(equalToConstant: editorTitlebarHeight),

            webView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: rootView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        buildSidebar()
    }

    private func updateEditorLeadingConstraints() {
        editorTitlebarLeadingToSidebarConstraint?.isActive = !isSidebarHidden
        webViewLeadingToSidebarConstraint?.isActive = !isSidebarHidden
        editorTitlebarLeadingToRootConstraint?.isActive = isSidebarHidden
        webViewLeadingToRootConstraint?.isActive = isSidebarHidden
    }

    @objc private func resetSidebarWidth(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        if isSidebarHidden {
            isSidebarHidden = false
            sidebarView.isHidden = false
            sidebarResizeHandle.isHidden = false
            sidebarResizeHandle.alphaValue = 1
            sidebarResizeHandleWidthConstraint?.constant = sidebarResizeHandleWidth
            updateEditorLeadingConstraints()
        }
        setSidebarWidth(defaultSidebarWidth, animated: true, persist: true)
    }

    private func savedSidebarWidth() -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: sidebarWidthKey)
        guard stored > 0 else { return defaultSidebarWidth }
        return clampedSidebarWidth(CGFloat(stored))
    }

    private func setSidebarWidth(_ width: CGFloat, animated: Bool, persist: Bool) {
        let clamped = clampedSidebarWidth(width)
        let updates = { [weak self] in
            guard let self else { return }
            self.sidebarWidthConstraint?.constant = clamped
            self.rootView.layoutSubtreeIfNeeded()
            self.rootView.displayIfNeeded()
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                updates()
            }
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updates()
            CATransaction.commit()
        }

        if persist {
            UserDefaults.standard.set(Double(clamped), forKey: sidebarWidthKey)
        }
    }

    private func clampedSidebarWidth(_ width: CGFloat) -> CGFloat {
        let availableMaximum = rootView.bounds.width > 0 ? max(minimumSidebarWidth, rootView.bounds.width - 420) : maximumSidebarWidth
        let upperBound = min(maximumSidebarWidth, availableMaximum)
        return min(max(width, minimumSidebarWidth), upperBound)
    }

    private func buildSidebar() {
        sidebarView.material = .underWindowBackground
        sidebarView.blendingMode = .behindWindow
        sidebarView.state = .active
        sidebarView.wantsLayer = true

        let contentView = NSView()
        let titleField = NSTextField(labelWithString: "工作区")
        let openWorkspaceButton = NSButton(title: "打开文件夹", target: self, action: #selector(toolbarOpenWorkspace(_:)))
        let scrollView = NSScrollView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        let menu = NSMenu()

        contentView.translatesAutoresizingMaskIntoConstraints = false
        titleField.translatesAutoresizingMaskIntoConstraints = false
        openWorkspaceButton.translatesAutoresizingMaskIntoConstraints = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        sortPopup.translatesAutoresizingMaskIntoConstraints = false
        sortDirectionButton.translatesAutoresizingMaskIntoConstraints = false
        workspaceNameField.translatesAutoresizingMaskIntoConstraints = false
        sidebarStatusField.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.textColor = sidebarVisualStyle.primaryText
        titleField.stringValue = "工作区"
        sidebarTitleField = titleField

        openWorkspaceButton.bezelStyle = .rounded
        openWorkspaceButton.controlSize = .small
        openWorkspaceButton.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "打开文件夹")
        openWorkspaceButton.imagePosition = .imageLeading

        searchField.placeholderString = "搜索文件"
        searchField.delegate = self
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 12)

        configureSortControls()

        workspaceNameField.lineBreakMode = .byTruncatingMiddle
        workspaceNameField.font = .systemFont(ofSize: 12, weight: .semibold)
        workspaceNameField.textColor = sidebarVisualStyle.primaryText

        sidebarStatusField.textColor = sidebarVisualStyle.secondaryText
        sidebarStatusField.font = .systemFont(ofSize: 11)

        column.title = ""
        column.resizingMask = .autoresizingMask
        fileOutline.addTableColumn(column)
        fileOutline.outlineTableColumn = column
        fileOutline.headerView = nil
        fileOutline.rowHeight = 42
        fileOutline.intercellSpacing = NSSize(width: 0, height: 3)
        fileOutline.indentationPerLevel = 14
        fileOutline.dataSource = self
        fileOutline.delegate = self
        fileOutline.target = self
        fileOutline.doubleAction = #selector(openSelectedWorkspaceFile(_:))
        fileOutline.keyDownHandler = { [weak self] event in
            self?.handleWorkspaceKeyDown(event) ?? false
        }
        fileOutline.allowsMultipleSelection = true
        fileOutline.selectionHighlightStyle = .regular
        fileOutline.backgroundColor = .clear
        fileOutline.usesAlternatingRowBackgroundColors = false
        fileOutline.enclosingScrollView?.drawsBackground = false
        fileOutline.registerForDraggedTypes([workspaceNodePasteboardType])
        fileOutline.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.documentView = fileOutline
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        menu.delegate = self
        menu.addItem(menuItem(title: "打开", action: #selector(openSelectedWorkspaceFile(_:))))
        let favoriteItem = menuItem(title: "加入收藏/置顶", action: #selector(toggleFavoriteSelectedWorkspaceItems(_:)))
        workspaceFavoriteMenuItem = favoriteItem
        menu.addItem(favoriteItem)
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "新建文件", action: #selector(createWorkspaceFile(_:))))
        menu.addItem(menuItem(title: "新建文件夹", action: #selector(createWorkspaceFolder(_:))))
        menu.addItem(menuItem(title: "重命名", action: #selector(renameSelectedWorkspaceItem(_:))))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "移动到文件夹...", action: #selector(moveSelectedWorkspaceItems(_:))))
        menu.addItem(menuItem(title: "复制到文件夹...", action: #selector(copySelectedWorkspaceItems(_:))))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "定位当前文件", action: #selector(locateCurrentWorkspaceFile(_:))))
        menu.addItem(menuItem(title: "在访达中显示", action: #selector(revealSelectedWorkspaceFile(_:))))
        menu.addItem(menuItem(title: "删除到废纸篓", action: #selector(trashSelectedWorkspaceFiles(_:))))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "刷新", action: #selector(refreshWorkspaceFromMenu(_:))))
        fileOutline.menu = menu

        sidebarBackdropView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.addSubview(sidebarBackdropView)
        sidebarView.addSubview(contentView)
        contentView.addSubview(titleField)
        contentView.addSubview(openWorkspaceButton)
        contentView.addSubview(searchField)
        contentView.addSubview(sortPopup)
        contentView.addSubview(sortDirectionButton)
        contentView.addSubview(workspaceNameField)
        contentView.addSubview(sidebarStatusField)
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            sidebarBackdropView.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            sidebarBackdropView.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            sidebarBackdropView.topAnchor.constraint(equalTo: sidebarView.topAnchor),
            sidebarBackdropView.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 12),
            contentView.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -12),
            contentView.topAnchor.constraint(equalTo: sidebarView.topAnchor, constant: 58),
            contentView.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor, constant: -12),

            titleField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            titleField.topAnchor.constraint(equalTo: contentView.topAnchor),

            openWorkspaceButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            openWorkspaceButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            openWorkspaceButton.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 10),
            openWorkspaceButton.heightAnchor.constraint(equalToConstant: 28),

            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            searchField.topAnchor.constraint(equalTo: openWorkspaceButton.bottomAnchor, constant: 8),

            workspaceNameField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            workspaceNameField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            workspaceNameField.topAnchor.constraint(equalTo: sortPopup.bottomAnchor, constant: 10),

            sortPopup.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sortPopup.trailingAnchor.constraint(equalTo: sortDirectionButton.leadingAnchor, constant: -6),
            sortPopup.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            sortPopup.heightAnchor.constraint(equalToConstant: 26),

            sortDirectionButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            sortDirectionButton.centerYAnchor.constraint(equalTo: sortPopup.centerYAnchor),
            sortDirectionButton.widthAnchor.constraint(equalToConstant: 54),
            sortDirectionButton.heightAnchor.constraint(equalToConstant: 26),

            sidebarStatusField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sidebarStatusField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            sidebarStatusField.topAnchor.constraint(equalTo: workspaceNameField.bottomAnchor, constant: 4),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: sidebarStatusField.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    private func configureToolbar(for window: NSWindow) {
        let toolbar = NSToolbar(identifier: "TonMarkToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.sizeMode = .regular
        window.toolbar = toolbar
    }

    private func installTitlebarDragRegion() {
        guard let frameView = window?.contentView?.superview else { return }

        titlebarDragRegionView.translatesAutoresizingMaskIntoConstraints = true
        titlebarDragRegionView.autoresizingMask = [.width, .minYMargin]
        titlebarDragRegionView.frame = titlebarDragRegionFrame(in: frameView)

        if titlebarDragRegionView.superview == nil {
            frameView.addSubview(titlebarDragRegionView, positioned: .above, relativeTo: nil)
        }

        DispatchQueue.main.async { [weak self] in
            self?.updateTitlebarDragRegionFrame()
        }
    }

    private func installTitlebarDragMonitor() {
        titlebarDragEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self, event.window === self.window else { return event }

            switch event.type {
            case .leftMouseDown:
                guard self.shouldStartTitlebarDrag(for: event) else { return event }
                self.isDraggingWindowFromTitlebar = true
                self.titlebarDragStartMouseLocation = NSEvent.mouseLocation
                self.titlebarDragStartWindowOrigin = self.window?.frame.origin ?? .zero
                return nil
            case .leftMouseDragged:
                guard self.isDraggingWindowFromTitlebar, let window = self.window else { return event }
                let mouseLocation = NSEvent.mouseLocation
                window.setFrameOrigin(NSPoint(
                    x: self.titlebarDragStartWindowOrigin.x + mouseLocation.x - self.titlebarDragStartMouseLocation.x,
                    y: self.titlebarDragStartWindowOrigin.y + mouseLocation.y - self.titlebarDragStartMouseLocation.y
                ))
                return nil
            case .leftMouseUp:
                guard self.isDraggingWindowFromTitlebar else { return event }
                self.isDraggingWindowFromTitlebar = false
                return nil
            default:
                return event
            }
        }
    }

    private func installToolbarHoverMonitor() {
        toolbarHoverEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { [weak self] event in
            guard let self, event.window === self.window else { return event }

            switch event.type {
            case .mouseMoved:
                self.updateToolbarTooltip(for: event)
            default:
                self.hideToolbarTooltip()
            }
            return event
        }
    }

    private func updateToolbarTooltip(for event: NSEvent) {
        guard let frameView = window?.contentView?.superview else {
            hideToolbarTooltip()
            return
        }

        let point = frameView.convert(event.locationInWindow, from: nil)
        let toolbarBand = NSRect(x: 0, y: max(0, frameView.bounds.height - 42), width: frameView.bounds.width, height: 42)
        guard toolbarBand.contains(point),
              let source = toolbarTooltipSource(at: point, in: frameView),
              let window else {
            hideToolbarTooltip()
            return
        }

        let key = source.label
        if toolbarTooltipKey != key {
            toolbarTooltipKey = key
            let anchor = window.convertPoint(toScreen: NSPoint(x: source.rect.midX, y: source.rect.minY))
            InstantTooltipPresenter.shared.show(text: source.label, anchorOnScreen: anchor)
        }
    }

    private func hideToolbarTooltip() {
        toolbarTooltipKey = nil
        InstantTooltipPresenter.shared.hide()
    }

    private func toolbarTooltipSource(at point: NSPoint, in frameView: NSView) -> (label: String, rect: NSRect)? {
        var matches: [(label: String, rect: NSRect, area: CGFloat)] = []

        func visit(_ view: NSView) {
            guard !view.isHidden, view.alphaValue > 0.01 else { return }

            let rect = view.convert(view.bounds, to: frameView)
            guard rect.contains(point) else {
                view.subviews.forEach(visit)
                return
            }

            if let label = toolbarTooltipLabel(for: view) {
                matches.append((label, rect, max(1, rect.width * rect.height)))
            }

            view.subviews.forEach(visit)
        }

        visit(frameView)
        return matches.max { lhs, rhs in
            lhs.area < rhs.area
        }.map { ($0.label, $0.rect) }
    }

    private func toolbarTooltipLabel(for view: NSView) -> String? {
        let candidates = [
            view.accessibilityLabel(),
            view.accessibilityHelp(),
            view.toolTip
        ]

        return candidates.compactMap { candidate -> String? in
            guard let candidate else { return nil }
            let label = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return toolbarTooltipLabels.contains(label) ? label : nil
        }.first
    }

    private func shouldStartTitlebarDrag(for event: NSEvent) -> Bool {
        guard event.clickCount <= 1,
              let frameView = window?.contentView?.superview else {
            return false
        }

        let point = frameView.convert(event.locationInWindow, from: nil)
        return titlebarDragRegionFrame(in: frameView).contains(point)
    }

    private func updateTitlebarDragRegionFrame() {
        guard let frameView = titlebarDragRegionView.superview else { return }
        titlebarDragRegionView.frame = titlebarDragRegionFrame(in: frameView)
    }

    private func titlebarDragRegionFrame(in frameView: NSView) -> NSRect {
        let height = max(36, editorTitlebarHeight)
        let width = max(0, frameView.bounds.width - titlebarDragLeadingInset - titlebarToolbarReservedWidth)
        return NSRect(
            x: titlebarDragLeadingInset,
            y: max(0, frameView.bounds.height - height),
            width: width,
            height: height
        )
    }

    private func configureToolbarItem(_ item: NSToolbarItem, label: String, symbol: String, action: Selector) {
        item.label = label
        item.paletteLabel = label
        item.toolTip = nil
        item.image = toolbarImage(symbol, label: label)
        item.target = self
        item.action = action
    }

    private func toolbarImage(_ symbol: String, label: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        image?.isTemplate = true
        return image
    }

    private func makeExportToolbarItem(itemIdentifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let menu = NSMenu(title: "导出")
        let htmlItem = NSMenuItem(title: "导出 HTML...", action: #selector(toolbarExportHTMLDocument(_:)), keyEquivalent: "")
        let pdfItem = NSMenuItem(title: "导出 PDF...", action: #selector(toolbarExportDocument(_:)), keyEquivalent: "")
        htmlItem.target = self
        pdfItem.target = self
        menu.addItem(htmlItem)
        menu.addItem(pdfItem)

        if #available(macOS 10.15, *) {
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "导出"
            item.paletteLabel = "导出"
            item.toolTip = nil
            item.image = toolbarImage("square.and.arrow.up", label: "导出")
            item.menu = menu
            return item
        }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "导出"
        item.paletteLabel = "导出"
        item.toolTip = nil
        item.image = toolbarImage("square.and.arrow.up", label: "导出")
        item.target = self
        item.action = #selector(toolbarExportDocument(_:))
        return item
    }

    private func makeAppearanceToolbarItem(itemIdentifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let menu = NSMenu(title: "外观")
        let themeMenu = NSMenu(title: "主题")
        let typographyMenu = NSMenu(title: "排版")

        [
            ("跟随系统", #selector(toolbarThemeSystem(_:))),
            ("浅色", #selector(toolbarThemeLight(_:))),
            ("深色", #selector(toolbarThemeDark(_:))),
            ("暖纸", #selector(toolbarThemeSepia(_:)))
        ].forEach { title, action in
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            themeMenu.addItem(item)
        }

        [
            ("增大字体", #selector(toolbarIncreaseFontSize(_:))),
            ("减小字体", #selector(toolbarDecreaseFontSize(_:))),
            ("增大行高", #selector(toolbarIncreaseLineHeight(_:))),
            ("减小行高", #selector(toolbarDecreaseLineHeight(_:))),
            ("恢复默认排版", #selector(toolbarResetTypography(_:)))
        ].forEach { title, action in
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            typographyMenu.addItem(item)
        }

        let themeItem = NSMenuItem(title: "主题", action: nil, keyEquivalent: "")
        themeItem.submenu = themeMenu
        let typographyItem = NSMenuItem(title: "排版", action: nil, keyEquivalent: "")
        typographyItem.submenu = typographyMenu
        menu.addItem(themeItem)
        menu.addItem(typographyItem)

        if #available(macOS 10.15, *) {
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "外观"
            item.paletteLabel = "外观"
            item.toolTip = nil
            item.image = toolbarImage("textformat.size", label: "外观")
            item.menu = menu
            return item
        }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "外观"
        item.paletteLabel = "外观"
        item.toolTip = nil
        item.image = toolbarImage("textformat.size", label: "外观")
        item.target = self
        item.action = #selector(toolbarShowSettings(_:))
        return item
    }

    private func configureSortControls() {
        sortPopup.removeAllItems()
        sortPopup.controlSize = .small
        sortPopup.bezelStyle = .rounded
        sortPopup.font = .systemFont(ofSize: 12)
        sortPopup.target = self
        sortPopup.action = #selector(changeWorkspaceSort(_:))

        for mode in WorkspaceSortMode.allCases {
            sortPopup.addItem(withTitle: mode.title)
            sortPopup.lastItem?.representedObject = mode.rawValue
        }

        sortPopup.selectItem(withTitle: currentWorkspaceSortMode().title)

        sortDirectionButton.bezelStyle = .rounded
        sortDirectionButton.controlSize = .small
        sortDirectionButton.font = .systemFont(ofSize: 12)
        sortDirectionButton.target = self
        sortDirectionButton.action = #selector(toggleWorkspaceSortDirection(_:))
        updateSortDirectionButtonTitle()
    }

    private func currentWorkspaceSortMode() -> WorkspaceSortMode {
        let rawValue = UserDefaults.standard.string(forKey: workspaceSortKey) ?? WorkspaceSortMode.name.rawValue
        if let mode = WorkspaceSortMode(rawValue: rawValue) {
            return mode
        }

        switch rawValue {
        case "name", "path", "nameAscending", "nameDescending":
            return .name
        case "createdAscending", "createdDescending":
            return .created
        case "modifiedNewest", "modifiedOldest", "modifiedAscending", "modifiedDescending":
            return .modified
        default:
            return .name
        }
    }

    private func currentWorkspaceSortDirection() -> WorkspaceSortDirection {
        if let rawValue = UserDefaults.standard.string(forKey: workspaceSortDirectionKey),
           let direction = WorkspaceSortDirection(rawValue: rawValue) {
            return direction
        }

        switch UserDefaults.standard.string(forKey: workspaceSortKey) {
        case "nameDescending", "createdDescending", "modifiedNewest", "modifiedDescending":
            return .descending
        default:
            return .ascending
        }
    }

    private func updateSortDirectionButtonTitle() {
        let direction = currentWorkspaceSortDirection()
        sortDirectionButton.title = direction.title
        sortDirectionButton.toolTip = direction == .ascending ? "切换为降序" : "切换为升序"
    }

    private func restoreLastWorkspace() {
        guard let path = UserDefaults.standard.string(forKey: lastWorkspaceKey), !path.isEmpty else {
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            UserDefaults.standard.removeObject(forKey: lastWorkspaceKey)
            return
        }

        workspaceURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        favoriteWorkspacePaths = savedFavoriteWorkspacePaths(for: workspaceURL)
        workspaceNameField.stringValue = workspaceURL?.lastPathComponent ?? "未打开文件夹"
        if let workspaceURL {
            rememberRecentWorkspace(workspaceURL)
        }
        startWorkspaceWatcher(for: URL(fileURLWithPath: path, isDirectory: true))
    }

    private func restoreLastOpenFileIfNeeded() {
        guard !didRestoreLastOpenFile else { return }
        didRestoreLastOpenFile = true

        guard let path = UserDefaults.standard.string(forKey: lastOpenFileKey), !path.isEmpty else {
            return
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            UserDefaults.standard.removeObject(forKey: lastOpenFileKey)
            return
        }

        loadFile(url, relativePath: relativeWorkspacePath(for: url))
    }

    private func setWorkspaceURL(_ url: URL, remember: Bool, showToast: Bool = true) {
        let standardizedURL = url.standardizedFileURL
        workspaceURL = standardizedURL
        favoriteWorkspacePaths = savedFavoriteWorkspacePaths(for: standardizedURL)
        if remember {
            UserDefaults.standard.set(standardizedURL.path, forKey: lastWorkspaceKey)
            rememberRecentWorkspace(standardizedURL)
        }
        startWorkspaceWatcher(for: standardizedURL)
        refreshWorkspaceFiles(showToast: showToast)
    }

    private func startWorkspaceWatcher(for url: URL) {
        stopWorkspaceWatcher()

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, contextInfo, _, _, _, _ in
            guard let contextInfo else { return }
            let controller = Unmanaged<EditorWindowController>.fromOpaque(contextInfo).takeUnretainedValue()
            DispatchQueue.main.async {
                controller.scheduleWorkspaceRefreshFromFileEvents()
            }
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.6,
            flags
        ) else {
            return
        }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
        workspaceEventStream = stream
    }

    private func stopWorkspaceWatcher() {
        workspaceRefreshWorkItem?.cancel()
        workspaceRefreshWorkItem = nil
        workspaceRefreshGeneration += 1

        guard let stream = workspaceEventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        workspaceEventStream = nil
    }

    private func scheduleWorkspaceRefreshFromFileEvents() {
        guard workspaceURL != nil else { return }

        workspaceRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshWorkspaceFiles(showToast: false)
        }
        workspaceRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func supportedOpenTypes() -> [UTType] {
        var types: [UTType] = [.plainText]
        ["md", "markdown", "mdown", "mkd"].forEach { ext in
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }

    private func refreshWorkspaceFiles(showToast: Bool = true) {
        guard let workspaceURL else {
            workspaceRefreshGeneration += 1
            allWorkspaceFiles = []
            filteredWorkspaceFiles = []
            allWorkspaceFolders = []
            filteredWorkspaceFolders = []
            filteredWorkspaceRootNodes = []
            nodeByRelativePath = [:]
            favoriteWorkspacePaths = []
            workspaceNameField.stringValue = "未打开文件夹"
            sidebarStatusField.stringValue = "打开文件夹后显示 Markdown 文件"
            fileOutline.reloadData()
            return
        }

        workspaceRefreshGeneration += 1
        let generation = workspaceRefreshGeneration
        workspaceNameField.stringValue = workspaceURL.lastPathComponent
        sidebarStatusField.stringValue = "正在扫描工作区..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let contents = self.collectWorkspaceContents(in: workspaceURL)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.workspaceRefreshGeneration == generation,
                      self.workspaceURL?.standardizedFileURL.path == workspaceURL.standardizedFileURL.path else {
                    return
                }

                self.applyWorkspaceContents(contents, workspaceURL: workspaceURL, showToast: showToast)
            }
        }
    }

    private func applyWorkspaceContents(_ contents: WorkspaceContents, workspaceURL: URL, showToast: Bool) {
        allWorkspaceFiles = contents.files
        allWorkspaceFolders = contents.folders
        pruneFavoriteWorkspacePaths()
        workspaceNameField.stringValue = workspaceURL.lastPathComponent
        applyWorkspaceFilter()
        if showToast {
            sendToWeb(["type": "toast", "message": "已打开 \(workspaceURL.lastPathComponent)"])
        }
    }

    private func applyWorkspaceFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredWorkspaceFiles = allWorkspaceFiles
            filteredWorkspaceFolders = allWorkspaceFolders
        } else {
            let matchingFolderPaths = Set(
                allWorkspaceFolders
                    .filter { workspaceFolder($0, matches: query) }
                    .map(\.relativePath)
            )
            filteredWorkspaceFiles = allWorkspaceFiles.filter { file in
                workspaceFile(file, matches: query)
                    || matchingFolderPaths.contains { folderPath in path(file.relativePath, isUnder: folderPath) }
            }
            filteredWorkspaceFolders = allWorkspaceFolders.filter { folder in
                workspaceFolder(folder, matches: query)
                    || matchingFolderPaths.contains { folderPath in path(folder.relativePath, isUnder: folderPath) }
                    || filteredWorkspaceFiles.contains { file in path(file.relativePath, isUnder: folder.relativePath) }
            }
        }
        nodeByRelativePath = [:]
        filteredWorkspaceRootNodes = buildWorkspaceTree(
            from: filteredWorkspaceFiles,
            folders: filteredWorkspaceFolders,
            recordLookup: true
        )

        let favoriteStatus = favoriteWorkspacePaths.isEmpty ? "" : " · \(favoriteWorkspacePaths.count) 个收藏"
        if workspaceURL == nil {
            sidebarStatusField.stringValue = "打开文件夹后显示 Markdown 文件"
        } else if filteredWorkspaceFiles.isEmpty && filteredWorkspaceFolders.isEmpty {
            sidebarStatusField.stringValue = query.isEmpty ? "没有找到 Markdown 文件" : "没有匹配的文件"
        } else if query.isEmpty {
            sidebarStatusField.stringValue = "\(filteredWorkspaceFiles.count) 个 Markdown 文件 · \(filteredWorkspaceFolders.count) 个文件夹\(favoriteStatus)"
        } else {
            sidebarStatusField.stringValue = "匹配 \(filteredWorkspaceFiles.count) / \(allWorkspaceFiles.count) 个文件 · \(filteredWorkspaceFolders.count) 个文件夹\(favoriteStatus)"
        }

        fileOutline.reloadData()
        if query.isEmpty {
            restoreExpandedWorkspaceFolders()
        } else {
            expandWorkspaceTreeForSearch(query)
        }
        selectWorkspaceFile(relativePath: nil, url: currentFileURL)
    }

    private func workspaceFile(_ file: WorkspaceFile, matches query: String) -> Bool {
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return file.name.range(of: query, options: options) != nil
            || file.relativePath.range(of: query, options: options) != nil
    }

    private func workspaceFolder(_ folder: WorkspaceFolder, matches query: String) -> Bool {
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return folder.name.range(of: query, options: options) != nil
            || folder.relativePath.range(of: query, options: options) != nil
    }

    private func path(_ childPath: String, isUnder parentPath: String) -> Bool {
        childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }

    private func buildWorkspaceTree(from files: [WorkspaceFile], folders: [WorkspaceFolder], recordLookup: Bool) -> [WorkspaceNode] {
        var rootNodes: [WorkspaceNode] = []
        var folderByPath: [String: WorkspaceNode] = [:]

        @discardableResult
        func ensureFolder(relativePath: String, url: URL?, createdAt: Date?, modifiedAt: Date?) -> WorkspaceNode? {
            guard !relativePath.isEmpty else { return nil }
            if let existingFolder = folderByPath[relativePath] {
                if let createdAt, existingFolder.createdAt == .distantPast || createdAt < existingFolder.createdAt {
                    existingFolder.createdAt = createdAt
                }
                if let modifiedAt, existingFolder.latestModificationDate == nil || modifiedAt > existingFolder.latestModificationDate! {
                    existingFolder.latestModificationDate = modifiedAt
                }
                return existingFolder
            }

            let components = relativePath.split(separator: "/").map(String.init)
            guard let folderName = components.last else { return nil }
            let parentPath = components.dropLast().joined(separator: "/")
            let parent = ensureFolder(
                relativePath: parentPath,
                url: workspaceURL?.appendingPathComponent(parentPath, isDirectory: true),
                createdAt: nil,
                modifiedAt: nil
            )
            let folderURL = url ?? workspaceURL?.appendingPathComponent(relativePath, isDirectory: true)
            let folder = WorkspaceNode(name: folderName, relativePath: relativePath, url: folderURL, file: nil)
            folder.createdAt = createdAt ?? .distantPast
            folder.latestModificationDate = modifiedAt
            folder.isFavorite = favoriteWorkspacePaths.contains(relativePath)
            folder.parent = parent

            if let parent {
                parent.children.append(folder)
            } else {
                rootNodes.append(folder)
            }
            folderByPath[relativePath] = folder
            if recordLookup {
                nodeByRelativePath[relativePath] = folder
            }
            return folder
        }

        for folder in folders {
            _ = ensureFolder(relativePath: folder.relativePath, url: folder.url, createdAt: folder.createdAt, modifiedAt: folder.modifiedAt)
        }

        for file in files {
            let components = file.relativePath.split(separator: "/").map(String.init)
            guard let fileName = components.last else { continue }
            let parentPath = components.dropLast().joined(separator: "/")
            let parent = ensureFolder(
                relativePath: parentPath,
                url: workspaceURL?.appendingPathComponent(parentPath, isDirectory: true),
                createdAt: nil,
                modifiedAt: nil
            )

            let fileNode = WorkspaceNode(name: fileName, relativePath: file.relativePath, url: file.url, file: file)
            fileNode.isFavorite = favoriteWorkspacePaths.contains(file.relativePath)
            fileNode.parent = parent
            if let parent {
                parent.children.append(fileNode)
                updateFolderModificationDates(from: parent, fileDate: file.modifiedAt)
            } else {
                rootNodes.append(fileNode)
            }
            if recordLookup {
                nodeByRelativePath[file.relativePath] = fileNode
            }
        }

        sortWorkspaceNodes(&rootNodes)
        return rootNodes
    }

    private func updateFolderModificationDates(from folder: WorkspaceNode, fileDate: Date) {
        var node: WorkspaceNode? = folder
        while let current = node {
            if current.latestModificationDate == nil || fileDate > current.latestModificationDate! {
                current.latestModificationDate = fileDate
            }
            node = current.parent
        }
    }

    private func sortWorkspaceNodes(_ nodes: inout [WorkspaceNode]) {
        let mode = currentWorkspaceSortMode()
        let direction = currentWorkspaceSortDirection()
        nodes.sort { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite {
                return lhs.isFavorite && !rhs.isFavorite
            }
            if lhs.isFolder != rhs.isFolder {
                return lhs.isFolder && !rhs.isFolder
            }
            return compareWorkspaceNode(lhs, rhs, mode: mode, direction: direction)
        }

        for node in nodes where node.isFolder {
            sortWorkspaceNodes(&node.children)
        }
    }

    private func compareWorkspaceNode(_ lhs: WorkspaceNode, _ rhs: WorkspaceNode, mode: WorkspaceSortMode, direction: WorkspaceSortDirection) -> Bool {
        let comparison: ComparisonResult
        switch mode {
        case .name:
            comparison = lhs.name.localizedStandardCompare(rhs.name)
        case .created:
            comparison = compareDate(lhs.createdAt, rhs.createdAt, fallbackLHS: lhs.name, fallbackRHS: rhs.name)
        case .modified:
            comparison = compareDate(lhs.latestModificationDate ?? .distantPast, rhs.latestModificationDate ?? .distantPast, fallbackLHS: lhs.name, fallbackRHS: rhs.name)
        }

        switch direction {
        case .ascending:
            return comparison == .orderedAscending
        case .descending:
            return comparison == .orderedDescending
        }
    }

    private func compareWorkspaceText(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private func compareDate(_ lhs: Date, _ rhs: Date, fallbackLHS: String, fallbackRHS: String) -> ComparisonResult {
        if lhs < rhs {
            return .orderedAscending
        }
        if lhs > rhs {
            return .orderedDescending
        }
        return fallbackLHS.localizedStandardCompare(fallbackRHS)
    }

    private func expandWorkspaceTreeForSearch(_ query: String) {
        guard !query.isEmpty else { return }
        isRestoringWorkspaceExpansion = true
        defer { isRestoringWorkspaceExpansion = false }
        expandAllFolders(in: filteredWorkspaceRootNodes)
    }

    private func expandAllFolders(in nodes: [WorkspaceNode]) {
        for node in nodes where node.isFolder {
            fileOutline.expandItem(node)
            expandAllFolders(in: node.children)
        }
    }

    private func expandParents(of node: WorkspaceNode) {
        var parent = node.parent
        while let currentParent = parent {
            fileOutline.expandItem(currentParent)
            parent = currentParent.parent
        }
    }

    private func restoreExpandedWorkspaceFolders() {
        let paths = savedExpandedWorkspaceFolderPaths()
        guard !paths.isEmpty else { return }

        isRestoringWorkspaceExpansion = true
        defer { isRestoringWorkspaceExpansion = false }

        let sortedPaths = paths.sorted {
            $0.split(separator: "/").count < $1.split(separator: "/").count
        }
        for path in sortedPaths {
            guard let node = nodeByRelativePath[path], node.isFolder else { continue }
            expandParents(of: node)
            fileOutline.expandItem(node)
        }
    }

    private func saveExpandedWorkspaceFolderPaths() {
        guard !isRestoringWorkspaceExpansion,
              let workspacePath = workspaceURL?.standardizedFileURL.path else {
            return
        }

        var stored = UserDefaults.standard.dictionary(forKey: expandedWorkspaceFoldersKey) as? [String: [String]] ?? [:]
        stored[workspacePath] = Array(currentExpandedWorkspaceFolderPaths(in: filteredWorkspaceRootNodes)).sorted {
            compareWorkspaceText($0, $1)
        }
        UserDefaults.standard.set(stored, forKey: expandedWorkspaceFoldersKey)
    }

    private func savedExpandedWorkspaceFolderPaths() -> Set<String> {
        guard let workspacePath = workspaceURL?.standardizedFileURL.path,
              let stored = UserDefaults.standard.dictionary(forKey: expandedWorkspaceFoldersKey) as? [String: [String]],
              let paths = stored[workspacePath] else {
            return []
        }
        return Set(paths)
    }

    private func savedFavoriteWorkspacePaths(for url: URL?) -> Set<String> {
        guard let workspacePath = url?.standardizedFileURL.path,
              let stored = UserDefaults.standard.dictionary(forKey: favoriteWorkspacePathsKey) as? [String: [String]],
              let paths = stored[workspacePath] else {
            return []
        }
        return Set(paths)
    }

    private func saveFavoriteWorkspacePaths() {
        guard let workspacePath = workspaceURL?.standardizedFileURL.path else { return }
        var stored = UserDefaults.standard.dictionary(forKey: favoriteWorkspacePathsKey) as? [String: [String]] ?? [:]
        stored[workspacePath] = favoriteWorkspacePaths.sorted { compareWorkspaceText($0, $1) }
        UserDefaults.standard.set(stored, forKey: favoriteWorkspacePathsKey)
    }

    private func pruneFavoriteWorkspacePaths() {
        let validPaths = Set(allWorkspaceFiles.map(\.relativePath) + allWorkspaceFolders.map(\.relativePath))
        let pruned = favoriteWorkspacePaths.intersection(validPaths)
        guard pruned != favoriteWorkspacePaths else { return }
        favoriteWorkspacePaths = pruned
        saveFavoriteWorkspacePaths()
    }

    private func updateWorkspaceFavoriteMenuItem() {
        let nodes = selectedWorkspaceNodes().filter { $0.url != nil }
        guard !nodes.isEmpty else {
            workspaceFavoriteMenuItem?.title = "加入收藏/置顶"
            workspaceFavoriteMenuItem?.isEnabled = false
            return
        }

        let allFavorited = nodes.allSatisfy { favoriteWorkspacePaths.contains($0.relativePath) }
        workspaceFavoriteMenuItem?.title = allFavorited ? "取消收藏/置顶" : "加入收藏/置顶"
        workspaceFavoriteMenuItem?.isEnabled = true
    }

    private func currentExpandedWorkspaceFolderPaths(in nodes: [WorkspaceNode]) -> Set<String> {
        var paths = Set<String>()
        for node in nodes where node.isFolder {
            if fileOutline.isItemExpanded(node) {
                paths.insert(node.relativePath)
            }
            paths.formUnion(currentExpandedWorkspaceFolderPaths(in: node.children))
        }
        return paths
    }

    private func selectWorkspaceFile(relativePath: String?, url: URL?) {
        let targetNode: WorkspaceNode?
        if let relativePath {
            targetNode = nodeByRelativePath[relativePath]
        } else if let url {
            targetNode = nodeByRelativePath.first { $0.value.url?.path == url.path }?.value
        } else {
            targetNode = nil
        }

        guard let targetNode else {
            fileOutline.deselectAll(nil)
            return
        }

        expandParents(of: targetNode)
        let row = fileOutline.row(forItem: targetNode)
        guard row >= 0 else { return }
        fileOutline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        fileOutline.scrollRowToVisible(row)
    }

    private func selectedWorkspaceFile() -> WorkspaceFile? {
        selectedWorkspaceNodes().compactMap(\.file).first
    }

    private func selectedWorkspaceNode() -> WorkspaceNode? {
        let row = fileOutline.selectedRow
        guard row >= 0 else { return nil }
        return fileOutline.item(atRow: row) as? WorkspaceNode
    }

    private func selectedWorkspaceNodes() -> [WorkspaceNode] {
        fileOutline.selectedRowIndexes.compactMap { row in
            fileOutline.item(atRow: row) as? WorkspaceNode
        }
    }

    private func topLevelSelectedWorkspaceNodes() -> [WorkspaceNode] {
        topLevelWorkspaceNodes(from: selectedWorkspaceNodes())
    }

    private func topLevelWorkspaceNodes(from nodes: [WorkspaceNode]) -> [WorkspaceNode] {
        nodes.filter { node in
            guard node.url != nil else { return false }
            var parent = node.parent
            while let currentParent = parent {
                if nodes.contains(where: { $0 === currentParent }) {
                    return false
                }
                parent = currentParent.parent
            }
            return true
        }
    }

    private func workspaceNodes(from pasteboard: NSPasteboard) -> [WorkspaceNode] {
        pasteboard.pasteboardItems?.compactMap { item in
            guard let relativePath = item.string(forType: workspaceNodePasteboardType) else { return nil }
            return nodeByRelativePath[relativePath]
        } ?? []
    }

    private func workspaceDropDestinationURL(for item: Any?) -> URL? {
        guard let node = item as? WorkspaceNode else {
            return workspaceURL
        }

        if node.isFolder {
            return node.url
        }

        return node.parent?.url ?? workspaceURL
    }

    private func workspaceDropTargetItem(for item: Any?) -> WorkspaceNode? {
        guard let node = item as? WorkspaceNode else { return nil }
        return node.isFolder ? node : node.parent
    }

    private func selectedNodesContainCurrentFile(_ nodes: [WorkspaceNode]) -> Bool {
        guard let currentFileURL else { return false }
        return nodes.contains { node in
            guard let nodeURL = node.url else { return false }
            return isURL(currentFileURL, insideOrSame: nodeURL)
        }
    }

    private func workspaceTargetDirectory() -> URL? {
        guard let workspaceURL else { return nil }
        guard let node = selectedWorkspaceNode() else { return workspaceURL }

        if node.isFolder {
            return node.url ?? workspaceURL
        }

        return node.file?.url.deletingLastPathComponent() ?? workspaceURL
    }

    private func workspaceChildURL(baseDirectory: URL, relativeName: String) -> URL? {
        guard let workspaceURL else { return nil }
        return WorkspacePathSecurity.childURL(
            baseDirectory: baseDirectory,
            relativeName: relativeName,
            workspaceURL: workspaceURL
        )
    }

    private func relativeWorkspacePath(for url: URL) -> String? {
        guard let workspaceURL else { return nil }
        let workspacePath = workspaceURL.standardizedFileURL.path
        let workspacePrefix = workspacePath.hasSuffix("/") ? workspacePath : workspacePath + "/"
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(workspacePrefix) else { return nil }
        return String(filePath.dropFirst(workspacePrefix.count))
    }

    private func isURL(_ childURL: URL, insideOrSame parentURL: URL) -> Bool {
        let childPath = childURL.standardizedFileURL.path
        let parentPath = parentURL.standardizedFileURL.path
        let parentPrefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath == parentPath || childPath.hasPrefix(parentPrefix)
    }

    private func chooseWorkspaceDestination(title: String, prompt: String, completion: @escaping (URL) -> Void) {
        guard let workspaceURL, let window else {
            sendToWeb(["type": "toast", "message": "请先打开工作区"])
            return
        }

        let panel = NSOpenPanel()
        panel.title = title
        panel.message = "请选择当前工作区内的目标文件夹。"
        panel.prompt = prompt
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = workspaceTargetDirectory() ?? workspaceURL

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let destinationURL = panel.url else { return }
            guard self.isURL(destinationURL, insideOrSame: workspaceURL) else {
                self.sendToWeb(["type": "toast", "message": "目标文件夹必须在当前工作区内"])
                return
            }
            completion(destinationURL)
        }
    }

    private func uniqueCopyURL(for sourceURL: URL, isFolder: Bool, in destinationDirectory: URL) -> URL {
        let fileManager = FileManager.default
        var candidate = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        guard fileManager.fileExists(atPath: candidate.path) else {
            return candidate
        }

        let baseName = isFolder ? sourceURL.lastPathComponent : sourceURL.deletingPathExtension().lastPathComponent
        let ext = isFolder ? "" : sourceURL.pathExtension
        var counter = 1
        repeat {
            let suffix = counter == 1 ? " copy" : " copy \(counter)"
            let name = ext.isEmpty ? "\(baseName)\(suffix)" : "\(baseName)\(suffix).\(ext)"
            candidate = destinationDirectory.appendingPathComponent(name)
            counter += 1
        } while fileManager.fileExists(atPath: candidate.path)

        return candidate
    }

    private func moveWorkspaceNodes(_ nodes: [WorkspaceNode], to destinationDirectory: URL) {
        var moves: [(source: URL, destination: URL)] = []

        for node in nodes {
            guard let sourceURL = node.url else { continue }
            if node.isFolder && isURL(destinationDirectory, insideOrSame: sourceURL) {
                sendToWeb(["type": "toast", "message": "不能移动到自身或子文件夹内"])
                return
            }

            let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            if destinationURL.standardizedFileURL.path == sourceURL.standardizedFileURL.path {
                continue
            }
            guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                sendToWeb(["type": "toast", "message": "目标文件夹已有同名项目"])
                return
            }
            moves.append((source: sourceURL, destination: destinationURL))
        }

        guard !moves.isEmpty else {
            sendToWeb(["type": "toast", "message": "项目已在目标文件夹中"])
            return
        }

        do {
            for move in moves {
                try FileManager.default.moveItem(at: move.source, to: move.destination)
                updateCurrentFileAfterMoving(from: move.source, to: move.destination)
            }
            refreshWorkspaceFiles(showToast: false)
            selectWorkspaceFile(relativePath: relativeWorkspacePath(for: moves[0].destination), url: moves[0].destination)
            sendToWeb(["type": "toast", "message": "移动完成"])
        } catch {
            sendToWeb(["type": "toast", "message": "移动失败"])
            refreshWorkspaceFiles(showToast: false)
        }
    }

    private func copyWorkspaceNodes(_ nodes: [WorkspaceNode], to destinationDirectory: URL) {
        var copies: [(source: URL, destination: URL)] = []

        for node in nodes {
            guard let sourceURL = node.url else { continue }
            if node.isFolder && isURL(destinationDirectory, insideOrSame: sourceURL) {
                sendToWeb(["type": "toast", "message": "不能复制到自身或子文件夹内"])
                return
            }
            let destinationURL = uniqueCopyURL(for: sourceURL, isFolder: node.isFolder, in: destinationDirectory)
            copies.append((source: sourceURL, destination: destinationURL))
        }

        guard !copies.isEmpty else { return }

        do {
            for copy in copies {
                try FileManager.default.copyItem(at: copy.source, to: copy.destination)
            }
            refreshWorkspaceFiles(showToast: false)
            selectWorkspaceFile(relativePath: relativeWorkspacePath(for: copies[0].destination), url: copies[0].destination)
            sendToWeb(["type": "toast", "message": "复制完成"])
        } catch {
            sendToWeb(["type": "toast", "message": "复制失败"])
            refreshWorkspaceFiles(showToast: false)
        }
    }

    private func promptForWorkspaceName(
        title: String,
        message: String,
        defaultValue: String,
        confirmTitle: String,
        completion: @escaping (String) -> Void
    ) {
        guard let window else { return }

        let input = NSTextField(string: defaultValue)
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 24)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = input
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "取消")

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            completion(value)
        }
    }

    private func updateCurrentFileAfterMoving(from oldURL: URL, to newURL: URL) {
        guard let currentFileURL else { return }

        let currentPath = currentFileURL.standardizedFileURL.path
        let oldPath = oldURL.standardizedFileURL.path
        let newPath: String
        if currentPath == oldPath {
            newPath = newURL.standardizedFileURL.path
        } else if currentPath.hasPrefix(oldPath + "/") {
            let suffix = String(currentPath.dropFirst(oldPath.count + 1))
            newPath = newURL.appendingPathComponent(suffix).standardizedFileURL.path
        } else {
            return
        }

        let movedURL = URL(fileURLWithPath: newPath)
        self.currentFileURL = movedURL
        UserDefaults.standard.set(movedURL.path, forKey: lastOpenFileKey)
        window?.title = "\(movedURL.lastPathComponent) - TonMark"
        removeRecentFile(oldURL.path)
        rememberRecentFile(movedURL)
        sendToWeb([
            "type": "saved",
            "path": movedURL.path,
            "name": movedURL.lastPathComponent,
            "basePath": movedURL.deletingLastPathComponent().path
        ])
    }

    private func confirmTrashWorkspaceNodes(_ nodes: [WorkspaceNode]) {
        guard let window else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = nodes.count == 1 ? "删除 \(nodes[0].name)？" : "删除 \(nodes.count) 个项目？"
        alert.informativeText = "这些项目会移动到废纸篓，可以从废纸篓恢复。"
        alert.addButton(withTitle: "删除到废纸篓")
        alert.addButton(withTitle: "取消")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.trashWorkspaceNodes(nodes)
        }
    }

    private func trashWorkspaceNodes(_ nodes: [WorkspaceNode]) {
        var deletedCurrentFile = false

        do {
            for node in nodes {
                guard let url = node.url else { continue }
                if let currentFileURL, isURL(currentFileURL, insideOrSame: url) {
                    deletedCurrentFile = true
                }
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                removeRecentFiles(under: url)
            }

            refreshWorkspaceFiles(showToast: false)
            if deletedCurrentFile {
                currentFileURL = nil
                UserDefaults.standard.removeObject(forKey: lastOpenFileKey)
                window?.title = "Untitled.md - TonMark"
                sendToWeb(["type": "newDocument"])
            }
            sendToWeb(["type": "toast", "message": "已移动到废纸篓"])
        } catch {
            sendToWeb(["type": "toast", "message": "删除失败"])
            refreshWorkspaceFiles(showToast: false)
        }
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func handleWorkspaceKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.charactersIgnoringModifiers?.lowercased()

        if event.keyCode == 51 || event.keyCode == 117 {
            trashSelectedWorkspaceFiles(nil)
            return true
        }

        if event.keyCode == 36 {
            openSelectedWorkspaceFile(nil)
            return true
        }

        if event.keyCode == 120 {
            renameSelectedWorkspaceItem(nil)
            return true
        }

        if flags.contains(.command), characters == "r" {
            refreshWorkspaceFiles()
            return true
        }

        if flags.contains(.command), flags.contains(.shift), characters == "n" {
            createWorkspaceFolder(nil)
            return true
        }

        if flags.contains(.command), flags.contains(.shift), characters == "l" {
            locateCurrentWorkspaceFile(nil)
            return true
        }

        if flags.contains(.command), flags.contains(.shift), characters == "p" {
            toggleFavoriteSelectedWorkspaceItems(nil)
            return true
        }

        return false
    }

    @objc private func openSelectedWorkspaceFile(_ sender: Any?) {
        let clickedRow = fileOutline.clickedRow
        if clickedRow >= 0, !fileOutline.selectedRowIndexes.contains(clickedRow) {
            fileOutline.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        let node = clickedRow >= 0
            ? fileOutline.item(atRow: clickedRow) as? WorkspaceNode
            : selectedWorkspaceNode()
        guard let node else { return }
        if node.isFolder {
            if fileOutline.isItemExpanded(node) {
                fileOutline.collapseItem(node)
            } else {
                fileOutline.expandItem(node)
            }
            return
        }

        guard let file = node.file else { return }
        if currentFileURL?.path == file.url.path { return }

        continueAfterUnsavedChanges(
            actionName: "切换文件",
            onCancel: { [weak self] in
                self?.selectWorkspaceFile(relativePath: nil, url: self?.currentFileURL)
            },
            proceed: { [weak self] in
                self?.loadFile(file.url, relativePath: file.relativePath)
            }
        )
    }

    @objc private func revealSelectedWorkspaceFile(_ sender: Any?) {
        let urls = selectedWorkspaceNodes().compactMap(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func locateCurrentWorkspaceFile(_ sender: Any?) {
        guard let currentFileURL else {
            sendToWeb(["type": "toast", "message": "当前没有打开文件"])
            return
        }

        guard let workspaceURL, isURL(currentFileURL, insideOrSame: workspaceURL) else {
            sendToWeb(["type": "toast", "message": "当前文件不在工作区内"])
            return
        }

        if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            applyWorkspaceFilter()
        } else {
            refreshWorkspaceFiles(showToast: false)
        }

        selectWorkspaceFile(relativePath: relativeWorkspacePath(for: currentFileURL), url: currentFileURL)
        guard selectedWorkspaceNode()?.url?.path == currentFileURL.path else {
            sendToWeb(["type": "toast", "message": "当前文件已不在工作区中"])
            return
        }

        window?.makeFirstResponder(fileOutline)
    }

    @objc private func toggleFavoriteSelectedWorkspaceItems(_ sender: Any?) {
        let nodes = selectedWorkspaceNodes().filter { $0.url != nil }
        guard !nodes.isEmpty else {
            sendToWeb(["type": "toast", "message": "请选择要收藏的项目"])
            return
        }

        let allFavorited = nodes.allSatisfy { favoriteWorkspacePaths.contains($0.relativePath) }
        for node in nodes {
            if allFavorited {
                favoriteWorkspacePaths.remove(node.relativePath)
            } else {
                favoriteWorkspacePaths.insert(node.relativePath)
            }
        }
        saveFavoriteWorkspacePaths()
        applyWorkspaceFilter()

        if let first = nodes.first {
            selectWorkspaceFile(relativePath: first.relativePath, url: first.url)
        }
        let message = allFavorited ? "已取消收藏" : "已加入收藏并置顶"
        sendToWeb(["type": "toast", "message": message])
    }

    @objc private func createWorkspaceFile(_ sender: Any?) {
        guard let baseDirectory = workspaceTargetDirectory() else {
            sendToWeb(["type": "toast", "message": "请先打开工作区"])
            return
        }

        promptForWorkspaceName(
            title: "新建文件",
            message: "可输入文件名，也可以输入 子文件夹/文件名.md。",
            defaultValue: "Untitled.md",
            confirmTitle: "创建"
        ) { [weak self] rawName in
            guard let self else { return }
            var fileName = rawName
            if URL(fileURLWithPath: fileName).pathExtension.isEmpty {
                fileName += ".md"
            }

            guard let fileURL = self.workspaceChildURL(baseDirectory: baseDirectory, relativeName: fileName) else {
                self.sendToWeb(["type": "toast", "message": "文件名无效"])
                return
            }

            guard !FileManager.default.fileExists(atPath: fileURL.path) else {
                self.sendToWeb(["type": "toast", "message": "文件已存在"])
                return
            }

            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "".write(to: fileURL, atomically: true, encoding: .utf8)
                self.refreshWorkspaceFiles(showToast: false)
                self.loadFile(fileURL, relativePath: self.relativeWorkspacePath(for: fileURL))
            } catch {
                self.sendToWeb(["type": "toast", "message": "创建失败"])
            }
        }
    }

    @objc private func createWorkspaceFolder(_ sender: Any?) {
        guard let baseDirectory = workspaceTargetDirectory() else {
            sendToWeb(["type": "toast", "message": "请先打开工作区"])
            return
        }

        promptForWorkspaceName(
            title: "新建文件夹",
            message: "可输入文件夹名，也可以输入 多级/文件夹。",
            defaultValue: "新建文件夹",
            confirmTitle: "创建"
        ) { [weak self] rawName in
            guard let self else { return }
            guard let folderURL = self.workspaceChildURL(baseDirectory: baseDirectory, relativeName: rawName) else {
                self.sendToWeb(["type": "toast", "message": "文件夹名无效"])
                return
            }

            guard !FileManager.default.fileExists(atPath: folderURL.path) else {
                self.sendToWeb(["type": "toast", "message": "文件夹已存在"])
                return
            }

            do {
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                self.refreshWorkspaceFiles(showToast: false)
                self.selectWorkspaceFile(relativePath: self.relativeWorkspacePath(for: folderURL), url: folderURL)
            } catch {
                self.sendToWeb(["type": "toast", "message": "创建文件夹失败"])
            }
        }
    }

    @objc private func renameSelectedWorkspaceItem(_ sender: Any?) {
        let nodes = selectedWorkspaceNodes()
        guard nodes.count == 1, let node = nodes.first, let oldURL = node.url else {
            sendToWeb(["type": "toast", "message": "请选择一个文件或文件夹"])
            return
        }

        promptForWorkspaceName(
            title: "重命名",
            message: "请输入新的名称。",
            defaultValue: oldURL.lastPathComponent,
            confirmTitle: "重命名"
        ) { [weak self] rawName in
            guard let self else { return }
            var newName = rawName
            if newName.contains("/") {
                self.sendToWeb(["type": "toast", "message": "名称不能包含路径分隔符"])
                return
            }
            if !node.isFolder, URL(fileURLWithPath: newName).pathExtension.isEmpty, !oldURL.pathExtension.isEmpty {
                newName += ".\(oldURL.pathExtension)"
            }

            guard let destinationURL = self.workspaceChildURL(baseDirectory: oldURL.deletingLastPathComponent(), relativeName: newName),
                  destinationURL.path != oldURL.path else {
                return
            }

            guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                self.sendToWeb(["type": "toast", "message": "同名项目已存在"])
                return
            }

            do {
                try FileManager.default.moveItem(at: oldURL, to: destinationURL)
                self.updateCurrentFileAfterMoving(from: oldURL, to: destinationURL)
                self.refreshWorkspaceFiles(showToast: false)
                self.selectWorkspaceFile(relativePath: self.relativeWorkspacePath(for: destinationURL), url: destinationURL)
            } catch {
                self.sendToWeb(["type": "toast", "message": "重命名失败"])
            }
        }
    }

    @objc private func moveSelectedWorkspaceItems(_ sender: Any?) {
        let nodes = topLevelSelectedWorkspaceNodes()
        guard !nodes.isEmpty else {
            sendToWeb(["type": "toast", "message": "请选择要移动的项目"])
            return
        }

        let proceed: () -> Void = { [weak self] in
            guard let self else { return }
            self.chooseWorkspaceDestination(title: "移动到文件夹", prompt: "移动") { destinationURL in
                self.moveWorkspaceNodes(nodes, to: destinationURL)
            }
        }

        if selectedNodesContainCurrentFile(nodes) && isDocumentDirty {
            continueAfterUnsavedChanges(actionName: "移动文件", proceed: proceed)
        } else {
            proceed()
        }
    }

    @objc private func copySelectedWorkspaceItems(_ sender: Any?) {
        let nodes = topLevelSelectedWorkspaceNodes()
        guard !nodes.isEmpty else {
            sendToWeb(["type": "toast", "message": "请选择要复制的项目"])
            return
        }

        chooseWorkspaceDestination(title: "复制到文件夹", prompt: "复制") { [weak self] destinationURL in
            self?.copyWorkspaceNodes(nodes, to: destinationURL)
        }
    }

    @objc private func trashSelectedWorkspaceFiles(_ sender: Any?) {
        let nodes = topLevelSelectedWorkspaceNodes()
        guard !nodes.isEmpty else {
            sendToWeb(["type": "toast", "message": "请选择要删除的项目"])
            return
        }

        let containsCurrentFile = selectedNodesContainCurrentFile(nodes)
        let proceed: () -> Void = { [weak self] in
            guard let self else { return }
            self.confirmTrashWorkspaceNodes(nodes)
        }

        if containsCurrentFile && isDocumentDirty {
            continueAfterUnsavedChanges(actionName: "删除项目", proceed: proceed)
        } else {
            proceed()
        }
    }

    @objc private func refreshWorkspaceFromMenu(_ sender: Any?) {
        refreshWorkspaceFiles()
    }

    @objc private func changeWorkspaceSort(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              WorkspaceSortMode(rawValue: rawValue) != nil else {
            return
        }
        UserDefaults.standard.set(rawValue, forKey: workspaceSortKey)
        applyWorkspaceFilter()
    }

    @objc private func toggleWorkspaceSortDirection(_ sender: NSButton) {
        let newDirection: WorkspaceSortDirection = currentWorkspaceSortDirection() == .ascending ? .descending : .ascending
        UserDefaults.standard.set(newDirection.rawValue, forKey: workspaceSortDirectionKey)
        updateSortDirectionButtonTitle()
        applyWorkspaceFilter()
    }

    @objc private func toolbarToggleSidebar(_ sender: Any?) {
        toggleFileTree()
    }

    @objc private func toolbarQuickOpen(_ sender: Any?) {
        showQuickOpen()
    }

    @objc private func toolbarWorkspaceSearch(_ sender: Any?) {
        showWorkspaceSearch()
    }

    @objc private func toolbarDocumentOutline(_ sender: Any?) {
        showDocumentOutline()
    }

    @objc private func toolbarNewDocument(_ sender: Any?) {
        newDocument()
    }

    @objc private func toolbarOpenDocument(_ sender: Any?) {
        openDocument()
    }

    @objc private func toolbarOpenWorkspace(_ sender: Any?) {
        openWorkspace()
    }

    @objc private func toolbarSaveDocument(_ sender: Any?) {
        saveDocument()
    }

    @objc private func toolbarExportHTMLDocument(_ sender: Any?) {
        exportHTML()
    }

    @objc private func toolbarExportDocument(_ sender: Any?) {
        exportPDF()
    }

    @objc private func toolbarThemeSystem(_ sender: Any?) {
        setTheme("system")
    }

    @objc private func toolbarThemeLight(_ sender: Any?) {
        setTheme("light")
    }

    @objc private func toolbarThemeDark(_ sender: Any?) {
        setTheme("dark")
    }

    @objc private func toolbarThemeSepia(_ sender: Any?) {
        setTheme("sepia")
    }

    @objc private func toolbarIncreaseFontSize(_ sender: Any?) {
        adjustFontSize(by: 1)
    }

    @objc private func toolbarDecreaseFontSize(_ sender: Any?) {
        adjustFontSize(by: -1)
    }

    @objc private func toolbarIncreaseLineHeight(_ sender: Any?) {
        adjustLineHeight(by: 0.05)
    }

    @objc private func toolbarDecreaseLineHeight(_ sender: Any?) {
        adjustLineHeight(by: -0.05)
    }

    @objc private func toolbarResetTypography(_ sender: Any?) {
        resetTypography()
    }

    @objc private func toolbarShowSettings(_ sender: Any?) {
        showSettings()
    }

    @objc private func toolbarTogglePreview(_ sender: Any?) {
        togglePreview()
    }
}

private struct WorkspaceFile {
    let name: String
    let relativePath: String
    let url: URL
    let createdAt: Date
    let modifiedAt: Date
}

private struct WorkspaceSearchResult {
    let file: WorkspaceFile
    let line: Int
    let snippet: String
}

private struct CachedWorkspaceContent {
    let modifiedAt: Date
    let byteCount: Int
    let lines: [String]
    let normalizedLines: [String]
    let estimatedCost: Int
}

private struct DocumentSnapshot {
    let url: URL
    let createdAt: Date
    let byteCount: Int
}

private struct WorkspaceFolder {
    let name: String
    let relativePath: String
    let url: URL
    let createdAt: Date
    let modifiedAt: Date
}

private struct WorkspaceContents {
    let files: [WorkspaceFile]
    let folders: [WorkspaceFolder]
}

private final class SnapshotHistoryPanelController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let snapshots: [DocumentSnapshot]
    private let restoreHandler: (DocumentSnapshot) -> Void
    private let tableView = NSTableView()
    private let previewTextView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let restoreButton = NSButton(title: "恢复到编辑器", target: nil, action: nil)
    private var didNotifyClose = false

    init(fileName: String, snapshots: [DocumentSnapshot], restoreHandler: @escaping (DocumentSnapshot) -> Void) {
        self.snapshots = snapshots
        self.restoreHandler = restoreHandler

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "\(fileName) 的版本历史"
        panel.isReleasedWhenClosed = false

        super.init(window: panel)

        panel.delegate = self
        buildPanel(fileName: fileName)
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        updatePreview()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        snapshots.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < snapshots.count else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("SnapshotCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SnapshotCellView ?? SnapshotCellView()
        cell.identifier = identifier
        cell.configure(snapshot: snapshots[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }

    func windowWillClose(_ notification: Notification) {
        notifyClose()
    }

    private func buildPanel(fileName: String) {
        guard let contentView = window?.contentView else { return }

        let titleLabel = NSTextField(labelWithString: "版本历史")
        let hintLabel = NSTextField(labelWithString: "恢复操作只会把快照载入编辑器，保存后才会写回原文件。")
        let tableScroll = NSScrollView()
        let previewScroll = NSScrollView()
        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closePanel(_:)))

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        previewScroll.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        restoreButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("snapshot"))
        column.title = ""
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 48
        tableView.intercellSpacing = NSSize(width: 0, height: 3)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(restoreSelectedSnapshot(_:))
        tableView.selectionHighlightStyle = .regular
        tableView.usesAlternatingRowBackgroundColors = false

        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .noBorder

        previewTextView.isEditable = false
        previewTextView.isRichText = false
        previewTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        previewTextView.textColor = .labelColor
        previewTextView.drawsBackground = true
        previewTextView.backgroundColor = .textBackgroundColor
        previewTextView.minSize = NSSize(width: 0, height: 0)
        previewTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        previewTextView.isVerticallyResizable = true
        previewTextView.isHorizontallyResizable = true
        previewTextView.autoresizingMask = [.width]
        previewTextView.textContainerInset = NSSize(width: 10, height: 10)
        previewTextView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        previewTextView.textContainer?.widthTracksTextView = false

        previewScroll.documentView = previewTextView
        previewScroll.hasVerticalScroller = true
        previewScroll.hasHorizontalScroller = true
        previewScroll.borderType = .lineBorder

        restoreButton.target = self
        restoreButton.action = #selector(restoreSelectedSnapshot(_:))
        restoreButton.bezelStyle = .rounded
        closeButton.bezelStyle = .rounded

        contentView.addSubview(titleLabel)
        contentView.addSubview(hintLabel)
        contentView.addSubview(tableScroll)
        contentView.addSubview(previewScroll)
        contentView.addSubview(statusLabel)
        contentView.addSubview(restoreButton)
        contentView.addSubview(closeButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),

            hintLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            hintLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),

            tableScroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            tableScroll.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 12),
            tableScroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),
            tableScroll.widthAnchor.constraint(equalToConstant: 250),

            previewScroll.leadingAnchor.constraint(equalTo: tableScroll.trailingAnchor, constant: 12),
            previewScroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            previewScroll.topAnchor.constraint(equalTo: tableScroll.topAnchor),
            previewScroll.bottomAnchor.constraint(equalTo: tableScroll.bottomAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: tableScroll.leadingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: restoreButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: restoreButton.leadingAnchor, constant: -12),

            closeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            closeButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            closeButton.widthAnchor.constraint(equalToConstant: 82),

            restoreButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            restoreButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            restoreButton.widthAnchor.constraint(equalToConstant: 116)
        ])
    }

    private func updatePreview() {
        let row = tableView.selectedRow
        guard row >= 0, row < snapshots.count else {
            previewTextView.string = ""
            statusLabel.stringValue = "\(snapshots.count) 个快照"
            restoreButton.isEnabled = false
            return
        }

        let snapshot = snapshots[row]
        previewTextView.string = (try? String(contentsOf: snapshot.url, encoding: .utf8)) ?? "快照读取失败"
        statusLabel.stringValue = "\(row + 1) / \(snapshots.count) 个快照"
        restoreButton.isEnabled = true
    }

    @objc private func restoreSelectedSnapshot(_ sender: Any?) {
        let row = tableView.selectedRow
        guard row >= 0, row < snapshots.count else { return }
        restoreHandler(snapshots[row])
        closePanel(nil)
    }

    @objc private func closePanel(_ sender: Any?) {
        guard let panel = window else { return }
        if let parent = panel.sheetParent {
            parent.endSheet(panel)
        }
        panel.orderOut(nil)
        notifyClose()
    }

    private func notifyClose() {
        guard !didNotifyClose else { return }
        didNotifyClose = true
        onClose?()
    }
}

private final class WorkspaceSearchPanelController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let files: [WorkspaceFile]
    private var results: [WorkspaceSearchResult] = []
    private let openHandler: (WorkspaceSearchResult) -> Void
    private let contentView = NSView()
    private let searchField = QuickOpenSearchField()
    private let tableView = QuickOpenTableView()
    private let hintLabel = NSTextField(labelWithString: "搜索当前工作区内所有 Markdown/txt 内容，回车打开命中行")
    private let statusLabel = NSTextField(labelWithString: "")
    private var visualStyle: SidebarVisualStyle
    private var searchWorkItem: DispatchWorkItem?
    private let searchQueue = DispatchQueue(label: "io.tonmark.workspace-search", qos: .userInitiated)
    private var contentCache: [String: CachedWorkspaceContent] = [:]
    private var contentCacheCost = 0
    private var searchGeneration = 0
    private var didNotifyClose = false
    private var outsideClickMonitor: Any?

    init(files: [WorkspaceFile], visualStyle: SidebarVisualStyle, openHandler: @escaping (WorkspaceSearchResult) -> Void) {
        self.files = files
        self.visualStyle = visualStyle
        self.openHandler = openHandler

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "工作区全文搜索"
        panel.isReleasedWhenClosed = false

        super.init(window: panel)

        panel.delegate = self
        buildPanel()
        applyVisualStyle(visualStyle)
        updateEmptyState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < results.count else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("WorkspaceSearchResultCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SearchResultCellView ?? SearchResultCellView()
        cell.identifier = identifier
        cell.configure(result: results[row], style: visualStyle)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SidebarOutlineRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateStatus()
    }

    func controlTextDidChange(_ obj: Notification) {
        scheduleSearch()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            openSelected(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closePanel()
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        searchWorkItem?.cancel()
        searchGeneration += 1
        removeOutsideClickMonitor()
        if let panel = window {
            panel.parent?.removeChildWindow(panel)
        }
        notifyClose()
    }

    func startOutsideClickDismissal() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.window, panel.isVisible else { return event }
            if event.window !== panel {
                self.closePanel()
            }
            return event
        }
    }

    private func buildPanel() {
        guard let panel = window else { return }

        let scrollView = NSScrollView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))

        contentView.translatesAutoresizingMaskIntoConstraints = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "搜索工作区内容"
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: 16)
        searchField.delegate = self
        searchField.keyDownHandler = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }

        hintLabel.textColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: 12)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)

        column.title = ""
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 60
        tableView.intercellSpacing = NSSize(width: 0, height: 3)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelected(_:))
        tableView.allowsMultipleSelection = false
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.keyDownHandler = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        panel.contentView = contentView
        contentView.addSubview(searchField)
        contentView.addSubview(hintLabel)
        contentView.addSubview(scrollView)
        contentView.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(equalToConstant: 720),
            contentView.heightAnchor.constraint(equalToConstant: 560),

            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            searchField.heightAnchor.constraint(equalToConstant: 34),

            hintLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: 2),
            hintLabel.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            hintLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: 2),
            statusLabel.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14)
        ])

        panel.initialFirstResponder = searchField
    }

    func applyVisualStyle(_ style: SidebarVisualStyle) {
        visualStyle = style
        window?.appearance = style.appearance
        window?.backgroundColor = style.panelBackground
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = style.panelBackground.cgColor
        searchField.appearance = style.appearance
        tableView.appearance = style.appearance
        tableView.backgroundColor = style.panelBackground
        hintLabel.textColor = style.secondaryText
        statusLabel.textColor = style.secondaryText
        SidebarOutlineRowView.selectionColor = style.selectionColor
        tableView.reloadData()
    }

    private func scheduleSearch() {
        searchWorkItem?.cancel()
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchGeneration += 1
            results = []
            tableView.reloadData()
            updateEmptyState()
            return
        }

        searchGeneration += 1
        let generation = searchGeneration
        statusLabel.stringValue = "准备搜索..."
        let workItem = DispatchWorkItem { [weak self] in
            self?.performSearch(query: query, generation: generation)
        }
        searchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    private func performSearch(query: String, generation: Int) {
        let files = self.files
        statusLabel.stringValue = "正在搜索 \(files.count) 个文档..."

        searchQueue.async { [weak self] in
            guard let self else { return }
            guard self.isCurrentSearchGeneration(generation) else { return }
            let found = self.search(files: files, query: query, generation: generation, limit: 600)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.searchGeneration == generation else { return }
                self.results = found
                self.tableView.reloadData()
                if found.isEmpty {
                    self.tableView.deselectAll(nil)
                } else {
                    self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    self.tableView.scrollRowToVisible(0)
                }
                self.updateStatus()
            }
        }
    }

    private func search(files: [WorkspaceFile], query: String, generation: Int, limit: Int) -> [WorkspaceSearchResult] {
        let foldedQuery = Self.normalized(query)
        guard !foldedQuery.isEmpty else { return [] }

        var output: [WorkspaceSearchResult] = []
        for (fileIndex, file) in files.enumerated() {
            if fileIndex.isMultiple(of: 25), !isCurrentSearchGeneration(generation) {
                return []
            }

            guard output.count < limit,
                  let content = cachedContent(for: file) else {
                continue
            }

            for (index, line) in content.lines.enumerated() {
                guard content.normalizedLines[index].contains(foldedQuery) else { continue }
                output.append(WorkspaceSearchResult(
                    file: file,
                    line: index + 1,
                    snippet: Self.snippet(from: line)
                ))
                if output.count >= limit {
                    return output
                }
            }
        }
        return output
    }

    private func cachedContent(for file: WorkspaceFile) -> CachedWorkspaceContent? {
        guard let values = try? file.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true else {
            removeCachedContent(for: file.url.path)
            return nil
        }

        let modifiedAt = values.contentModificationDate ?? file.modifiedAt
        let byteCount = values.fileSize ?? 0
        let path = file.url.path
        if let cached = contentCache[path],
           cached.modifiedAt == modifiedAt,
           cached.byteCount == byteCount {
            return cached
        }

        guard let content = try? String(contentsOf: file.url, encoding: .utf8) else {
            removeCachedContent(for: path)
            return nil
        }

        let lines = content.components(separatedBy: .newlines)
        let cached = CachedWorkspaceContent(
            modifiedAt: modifiedAt,
            byteCount: byteCount,
            lines: lines,
            normalizedLines: lines.map(Self.normalized),
            estimatedCost: content.utf8.count * 2
        )
        storeCachedContent(cached, for: path)
        return cached
    }

    private func storeCachedContent(_ cached: CachedWorkspaceContent, for path: String) {
        removeCachedContent(for: path)
        contentCache[path] = cached
        contentCacheCost += cached.estimatedCost
        pruneContentCacheIfNeeded()
    }

    private func removeCachedContent(for path: String) {
        guard let cached = contentCache.removeValue(forKey: path) else { return }
        contentCacheCost = max(0, contentCacheCost - cached.estimatedCost)
    }

    private func pruneContentCacheIfNeeded() {
        let maximumCacheCost = 48 * 1024 * 1024
        guard contentCacheCost > maximumCacheCost else { return }
        contentCache.removeAll(keepingCapacity: true)
        contentCacheCost = 0
    }

    private func isCurrentSearchGeneration(_ generation: Int) -> Bool {
        if Thread.isMainThread {
            return searchGeneration == generation
        }

        return DispatchQueue.main.sync { [weak self] in
            self?.searchGeneration == generation
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }

    private static func snippet(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 180 else { return trimmed.isEmpty ? "空行" : trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: 180)
        return "\(trimmed[..<end])..."
    }

    private func updateEmptyState() {
        statusLabel.stringValue = "输入关键词后搜索 \(files.count) 个文档"
    }

    private func updateStatus() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            updateEmptyState()
            return
        }

        if results.isEmpty {
            statusLabel.stringValue = "没有找到匹配内容"
            return
        }

        let selected = tableView.selectedRow >= 0 ? tableView.selectedRow + 1 : 1
        let capped = results.count >= 600 ? "，已显示前 600 条" : ""
        statusLabel.stringValue = "\(selected) / \(results.count) 个结果\(capped)"
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 76:
            openSelected(nil)
            return true
        case 53:
            closePanel()
            return true
        case 125:
            moveSelection(by: 1)
            return true
        case 126:
            moveSelection(by: -1)
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let current = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        let next = min(max(current + delta, 0), results.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    @objc private func openSelected(_ sender: Any?) {
        let row = tableView.selectedRow
        guard row >= 0, row < results.count else { return }
        let result = results[row]
        closePanel()
        openHandler(result)
    }

    private func closePanel() {
        searchWorkItem?.cancel()
        removeOutsideClickMonitor()
        guard let panel = window else { return }
        if let parent = panel.sheetParent {
            parent.endSheet(panel)
        }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        notifyClose()
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func notifyClose() {
        guard !didNotifyClose else { return }
        didNotifyClose = true
        onClose?()
    }
}

private final class QuickOpenPanelController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let files: [WorkspaceFile]
    private var filteredFiles: [WorkspaceFile]
    private let currentFileURL: URL?
    private let openHandler: (WorkspaceFile) -> Void
    private let contentView = NSView()
    private let searchField = QuickOpenSearchField()
    private let tableView = QuickOpenTableView()
    private let hintLabel = NSTextField(labelWithString: "输入文件名或路径搜索，上下键选择，回车打开")
    private let statusLabel = NSTextField(labelWithString: "")
    private var visualStyle: SidebarVisualStyle
    private var didNotifyClose = false
    private var outsideClickMonitor: Any?

    init(files: [WorkspaceFile], currentFileURL: URL?, visualStyle: SidebarVisualStyle, openHandler: @escaping (WorkspaceFile) -> Void) {
        self.files = files
        self.filteredFiles = files
        self.currentFileURL = currentFileURL
        self.visualStyle = visualStyle
        self.openHandler = openHandler

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "快速打开"
        panel.isReleasedWhenClosed = false

        super.init(window: panel)

        panel.delegate = self
        buildPanel()
        applyVisualStyle(visualStyle)
        applyFilter(selectingCurrent: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredFiles.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < filteredFiles.count else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("QuickOpenFileCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? FileCellView ?? FileCellView()
        let file = filteredFiles[row]
        cell.identifier = identifier
        cell.configure(name: file.name, path: file.relativePath, isFolder: false, isFavorite: false, style: visualStyle)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SidebarOutlineRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateStatus()
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(selectingCurrent: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            openSelected(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closePanel()
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        removeOutsideClickMonitor()
        if let panel = window {
            panel.parent?.removeChildWindow(panel)
        }
        notifyClose()
    }

    func startOutsideClickDismissal() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.window, panel.isVisible else { return event }
            if event.window !== panel {
                self.closePanel()
            }
            return event
        }
    }

    private func buildPanel() {
        guard let panel = window else { return }

        let scrollView = NSScrollView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))

        contentView.translatesAutoresizingMaskIntoConstraints = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "快速打开文件"
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: 16)
        searchField.delegate = self
        searchField.keyDownHandler = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }

        hintLabel.textColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: 12)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)

        column.title = ""
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelected(_:))
        tableView.allowsMultipleSelection = false
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.keyDownHandler = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        panel.contentView = contentView
        contentView.addSubview(searchField)
        contentView.addSubview(hintLabel)
        contentView.addSubview(scrollView)
        contentView.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(equalToConstant: 640),
            contentView.heightAnchor.constraint(equalToConstant: 500),

            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            searchField.heightAnchor.constraint(equalToConstant: 34),

            hintLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: 2),
            hintLabel.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            hintLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: 2),
            statusLabel.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14)
        ])

        panel.initialFirstResponder = searchField
    }

    func applyVisualStyle(_ style: SidebarVisualStyle) {
        visualStyle = style
        window?.appearance = style.appearance
        window?.backgroundColor = style.panelBackground
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = style.panelBackground.cgColor
        searchField.appearance = style.appearance
        tableView.appearance = style.appearance
        tableView.backgroundColor = style.panelBackground
        hintLabel.textColor = style.secondaryText
        statusLabel.textColor = style.secondaryText
        SidebarOutlineRowView.selectionColor = style.selectionColor
        tableView.reloadData()
    }

    private func applyFilter(selectingCurrent: Bool) {
        let query = normalized(searchField.stringValue)
        let tokens = query.split(separator: " ").map(String.init)

        if tokens.isEmpty {
            filteredFiles = files
        } else {
            filteredFiles = files
                .filter { file in
                    let name = normalized(file.name)
                    let path = normalized(file.relativePath)
                    return tokens.allSatisfy { token in
                        name.contains(token) || path.contains(token)
                    }
                }
                .sorted { lhs, rhs in
                    let lhsScore = matchScore(for: lhs, query: query)
                    let rhsScore = matchScore(for: rhs, query: query)
                    if lhsScore != rhsScore {
                        return lhsScore < rhsScore
                    }
                    return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
                }
        }

        tableView.reloadData()
        selectBestRow(selectingCurrent: selectingCurrent)
        updateStatus()
    }

    private func selectBestRow(selectingCurrent: Bool) {
        guard !filteredFiles.isEmpty else {
            tableView.deselectAll(nil)
            return
        }

        let row: Int
        if selectingCurrent,
           let currentFileURL,
           let currentIndex = filteredFiles.firstIndex(where: { $0.url.path == currentFileURL.path }) {
            row = currentIndex
        } else {
            row = 0
        }

        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func updateStatus() {
        if filteredFiles.isEmpty {
            statusLabel.stringValue = "没有匹配的文件"
            return
        }

        let selected = tableView.selectedRow >= 0 ? tableView.selectedRow + 1 : 1
        statusLabel.stringValue = "\(selected) / \(filteredFiles.count) 个匹配 · 工作区共 \(files.count) 个文档"
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private func matchScore(for file: WorkspaceFile, query: String) -> Int {
        let name = normalized(file.name)
        let path = normalized(file.relativePath)

        if name == query { return 0 }
        if name.hasPrefix(query) { return 10 }
        if path.hasPrefix(query) { return 20 }
        if name.contains(query) { return 30 }
        if path.contains(query) { return 40 }
        return 100
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 76:
            openSelected(nil)
            return true
        case 53:
            closePanel()
            return true
        case 125:
            moveSelection(by: 1)
            return true
        case 126:
            moveSelection(by: -1)
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !filteredFiles.isEmpty else { return }
        let current = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        let next = min(max(current + delta, 0), filteredFiles.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    @objc private func openSelected(_ sender: Any?) {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredFiles.count else { return }
        let file = filteredFiles[row]
        closePanel()
        openHandler(file)
    }

    private func closePanel() {
        removeOutsideClickMonitor()
        guard let panel = window else { return }
        if let parent = panel.sheetParent {
            parent.endSheet(panel)
        }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        notifyClose()
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func notifyClose() {
        guard !didNotifyClose else { return }
        didNotifyClose = true
        onClose?()
    }
}

private final class WorkspaceOutlineView: NSOutlineView {
    var keyDownHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyDownHandler?(event) == true {
            return
        }
        super.keyDown(with: event)
    }
}

private final class QuickOpenSearchField: NSSearchField {
    var keyDownHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyDownHandler?(event) == true {
            return
        }
        super.keyDown(with: event)
    }
}

private final class QuickOpenTableView: NSTableView {
    var keyDownHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyDownHandler?(event) == true {
            return
        }
        super.keyDown(with: event)
    }
}

private final class SearchResultCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let snippetLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    func configure(result: WorkspaceSearchResult, style: SidebarVisualStyle = .dark) {
        iconView.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: result.file.name)
        iconView.contentTintColor = style.fileIcon
        titleLabel.stringValue = "\(result.file.name):\(result.line)"
        pathLabel.stringValue = result.file.relativePath
        snippetLabel.stringValue = result.snippet
        titleLabel.textColor = style.primaryText
        pathLabel.textColor = style.tertiaryText
        snippetLabel.textColor = style.primaryText
    }

    private func build() {
        wantsLayer = true

        let stack = NSStackView(views: [titleLabel, pathLabel, snippetLabel])
        stack.orientation = .vertical
        stack.spacing = 1
        stack.alignment = .leading
        stack.distribution = .fill

        iconView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1

        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1

        snippetLabel.font = .systemFont(ofSize: 11)
        snippetLabel.textColor = .labelColor
        snippetLabel.lineBreakMode = .byTruncatingTail
        snippetLabel.maximumNumberOfLines = 1

        addSubview(iconView)
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            stack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -5)
        ])
    }
}

private final class SnapshotCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let byteFormatter = ByteCountFormatter()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    func configure(snapshot: DocumentSnapshot) {
        titleLabel.stringValue = Self.dateFormatter.string(from: snapshot.createdAt)
        byteFormatter.countStyle = .file
        subtitleLabel.stringValue = byteFormatter.string(fromByteCount: Int64(snapshot.byteCount))
    }

    private func build() {
        wantsLayer = true

        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.maximumNumberOfLines = 1
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 1

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6)
        ])
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

private final class WorkspaceNode {
    let name: String
    let relativePath: String
    let url: URL?
    let file: WorkspaceFile?
    var children: [WorkspaceNode] = []
    var createdAt: Date
    var latestModificationDate: Date?
    var isFavorite = false
    weak var parent: WorkspaceNode?

    init(name: String, relativePath: String, url: URL?, file: WorkspaceFile?) {
        self.name = name
        self.relativePath = relativePath
        self.url = url
        self.file = file
        self.createdAt = file?.createdAt ?? .distantPast
        self.latestModificationDate = file?.modifiedAt
    }

    var isFolder: Bool {
        file == nil
    }

    var displayPath: String {
        if isFolder {
            if children.isEmpty {
                return "空文件夹"
            }
            return children.count == 1 ? "1 个项目" : "\(children.count) 个项目"
        }
        return relativePath
    }
}

private struct ImageAssetTarget {
    let directory: URL
    let baseDirectory: URL

    func relativePath(to fileURL: URL) -> String {
        let base = baseDirectory.standardizedFileURL.pathComponents
        let target = fileURL.standardizedFileURL.pathComponents
        var common = 0

        while common < base.count && common < target.count && base[common] == target[common] {
            common += 1
        }

        let parents = Array(repeating: "..", count: base.count - common)
        let children = Array(target.dropFirst(common))
        return (parents + children).joined(separator: "/")
    }
}

private final class TonMarkAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    var allowedRootsProvider: (() -> [URL])?

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let fileURL = fileURL(from: requestURL),
              isAllowed(fileURL),
              let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(CocoaError(.fileReadNoPermission))
            return
        }

        let response = URLResponse(
            url: requestURL,
            mimeType: mimeType(for: fileURL),
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func fileURL(from url: URL) -> URL? {
        guard url.scheme?.lowercased() == "tonmark-asset",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func isAllowed(_ fileURL: URL) -> Bool {
        let roots = readAllowedRoots()
        return roots.contains { root in
            Self.isURL(fileURL, insideOrSame: root)
        }
    }

    private func readAllowedRoots() -> [URL] {
        if Thread.isMainThread {
            return allowedRootsProvider?() ?? []
        }
        return DispatchQueue.main.sync { [weak self] in
            self?.allowedRootsProvider?() ?? []
        }
    }

    private func mimeType(for fileURL: URL) -> String {
        UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    private static func isURL(_ childURL: URL, insideOrSame parentURL: URL) -> Bool {
        let childPath = childURL.standardizedFileURL.path
        let parentPath = parentURL.standardizedFileURL.path
        let parentPrefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath == parentPath || childPath.hasPrefix(parentPrefix)
    }
}

private final class EditorWebView: WKWebView {}

private final class InstantTooltipToolbarButton: NSButton {
    private let tooltipText: String
    private let popupMenu: NSMenu?
    private var trackingAreaRef: NSTrackingArea?

    override var fittingSize: NSSize {
        NSSize(width: 30, height: 28)
    }

    init(label: String, symbol: String, target: AnyObject?, action: Selector) {
        self.tooltipText = label
        self.popupMenu = nil
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: 30, height: 28)))
        configure(label: label, symbol: symbol)
        self.target = target
        self.action = action
    }

    init(label: String, symbol: String, menu: NSMenu) {
        self.tooltipText = label
        self.popupMenu = menu
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: 30, height: 28)))
        configure(label: label, symbol: symbol)
        target = self
        action = #selector(showPopupMenu(_:))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard let window else { return }
        let anchorInWindow = convert(NSPoint(x: bounds.midX, y: bounds.minY), to: nil)
        InstantTooltipPresenter.shared.show(
            text: tooltipText,
            anchorOnScreen: window.convertPoint(toScreen: anchorInWindow)
        )
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        InstantTooltipPresenter.shared.hide()
    }

    override func mouseDown(with event: NSEvent) {
        InstantTooltipPresenter.shared.hide()
        super.mouseDown(with: event)
    }

    private func configure(label: String, symbol: String) {
        translatesAutoresizingMaskIntoConstraints = false
        setButtonType(.momentaryPushIn)
        bezelStyle = .texturedRounded
        isBordered = true
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        imagePosition = .imageOnly
        toolTip = nil
        setAccessibilityLabel(label)
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    @objc private func showPopupMenu(_ sender: Any?) {
        guard let popupMenu else { return }
        popupMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.minY - 4), in: self)
    }
}

private final class InstantTooltipPresenter {
    static let shared = InstantTooltipPresenter()

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    private init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.transient, .ignoresCycle]

        let contentView = NSView()
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 6
        contentView.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.92).cgColor

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false

        panel.contentView = contentView
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5)
        ])
    }

    func show(text: String, anchorOnScreen: NSPoint) {
        label.stringValue = text
        let size = label.intrinsicContentSize
        let panelSize = NSSize(width: ceil(size.width + 16), height: 26)
        panel.setFrame(
            NSRect(
                x: anchorOnScreen.x - panelSize.width / 2,
                y: anchorOnScreen.y - panelSize.height - 6,
                width: panelSize.width,
                height: panelSize.height
            ),
            display: true
        )
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private final class TitlebarDragRegionView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, bounds.contains(point) else {
            return nil
        }

        guard !containsInteractiveControl(at: point) else {
            return nil
        }

        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }

        let startMouseLocation = NSEvent.mouseLocation
        let startWindowOrigin = window.frame.origin

        while let dragEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            switch dragEvent.type {
            case .leftMouseDragged:
                let currentMouseLocation = NSEvent.mouseLocation
                window.setFrameOrigin(NSPoint(
                    x: startWindowOrigin.x + currentMouseLocation.x - startMouseLocation.x,
                    y: startWindowOrigin.y + currentMouseLocation.y - startMouseLocation.y
                ))
            case .leftMouseUp:
                return
            default:
                break
            }
        }
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func containsInteractiveControl(at point: NSPoint) -> Bool {
        guard let frameView = superview else { return false }
        return containsInteractiveControl(at: point, in: frameView)
    }

    private func containsInteractiveControl(at point: NSPoint, in view: NSView) -> Bool {
        for subview in view.subviews.reversed() where subview !== self && !subview.isHidden && subview.alphaValue > 0.01 {
            let pointInSubview = subview.convert(point, from: self)
            guard subview.bounds.contains(pointInSubview) else { continue }

            if subview is NSControl {
                return true
            }

            if containsInteractiveControl(at: point, in: subview) {
                return true
            }
        }

        return false
    }
}

private final class EditorTitlebarView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, bounds.contains(point) else {
            return nil
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }

        let startMouseLocation = NSEvent.mouseLocation
        let startWindowOrigin = window.frame.origin

        while let dragEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            switch dragEvent.type {
            case .leftMouseDragged:
                let currentMouseLocation = NSEvent.mouseLocation
                window.setFrameOrigin(NSPoint(
                    x: startWindowOrigin.x + currentMouseLocation.x - startMouseLocation.x,
                    y: startWindowOrigin.y + currentMouseLocation.y - startMouseLocation.y
                ))
            case .leftMouseUp:
                return
            default:
                break
            }
        }
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

private struct SidebarVisualStyle {
    let backdropPalette: SidebarBackdropPalette
    let appearance: NSAppearance?
    let primaryText: NSColor
    let secondaryText: NSColor
    let tertiaryText: NSColor
    let folderIcon: NSColor
    let fileIcon: NSColor
    let selectionColor: NSColor
    let panelBackground: NSColor

    static let dark = SidebarVisualStyle(
        backdropPalette: .dark,
        appearance: NSAppearance(named: .darkAqua),
        primaryText: NSColor.white.withAlphaComponent(0.84),
        secondaryText: NSColor.white.withAlphaComponent(0.55),
        tertiaryText: NSColor.white.withAlphaComponent(0.46),
        folderIcon: NSColor.white.withAlphaComponent(0.78),
        fileIcon: NSColor.white.withAlphaComponent(0.58),
        selectionColor: NSColor(calibratedWhite: 1, alpha: 0.12),
        panelBackground: NSColor(calibratedRed: 0.17, green: 0.16, blue: 0.14, alpha: 1)
    )

    static let light = SidebarVisualStyle(
        backdropPalette: .light,
        appearance: NSAppearance(named: .aqua),
        primaryText: NSColor(calibratedRed: 0.20, green: 0.19, blue: 0.17, alpha: 0.88),
        secondaryText: NSColor(calibratedRed: 0.46, green: 0.43, blue: 0.38, alpha: 0.82),
        tertiaryText: NSColor(calibratedRed: 0.54, green: 0.50, blue: 0.44, alpha: 0.78),
        folderIcon: NSColor(calibratedRed: 0.42, green: 0.39, blue: 0.34, alpha: 0.82),
        fileIcon: NSColor(calibratedRed: 0.52, green: 0.48, blue: 0.42, alpha: 0.78),
        selectionColor: NSColor(calibratedRed: 0.88, green: 0.85, blue: 0.80, alpha: 0.82),
        panelBackground: NSColor(calibratedRed: 0.984, green: 0.980, blue: 0.969, alpha: 1)
    )

    static let sepia = SidebarVisualStyle(
        backdropPalette: .sepia,
        appearance: NSAppearance(named: .aqua),
        primaryText: NSColor(calibratedRed: 0.27, green: 0.22, blue: 0.16, alpha: 0.88),
        secondaryText: NSColor(calibratedRed: 0.50, green: 0.41, blue: 0.30, alpha: 0.82),
        tertiaryText: NSColor(calibratedRed: 0.58, green: 0.48, blue: 0.35, alpha: 0.78),
        folderIcon: NSColor(calibratedRed: 0.45, green: 0.36, blue: 0.24, alpha: 0.82),
        fileIcon: NSColor(calibratedRed: 0.55, green: 0.45, blue: 0.32, alpha: 0.78),
        selectionColor: NSColor(calibratedRed: 0.84, green: 0.77, blue: 0.66, alpha: 0.82),
        panelBackground: NSColor(calibratedRed: 0.957, green: 0.925, blue: 0.858, alpha: 1)
    )
}

private struct SidebarBackdropPalette {
    let gradientColors: [NSColor]
    let overlayColor: NSColor
    let separatorColor: NSColor

    static let dark = SidebarBackdropPalette(
        gradientColors: [
            NSColor(calibratedRed: 0.43, green: 0.39, blue: 0.29, alpha: 0.34),
            NSColor(calibratedRed: 0.30, green: 0.27, blue: 0.22, alpha: 0.34),
            NSColor(calibratedRed: 0.17, green: 0.18, blue: 0.16, alpha: 0.42)
        ],
        overlayColor: NSColor(calibratedWhite: 0.03, alpha: 0.10),
        separatorColor: NSColor(calibratedWhite: 1, alpha: 0.12)
    )

    static let light = SidebarBackdropPalette(
        gradientColors: [
            NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.94, alpha: 0.82),
            NSColor(calibratedRed: 0.94, green: 0.92, blue: 0.87, alpha: 0.78),
            NSColor(calibratedRed: 0.90, green: 0.87, blue: 0.81, alpha: 0.72)
        ],
        overlayColor: NSColor.white.withAlphaComponent(0.18),
        separatorColor: NSColor(calibratedWhite: 0, alpha: 0.10)
    )

    static let sepia = SidebarBackdropPalette(
        gradientColors: [
            NSColor(calibratedRed: 0.97, green: 0.92, blue: 0.82, alpha: 0.84),
            NSColor(calibratedRed: 0.91, green: 0.84, blue: 0.72, alpha: 0.78),
            NSColor(calibratedRed: 0.84, green: 0.75, blue: 0.60, alpha: 0.70)
        ],
        overlayColor: NSColor.white.withAlphaComponent(0.10),
        separatorColor: NSColor(calibratedWhite: 0, alpha: 0.12)
    )
}

private final class SidebarBackdropView: NSView {
    var palette = SidebarBackdropPalette.dark {
        didSet {
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSGradient(colors: palette.gradientColors)?.draw(in: bounds, angle: 245)

        palette.overlayColor.setFill()
        bounds.fill()

        let rightEdge = NSBezierPath(rect: NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height))
        palette.separatorColor.setFill()
        rightEdge.fill()
    }
}

private final class SidebarOutlineRowView: NSTableRowView {
    static var selectionColor = SidebarVisualStyle.dark.selectionColor

    override func drawBackground(in dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }

        let selectionRect = bounds.insetBy(dx: 0, dy: 1)
        let color = SidebarOutlineRowView.selectionColor
        color.withAlphaComponent(color.alphaComponent * (isEmphasized ? 1 : 0.72)).setFill()
        NSBezierPath(roundedRect: selectionRect, xRadius: 7, yRadius: 7).fill()
    }
}

private final class SidebarResizeHandle: NSView {
    var onDragBegan: ((CGFloat) -> Void)?
    var onDragged: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func mouseDown(with event: NSEvent) {
        onDragBegan?(NSEvent.mouseLocation.x)

        var shouldContinueTracking = true
        while shouldContinueTracking,
              let event = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            switch event.type {
            case .leftMouseDragged:
                onDragged?(NSEvent.mouseLocation.x)
            case .leftMouseUp:
                onDragEnded?()
                shouldContinueTracking = false
            default:
                break
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let separatorX = floor(bounds.midX) + 0.5
        let line = NSBezierPath()
        line.move(to: NSPoint(x: separatorX, y: bounds.minY))
        line.line(to: NSPoint(x: separatorX, y: bounds.maxY))
        NSColor.separatorColor.withAlphaComponent(0.18).setStroke()
        line.lineWidth = 1
        line.stroke()
    }
}

private enum ToolbarIdentifiers {
    static let toggleSidebar = NSToolbarItem.Identifier("TonMark.Toolbar.ToggleSidebar")
    static let quickOpen = NSToolbarItem.Identifier("TonMark.Toolbar.QuickOpen")
    static let workspaceSearch = NSToolbarItem.Identifier("TonMark.Toolbar.WorkspaceSearch")
    static let documentOutline = NSToolbarItem.Identifier("TonMark.Toolbar.DocumentOutline")
    static let newDocument = NSToolbarItem.Identifier("TonMark.Toolbar.NewDocument")
    static let openDocument = NSToolbarItem.Identifier("TonMark.Toolbar.OpenDocument")
    static let openWorkspace = NSToolbarItem.Identifier("TonMark.Toolbar.OpenWorkspace")
    static let saveDocument = NSToolbarItem.Identifier("TonMark.Toolbar.SaveDocument")
    static let exportDocument = NSToolbarItem.Identifier("TonMark.Toolbar.ExportDocument")
    static let appearance = NSToolbarItem.Identifier("TonMark.Toolbar.Appearance")
    static let togglePreview = NSToolbarItem.Identifier("TonMark.Toolbar.TogglePreview")
}

private enum WorkspaceSortMode: String, CaseIterable {
    case name
    case created
    case modified

    var title: String {
        switch self {
        case .name:
            return "按名称排序"
        case .created:
            return "按创建时间排序"
        case .modified:
            return "按修改时间排序"
        }
    }
}

private enum WorkspaceSortDirection: String {
    case ascending
    case descending

    var title: String {
        switch self {
        case .ascending:
            return "升序"
        case .descending:
            return "降序"
        }
    }
}

private final class FileCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    func configure(name: String, path: String, isFolder: Bool, isFavorite: Bool, style: SidebarVisualStyle = .dark) {
        let symbolName = isFolder ? "folder.fill" : "doc.text"
        nameLabel.stringValue = isFavorite ? "★ \(name)" : name
        pathLabel.stringValue = path
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: name)
        iconView.contentTintColor = isFavorite ? .systemYellow : (isFolder ? style.folderIcon : style.fileIcon)
        nameLabel.textColor = style.primaryText
        pathLabel.textColor = style.tertiaryText
    }

    private func build() {
        wantsLayer = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = SidebarVisualStyle.dark.primaryText
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = SidebarVisualStyle.dark.tertiaryText
        nameLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.lineBreakMode = .byTruncatingMiddle

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(pathLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),

            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            pathLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4)
        ])
    }
}
