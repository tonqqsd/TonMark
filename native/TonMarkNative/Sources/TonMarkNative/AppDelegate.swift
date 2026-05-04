import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var editorWindowController: EditorWindowController?
    private let recentMenu = NSMenu(title: "Open Recent")

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        let controller = EditorWindowController()
        controller.recentFilesDidChange = { [weak self] in
            self?.rebuildRecentMenu()
        }
        editorWindowController = controller
        rebuildRecentMenu()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        editorWindowController?.applicationShouldTerminate(sender) ?? .terminateNow
    }

    @objc private func newDocument(_ sender: Any?) {
        editorWindowController?.newDocument()
    }

    @objc private func openDocument(_ sender: Any?) {
        editorWindowController?.openDocument()
    }

    @objc private func openWorkspace(_ sender: Any?) {
        editorWindowController?.openWorkspace()
    }

    @objc private func quickOpen(_ sender: Any?) {
        editorWindowController?.showQuickOpen()
    }

    @objc private func workspaceSearch(_ sender: Any?) {
        editorWindowController?.showWorkspaceSearch()
    }

    @objc private func openRecentFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        editorWindowController?.openRecentFile(path)
    }

    @objc private func clearRecentFiles(_ sender: Any?) {
        editorWindowController?.clearRecentFiles()
    }

    @objc private func saveDocument(_ sender: Any?) {
        editorWindowController?.saveDocument()
    }

    @objc private func saveDocumentAs(_ sender: Any?) {
        editorWindowController?.saveDocumentAs()
    }

    @objc private func exportHTML(_ sender: Any?) {
        editorWindowController?.exportHTML()
    }

    @objc private func exportPDF(_ sender: Any?) {
        editorWindowController?.exportPDF()
    }

    @objc private func setThemeSystem(_ sender: Any?) {
        editorWindowController?.setTheme("system")
    }

    @objc private func setThemeLight(_ sender: Any?) {
        editorWindowController?.setTheme("light")
    }

    @objc private func setThemeDark(_ sender: Any?) {
        editorWindowController?.setTheme("dark")
    }

    @objc private func setThemeSepia(_ sender: Any?) {
        editorWindowController?.setTheme("sepia")
    }

    @objc private func increaseEditorFontSize(_ sender: Any?) {
        editorWindowController?.adjustFontSize(by: 1)
    }

    @objc private func decreaseEditorFontSize(_ sender: Any?) {
        editorWindowController?.adjustFontSize(by: -1)
    }

    @objc private func increaseEditorLineHeight(_ sender: Any?) {
        editorWindowController?.adjustLineHeight(by: 0.05)
    }

    @objc private func decreaseEditorLineHeight(_ sender: Any?) {
        editorWindowController?.adjustLineHeight(by: -0.05)
    }

    @objc private func resetEditorTypography(_ sender: Any?) {
        editorWindowController?.resetTypography()
    }

    @objc private func copyChapterBody(_ sender: Any?) {
        editorWindowController?.copyChapterBody()
    }

    @objc private func saveSnapshot(_ sender: Any?) {
        editorWindowController?.saveSnapshot()
    }

    @objc private func showSnapshotHistory(_ sender: Any?) {
        editorWindowController?.showSnapshotHistory()
    }

    @objc private func toggleFileTree(_ sender: Any?) {
        editorWindowController?.toggleFileTree()
    }

    @objc private func togglePreview(_ sender: Any?) {
        editorWindowController?.togglePreview()
    }

    @objc private func showDocumentOutline(_ sender: Any?) {
        editorWindowController?.showDocumentOutline()
    }

    @objc private func showSettings(_ sender: Any?) {
        editorWindowController?.showSettings()
    }

    @objc private func toggleFocusMode(_ sender: Any?) {
        editorWindowController?.toggleFocusMode()
    }

    @objc private func toggleTypewriterMode(_ sender: Any?) {
        editorWindowController?.toggleTypewriterMode()
    }

    @objc private func findInDocument(_ sender: Any?) {
        editorWindowController?.showFindPanel()
    }

    @objc private func replaceInDocument(_ sender: Any?) {
        editorWindowController?.showReplacePanel()
    }

    @objc private func findNext(_ sender: Any?) {
        editorWindowController?.findNext()
    }

    @objc private func findPrevious(_ sender: Any?) {
        editorWindowController?.findPrevious()
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 TonMark", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        addAppMenuItem(to: appMenu, title: "偏好设置...", action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 TonMark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        addAppMenuItem(to: fileMenu, title: "新建", action: #selector(newDocument(_:)), keyEquivalent: "n")
        addAppMenuItem(to: fileMenu, title: "打开...", action: #selector(openDocument(_:)), keyEquivalent: "o")
        let openRecentItem = NSMenuItem(title: "打开最近使用", action: nil, keyEquivalent: "")
        openRecentItem.submenu = recentMenu
        fileMenu.addItem(openRecentItem)
        addAppMenuItem(to: fileMenu, title: "快速打开...", action: #selector(quickOpen(_:)), keyEquivalent: "p")
        addAppMenuItem(to: fileMenu, title: "打开文件夹...", action: #selector(openWorkspace(_:)), keyEquivalent: "o", modifiers: [.command, .shift])
        fileMenu.addItem(.separator())
        addAppMenuItem(to: fileMenu, title: "保存", action: #selector(saveDocument(_:)), keyEquivalent: "s")
        addAppMenuItem(to: fileMenu, title: "另存为...", action: #selector(saveDocumentAs(_:)), keyEquivalent: "s", modifiers: [.command, .shift])
        addAppMenuItem(to: fileMenu, title: "保存快照", action: #selector(saveSnapshot(_:)), keyEquivalent: "s", modifiers: [.command, .option])
        addAppMenuItem(to: fileMenu, title: "版本历史...", action: #selector(showSnapshotHistory(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        addAppMenuItem(to: fileMenu, title: "导出 HTML...", action: #selector(exportHTML(_:)), keyEquivalent: "")
        addAppMenuItem(to: fileMenu, title: "导出 PDF...", action: #selector(exportPDF(_:)), keyEquivalent: "")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z").keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        addAppMenuItem(to: editMenu, title: "复制章节正文", action: #selector(copyChapterBody(_:)), keyEquivalent: "c", modifiers: [.command, .option])
        editMenu.addItem(.separator())
        addAppMenuItem(to: editMenu, title: "查找...", action: #selector(findInDocument(_:)), keyEquivalent: "f")
        addAppMenuItem(to: editMenu, title: "工作区全文搜索...", action: #selector(workspaceSearch(_:)), keyEquivalent: "f", modifiers: [.command, .shift])
        addAppMenuItem(to: editMenu, title: "查找下一个", action: #selector(findNext(_:)), keyEquivalent: "g")
        addAppMenuItem(to: editMenu, title: "查找上一个", action: #selector(findPrevious(_:)), keyEquivalent: "g", modifiers: [.command, .shift])
        addAppMenuItem(to: editMenu, title: "替换...", action: #selector(replaceInDocument(_:)), keyEquivalent: "f", modifiers: [.command, .option])
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "视图")
        addAppMenuItem(to: viewMenu, title: "显示/隐藏文件树", action: #selector(toggleFileTree(_:)), keyEquivalent: "\\")
        addAppMenuItem(to: viewMenu, title: "显示/隐藏大纲", action: #selector(showDocumentOutline(_:)), keyEquivalent: "o", modifiers: [.command, .option])
        addAppMenuItem(to: viewMenu, title: "偏好设置...", action: #selector(showSettings(_:)), keyEquivalent: "")
        viewMenu.addItem(makeSubmenuItem(title: "主题", menu: makeThemeMenu()))
        viewMenu.addItem(makeSubmenuItem(title: "排版", menu: makeFormatMenu()))
        viewMenu.addItem(.separator())
        addAppMenuItem(to: viewMenu, title: "专注模式", action: #selector(toggleFocusMode(_:)), keyEquivalent: "")
        addAppMenuItem(to: viewMenu, title: "打字机模式", action: #selector(toggleTypewriterMode(_:)), keyEquivalent: "")
        addAppMenuItem(to: viewMenu, title: "切换编辑模式", action: #selector(togglePreview(_:)), keyEquivalent: "p", modifiers: [.command, .option])
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let themeItem = NSMenuItem()
        themeItem.submenu = makeThemeMenu()
        mainMenu.addItem(themeItem)

        let formatItem = NSMenuItem()
        formatItem.submenu = makeFormatMenu()
        mainMenu.addItem(formatItem)

        NSApp.mainMenu = mainMenu
    }

    private func makeThemeMenu() -> NSMenu {
        let themeMenu = NSMenu(title: "主题")
        addAppMenuItem(to: themeMenu, title: "跟随系统", action: #selector(setThemeSystem(_:)), keyEquivalent: "")
        addAppMenuItem(to: themeMenu, title: "浅色", action: #selector(setThemeLight(_:)), keyEquivalent: "")
        addAppMenuItem(to: themeMenu, title: "深色", action: #selector(setThemeDark(_:)), keyEquivalent: "")
        addAppMenuItem(to: themeMenu, title: "暖纸", action: #selector(setThemeSepia(_:)), keyEquivalent: "")
        return themeMenu
    }

    private func makeFormatMenu() -> NSMenu {
        let formatMenu = NSMenu(title: "格式")
        addAppMenuItem(to: formatMenu, title: "增大字体", action: #selector(increaseEditorFontSize(_:)), keyEquivalent: "=", modifiers: [.command])
        addAppMenuItem(to: formatMenu, title: "减小字体", action: #selector(decreaseEditorFontSize(_:)), keyEquivalent: "-", modifiers: [.command])
        formatMenu.addItem(.separator())
        addAppMenuItem(to: formatMenu, title: "增大行高", action: #selector(increaseEditorLineHeight(_:)), keyEquivalent: "=", modifiers: [.command, .option])
        addAppMenuItem(to: formatMenu, title: "减小行高", action: #selector(decreaseEditorLineHeight(_:)), keyEquivalent: "-", modifiers: [.command, .option])
        addAppMenuItem(to: formatMenu, title: "恢复默认排版", action: #selector(resetEditorTypography(_:)), keyEquivalent: "0", modifiers: [.command, .option])
        return formatMenu
    }

    private func makeSubmenuItem(title: String, menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @discardableResult
    private func addAppMenuItem(
        to menu: NSMenu,
        title: String,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.keyEquivalentModifierMask = keyEquivalent.isEmpty ? [] : modifiers
        menu.addItem(item)
        return item
    }

    private func rebuildRecentMenu() {
        recentMenu.removeAllItems()

        guard let items = editorWindowController?.recentFileMenuItems(), !items.isEmpty else {
            let emptyItem = NSMenuItem(title: "没有最近文件", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            recentMenu.addItem(emptyItem)
            return
        }

        items.forEach { item in
            let menuItem = NSMenuItem(title: item.title, action: #selector(openRecentFile(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.path
            menuItem.toolTip = item.path
            recentMenu.addItem(menuItem)
        }

        recentMenu.addItem(.separator())
        let clearItem = NSMenuItem(title: "清除列表", action: #selector(clearRecentFiles(_:)), keyEquivalent: "")
        clearItem.target = self
        recentMenu.addItem(clearItem)
    }
}
