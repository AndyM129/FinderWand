import Foundation
import AppKit
import FinderSync

/// Finder Sync 扩展主类（M3 slice 2：xbar 风格动态多级菜单）
/// 职责（沙箱内）：
///   1. 监控根目录，使右键菜单在任意路径出现
///   2. 右键时同步向主 App 请求「菜单规格」（主 App 跑脚本、解析输出后返回），据此构建多级菜单
///   3. 点击可执行项时，携带 actionId 通知主 App 执行对应动作
/// 说明：扩展不读插件目录、不执行脚本，全部交由非沙箱主 App，规避沙箱限制。
class FinderSync: FIFinderSync {

    /// 轮询响应文件的间隔（微秒）：fileExists 开销极小，间隔越短菜单出现越快
    private let pollInterval: useconds_t = 5_000

    override init() {
        super.init()
        refreshDirectoryURLs()
        observeVolumeChanges()
    }

    // MARK: - 监控目录注册

    /// 注册当前所有已挂载卷为监控目录。
    /// Finder Sync 的目录观察不跨卷边界：`/` 只覆盖启动卷，挂载在 /Volumes 下的
    /// 独立卷（外接盘、NAS 等网络卷）必须把各自的挂载点单独加入，右键菜单才会出现。
    private func refreshDirectoryURLs() {
        // mountedVolumeURLs 返回各卷挂载点（含 `/`、/Volumes/... 等）；
        // 再并上根卷兜底，directoryURLs 为 Set，天然去重。
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        ) ?? []

        FIFinderSyncController.default().directoryURLs = Set(mounted).union([URL(fileURLWithPath: "/")])
    }

    /// 监听卷的挂载/卸载，变化时重新注册监控目录，使 NAS 等插拔即时生效。
    private func observeVolumeChanges() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]
        for name in names {
            center.addObserver(
                self,
                selector: #selector(volumesChanged(_:)),
                name: name,
                object: nil)
        }
    }

    @objc private func volumesChanged(_ note: Notification) {
        refreshDirectoryURLs()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// 右键菜单：向主 App 请求菜单规格并构建
    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")

        let selected = (FIFinderSyncController.default().selectedItemURLs() ?? []).map { $0.path }
        let currentDir = currentDirectoryPath()

        guard let items = requestMenuSpec(currentDir: currentDir, selected: selected) else {
            // 无响应/超时：主 App 大概率未启动，给出引导文案
            menu.addItem(placeholderItem(title: "请先启动 FinderWand"))
            return menu
        }

        guard !items.isEmpty else {
            // 有响应但无菜单项：主 App 在运行，只是当前无插件输出可显示项
            menu.addItem(placeholderItem(title: "FinderWand（无可用菜单）"))
            return menu
        }

        appendItems(items, to: menu, isDark: Self.isDarkAppearance)
        return menu
    }

    /// 构造不可点击的占位菜单项
    private func placeholderItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - 请求菜单规格

    /// 写构建请求、通知主 App、轮询响应，返回菜单项数组
    private func requestMenuSpec(currentDir: String, selected: [String]) -> [[String: Any]]? {
        let containerData = URL(fileURLWithPath: NSHomeDirectory())
        let requestId = UUID().uuidString

        let requestsDir = FWIPC.buildRequestsDirectory(containerDataDirectory: containerData)
        let responsesDir = FWIPC.buildResponsesDirectory(containerDataDirectory: containerData)
        let requestURL = requestsDir.appendingPathComponent("\(requestId).json")
        let responseURL = responsesDir.appendingPathComponent("\(requestId).json")

        let request: [String: Any] = [
            "id": requestId,
            "currentDir": currentDir,
            "selected": selected
        ]

        do {
            try FileManager.default.createDirectory(at: requestsDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: responsesDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: request, options: [])
            // 原子写入，避免主 App 读到半截请求
            try data.write(to: requestURL, options: .atomic)
        } catch {
            NSLog("FinderWand 扩展: 写构建请求失败 \(error.localizedDescription)")
            return nil
        }

        postDarwinNotification(FWIPC.darwinBuildName)

        let items = waitForResponse(at: responseURL)
        if items == nil {
            // 超时：撤回尚未被主 App 取走的请求，主 App 未运行时不留积压
            try? FileManager.default.removeItem(at: requestURL)
        }

        return items
    }

    /// 轮询等待主 App 写出的响应文件
    private func waitForResponse(at responseURL: URL) -> [[String: Any]]? {
        let deadline = Date().addingTimeInterval(FWIPC.buildTimeout)

        while Date() < deadline {
            if FileManager.default.fileExists(atPath: responseURL.path) {
                defer { try? FileManager.default.removeItem(at: responseURL) }
                guard
                    let data = try? Data(contentsOf: responseURL),
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    return nil
                }

                return object["items"] as? [[String: Any]]
            }
            usleep(pollInterval)
        }

        return nil
    }

    // MARK: - 构建菜单

    /// 递归把菜单项数组添加到菜单
    private func appendItems(_ items: [[String: Any]], to menu: NSMenu, isDark: Bool) {
        for item in items {
            if item["separator"] as? Bool == true {
                // Finder Sync 右键菜单不支持原生分隔线（NSMenuItem.separator 会显示为空行），
                // 仅用受支持的 title+enabled 属性，以一行短横线模拟。
                let separator = NSMenuItem(title: "----------", action: nil, keyEquivalent: "")
                separator.isEnabled = false
                menu.addItem(separator)
                continue
            }

            let title = item["title"] as? String ?? ""
            let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let isEnabled = (item["enabled"] as? Bool) != false

            if let children = item["children"] as? [[String: Any]], !children.isEmpty {
                let submenu = NSMenu(title: title)
                appendItems(children, to: submenu, isDark: isDark)
                menuItem.submenu = submenu
            } else if let actionId = item["actionId"] as? Int {
                menuItem.action = #selector(runAction(_:))
                menuItem.target = self
                menuItem.tag = actionId
            }

            // disabled=true → 置灰（Finder Sync 支持 enabled 属性）
            if !isEnabled {
                menuItem.isEnabled = false
            }

            // 图标：按当前深浅色着色；禁用项图标同步变暗，与置灰标题一致
            if let symbol = item["sfimage"] as? String {
                menuItem.image = Self.tintedSymbol(symbol, accessibilityDescription: title, enabled: isEnabled, isDark: isDark)
            }

            menu.addItem(menuItem)
        }
    }

    /// 当前系统是否为深色外观
    private static var isDarkAppearance: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
    }

    /// 生成按当前系统深浅色着色的 SF Symbol 图标（禁用项变暗）
    private static func tintedSymbol(_ name: String, accessibilityDescription: String, enabled: Bool, isDark: Bool) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription) else {
            return nil
        }

        var color: NSColor = isDark ? .white : .black
        if !enabled {
            // 与置灰标题保持一致：降低不透明度
            color = color.withAlphaComponent(0.35)
        }

        let configuration = NSImage.SymbolConfiguration(paletteColors: [color])
        let tinted = base.withSymbolConfiguration(configuration) ?? base
        tinted.isTemplate = false
        return tinted
    }

    // MARK: - 执行动作

    /// 点击可执行项：携带 actionId 通知主 App 执行
    @objc func runAction(_ sender: NSMenuItem) {
        let actionId = sender.tag
        guard actionId != 0 else { return }

        let containerData = URL(fileURLWithPath: NSHomeDirectory())
        let actionsDir = FWIPC.actionRequestsDirectory(containerDataDirectory: containerData)

        do {
            try FileManager.default.createDirectory(at: actionsDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["actionId": actionId], options: [])
            try data.write(to: actionsDir.appendingPathComponent("\(UUID().uuidString).json"), options: .atomic)
        } catch {
            NSLog("FinderWand 扩展: 写动作请求失败 \(error.localizedDescription)")
            return
        }

        postDarwinNotification(FWIPC.darwinActionName)
    }

    // MARK: - 辅助

    /// 推断「当前所在目录」：目标是目录则取目标，否则取其父目录
    private func currentDirectoryPath() -> String {
        guard let targeted = FIFinderSyncController.default().targetedURL() else { return "" }

        let isDirectory = (try? targeted.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        return isDirectory ? targeted.path : targeted.deletingLastPathComponent().path
    }

    /// 发送 Darwin 通知
    private func postDarwinNotification(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true)
    }
}
