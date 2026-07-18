import AppKit

/// 菜单栏控制器
/// 负责创建并管理菜单栏状态项（NSStatusItem）及其下拉菜单与菜单动作。
final class MenuBarController: NSObject {

    /// 菜单栏状态项，需强引用持有，否则会被释放导致图标消失
    private let statusItem: NSStatusItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        rebuildMenu()
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
                                   accessibilityDescription: "Finder Wand")
        }
    }

    /// 重建下拉菜单
    /// 菜单项：刷新、打开插件目录、分割线、版本号、检查更新、开机自动运行、关于、分割线、退出。
    private func rebuildMenu() {
        let menu = NSMenu()

        menu.addItem(actionItem(title: "刷新",
                                action: #selector(refresh),
                                keyEquivalent: "r"))
        menu.addItem(actionItem(title: "打开插件目录",
                                action: #selector(openPluginDirectory)))

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

        menu.addItem(actionItem(title: "关于 Finder Wand",
                                action: #selector(openAbout)))

        menu.addItem(.separator())

        menu.addItem(actionItem(title: "退出 Finder Wand",
                                action: #selector(quit),
                                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    /// 构建一个以 self 为 target 的菜单项
    private func actionItem(title: String,
                            action: Selector,
                            keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    // MARK: - 菜单动作

    /// 刷新：重新加载配置并重建菜单
    /// M2 阶段暂无插件配置，先重建菜单占位，后续里程碑接入插件加载。
    @objc private func refresh() {
        rebuildMenu()
    }

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
        rebuildMenu()
    }

    /// 退出应用
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
