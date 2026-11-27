import AppKit
import UniformTypeIdentifiers

/// 菜单栏控制器
/// 负责创建并管理菜单栏状态项（NSStatusItem）及其下拉菜单与菜单动作。
final class MenuBarController: NSObject {

    /// 菜单栏状态项，需强引用持有，否则会被释放导致图标消失
    private let statusItem: NSStatusItem

    /// 插件详情窗口控制器（打开时强引用持有，关闭后释放）
    private var detailWindowController: PluginDetailWindowController?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()

        // 菜单设为持久实例并设代理，每次打开前重新填充，保证插件启用态等动态信息实时
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        populateMenu(menu)
    }

    /// 配置菜单栏按钮图标
    private func configureButton() {
        guard let button = statusItem.button else { return }

        // 优先使用资源目录中的品牌模板图标（随深浅色自适应），找不到再回退系统符号
        if let icon = NSImage(named: "MenuBarIconTemplate") {
            icon.isTemplate = true
            button.image = icon
        } else {
            button.image = NSImage(systemSymbolName: "wand.and.stars",
                                   accessibilityDescription: "FinderWand")
        }
    }

    /// 填充下拉菜单（清空后重建），每次菜单打开前调用以保证动态信息实时
    /// 菜单项：打开插件目录、已安装插件、安装插件、新建插件、分割线、版本号、检查更新、开机自动运行、关于、分割线、退出。
    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(actionItem(title: "打开插件目录",
                                action: #selector(openPluginDirectory)))

        // 已安装插件：列出各插件的标题、版本、启用态等信息
        menu.addItem(installedPluginsMenuItem())

        // 安装插件：三种来源
        let installParent = NSMenuItem(title: "安装插件", action: nil, keyEquivalent: "")
        let installMenu = NSMenu()
        installMenu.addItem(actionItem(title: "从插件市场安装", action: #selector(installFromMarket)))
        installMenu.addItem(actionItem(title: "从指定插件仓库安装", action: #selector(installFromRepo)))
        installMenu.addItem(actionItem(title: "从指定目录导入并安装", action: #selector(importPluginFromDirectory)))
        installParent.submenu = installMenu
        menu.addItem(installParent)

        menu.addItem(actionItem(title: "新建自定义插件",
                                action: #selector(newPluginFromTemplate)))

        menu.addItem(.separator())

        // 版本号：点击打开当前版本的 Release 页
        menu.addItem(actionItem(title: AppInfo.displayVersion,
                                action: #selector(openReleasePage)))

        menu.addItem(actionItem(title: "检查更新",
                                action: #selector(checkForUpdates)))

        // 开机自动运行：勾选态反映当前状态
        let launchItem = actionItem(title: "开机自动运行",
                                    action: #selector(toggleLaunchAtLogin))
        launchItem.state = LoginItemManager.shared.isEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(actionItem(title: "关于 FinderWand",
                                action: #selector(openAbout)))

        menu.addItem(.separator())

        menu.addItem(actionItem(title: "退出 FinderWand",
                                action: #selector(quit),
                                keyEquivalent: "q"))
    }

    /// 构建一个以 self 为 target 的菜单项
    private func actionItem(title: String,
                            action: Selector,
                            keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    // MARK: - 已安装插件

    /// 「已安装插件」子菜单：展示每个插件的标题、id、版本、作者、标签、启用态与简介，并可在 Finder 中显示
    private func installedPluginsMenuItem() -> NSMenuItem {
        let plugins = PluginService.shared.installedPlugins()

        let parent = NSMenuItem(title: "已安装插件（\(plugins.count)）", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        guard !plugins.isEmpty else {
            let empty = NSMenuItem(title: "暂无插件", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            parent.submenu = submenu
            return parent
        }

        for plugin in plugins {
            submenu.addItem(pluginItem(for: plugin))
        }

        parent.submenu = submenu
        return parent
    }

    /// 单个插件项：标题带启用勾选态，子菜单展示详情与「在 Finder 中显示」
    private func pluginItem(for plugin: PluginService.InstalledPlugin) -> NSMenuItem {
        let metadata = plugin.metadata
        let title = metadata.title ?? plugin.id

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        // 勾选态反映是否启用
        item.state = metadata.enabled ? .on : .off
        // 插件图标（iconUrl，网络图缓存 / 文件夹内相对图）
        item.image = PluginIconLoader.menuIcon(for: plugin)

        let detail = NSMenu()
        addInfoItem(to: detail, "ID", plugin.id)
        if let version = metadata.version { addInfoItem(to: detail, "版本", version) }
        if let author = metadata.author { addInfoItem(to: detail, "作者", author) }
        if !metadata.tags.isEmpty { addInfoItem(to: detail, "标签", metadata.tags.joined(separator: ", ")) }
        addInfoItem(to: detail, "状态", metadata.enabled ? "已启用" : "已停用")
        if let description = metadata.pluginDescription { addInfoItem(to: detail, "简介", description) }

        detail.addItem(.separator())

        // 查看详情：图标、简介、预览图、作者等
        let detailItem = NSMenuItem(title: "查看详情",
                                    action: #selector(showPluginDetail(_:)),
                                    keyEquivalent: "")
        detailItem.target = self
        detailItem.representedObject = plugin
        detail.addItem(detailItem)

        // 查看说明：插件目录存在 README.md 时才提供
        let readmeURL = plugin.entryURL.deletingLastPathComponent().appendingPathComponent("README.md")
        if FileManager.default.fileExists(atPath: readmeURL.path) {
            let readmeItem = NSMenuItem(title: "查看说明",
                                        action: #selector(openPluginReadme(_:)),
                                        keyEquivalent: "")
            readmeItem.target = self
            readmeItem.representedObject = readmeURL
            detail.addItem(readmeItem)
        }

        let openItem = NSMenuItem(title: "在 Finder 中显示",
                                  action: #selector(openPluginFolder(_:)),
                                  keyEquivalent: "")
        openItem.target = self
        openItem.representedObject = plugin.entryURL.deletingLastPathComponent()
        detail.addItem(openItem)

        detail.addItem(.separator())

        // 快速切换启用/停用
        let toggleItem = NSMenuItem(title: metadata.enabled ? "停用该插件" : "启用该插件",
                                    action: #selector(togglePluginEnabled(_:)),
                                    keyEquivalent: "")
        toggleItem.target = self
        toggleItem.representedObject = plugin.entryURL
        detail.addItem(toggleItem)
        
        // 导出为 zip（分享）
        let exportItem = NSMenuItem(title: "导出为 zip…",
                                    action: #selector(exportPlugin(_:)),
                                    keyEquivalent: "")
        exportItem.target = self
        exportItem.representedObject = plugin.entryURL.deletingLastPathComponent()
        detail.addItem(exportItem)

        detail.addItem(.separator())

        // 卸载（移到废纸篓）
        let uninstallItem = NSMenuItem(title: "卸载插件…",
                                       action: #selector(uninstallPlugin(_:)),
                                       keyEquivalent: "")
        uninstallItem.target = self
        uninstallItem.representedObject = plugin.entryURL.deletingLastPathComponent()
        detail.addItem(uninstallItem)

        item.submenu = detail
        return item
    }

    /// 向菜单追加一条不可点击的「键: 值」信息项
    private func addInfoItem(to menu: NSMenu, _ key: String, _ value: String) {
        let item = NSMenuItem(title: "\(key): \(value)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    // MARK: - 菜单动作

    /// 打开插件目录（不存在则自动创建）
    @objc private func openPluginDirectory() {
        let directory = AppInfo.pluginDirectory
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        } catch {
            NSLog("创建插件目录失败: \(error.localizedDescription)")
        }
        NSWorkspace.shared.open(directory)
    }

    /// 新建插件：优先从插件市场拉取最新 TemplatePlugin，失败则回退到内置模板
    @objc private func newPluginFromTemplate() {
        UserNotifier.notify(title: "FinderWand", body: "正在获取最新模板…")

        DispatchQueue.global().async {
            let result = PluginInstaller.fetchFromMarket(id: "TemplatePlugin")
            DispatchQueue.main.async {
                switch result {
                case let .success(stagedURL, _, _):
                    self.placeNewPlugin(source: stagedURL, isTemp: true)

                case .failure:
                    self.newPluginFromBundledTemplate()
                }
            }
        }
    }

    /// 使用 App 内置模板新建插件（市场拉取失败时的回退）
    private func newPluginFromBundledTemplate() {
        guard let template = Bundle.main.url(forResource: "TemplatePlugin", withExtension: nil) else {
            UserNotifier.notify(title: "FinderWand", body: "⚠️ 未找到内置插件模板")
            return
        }

        placeNewPlugin(source: template, isTemp: false)
    }

    /// 把模板文件夹放入插件目录（同名则加时间戳后缀），通知并打开
    /// isTemp 为真时来源是临时暂存目录，用移动并清理；否则用拷贝
    private func placeNewPlugin(source: URL, isTemp: Bool) {
        let directory = AppInfo.pluginDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let baseName = source.lastPathComponent
        var destination = directory.appendingPathComponent(baseName, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(baseName)-\(timestampSuffix())", isDirectory: true)
        }

        do {
            if isTemp {
                try FileManager.default.moveItem(at: source, to: destination)
            } else {
                try FileManager.default.copyItem(at: source, to: destination)
            }
        } catch {
            UserNotifier.notify(title: "FinderWand", body: "⚠️ 新建插件失败：\(error.localizedDescription)")
            if isTemp { PluginInstaller.cleanup(source.deletingLastPathComponent()) }
            return
        }

        if isTemp { PluginInstaller.cleanup(source.deletingLastPathComponent()) }

        UserNotifier.notify(title: "FinderWand", body: "✨ 已新建插件「\(destination.lastPathComponent)」")
        NSWorkspace.shared.open(destination)

        if let menu = statusItem.menu { populateMenu(menu) }
    }

    /// 生成用于文件夹去重的时间戳后缀（形如 20260719131005）
    private func timestampSuffix() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: Date())
    }

    // MARK: - 安装插件

    /// 从插件市场安装：输入 id，从市场仓库拉取
    @objc private func installFromMarket() {
        guard let id = promptInstallInput(title: "从插件市场安装",
                                          subtitle: "请输入插件市场中要安装插件的 ID",
                                          placeholder: "插件 ID") else { return }

        UserNotifier.notify(title: "FinderWand", body: "正在从插件市场获取「\(id)」…")
        runFetch { PluginInstaller.fetchFromMarket(id: id) }
    }

    /// 从指定插件仓库安装：拉取整仓，落地文件夹名为仓库名
    @objc private func installFromRepo() {
        guard let input = promptInstallInput(title: "从指定插件仓库安装",
                                            subtitle: "请输入插件仓库地址（owner/repo 或完整 GitHub 地址）",
                                            placeholder: "owner/repo") else { return }

        UserNotifier.notify(title: "FinderWand", body: "正在拉取仓库「\(input)」…")
        runFetch { PluginInstaller.fetchFromRepo(input: input) }
    }

    /// 从指定目录导入并安装：选择本地目录拷贝到插件目录
    @objc private func importPluginFromDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "导入"
        panel.message = "选择要导入的插件目录"

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let source = panel.url else { return }

        UserNotifier.notify(title: "FinderWand", body: "正在导入「\(source.lastPathComponent)」…")
        runFetch { PluginInstaller.importFromDirectory(source) }
    }

    /// 弹出带输入框的对话框，返回去空白后的非空输入，取消或空返回 nil
    private func promptInstallInput(title: String, subtitle: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = subtitle

        let input = EditableTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = placeholder
        alert.accessoryView = input
        alert.addButton(withTitle: "安装")
        alert.addButton(withTitle: "取消")

        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let value = input.stringValue.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// 后台执行拉取校验，回主线程处理结果
    private func runFetch(_ fetch: @escaping () -> PluginInstaller.FetchResult) {
        DispatchQueue.global().async {
            let result = fetch()
            DispatchQueue.main.async { self.handleFetchResult(result) }
        }
    }

    /// 处理拉取与校验结果
    private func handleFetchResult(_ result: PluginInstaller.FetchResult) {
        switch result {
        case .failure(let message):
            UserNotifier.notify(title: "FinderWand", body: "⚠️ \(message)")

        case let .success(stagedURL, id, alreadyInstalled):
            if alreadyInstalled {
                promptConflict(stagedURL: stagedURL, id: id)
            } else {
                applyInstall(id: id) { PluginInstaller.installFresh(stagedURL: stagedURL, id: id) }
            }
        }
    }

    /// 插件已存在时的三选一处理
    private func promptConflict(stagedURL: URL, id: String) {
        let alert = NSAlert()
        alert.messageText = "插件「\(id)」已安装"
        alert.informativeText = "请选择处理方式：备份后安装会先把现有插件压缩备份再整体替换；覆盖安装仅覆盖同名文件、保留其它文件。"
        alert.addButton(withTitle: "备份后安装")
        alert.addButton(withTitle: "覆盖安装")
        alert.addButton(withTitle: "取消")

        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            applyInstall(id: id) { PluginInstaller.backupThenReplace(stagedURL: stagedURL, id: id) }

        case .alertSecondButtonReturn:
            applyInstall(id: id) { PluginInstaller.overlayInstall(stagedURL: stagedURL, id: id) }

        default:
            PluginInstaller.cleanup(stagedURL.deletingLastPathComponent())
        }
    }

    /// 在后台执行写盘操作，回主线程通知并刷新菜单
    private func applyInstall(id: String, _ operation: @escaping () -> Bool) {
        DispatchQueue.global().async {
            let succeeded = operation()
            DispatchQueue.main.async {
                if succeeded {
                    UserNotifier.notify(title: "FinderWand", body: "✅ 已安装插件「\(id)」")
                    if let menu = self.statusItem.menu { self.populateMenu(menu) }
                } else {
                    UserNotifier.notify(title: "FinderWand", body: "⚠️ 安装插件「\(id)」失败")
                }
            }
        }
    }

    @objc private func openPluginFolder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }

        NSWorkspace.shared.open(url)
    }

    /// 打开某插件的 README.md 使用说明
    @objc private func openPluginReadme(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }

        NSWorkspace.shared.open(url)
    }

    /// 打开插件详情窗口
    @objc private func showPluginDetail(_ sender: NSMenuItem) {
        guard let plugin = sender.representedObject as? PluginService.InstalledPlugin else { return }

        let controller = PluginDetailWindowController(plugin: plugin)
        detailWindowController = controller
        controller.show { [weak self] in self?.detailWindowController = nil }
    }

    /// 导出插件为 zip 到用户选择的位置（分享）
    @objc private func exportPlugin(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? URL else { return }

        let id = folder.lastPathComponent
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(id).zip"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.zip]
        panel.message = "导出插件「\(id)」为 zip"

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        DispatchQueue.global().async {
            let succeeded = PluginInstaller.exportZip(folder: folder, to: destination)
            DispatchQueue.main.async {
                if succeeded {
                    UserNotifier.notify(title: "FinderWand", body: "✅ 已导出插件「\(id)」")
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                } else {
                    UserNotifier.notify(title: "FinderWand", body: "⚠️ 导出插件「\(id)」失败")
                }
            }
        }
    }

    /// 卸载插件：确认后把插件文件夹移到废纸篓
    @objc private func uninstallPlugin(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? URL else { return }

        let id = folder.lastPathComponent
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "卸载插件「\(id)」？"
        alert.informativeText = "将把该插件文件夹移到废纸篓，可从废纸篓恢复。"
        alert.addButton(withTitle: "卸载")
        alert.addButton(withTitle: "取消")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        DispatchQueue.global().async {
            var succeeded = false
            do {
                try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
                succeeded = true
            } catch {
                NSLog("卸载插件失败: \(error.localizedDescription)")
            }

            DispatchQueue.main.async {
                if succeeded {
                    UserNotifier.notify(title: "FinderWand", body: "🗑️ 已卸载插件「\(id)」")
                    if let menu = self.statusItem.menu { self.populateMenu(menu) }
                } else {
                    UserNotifier.notify(title: "FinderWand", body: "⚠️ 卸载插件「\(id)」失败")
                }
            }
        }
    }

    /// 快速切换某插件的启用/停用（改写其 main.sh 头部的 enabled 字段）
    @objc private func togglePluginEnabled(_ sender: NSMenuItem) {
        guard let entryURL = sender.representedObject as? URL else { return }

        let metadata = PluginMetadataStore.metadata(forEntry: entryURL)
        let name = metadata.title ?? entryURL.deletingLastPathComponent().lastPathComponent
        let target = !metadata.enabled

        let succeeded = PluginMetadataStore.setEnabled(target, forEntry: entryURL)
        if succeeded {
            UserNotifier.notify(title: "FinderWand",
                                body: "\(target ? "🟢 已启用" : "🔴 已停用")插件「\(name)」")
        } else {
            UserNotifier.notify(title: "FinderWand",
                                body: "⚠️ 切换插件「\(name)」失败，请检查文件权限")
        }

        if let menu = statusItem.menu { populateMenu(menu) }
    }

    /// 关于：在浏览器打开项目 GitHub 主页
    @objc private func openAbout() {
        NSWorkspace.shared.open(AppInfo.repositoryURL)
    }

    /// 版本号：在浏览器打开当前版本的 Release 页
    @objc private func openReleasePage() {
        NSWorkspace.shared.open(AppInfo.releaseURL)
    }

    /// 检查更新：查询 GitHub 最新正式版并提示
    @objc private func checkForUpdates() {
        UpdateChecker.shared.check { [weak self] result in
            self?.presentUpdateResult(result)
        }
    }

    /// 展示检查更新结果
    private func presentUpdateResult(_ result: UpdateCheckResult) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        switch result {
        case .upToDate:
            alert.messageText = "已是最新版本"
            alert.informativeText = "当前版本 \(AppInfo.displayVersion) 已是最新。"
            alert.addButton(withTitle: "好")
            alert.runModal()

        case .failed(let message):
            alert.messageText = "检查更新失败"
            alert.informativeText = message
            alert.addButton(withTitle: "好")
            alert.runModal()

        case let .updateAvailable(version, notes, downloadURL, pageURL):
            alert.messageText = "发现新版本 v\(version)"
            alert.informativeText = notes.isEmpty ? "有可用更新。" : notes
            alert.addButton(withTitle: downloadURL != nil ? "下载安装包" : "打开发布页")
            alert.addButton(withTitle: "查看发布页")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                NSWorkspace.shared.open(downloadURL ?? pageURL)
            case .alertSecondButtonReturn:
                NSWorkspace.shared.open(pageURL)
            default:
                break
            }
        }
    }

    /// 切换开机自动运行
    @objc private func toggleLaunchAtLogin() {
        LoginItemManager.shared.toggle()
        if let menu = statusItem.menu { populateMenu(menu) }
    }

    /// 退出应用
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {

    /// 菜单每次打开前重新填充，保证插件启用态、版本、开机自启勾选等动态信息实时
    func menuNeedsUpdate(_ menu: NSMenu) {
        populateMenu(menu)
    }
}

/// 支持标准编辑快捷键（剪切/复制/粘贴/全选）的输入框
/// 菜单栏 App（LSUIElement）没有主菜单，`NSAlert` 里的普通 `NSTextField` 收不到 Cmd+V 等快捷键，
/// 这里通过 `performKeyEquivalent` 手动派发编辑动作以支持粘贴。
final class EditableTextField: NSTextField {

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isCommand = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        if event.type == .keyDown, isCommand {
            switch event.charactersIgnoringModifiers {
            case "x": if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "c": if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "v": if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "a": if NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: self) { return true }
            default: break
            }
        }

        return super.performKeyEquivalent(with: event)
    }
}
